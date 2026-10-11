# Edge-to-edge audit (Android mobile)

Branch `cindy/edge-to-edge-audit`, based on `cindy/integration` (4d38874). Analysis and
adaptation plan only: no production code changed. Evidence harness:
`apps/raft_flutter/test/edge_to_edge_audit_test.dart` (56 widget tests, all green; it records
evidence, it does not assert the bug). Run it with
`tool/flutter test test/edge_to_edge_audit_test.dart` in `apps/raft_flutter`; PNGs and
`metrics.json` go to `<repo>/.local/edge-to-edge/` (git-ignored; override with
`RAFT_EDGE_AUDIT_DIR`).

## 1. How edge-to-edge works today

| Layer | Where | What it does |
| --- | --- | --- |
| Manifest / activity | `android/app/src/main/AndroidManifest.xml:23` (`adjustResize`), `MainActivity.kt` | `targetSdk=37`, so Android enforces edge-to-edge. `MainActivity` has no `enableEdgeToEdge`, no bar colours and no contrast flags. Dart owns everything. |
| App root | `lib/platform/system_bars.dart:103-127` (`RaftSystemBars`, mounted in `lib/main.dart:1212`) | `SystemChrome.setEnabledSystemUIMode(edgeToEdge)`. Transparent status and nav bar, `systemNavigationBarContrastEnforced: false`. Paints `ColoredBox(theme.scaffoldBackgroundColor)` under the whole app. This is the colour you see where no page paints. |
| Per page | `RaftSystemBarSurface` (`system_bars.dart:45-102`) | Sets the icon-brightness `AnnotatedRegion`. Paints an opaque status strip (`padding.top`) and, **only if `navigationBarBackground != null`, an opaque nav strip of height `padding.bottom`**. |
| Hosts | five `RaftSystemBarSurface` call sites (table below) | Every host passes `navigationBarBackground` (panel, canvas or cream) except the home-tab case, which passes `null`. |

Root cause of the strip: all hosts except the home-tab one wrap their body in `SafeArea(bottom: true)`
and paint an opaque `navigationBarBackground` over the inset. Content therefore ends at the top of
the bar, scroll views are clipped there, and bottom controls are lifted by the bar height. The
Android bar is transparent but nothing is allowed to draw under it.

The one immersive case is `workspace_view.dart:938` (`immersiveNavigation = androidMobile && rootTab != null && w.server != null`),
which turns off `SafeArea(bottom:)` and the nav strip for the four tab roots only (`mobileRootTab`
in `lib/data/workspace_navigation.dart:272`: home, tasks, members, settings root). The tab bar then
owns the inset itself (`mobile_workspace_navigation.dart:98`, brutal paints the bar colour under the
bar; elegant floats a capsule over content, `workspace_view.dart:1375`).

A second, accidental mechanism: `SafeArea` also removes `padding` and `viewPadding` from the body's
`MediaQuery`. raft_ui widgets written to Web `safe-bottom` parity already read
`MediaQuery.paddingOf(context).bottom` (`channel_overflow_sheet.dart:262/275`,
`channel_settings_sheet.dart:342`, `runtime_usage_card.dart:654`, `toast.dart:257`,
`bottom_sheet.dart` `safeBottom`). They currently see 0, so they work only because the host strip
exists. `RaftComposerRecipe.bottomSafeInset` (`composer_recipe.dart:35`) is never passed by the app
(0). Both are unused capacity for the fix, and both are traps (see risks).

### MediaQuery facts measured by the harness (gesture bar 48 px, keyboard 300 dp)

| Body context | nav bar only | keyboard up |
| --- | --- | --- |
| Under `Scaffold(resizeToAvoidBottomInset: true)`, no SafeArea | padding 48, viewPadding 48, viewInsets 0 | padding 0, viewPadding 0, viewInsets 0 (Scaffold shrinks the body and strips all three) |
| `resizeToAvoidBottomInset: false` | padding 48, viewPadding 48 | padding 0, viewPadding 48, viewInsets 788 |
| Inside the current `SafeArea` | 0 / 0 / 0 | 0 / 0 / 0 |

