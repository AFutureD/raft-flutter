# Unexpected sign-out audit (2026-10-12)

Rule: **the session ends only when the server definitively says the credentials are invalid.** Everything else keeps the session and its stored credentials, shows a non-destructive state, and retries with backoff. Startup failures that are not "no stored credentials" show a recovery state, never the login form.

Code: `packages/raft_client/lib/src/session_policy.dart` (verdicts, restore failure kinds, audit events), `packages/raft_client/lib/src/client.dart`, `apps/raft_flutter/lib/main.dart` (`restore`, `enterRestoreRecovery`), `lib/features/session_recovery_view.dart`, `lib/platform/auth_audit_log.dart`, `lib/platform/session_store.dart`.

## What is definitive

The server (`packages/server/src/routes/auth.ts`, `middleware/auth.ts`) answers:

| Route | Answer | Meaning |
|---|---|---|
| `POST /auth/refresh` | `401 {"error":"Invalid or expired refresh token"}` | token unknown, expired, revoked, reused, family revoked, account retired |
| `POST /auth/refresh` | `400` (missing token / `Invalid refresh replay binding`), `500 {"error":"Token refresh failed"}` | client bug / server fault: not a verdict |
| `GET /auth/me`, any `requireAuth` route | `401 {"error":"Invalid or expired token","code":"auth_required"}` | access token bad; account missing or retired; session family revoked |
| resources | `403 {"error":"Not a member of this server"}`, `403 Email verification required`, `403 PROFILE_SETUP_REQUIRED` | resource or account-state refusal: never a sign-out |
| socket handshake | `Invalid or expired token`, `Invalid token type`, `Authentication required`, `Authentication changed; reconnect required`, `Not a member of this server` | only the first two are token problems |

Sign out (and clear stored credentials) happens only for **401 whose body is the server's JSON error** (`RaftApiException.structured`) from `/auth/refresh`, or from `/auth/me` after a refresh succeeded. A 401 with an HTML/empty body, any 403 (the server never sends one on these routes: it is a proxy/WAF/captive portal), 400, 404, 408, 429, 5xx, timeouts, connection errors and unparseable 200s keep the session. Web (`authVerdict.ts`) treats 401 and 403 from refresh as terminal and everything else as keep-session; Flutter matches that except that it does not treat 403 or a body-less 401 as terminal, because the server never sends either on these routes.

## Path table

"Before" is `00529b30`; "now" is this branch.

