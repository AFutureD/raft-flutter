# Edge-to-edge follow-up — 2026-10-11

Base: `ff6e87f` on `cindy/integration`. This supplements the historical
`edge-to-edge-audit.md`; its old description of an opaque navigation strip no
longer describes the current implementation. Pages own their safe content
bounds, while their backgrounds continue to paint under Android's system bars.

## Confirmed omissions and fixes

| Surface | Cause | Correction | Regression evidence |
| --- | --- | --- | --- |
| Bottom bar settings preview | Pinned dock used a fixed visual gap, independent of the system inset | Existing `RaftBottomInsetSurface` owns the navigation inset; preserve the capsule's visual gap | 0/24/48dp, all three themes, IME show/hide, already-consumed SafeArea; actual settings route in both navigation modes |
| Server setup gate | Explicit scroll padding ignored the bottom inset; centered minimum height subtracted only the old fixed padding | `raftScrollPadding`; subtract its full vertical padding from the centered minimum height, clamped to zero | Computer/runtime, survey, handoff and create-agent surfaces; short screen and IME |
| Shared anchored menus | Collision rectangle included system bars/IME; a portal inherited the trigger's consumed metrics | Use the owning overlay's metrics for placement and size cap; remeasure on window metric changes | Oversized menu under SafeArea and keyboard; scroll and click its final option; existing flip/resize/theme tests |
| Notification center popup | Fixed maximum height and placement bounded only by window size | Clamp within the root overlay's safe viewport, including the keyboard | Short viewport/IME, normal opening, dismissal and keyboard action tests |

Red runs are retained under `.local/tabbar-preview-inset/`. In particular the
preview failed 9 cases before its correction, the setup scroll cases failed at
24/48dp, and both oversized menu cases failed before placement was corrected.
These files contain local evidence and are not committed.

## Scope reviewed

| Area | Current inset owner | Coverage in this follow-up |
| --- | --- | --- |
| Home, Tasks, Members, Settings roots | Adaptive workspace + real tab bar; list padding includes floating bar clearance | Actual route captures, scroll-end assertions and keyboard-stable tab bar regressions |
| Activity, Saved, Search, account/workspace settings | Route scroll host or page's `raftScrollPadding` | Actual route geometry; shared settings hosts and independent `scroll:false` destinations reviewed |
| Computer directory | Mobile `RaftMobileComputerList` already uses `raftScrollPadding` | Populate the actual route with 16 computers; long-list component tests. Desktop-only `RaftComputerSidebarList` left unchanged |
| Chat/thread, task detail | Composer surface or task scroll host | Actual route bounds and IME layout checks |
| Channel/DM settings and members | Shared settings page/scroll surfaces | Source ownership review; channel routes in capture suite |
| Attachment document/media preview, image lightbox | Preview shell/lightbox owns body/footer inset | Source review; actual attachment route capture. Nested document scroll views must not add it again |
| Forwarding and incoming share picker | Scroll host + inset-owning footer | Actual route/picker captures |
| Login/auth, overflow sheets, usage dialog | Existing explicit safe padding or bounded dialog host | Source review; no additional blanket SafeArea added |
| Centered dialogs, bounded nested/horizontal lists | Dialog safe bounds or owning page viewport | Source review; not counted as missing root insets merely because they lack the helper |

The route harness now passes 73 scoped cases. It distinguishes the Brutal tab
bar's intentional bottom border from an opaque system navigation strip, and
checks the preview bar's bottom against the actual inset. It records screenshots
and metrics under `.local/tabbar-preview-inset/routes-final/`.

SDK previews include gesture/three-button bottom bar settings and a long mobile
computer list. Relevant widget checks, static analysis and the design-system
audit pass. No full project test run was performed.

These are widget/geometry and source-ownership results, not physical Android
gesture, accessibility, notification or IME acceptance. The connected phone's
logs were read for the separately reported crash, but the modified app has not
been installed in this task.