Consequence: under a resizing Scaffold, `MediaQuery.paddingOf(context).bottom` is already
keyboard-correct (nav inset when no IME, 0 when IME is up). A bottom-anchored surface that pads by
it never double counts. Never compute `viewPadding - viewInsets` inside such a Scaffold, and never
read `viewPaddingOf` (it is only 0 there because the Scaffold also strips it when the keyboard is
up; outside a resizing Scaffold it stays 48 under the IME).

## 2. Inventory

Strip = opaque nav strip or SafeArea clip. "Gap" is the measured distance (dp) between the lowest
wide scroll viewport and the screen bottom (`metrics.json`): 18.3 dp with the 48 px gesture bar,
48.0 dp with the 126 px 3-button bar, 0 when the list runs under the bar. Target kinds: **L** =
scroll list (scrolls under the transparent bar, last item gets bottom padding),
**B** = bottom-anchored control (its own background extends under the bar, padding inside it),
**M** = modal (own background extends under the bar).

### 2a. Screenshotted (real `RaftApp` routes, 412x915 dp, DPR 2.625, brutal and elegant light)

| # | Page | Host (file:line) | Today | Verdict | Target |
| --- | --- | --- | --- | --- | --- |
| 1 | Home root (sidebar list + tab bar) | `workspace_view.dart:1314-1324` (nav strip null, `SafeArea(bottom:false)`), sidebar `:3093`/`:3128` | List and bar run under the bar. Brutal: bar background fills the inset. Elegant: floating capsule, gap 0. | immersive | keep |
| 2 | Tasks root | same host, `resource_view.dart` list | Immersive. Elegant: last row ("Closed") ends under the capsule, no clearance (`05-tasks-root-scrolled-end-elegant`). | immersive, clearance missing | L: bottom padding = 68 + inset (116 with live-activity strip), as Web `.mobile-nav-clearance` |
| 3 | Members root | same | Immersive; short list fits, same clearance gap for long lists | immersive, clearance missing | L, as 2 |
| 4 | Settings root | same, `settings_page.dart` | Immersive; fits on 915 dp, last rows at risk on small phones | immersive, clearance missing | L, as 2 |
| 5 | Channel chat (+composer) | `workspace_view.dart:1320-1324` | Scaffold SafeArea + nav strip `t.panel`. Composer lifted 18 dp (gesture) / 48 dp (3-button). | STRIP | B: composer host extends under bar (`bottomSafeInset`) |
| 6 | Thread | same | same, composer lifted | STRIP | B |
| 7 | Search | same | list clipped at bar, gap 18.3 / 48 | STRIP | L |
| 8 | Activity | same | strip `#FFFFFF` over page `#F8F8F7` in elegant: visible band | STRIP | L |
| 9 | Saved | same | same visible band | STRIP | L |
| 10 | Settings sub-pages (account, language, appearance, notifications, server profile, billing, admin, applications, MCP, providers, IM bridges, joint channels, sidebar) | same | list clipped at bar | STRIP (about 13 pages, one host) | L |
| 11 | Computers list / computer detail | same (`workspace_view.dart`, `fleet_views.dart`) | clipped | STRIP | L |
| 12 | Agent / member detail, member graph | same | clipped | STRIP | L |
| 13 | Channel Tasks / Files tabs | same (`channel_tabs`) | clipped | STRIP | L |
| 14 | Channel settings page (overflow sheet content) | `workspace_view.dart:3342-3354` (nav strip panel, or cream in brutal settings) | clipped at bar; the raft_ui `16 + paddingOf.bottom` padding reads 0 | STRIP | L |
| 15 | Channel members page | same | clipped | STRIP | L |
| 16 | Task detail (thread composer) | `workspace_task_host.dart:299-304` (`Scaffold` + surface + SafeArea, nav strip = page colour) | composer lifted | STRIP | B |
| 17 | Attachment preview page | `attachment_view.dart:566-568` + `attachment_preview_shell.dart:222` (SafeArea) | comments footer bar lifted over a strip | STRIP | B (footer) + L (body) |
| 18 | Attachment comments page | `attachment_comments.dart:417` `Material`+`SafeArea` | clipped (code) | STRIP | B |
| 19 | Forward composer page | `forward_composer_page.dart:102` + `forward_composer.dart:24` `RaftForwardPage` SafeArea | footer lifted, gap 30 | STRIP | B (footer), L (list) |
| 20 | Incoming share picker | `main.dart:263` + `RaftForwardPage` (`incoming_share_picker.dart:179`) | "Continue" footer lifted | STRIP | B |

