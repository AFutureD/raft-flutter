# iOS receiving shares

Runner packages two public native extensions: ShareExtension in the share app row,
and ActionExtension (Share to Raft / 分享到 Raft) in the Action list. Both use Apple's
`SLComposeServiceViewController`, with editable text, searchable server/conversation
selectors and the system Post/Cancel controls. Opening the sheet loads available
targets; only an explicit Post uploads attachments and sends a message. It does not
launch the containing app or automatically send shared content. Safari page
preprocessing obtains the page URL/title through the documented JavaScript hook.
Photos, Files and other providers use `NSItemProvider` text/URL/file representations.
System ordering and Action availability still depend on the host share sheet.

## Account and API contract

`IOSShareSession` exports only the currently accepted account's access token to an
explicit shared Keychain group. Refresh tokens stay in the main app. The record
has origin, principal, name, access expiry and preferred server; it uses
WhenUnlockedThisDeviceOnly protection. Logout, account replacement, expired access
and offline restoration retire it. Publication follows accepted login, selected
server changes and a payload-free session:credentials-updated event after token
rotation; ordinary API responses neither read the Keychain nor publish a record. The app keeps its previous default Keychain
access group first, so introducing this shared group does not move old login items.
The group is provisioned for Runner, ShareExtension and ActionExtension.

An extension without usable access asks the user to open Raft and sign in; it
neither reads the refresh token nor presents an independent login flow. Existing
sheet requests re-read current access, accepting token rotation or preferred-server
changes only for the same origin/principal. An account change, logout or expired
record blocks subsequent requests and late responses. Every Post rechecks `/auth/me`,
server membership and destination availability, including archived and conversion
fences. The user's explicit destination supplies `X-Server-Id` and cannot be silently
replaced by the main app's selected server. Guest/member/admin/owner roles use the
same mounted human API endpoints as RaftClient.

`/attachments/upload-capabilities` supplies the server limit before upload.
Multipart bodies are written in 64 KiB chunks to private temporary files and sent
with URLSession's file upload API; no whole-file memory copy is used in production.
Redirects are rejected, cookies/cache are disabled and response sizes are bounded.
A failed message retains its randomId and already uploaded attachment IDs, so an
unchanged retry uses the ordinary server idempotency contract. Editing content or
changing the target creates a new message identity. Uploads that complete before
cancellation may remain on the server, but cancellation prevents the message request.
Local multipart and staging files are removed on completion/cancel.

## Files, legacy inbox and outgoing sharing

Runner and both extensions declare `group.app.raft.raftFlutter`. Copying is bounded
to 9 files, 25 MiB per file and 100 MiB total; text is bounded to 65,536 UTF-16 units.
Credential/OAuth/signed-resource URLs follow the existing unsafe-text policy.
Provider files are opened before temporary callbacks end and copied from retained
descriptors. Private `.staging-<token>` folders stay unpublished during direct Post;
cancel signals ongoing copying and removes staging. Orphan staging older than 24
hours is reaped without disturbing live transfers or committed inbox records.

Previously saved `envelope.json`/`item-N` records remain compatible with cold/resume
recovery, account binding and the main app's existing draft target picker. Android
continues to use receive_intent and its existing draft handoff. The iOS bridge also
presents outgoing sharing from private app export leases in the active scene.

The incoming implementation uses public extension APIs and no incoming pub plugin:
receive_intent is Android-only; share_plus handles outgoing shares. The previously
reviewed receive_sharing_intent/share_handler redirect and shared-defaults designs
did not satisfy this app's inbox contract. See [Apple's extension guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html).

## UIScene and system bars

The app already follows [Flutter's UIScene migration](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate):
AppDelegate registers the implicit engine/plugins; SceneDelegate inherits
FlutterSceneDelegate and calls super before attaching a temporary splash UIView.
It does not replace the root FlutterViewController, create an extra UIWindow,
request fullscreen or override Home indicator preferences. UIScene must remain
adopted for builds with the iOS 27 SDK.

RaftSystemBars now explicitly requests edgeToEdge on iOS as well as Android. The
Flutter iOS implementation issues a show-home-indicator notification for that
mode. Miraa's local source likewise initializes edgeToEdge on iOS. A regression
checks this platform request, but it does not establish physical indicator
visibility. Kevin reported the indicator becomes visible when swiping; iOS 26
system behavior is a possible factor ([Unity's verified issue](https://issuetracker.unity.com/issues/4265/hide-home-button-setting-is-ignored-on-ios-26-devices-home-button-is-always-hidden)).
Neither that source nor the static comparison establishes the cause on this phone.

## Verification boundaries

The native transport fixtures use synthetic credentials/DTOs and local files only.
They cover same-account access rotation, account retirement, response identity,
membership/archive/conversion fencing, server upload limits, exact binary multipart
bytes, retry identity, retained attachment IDs and cancellation. Dart tests cover
access-only export, offline/expired/wrong-principal rejection, delayed credential
reads, native write ordering and existing inbox/draft handoff. Producer fixtures
still check provider file lifetime, bounded copies and legacy atomic publication.

`tool/ios-simulator-build` builds and ad-hoc signs Runner and both extensions with
explicit groups; it never installs or launches and is not physical provisioning.
Physical updates use real profiles/certificates and preserve the accepted personal
bundle IDs. Native compilation and fixture results do not certify system provider
UI, actual authenticated sending, Action placement, store approval or indicator
visibility. Those require real device verification through background Computer Use
or Kevin. No real message is sent by these fixtures. The latest background Device
Hub binding failed with native pipe startup failure, so dependent UI actions stop
under the user's AGENTS.md restriction.