| # | Path (file:line before) | Trigger | Before | Now |
|---|---|---|---|---|
| 1 | `client.dart:745` `_rotate` catch | refresh answers 401 **or 403** | log out, **`POST /auth/logout`** with the (possibly stale) token, clear store, clear device cache | 401+JSON only: adopt a newer stored record if another owner rotated, else end session `refresh_rejected`, **no** server revoke. 403/other: keep, `session:degraded`, retry |
| 2 | `client.dart:364` `_validateRestoredSession` | `/auth/me` any 4xx (incl. 400, 403, 404, 408, 429) | **logout** (cache wiped, credentials deleted) | 4xx other than structured 401: keep, `restoredOffline`, backoff retry |
| 3 | `client.dart:283` `restore` (no cached account) | `/auth/me` 4xx | rethrow, then `main.dart:554` login form | keep, `SessionRestoreException`, recovery view |
| 4 | `client.dart:283/302` `restore` (no cached account) | `/auth/me` timeout / connection error / unparseable 200 | exception to `main.dart:553` catch, **login form** | recovery view with retry |
| 5 | `main.dart:553-554` `restore` catch-all | any exception: secure storage throws, JSON decode, cache open (Drift), SharedPreferences | `bootError = 'Could not restore the session. Sign in to reconnect.'` and **login form** | storage / network / unexpected recovery view; cache failure ignored |
| 6 | `session_store.dart:16` Android secure storage | any exception during read/write (Keystore unavailable, background engine race, key unwrap failure) | plugin default `resetOnError: true` **deletes every stored value** and returns `"Data has been reset"`: JSON decode fails (path 5) and credentials are gone for good | `AndroidOptions(resetOnError: false)`: the error surfaces, the record stays, recovery view retries |
| 7 | iOS keychain (`first_unlock_this_device`) read before first unlock | `errSecInteractionNotAllowed` | same as 5 (login form; record intact) | recovery view; retries on resume / timer |
| 8 | `client.dart:458-486` `logout` | explicit user logout | revoke + clear | unchanged (the only revoking path) |
| 9 | `session:ended` handler `main.dart:1631` | any session end | also clears the account's device cache and attachments | unchanged, but now reached only by definitive ends and explicit logout |
| 10 | `client.dart:806-835` socket `connect_error` | `Invalid or expired token` | refresh; on throw one 2 s retry, then wedged; immediate reconnect loop if the server keeps rejecting | refresh (only a definitive refresh answer ends the session); backoff 2/5/15/30/60 s, first retry immediate |
| 11 | socket `connect_error` | `Authentication changed; reconnect required`, `Authentication required` | ignored: socket stays down until resume | reconnect with backoff, no refresh, no sign-out |
| 12 | socket `connect_error` | `Not a member of this server` | server revoked locally (`workspace_controller.dart:6069`) | unchanged: server-level, never touches the account |
| 13 | socket `disconnect` reason `io server disconnect` (other device signed out, membership change) | server drops the socket | no reconnect | reconnect with backoff; the handshake plus refresh decide (definitive 401 ends the session) |
| 14 | resource 401 `client.dart:~632` | expired access token | refresh and retry once (a request whose 401 arrives after another request already rotated rotates again) | skips the second rotation; failed refresh cooldown 3 s |
| 15 | resource 400/403/404/409/422/429/5xx | any | error to the caller, no sign-out | unchanged (pinned by tests); `403 Not a member` revokes only that server |
| 16 | `workspace_controller.dart:2799,3672,3846,4198,5051,5364,5404` | 403/404 on a channel or server | resource/server-level state | unchanged |
| 17 | Background WorkManager guest (`background_notifications.dart:104`) | refresh rejected | could clear the stored session and revoke the family | `allowSessionEnd: false`: it only stops; the foreground meets the same rejection with the user present |
| 18 | `_reloadOwnedCredentials` `client.dart:~323` | stored record cleared or a different principal after a guest handoff | `session:ended` | same, now audited (`store_cleared` / `principal_changed`) |
| 19 | `main.dart:1604` `account:updated` principal mismatch | `/auth/me` returns another id | logout | unchanged, reason `principal_changed` |
| 20 | `_rotate` after a 200 that is not a token pair | captive portal / proxy page | `TypeError`, request fails (no sign-out) | explicit transient error |
| 21 | `_rotate` persist failure (secure storage write throws after the server rotated) | storage error | error propagates; stored record stale, replay window 15 min | unchanged, audited `refresh_local_error`; replay by attempt id covers 15 min, afterwards a definitive 401 is the correct end |
| 22 | clock skew: device ahead | `_accessNeedsRefresh` always true | rotation on every socket handshake | at most one proactive rotation per 60 s; device behind just relies on the 401 path |
| 23 | iOS share extension (`ShareSessionVault`, `ShareComposeClient`) | 401 in the extension | `ShareComposeFailure.signIn` inside the extension only; it holds an access token copy, never the refresh token, and never writes the main record | unchanged |
| 24 | Android Keystore invalidation (key permanently unusable) | read throws every time | wipe (path 6) then login form | recovery view; "Sign in again" is offered; nothing is deleted until a new sign-in replaces the record |
| 25 | Server revoked the family elsewhere (sign-out on another device, "log out everywhere", account retired) | next refresh 401 JSON | logout | logout (correct), reason `refresh_rejected` / `account_rejected`, message "Your session has expired. Sign in again." |

## Most likely causes of Kevin's reports

1. **Path 6/5**: the Android secure-storage plugin wipes all credentials on any read/write exception (`resetOnError` defaults to true) and the app showed the login form for the decode failure. Hits "some devices, sometimes": Keystore hiccups, direct-boot/locked-device background wakes, OEM Keystore bugs, the WorkManager engine reading while the foreground does.
2. **Path 2/1**: any non-5xx 4xx from `/auth/me` at startup (a 429 from the rate limiter, a 403/400 from a proxy, a 404 during a deploy) or a 403 from `/auth/refresh` ended the session and deleted credentials.
3. **Path 1 (revoke)**: the involuntary logout also called `/auth/logout` with the stale token; the server resolves a predecessor token to its family and revokes it, so one engine losing a race could revoke the family the other engine was using.
4. **Path 4/3**: a session with no cached account record (older sessions, first run after an update) and a flaky network at startup showed the login form.

## Diagnostics

`AuthAuditLog` (`platform/auth_audit_log.dart`) keeps 200 entries in `auth-audit.jsonl` under the app support directory (foreground and background workers append). Each entry: time, kind (`session_end`, `session_kept`, `restore_failed`, `socket_auth`, `recovered`, `store_error`), reason, HTTP status, endpoint, and a sanitized detail (token-like strings and e-mails are replaced). Account settings shows a "Sign-in diagnostics" card only when something was recorded; "Copy" puts the text on the clipboard for a feedback report.

## Tests

`packages/raft_client/test/logout_policy_test.dart` (status tables for refresh, `/auth/me`, resources, restore failure kinds, races, recovery, audit, websocket handshake against a fake Engine.IO server), `apps/raft_flutter/test/session_restore_recovery_test.dart`, `apps/raft_flutter/test/auth_audit_log_test.dart`.