Counts for the 19 captured page states (4 roots, chat, thread, search, activity, saved, account,
server profile, computers, member detail, channel settings, channel members, task detail,
attachment preview, forward composer, share picker): **4 immersive, 15 strip**. Of the 4
immersive roots, tasks was measured to lack the capsule clearance in elegant; members and
settings are at risk with longer content. Rows 13 and 18 are inferred from the shared host or
the code, not separately captured.
Counting by distinct page kinds in the code (one row above can cover many pages, for example
all settings sub-pages share one host): about 35 pages go through a strip host (about 26 behind the single workspace Scaffold), 4 roots are immersive.

### 2b. Code-inspected only

| Page / surface | Host (file:line) | Handling today | Verdict | Target |
| --- | --- | --- | --- | --- |
| Auth, server selector, onboarding | `auth_view.dart:403` (`navigationBarBackground: t.canvas`), `RaftAuthPage` `auth_page.dart:57` reads `paddingOf` | content padded inside scroll view, strip colour = page colour | immersive in effect, still paints a strip widget | keep padding; drop strip paint |
| Standalone `MaterialPageRoute` Scaffolds without SafeArea: `fleet_views.dart:1324`, `integrations_views.dart:355`, `agent_scopes_view.dart:135`, `agent_migration_view.dart:189`, `system_notification_center.dart:410` | bare `Scaffold` + `raftPageAppBar` | Scaffold background paints under the bar; `ListView(padding: all(24))` | immersive by accident; with the 3-button bar (48 dp) the last 24 dp are hidden | L: add inset to explicit padding |
| Computer detail pushed from list: `fleet_views.dart:381` `Scaffold(body: SafeArea(...))` | SafeArea bottom | STRIP in Scaffold colour | L |
| Centered dialogs: `showRaftDialog`/`showDialog` (`overlays/dialog.dart:546` SafeArea, barrier outside it) | content centered, barrier covers the whole window | immersive (barrier covers the bar) | none |
| Lightbox (`attachment_lightbox.dart:342`) | `SafeArea` inside a dark dialog route | strip = backdrop colour; image/controls clipped to safe area | partial | M: bottom thumbnails/controls pad by inset, image full-bleed |
| Image export review (`message_image_export.dart:428`) | `Dialog.fullscreen` + SafeArea on lightbox backdrop | same | partial | M |
| Runtime usage sheet (`runtime_usage_card.dart:654`) | floating card, `padding.bottom > 12` | correct pattern (floating) | immersive | none |
| `RaftBottomSheet` (`bottom_sheet.dart:45`) | `safeBottom` param, never passed by callers | n/a (no mounted caller) | -- | default from `paddingOf` |
| Toast (`toast.dart:257`) | `16 + max(padding.bottom, viewInsets.bottom)` | correct | immersive | none |
| Selection action bar (chat select mode, `chat_view.dart` ~2810) | inside page body | lifted by strip | STRIP | B (Web `safe-bottom-action-bar`) |
| Message context menu / popovers / quick switcher (`RawDialogRoute`) | overlays | not bottom-anchored | n/a | none |
| Desktop rail `adaptive_workspace.dart:471` | SafeArea | desktop only | n/a | none |
| `timeline_scrollbar.dart:160` | `padding = MediaQuery.paddingOf` | will follow the new inset automatically | ok | none |

## 3. Screenshots

All in `/home/kevinzhow/github/raft-flutter-wt/edge-to-edge-audit/.local/edge-to-edge/`.
Magenta band = system navigation bar (48 px gesture or 126 px 3-button); green = status bar; blue =
keyboard. Individual shots are named `<n>-<page>-<theme>-<gesture|buttons>.png`; contact sheets
(4 pages per sheet, left to right) are in `sheets/`.

