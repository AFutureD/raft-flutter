# Mobile Computer pages

Settings → Computers previously opened the generic FleetView inside a settings
subpage: `/settings/computers`, a second “Computers” heading, a top registration
button and Material ListTiles. Its standalone detail route had no safe-area or
mobile Back header. A direct Computer URL used a generic outer header plus the
desktop detail header.

Settings now opens `/s/:server/computers` through the existing workspace
navigation. The mobile list follows `MobileComputersPanel.tsx` in the pinned
Web reference (26f77ef): canvas padding 16, card gap 10, card padding 12, 40px
monitor/status cell, name/description/version and upgrade/disk metadata, and a
dashed Add row at the bottom. Add uses the existing permission-checked dialog.
Loading skeletons, cached refresh rows, retry and empty/attention states share
the existing server-scoped entity directory. Metadata wraps for narrow or large
text layouts. Desktop sidebar rows keep their existing geometry.

The mobile Computer detail owns one canonical named header, Back action and
safe-area geometry. Workspace history handles Back, cached revisits and cold
link fallback to Settings. Agent links from the detail use workspace URLs.
The desktop detail continues to use its original header. Standalone FleetView
consumers keep their native Navigator route with Scaffold/SafeArea; the design
system audit explicitly allowlists that platform host, not its content styling.
No route transition or Predictive Back configuration changes.

## Validation

- 3 component tests: Brutal, Elegant light/dark; pointer and keyboard activation,
  button semantics, loading/error/retry/empty/cached-refresh, and 280px at 2× text.
- 6 mounted `RaftApp` tests: Settings/list/detail canonical URL, single header,
  24px top inset, header/hardware Back, revisit without extra directory reads,
  cold-link fallback, and no accidental application exit, in all three themes.
- 27 app tests passed together (the 6 above plus settings, entity-directory
  surfaces, fleet authority and desktop directory groups); 30 unique tests with
  the component cases. Focused analysis passed. Design-system audit passed with
  the documented native Scaffold allowlist.
- Replacing the four changed app feature files with base 2d0dd86 makes the six
  mounted tests fail: three wrong route/list cases and three missing mobile
  detail headers. Candidate files were restored and hash-verified afterward.
- Full mounted before/after page PNGs at 390×900, 2× capture density were visually
  reviewed. The Android test engine has no native font manager: Inter and
  GeistMono are registered as explicit generic-family stand-ins, plus real
  MaterialIcons. These validate layout, not the phone's selected native font.
  Component PNGs use the bundled theme fonts. Early Ahem captures are excluded.
- Three SDK Widget Previews were added for loaded/loading/empty/error and
  callbacks. `widget-preview start --web-server --no-pub` compiled and served
  successfully, but the Computer Use hidden IAB browser was unavailable.
  Interactive preview-browser verification remains open; no foreground browser
  fallback was used. Component interactions were exercised in widget tests.

Native Android safe-area, hardware Back, predictive gesture and selected system
font appearance still need phone verification after integration. No APK was
installed for this change, and there is no native performance claim. Cindy owns
batch full-project checks and integration.

## Reproduce

Use the pinned SDK through `RAFT_FLUTTER_BIN` and `tool/flutter`. Run tests from
`packages/raft_ui` and `apps/raft_flutter`, respectively. Optional evidence
variables are `RAFT_COMPUTER_EVIDENCE_DIR` (component images) and
`RAFT_COMPUTER_PAGE_EVIDENCE_DIR` (mounted app images). Fonts come from the
resolved package assets and do not rely on the command's working directory.