| File | Caption |
| --- | --- |
| `sheets/A-roots-brutal.png`, `sheets/A-roots-elegant-light.png` | Home, Tasks, Members, Settings roots: tab bar owns the inset, immersive |
| `sheets/B-roots-scrolled-end-*.png` | Tasks, Settings, Home scrolled to the end; elegant Tasks "Closed" row is covered by the capsule |
| `sheets/C-chat-thread-search-activity-*.png` | Channel chat, thread, search, activity: composer and lists stop at the bar |
| `sheets/D-saved-settings-computers-*.png` | Saved, account, server profile, computers: clipped at the bar; elegant Saved shows the strip colour differing from the page |
| `sheets/E-member-chanmembers-chansettings-*.png` | Member detail, channel members, channel settings, and a settings page with a 3-button bar (48 dp strip) |
| `sheets/F-task-attachment-forward-share-*.png` | Task detail, attachment preview, forward composer, share picker: bottom bars lifted above a strip |
| `sheets/G-keyboard-and-3button-*.png` | Chat resting, keyboard up, keyboard down, and 3-button bar (large 48 dp strip) |
| `01-home-root-*`, `10-channel-chat-*`, ... | full-resolution (1081x2402) originals, brutal and elegant light, plus 3-button variants of home, chat, search, server profile |
| `metrics.json` | per capture: colour under the bar, colour 8 px above, scroll-viewport gap in dp, MediaQuery probes |

Honest reading of the images: where the page background equals the panel colour (most brutal
pages, chat in both themes) the strip is invisible as a colour, but it is still reserved space:
the composer floats 18 dp (gesture) or 48 dp (3-button) above the screen bottom and scroll
content is cut off at the bar line instead of passing under it. The strip is visible as a colour
band on pages whose background is not panel white (elegant Activity and Saved, the cream
brutal attachment preview body, dark themes). Dark themes were not captured in this round.

## 4. Web alignment (read-only, `packages/web`)

Web has no external strip anywhere. Each surface's own background extends under the bar and pads
by the inset (`env(safe-area-inset-bottom)`):

| Web | Rule |
| --- | --- |
| `index.css:755` `.safe-bottom` | `padding-bottom: inset + 1rem`. Used on composer (`MessageInput.tsx:2496`), scroll panels (`TasksPanel`, `SavedPanel`, `ThreadsInbox`, `MobileComputersPanel`, `LegacyTaskPanel`), channel settings footer (`EditChannelDialog.tsx:1526/1561`). |
| `index.css:759` `.safe-bottom-action-bar` | `inset` (+1rem on coarse pointers). Select-mode toolbar (`SelectModeToolbar.tsx:124`). |
| `BottomSheet.tsx:74` | `pb-[max(12px, inset)]` |
| `ForwardComposerMobile.tsx:137/164` | `pb-[max(12px, inset)]` on list and footer |
| `MainLayout.tsx:128/351` | in-flow tab bar `paddingBottom: min(inset, 34px)`; elegant floating capsule |
| `index.css:769/777` `.mobile-nav-clearance` | elegant tab-root scroll surfaces `padding-bottom: 68px + inset` (116 px + inset with the live-activity strip), brutal none |
| top | `.safe-top`, lightbox `top: calc(56px + env(safe-area-inset-top))` |

Flutter matches this model by making every surface pad by the inset. Do not copy the 34 px cap
on Android: the 3-button bar is 48 dp and a capped tab bar would sit under the nav buttons.

## 5. Adaptation plan

Goal: one rule for the whole app. Nothing paints an opaque strip, no host uses `SafeArea(bottom)`;
every surface that touches the bottom edge pads itself by the system inset, using the same
`paddingOf` source Web uses. Sheets and modals extend their own background.

### 5.1 Shared mechanism

New `packages/raft_ui/lib/src/system_inset.dart`, exported from `raft_ui.dart`
(raft_ui must stay free of platform services; `MediaQuery` is plain Flutter, so this is allowed):

1. `double raftBottomInset(BuildContext)`: `MediaQuery.paddingOf(context).bottom`. Documented as
   keyboard-safe under a resizing Scaffold (section 1 table). Single place to change if a future
   Flutter changes the semantics.
2. `RaftBottomInsetSurface({color, decoration, padding, child})`: a `DecoratedBox`/`Padding` whose
   background paints to the screen edge and whose bottom padding is `base + raftBottomInset`.
   Optionally an `AnnotatedRegion<SystemUiOverlayStyle>` for nav icon brightness from its colour:
   Flutter samples the nav-bar style at the bottom-centre pixel of the window
   (`RenderView._updateSystemChrome`), so the bottom-most surface decides the icon colour. This
   replaces the global `navigationBarBackground` guess and fixes icon contrast per surface.
3. `EdgeInsets raftScrollPadding(BuildContext, [EdgeInsets base])`: adds the bottom inset (and
   optional tab-bar clearance, `raftTabBarClearance(liveActivity)` = 68 / 116) to scroll padding.
   Note `ListView`/`GridView` with `padding: null` already add `MediaQuery.padding`; only
   explicit-padding lists need the helper.
4. Make `RaftBottomSheet.safeBottom` default to `max(12, raftBottomInset)` like Web.

App side (`lib/platform/system_bars.dart`):

5. `RaftSystemBarSurface`: delete the opaque nav strip and `navigationBarBackground` (keep the
   status strip and the icon-brightness annotation; take brightness from a new optional
   `navigationIconBrightness` or from the page background). The five call sites drop the argument.
6. Add a thin `RaftSystemBarHost` (or reuse the surface) that is the only place hosts call; hosts
   use `SafeArea(bottom: false)` (top-only). Keep `RaftSystemBars` root as is: it provides the
   last-resort colour under the bar.
7. Remove `immersiveNavigation` branching in `workspace_view.dart`; the same code path serves roots
   and detail pages.

### 5.2 Files to touch (estimate)

| Area | Files | Change | Size |
| --- | --- | --- | --- |
| raft_ui core | new `system_inset.dart`, `raft_ui.dart`, new preview + test | helper widgets, keyboard/3-button preview, unit tests | ~150 lines |
| raft_ui composer / bars | `components.dart` (RaftComposer), `composer_recipe.dart`, `chat_composition.dart`, `bottom_sheet.dart` | composer host wraps in `RaftBottomInsetSurface`; recipe reads inset | ~40 lines |
| raft_ui pages | `forward_composer.dart` (`RaftForwardPage`: top-only SafeArea, footer inset), `attachment_preview_shell.dart:222`, `attachment_comments.dart:417`, `attachment_lightbox.dart:342`, `channel_overflow_sheet.dart`, `channel_settings_sheet.dart` | drop `SafeArea(bottom)`; footer pads by inset; overflow/settings keep existing `paddingOf` | ~80 lines |
| App hosts | `system_bars.dart`, `workspace_view.dart` (:938, :1320-1324, :3342-3354), `workspace_task_host.dart` (:299-304), `attachment_view.dart` (:566-568), `auth_view.dart` (:403), `fleet_views.dart` (:381) | strip removal, `SafeArea(bottom:false)` | ~60 lines |
| App lists with explicit padding | `resource_view.dart`, `settings_page.dart` and settings sections, `channel_settings.dart`, `channel_members.dart`, `fleet_views.dart`, `integrations_views.dart`, `agent_scopes_view.dart`, `agent_migration_view.dart`, `agent_detail_view.dart`, `member_profile_view.dart`, `search_home.dart`, `activity_destination.dart`, `source_feedback_view.dart` (about 12-15 files) | `raftScrollPadding` | ~5 lines each |
| Tab-root clearance | `resource_view.dart` (tasks), members list, `settings_page.dart` | 68 / 116 + inset in elegant (the home sidebar already does this via `recipe.contentInset(bottomInset:)`, `design_primitives.dart:154`) | ~30 lines |
| Chat | `chat_view.dart` composer and selection toolbar (:2810 area) | pass inset / wrap in `RaftBottomInsetSurface` | ~25 lines |
| Tests | `system_bars_test.dart` update; new `edge_to_edge_pages_test.dart` from this harness | see 5.4 | ~200 lines |

Total about 25 files, 600-700 lines, 1.5 to 2 days including tests and dark theme captures.
Medium risk, mostly mechanical; the shared helpers keep per-page edits to one call.

### 5.3 Per-kind target

| Kind | Treatment |
| --- | --- |
| Scroll list / page | host is `SafeArea(bottom:false)`; list has `padding.bottom += raftBottomInset`; content scrolls under the transparent bar; no strip |
| Bottom-anchored control (composer, selection toolbar, forward "Continue", attachment comments footer) | control's own background reaches the screen edge; inside it `padding.bottom += raftBottomInset`; thread/task composers included |
| Tab roots | unchanged owner (tab bar), plus 68 / 116 + inset scroll clearance in elegant |
| Sheet / dialog / lightbox | own backdrop or card extends under the bar; floating cards pad by inset (already so: usage sheet, toast) |

### 5.4 Verification (from this harness)

- Convert `metrics.json` checks to assertions: for every page, `scrollGap == 0` (or equals the
  in-flow tab bar height in brutal); bottom-anchored controls end exactly at the screen bottom;
  nav band colour equals the colour of the surface above it.
- Keyboard: for chat and thread, with the IME up, the composer's bottom padding is 16 (no inset)
  and with it down it is `16 + inset`; frame-by-frame no jump while the IME animates.
- Dark themes and the 3-button bar for chat, search, settings, task detail.
- Existing: `system_bars_test.dart`, `mobile_*_test.dart`, `page_layout_test.dart`,
  `mobile_attachment_preview_page_test.dart`, `mobile_tab_bar_root_test.dart`; the Web parity
  suites for composer geometry (`composer-linebox-parity`) must be re-run because composer
  bottom padding changes on device only (tests have inset 0).

### 5.5 Risks

1. **Keyboard interplay.** Under a resizing Scaffold `paddingOf` is already 0 with the IME up, so
   the composer must read `paddingOf` (not `viewPadding`, not `viewPadding - viewInsets`). If a host
   ever sets `resizeToAvoidBottomInset: false`, `viewPadding` stays 48 under the IME and a
   `viewPadding`-based surface floats above the keyboard. The tab bar's `RaftMobileNav` reads
   `viewPaddingOf` when `bottomInset` is null (`mobile_navigation.dart:249`) while the host passes
   `bottomInset: 0` and wraps it in `SafeArea` (`mobile_workspace_navigation.dart:98`); this
   mixed use is the likeliest place for the "tab bar stays lifted after the keyboard hides"
   defect the other investigation covers. The fix for both should land together: one helper, one
   source (`paddingOf`), no `SafeArea` around the tab bar.
2. **Predictive back / route snapshots.** `_MobilePageFrame` snapshots a page for the fade
   (`mobile_workspace_pages.dart`, `captureLastFrame`). Today each snapshot contains an opaque
   strip; after the change it contains content running under the bar. Snapshots must be
   captured at full window height (they are, they capture the page boundary) and
   the incoming/outgoing pages must both be edge-to-edge or the bar band will flash between
   two colours during the transition. Convert every host in the same change, not page by page.
3. **Tab bar.** Keep the owner as is; do not cap the inset at 34 as Web does (3-button 48 dp).
   Brutal in-flow bar needs the bar colour painted under the inset (already so).
4. **3-button navigation contrast.** The bar is transparent with `contrastEnforced: false`, so
   the system draws no scrim and the icons sit directly on the app. Icon brightness must follow
   the bottom-most surface colour (5.1 item 2) or icons vanish (white icons on a white composer
   in a dark theme, black on a dark brutal footer). On Android 17 do not re-enable the scrim:
   it would reintroduce a visible translucent strip. Verify on a real 3-button device.
5. **Double padding.** raft_ui sheets already add `paddingOf`; they start working as soon as the
   host drops its `SafeArea`. A host that keeps `SafeArea(bottom)` plus a surface that pads again
   would double count. Remove `SafeArea(bottom)` and add the surface padding in the same commit.
6. **Brutal chat** composer has a heavy top border and inset `16 + inset`: confirm the extra
   height does not change the keyboard-up layout (it should not, inset is 0 then).
7. **Desktop / Linux / web builds** do not go through `RaftSystemBarSurface` (`kIsWeb` / not
   Android returns the child), so the app-side change is Android-only. raft_ui helpers return 0
   where the platform reports no padding.
8. **Scroll lists with explicit padding** are the long tail. Mitigation: a test that scrolls
   every captured page to the end and asserts the last item's bottom is above the bar line.
