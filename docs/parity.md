# Visual parity against the official Raft tool

Agents adding or fixing extension surfaces: start with [parity-ext-quickstart.md](parity-ext-quickstart.md).

raft-flutter is measured with the Raft team's own cross-platform visual
parity tool (`raft-source/packages/visual-testing`, CLI `src/cli.mjs`), not a
home-grown differ. The Flutter app is plugged in as a **provider**: it writes
captures in the official provider output contract and the official CLI does
`diff`, `site` and all scoring.

## Authorized baseline fixture repair (2026-10-09)

Human message `65b111e1` authorizes fixing defective test baselines. Five
`components.thread.message-row.md-wrap-*` cases previously seeded channel
tasks with `taskNumber` alone. Missing `status` made `TaskStatusIconRoot`
throw, and `MarkdownContentErrorBoundary` showed processed raw Markdown/HTML
instead of the intended message.

`tool/reference-patches/markdown-tasks.json` now declares complete public
task fixtures shared by both providers. All five are explicitly `in_progress`;
#606 and #607 match their message text. These are declared test states,
not claims about historical live tasks. A generated Vite host replaces only
that exact fixture block in the pinned reference. Neither the Source checkout
nor reference product components are edited. The three-theme runner applies
the same fixture repair.

Capture admission checks the pinned Source commit and exact patch anchor.
Repaired cases invalidate the old cache and must show real task chips with
valid states and no render error/raw-markdown fallback. Metadata records the
fixture SHA-256 and DOM evidence. Old PNGs and metadata are archived by hash
before replacement; the existing report links them alongside the current
image. The 99-case selection, message content, geometry and official scoring
thresholds remain unchanged. Repairing a React baseline does not pass Flutter.

## Message-row markdown cluster (2026-10-10)

Run `20261010T110648Z-flutter-cf9c833` reused the same React captures as
the `cfb67cc` run. All 99 PNGs are byte-identical. The run scored 82/99:
9 pass, 73 basic-pass and 17 different.

On the unfixed 0cc2888, four cases had dropped below the pass line because
the parity harness drifted from the app:

- `login.signing`: the fixture client's `.invalid` origin went to real DNS
  through the Android local-network check, so the providers never loaded.
- agent-detail `no-computer` / `computer-missing`: the directory row now
  wins over `GET /agents/:id`, so the seeded `createdAgents` was lost.
- `composer.member-suggestions`: people now come from the entity directory,
  which was not preloaded.

The fixed root causes in the markdown rows were these colours and metrics:

| Item | Web value | Old Flutter value |
| --- | --- | --- |
| brutal message inline code | `bg-black/5 text-black` | foreground ink on strong/5 |
| elegant message inline code | `bg-fill-muted text-foreground-strong` | foreground ink |
| link colour (light / dark) | Tailwind 4 blue-700 / blue-300: `#1447e6` / `#8ec5ff` | Tailwind 3 values |
| reference chip label baseline | Blink rounded ascent plus floored half-leading | fractional metrics |

Remaining causes, all measured from the side-by-side images:

1. **Line breaking.** Web uses `overflow-wrap: anywhere` for inline code. A
   token longer than a line moves to the next line first. SkParagraph breaks
   it at once on the current line. The code's padding placeholders also add
   break opportunities that Blink does not have, for example after `（`.
   Blink does not break after `/` before a letter, but ICU does.
2. **Host font fallback.** Chromium on this host draws `。` and `→` from Noto
   Sans Mongolian / Liberation Sans.
3. **List item gap.** It is 4px in Flutter (`blockSpacing`) and `mb-0.5`
   (2px) on the Web.
4. **Text rasterisation.** Chromium's text gamma and contrast differ from
   Flutter's Skia. About half of all ink pixels differ even when glyph
   positions match exactly, so text-dense captures stay at about 93–95%
   pixel-perfect after their layout matches.

Per-row classification of the 17 remaining `different` rows at that time
(run `20261010T112612Z`, `.local/parity-final/classify*.py`; superseded by
"Official-suite root causes (2026-10-11)" below). Each mismatched
pixel was put into one of four buckets:

- **AA**: another-image pixel within 1 device px differs by <= 40/255.
- **subpx**: the same, within 2 device px.
- **other**: everything left after AA and subpx.
- **visible**: differs by more than 40/255 after a 1-CSS-px Gaussian blur.

React used production fonts and `--disable-lcd-text --font-render-hinting=none`
(`textRendering.chromiumArgs` in all 99 metadata files).

| row | exact | AA | subpx | other | visible | remaining real difference |
| --- | --- | --- | --- | --- | --- | --- |
| ui.card.states.elegant | 6.83 | 6.66 | 0.12 | 0.06 | 0.00 | none: rasteriser only (text coverage, shadow blur ±1 level) |
| members.avatar-management | 5.05 | 4.55 | 0.28 | 0.23 | 0.00 | none: rasteriser and fractional border edges |
| message-row.deleted-human | 4.37 | 3.51 | 0.47 | 0.39 | 0.00 | none visible: badge border at fractional x, `+` icon stroke coverage |
| thread.message.row | 5.68 | 4.02 | 0.84 | 0.82 | 0.01 | `+` add-reaction icon stroke slightly heavier |
| create-agent.dialog-onboarding | 4.34 | 2.64 | 0.82 | 0.88 | 0.85 | section borders 0.3–0.7 CSS px off (Blink snaps borders to device px) |
| message-row.rich-content | 5.19 | 3.38 | 0.85 | 0.97 | 0.44 | link underline thickness/offset |
| message-row.long-inline-code | 5.76 | 3.78 | 0.86 | 1.12 | 0.67 | line with the 20px unknown-task badge does not grow: flutter_markdown_plus forces a strut, Web grows the line box (+2px below) |
| message-row.md-wrap-adjacent | 6.31 | 4.32 | 0.72 | 1.27 | 0.16 | `。` drawn by host fallback font (Noto Sans Mongolian) in Chromium |
| message-row.md-wrap-task607 | 7.34 | 4.48 | 1.05 | 1.81 | 0.70 | `→` / `。` host fallback fonts |
| message-row.md-link-ref | 6.99 | 3.81 | 1.21 | 1.97 | 1.31 | link underline 2px at baseline+2 (Web) vs font-metric ×2 (≈1.1px, 1px higher) |
| message-row.md-latest-release | 8.69 | 6.08 | 0.73 | 1.88 | 1.71 | Flutter breaks inside `` `/share/<token>` `` after `/` |
| message-row.md-wrap-slice1 | 9.10 | 5.98 | 1.24 | 1.88 | 1.76 | list item gap 4px vs `mb-0.5`; fallback `。`/`→` |
| composer.pending-mention-actions | 4.15 | 3.22 | 0.06 | 0.87 | 1.59 | composer keeps focus after button send (shadow-md); Source blurs on click send |
| message-row.md-wrap-clarify | 11.15 | 5.24 | 1.98 | 3.93 | 4.84 | break after `（` before inline code (padding placeholders add break opportunities) |
| settings.notifications.page | 9.71 | n/a | n/a | n/a | n/a | intended difference: Web Web Push card vs Flutter phone card (see below) |
| message-share.selection | 5.81 | 1.31 | 0.04 | 4.46 | 6.63 | bottom-anchored real chat with date divider; square vs circular select checkbox; no Owner badge |
| message-row.md-wrap-status606 | 16.63 | 7.96 | 1.92 | 6.76 | 9.61 | long inline code breaks on the current line instead of moving down (`wrap-anywhere`); break after `/` |

## Official-suite root causes (2026-10-11)

Starting point: integration 80769ee, official run `20261010T144652Z`
(published as `raft_flutter_parity/latest`): 83/99. Branch
`cindy/parity-official` fixes, each verified with a full 99-case run
(no case got worse in any step):

| fix | cause class | cases |
| --- | --- | --- |
| Composer Send no longer requests editor focus (Source only prevents the Send pointer-down blur) | missing state | composer.pending-mention-actions 95.85 -> 96.83 (pass) |
| `RaftCssText` aligns the glyph baseline SkParagraph actually paints (`round(reported)`, e.g. 12/20 Hanken reports 14.182, paints 14) | layout metric | 34 cases up, 0 down; create-agent.dialog-onboarding 95.66 -> 95.97 |
| CSS `font-black` renders the served 700 face (`RaftTypography.black`); w900 + `wght 700` was also synthetically emboldened (+29% ink) | font | dialog-onboarding -> 96.01 (pass) |
| Brutal departure badge keeps the 20px sender line (inherited 20/14 ratio at 10px grew the header by 1/3px) | layout metric | message-row.deleted-human 95.73 -> 96.57 (pass) |
| Message task chip label uses the Blink line box (13px on 16.25px: Blink baseline 12, Flutter rounded 12.63 -> 13) | layout metric | message.row +0.32, md-link-ref +0.20, rich-content +0.14, long-inline-code +0.07 |

Result on the branch: **86/99** (10 strict passes).

### Why the remaining 13 rows stay below 96%

Measured with a 1-device-px tolerance (`aa` = mismatches that disappear when
a pixel may match a neighbour within 40/255; `ifAA` = pixelPerfect if those
were equal):

* **Text rasterisation (dominant, not fixable in app code).** Flutter's
  SkParagraph shapes every run with FreeType *slight* (vertical) hinting:
  a 36px `C` (Hanken Grotesk) covers rows 75..99 for a baseline at 100,
  i.e. the overshoot is snapped away; Chromium with
  `--font-render-hinting=none` draws it unhinted (rows 74..100, partial
  coverage). Chromium also applies its A8 gamma/contrast, ~7% more ink.
  Glyph advances match to 0.01px, so the difference is pure coverage: 4-10%
  of all pixels in text-dense captures. No Dart API changes hinting.
* **Blink pixel snapping of box edges.** Blink paints borders/backgrounds at
  whole CSS px; Flutter paints fractional rects anti-aliased (e.g. 18.25px
  task chips, 0.5px-offset chip rows). Owned by the ext-suite border
  primitive work, not changed here.
* **Line breaking (markdown rows).** Inline-code padding placeholders
  (U+FFFC) are ICU break opportunities, ICU breaks after `/` before a
  letter (Blink's ASCII table does not), SkParagraph force-breaks an
  over-long code token on the current line instead of moving it down first
  (`overflow-wrap: anywhere`), and Chrome's default `text-spacing-trim`
  halves adjacent CJK punctuation (`），`). A word-joiner fix needs a
  copy-stripping selection delegate; not done in this pass.
* **Host fallback fonts:** Chromium draws `→`/`。` from Liberation/Noto
  Sans Mongolian on this host.

| row | pixelPerfect | ifAA | aa | remaining difference |
| --- | --- | --- | --- | --- |
| members.avatar-management | 95.14 | 99.77 | 4.63 | text raster; chip/env rows behind the scrim sit 0.5px off (Blink snaps) |
| thread.message-row.rich-content | 94.94 | 99.06 | 4.12 | text raster; chip borders at fractional y (snap); link underline thickness |
| thread.message.row | 94.64 | 99.24 | 4.60 | text raster; 18.25px task chip border snap; `+` icon stroke |
| thread.message-row.long-inline-code | 94.32 | 98.90 | 4.58 | text raster; unknown-task line box does not grow (strut); code break position |
| thread.message-row.md-wrap-adjacent | 93.69 | 98.73 | 5.04 | text raster; `。` host fallback font |
| settings.notifications.page | 90.29 | n/a | n/a | intended difference: the case mounts Web's browser Web Push card ("Push Notifications", Enable/Send Test Push); Flutter shows the phone card ("Phone notifications", permission-based, no server push). Desktop parity is covered by `components.notifications.desktop.*` in the extension suite |
| thread.message-row.md-link-ref | 93.20 | 98.07 | 4.86 | text raster; link underline 2px at baseline+2 vs font metric |
| ui.card.states.elegant | 93.17 | 99.94 | 6.78 | shadow blur and gradient dither +-1 level (4.3% of pixels differ by exactly 1); text raster |
| thread.message-row.md-wrap-task607 | 92.66 | 98.19 | 5.53 | text raster; `→`/`。` fallback fonts |
| thread.message-row.md-latest-release | 91.31 | 98.12 | 6.80 | ICU breaks inside `/share/<token>` after `/` |
| thread.message-row.md-wrap-slice1 | 90.92 | 98.13 | 7.21 | list item gap 4px vs `li mb-0.5`; `），` punctuation trim; fallback `。`/`→` |
| thread.message-row.md-wrap-clarify | 88.86 | 96.07 | 7.21 | inline-code padding placeholder lets `（` + code break apart; cascades |
| thread.message-row.md-wrap-status606 | 83.37 | 93.24 | 9.87 | long inline code force-broken on the current line; break after `/` |

## One command

```bash
tool/parity run                       # React (cached) + Flutter capture, official diff + site, summary
tool/parity run --cases 'components.ui.*'   # recapture a subset; diff/site/summary still cover every case
tool/parity run --refresh-react       # also recapture the React baselines
tool/parity publish                   # copy site to the report hub, update latest, verify URLs + images
tool/parity summary                   # recompute build/parity/summary.json from the last diff
```

Environment overrides: `PARITY_RAFT_SOURCE` (raft-source checkout),
`PARITY_OUT` (default `build/parity`), `PARITY_TOOLCHAIN_PATHS` (file listing
the Node 24 / pnpm 10 binaries), `PARITY_REPORTS_ROOT`, `PARITY_BASE_URL`,
`PARITY_WEB_PORT` (Vite port for the React provider, default 4391),
`PARITY_SHARDS` (parallel `flutter test` processes, default 4).

Published report: <http://100.109.192.23:18931/raft_flutter_parity/latest/>
(each run is kept under `raft_flutter_parity/<UTC timestamp>/`).

## How it is wired

| Step | What runs | Output (`build/parity/`, gitignored) |
| --- | --- | --- |
| React baseline | official React provider spec + Playwright config, run as a generated copy with production fonts (see "Baseline fonts"; `--react-fonts upstream` runs the unmodified `cli.mjs capture --providers react`) — Playwright + `packages/web/visual-testing` Vite host, 390x844 @3x | `visual-testing-results/react/<case>.png` + `.metadata.json` |
| Flutter provider | `flutter test apps/raft_flutter/test/parity/parity_capture_test.dart`, sharded | `visual-testing-results/android/<case>.png` + `.metadata.json`, `android-case-map.json` |
| Diff | official `cli.mjs diff --pairs react__android --manifest shared` | `visual-testing-results/diff/react__android*` |
| Site | official `cli.mjs site --pairs react__android --skip-analysis --site-dir build/parity/site` | `site/` (storybook-style home, `latest/`, `runs/<id>/`) |
| Summary | `tool/parity` reads the official diff JSON + Flutter case map | `summary.json` (also `site/flutter-parity-summary.json`) |

The CLI runs with `SLOCK_VISUAL_REPO_ROOT=build/parity` and
`SLOCK_REACT_REPO_DIR=<raft-source>`, so every result lands outside the
raft-source tree (Playwright's scratch `packages/web/test-results/` is the only
write there; it is untracked).

Exact command of the FIRST (upstream-font) React baseline, kept for
reference; the current baseline uses production fonts, see below (run from
`raft-source/packages/visual-testing`, Node 24.21.0 first on `PATH`, all
`npm_config_*` variables unset):

```bash
SLOCK_VISUAL_REPO_ROOT=<flutter-worktree>/build/parity \
SLOCK_REACT_REPO_DIR=<raft-source> PLAYWRIGHT_WEB_PORT=4391 \
node src/cli.mjs capture --providers react --manifest shared --webPort 4391
```

Result: 152 Playwright tests passed (99 provider captures + the package's
metric specs), 99/99 React captures. Provenance (raft-source commit and dirty
files at capture time) is in `build/parity/react-source.json`.

One-time host setup that was needed: the pinned `@playwright/test` 1.59.1
wants `chromium_headless_shell-1217`, and Playwright refuses to download on
Ubuntu 26.04, so it was installed with
`PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 pnpm exec playwright install chromium`
from `raft-source/packages/web`.

### Provider identity

The CLI's pair model knows `react > android > ios > ohos`. The Flutter
provider therefore writes under provider **`android`** and records itself in
metadata as `"source": "flutter"`, `"providerType": "flutter-widget-test"`
(README: "If Android or Harmony renders KMP/shared UI, record that as the
provider `source`"). `diff --pairs react__android` and `site` work unmodified.

### Flutter capture contract

* Each official case is pumped in a `flutter test` widget test at the case
  viewport (`physicalSize = width x height x density`, `devicePixelRatio =
  density`, i.e. 390x844 @3x → 1170px wide like React).
* Theme follows the React render host: `.elegant` case ids → elegant light,
  everything else → brutal light, via `raftTheme(...)` / `RaftTokens`.
  No official case declares elegant-dark, so dark has 0 official units.
* Target platform is Android (`TargetPlatformVariant.only(android)`), so
  `RaftDensityScope` resolves to touch density exactly as on a phone.
* Real fonts: every family in the app's `FontManifest.json` (raft_ui
  HankenGrotesk/Geist/GeistMono/Inter/RaftDiagramSans, MaterialIcons) is loaded
  with `FontLoader`, plus the system Noto Sans CJK / Noto Color Emoji files
  for the families the theme names as fallbacks. Ahem is never used.
* The full viewport is rasterised (`RenderRepaintBoundary.toImage(pixelRatio:
  density)`) and cropped to the case target rect, like Playwright's clipped
  page screenshot (overlays/portals above the target are included; rects
  outside the viewport are clamped like React). `body` selectors and
  `modal-viewport` / `viewport-with-portal` contracts capture the viewport.
* A case that throws during build/layout fails and writes no image (it is
  counted as `flutter-capture-failed`, never as a stale or error-screen image).
* Metadata carries `typography` and `styleTokens` probes (README "style
  probes"), auto-collected from `RenderParagraph` / `RenderDecoratedBox`
  inside the target, plus the Flutter widgets exercised.

### Coverage map

`apps/raft_flutter/test/parity/case_map.dart` merges one map per group in
`apps/raft_flutter/test/parity/cases/*.dart`: `case id → ParityCase(builder)`.
A case without a builder is NOT COVERED. Reasons are explicit
(`ParityUncovered`): `harnessTodo` (builder not written yet),
`noFlutterSurface` (the Flutter app has no implementation of that surface),
`deviceOnly` (needs a real device). The map for every manifest case is written
to `build/parity/visual-testing-results/android-case-map.json`.

Builders compose the **real** raft_ui / app widgets in the same fixture frame
the React render host uses for that case id (frame size, padding, content
from `shared/fixtureData.json` etc.). They never patch product visuals; when
Flutter lacks a variant, the nearest product widget is rendered and the diff
shows the gap.

## Baseline fonts: production Google Fonts instead of the upstream Space Grotesk stub

**Deviation from the official spec, decided by the owner:** the target is the
production Web, so the React baseline must render the real raft-ui fonts.

Why: the upstream provider spec (`tests/react-provider.spec.ts`, `quietApi`)
fulfils raft-ui's font URL
(`css2?family=Geist…&family=Geist+Mono…&family=Hanken+Grotesk…&family=Inter…`)
with `packages/web/src/assets/fonts/fonts.css`, which only declares Space
Grotesk and Space Mono, and answers every other Google Fonts request with 502.
raft-ui's stacks (`Hanken Grotesk, system-ui, sans-serif`, Geist, Inter, Geist
Mono) therefore fell back to Chromium's system-ui (Noto Sans) — not what
production Web shows. (Production `index.css` imports only raft-ui's URL plus
the `Raft Quote Glyphs` woff2; the Space Grotesk URLs are not requested by the
product.)

What `tool/parity run` does now (raft-source untouched):

* `tool/parity-fonts/` (committed, 492 KB, OFL): the exact CSS Google returns
  for raft-ui's URL to the pinned Chromium 147 UA (identical to the headed
  Chrome 147 response) and all 22 woff2 files it references, sha256-pinned in
  `manifest.json`. `tool/parity fonts` verifies, `--refresh` refetches.
* The official spec and Playwright config are copied into
  `build/parity/react-provider/` and patched; every patch anchor must match
  exactly once or the run stops. Changes: path wiring (spec runs outside its
  package); raft-ui's URL and its gstatic files are fulfilled from the cache
  (the legacy Space Grotesk URL mapping and the Quote Glyphs file stay as
  upstream); the font-readiness assertions probe Hanken Grotesk, Geist, Geist
  Mono, Inter (400/700) + Raft Quote Glyphs and require each family's files to
  be served; every capture's metadata gains `fontFaces` (document.fonts
  status) and `platformFonts` (the faces Chromium actually drew, via CDP
  `CSS.getPlatformFontsForNode`). Everything else is the official spec,
  invoked with the same env as the CLI's `runReactProvider`.
* Verified across all 99 captures (glyphs drawn): Hanken Grotesk 45,327,
  Geist Mono 16,262, Inter 521, Geist 45; system fonts only for glyphs outside
  the served subsets (Noto Sans CJK 1,060 for Chinese text, plus 32 symbol
  glyphs from Noto Sans Mongolian/DejaVu Sans Mono) — the same fallback the
  production page gets on this host. E.g. `components.ui.card.states` →
  Hanken Grotesk only; `components.ui.card.states.elegant` → Inter + Geist;
  `message-row.long-inline-code` → Hanken Grotesk + Geist Mono.

Flutter side: `packages/raft_ui/assets/fonts` were compared with Google's
served files (fontTools, every Google-served codepoint, wght 300–700,
outlines + advances + vertical metrics): Geist 1.800, Geist Mono 1.701 and
Hanken Grotesk 3.013 are identical. Inter 4.001 had the same outlines at
opsz 14 but carried the `opsz` axis, and raft_ui's theme varies opsz up to 32
for elegant headings, while Google serves Web a wght-only Inter (opsz pinned
at 14). `Inter.ttf` is now derived from the same pinned upstream file with
opsz pinned at 14 (`tool/parity-fonts/derive_inter.py`, provenance in
`docs/inter-font-provenance.json`); it is outline-identical to every Google
Inter subset at all tested weights. The theme's `FontVariation('opsz')` is now
inert, matching Web. raft_ui tests: 571 passed.

## Text rendering: React captures emulate Android Chrome

**Owner decision:** the official cases are mobile (390x844 @3x) and their
production target is Android, where Chrome rasterises text with grayscale
anti-aliasing and subpixel glyph positioning (fractional advances). Desktop
Linux Chromium — what the pinned Playwright headless shell is — defaults to
LCD subpixel AA (coloured fringes) and hinted, whole-pixel glyph advances.
Flutter draws grayscale AA with fractional advances, so the desktop default
added rasteriser noise to every text pixel and shifted text runs by whole
pixels.

Flags (added to the generated Playwright config as `launchOptions.args`,
`tool/parity run --react-text-render android`, the default; `desktop` restores
the Chromium default): `--disable-lcd-text --font-render-hinting=none`.
`--disable-lcd-text` forces grayscale AA; `--font-render-hinting=none`
disables FreeType hinting, which on Linux is what enables subpixel
positioning and unrounded advances. No other flag was needed.

Evidence (`tool/parity render-evidence` → `build/parity/render-evidence/`:
neutral ink on white in the production fonts, same Chromium, 3x; plus the
refreshed captures' metadata):

| check | desktop default | `--disable-lcd-text --font-render-hinting=none` |
| --- | --- | --- |
| (a) LCD pixels (per-channel coverage spread > 0.08) in the synthetic text page | 25,321 | **0** (0 chromatic pixels at all) |
| (a) pixels that are not a single-coverage blend of two flat colours, `components.settings.notifications.page` | 41,297 | **0** |
| (a) same, `components.ui.badge.states` | 3,359 | 752 (dark-pink text on pink badge: a text colour below the flat-colour threshold, grayscale on inspection) |
| (b) badge text run widths (Shared / Installed / Update / Built In / task #273 / Install) | 46 / 54 / 47 / 47 / 62 / 43 | 46 / 52.84 / 46.5 / 45.48 / 59.80 / 41.69 |
| (b) synthetic runs: Hanken 400 14px, Hanken 700 16px, Geist 400 14px, Inter 600 18px, Geist Mono 400 13px | 378 / 431 / 309 / 408 / 424 | 367.31 / 427.03 / 304.64 / 406.39 / 413.41 |
| (b) Flutter `TextPainter`, same strings and fonts | | 367.30 / 427.02 / 304.64 / 406.39 / 413.40 |
| (c) faces loaded (document.fonts) | Geist, Geist Mono, Hanken Grotesk, Inter | same; all 99 captures have every Geist / Geist Mono / Hanken Grotesk / Inter / Raft Quote Glyphs face `loaded` |

With the flags Chromium's text advances match Flutter's to within 0.01 px.
Across the 99 refreshed captures, 942 of 1,969 probed text runs have
fractional widths (`textRendering.textRunWidths` in each React metadata JSON;
the rest are elements whose box width comes from layout, e.g. block
elements sized by their container, not from their text).

## Capture determinism: animations and carets

* **React animations:** the upstream spec takes screenshots with Playwright's
  default `animations: "allow"`, so animated elements were caught mid-frame:
  Skeleton's `animate-pulse` at opacity ~0.999 (greys 231/243 instead of the
  at-rest #e5e5e5 = 229 / 242), and the Spinner mid-rotation (arc at 3
  o'clock) because its `animation: none` style does not reach the rotating
  inner element. The generated spec now passes `animations: "disabled"` to all
  four screenshot calls (the run stops if upstream's call count changes):
  finite animations/transitions finish, infinite ones reset to their initial
  frame — the at-rest first frame the Web shows before animating.
* **Spinner frame:** React's at-rest frame is rotation 0 (arc centred on 12
  o'clock). Flutter's `RaftSpinner` under reduced motion paints rotation 0,
  i.e. its own t=0 frame (brutal has no dash phase). The two t=0 frames
  differ in arc start angle (Flutter's arc spans ~9:30–12:30); that is a
  `RaftSpinner` painter difference left for the UI track, not a capture issue.
* **Flutter caret:** Playwright captures with `caret: "hide"`. The harness
  already made the theme's cursor colour transparent, but product fields now
  set `cursorColor` explicitly, so the harness also sets every
  `RenderEditable.cursorColor` to transparent for the captured frame and
  repaints with a zero-duration pump (no blink-timer advance, no product
  change). Verified: `components.ui.selection-popover.states` shows no caret.

Effect on integration 053ffa0 (Flutter identical before/after; React refreshed
with the new option): skeleton 60.15% → 62.36%, spinner 98.11% → 98.94%
(basic-pass), selection-popover 95.39% → 95.43%; four other cases moved by
<= 0.04pp; total stays 29/99 (29.29%), mean pixelPerfect over 95 captured
80.38% → 80.42%.

## Scoring

Unit = official case x variant x theme. Every default case (non-skipped,
non-pending, the CLI's default selection) declares exactly one variant and one
theme, so units = cases.

* **passing** = official diff status `same | pass | basic-pass`
  (pixelPerfectSimilarity > 96%; this is the site's own pass count).
  `strictPass` (> 99%) is reported separately.
* **failing** = both providers captured, status `different`.
* **not covered** = no Flutter builder (any reason).
* **percentage = passing / total**.

## Latest result (production-font baseline)

Report: <http://100.109.192.23:18931/raft_flutter_parity/latest/> (every run
is kept as `raft_flutter_parity/<UTC timestamp>/`). Machine-readable:
`latest/flutter-parity-summary.json`, per-case table `latest/flutter-parity-summary.md`.

| baseline | units | React | Flutter | passing (>96%) | strict (>99%) | failing | not covered | percentage | mean pixelPerfect of 92 captured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| upstream font stub (run 20261008T220459Z) | 99 | 99 | 92 | 4 | 1 | 88 | 7 | 4.04% | 74.08% |
| production fonts + opsz-pinned Inter | 99 | 99 | 92 | 4 | 1 | 88 | 7 | 4.04% | 74.36% |
| + Android text rendering (current) | 99 | 99 | 92 | 5 | 1 | 87 | 7 | **5.05%** | 74.81% |

Android text rendering (current vs the previous row): passes are now
titlebar 99.48% (pass), spinner 98.11%, composer.empty 97.13%,
section-eyebrow 96.49% (new) and agent-detail.workspace 96.25%. 69 cases
improved, 1 got worse, 22 unchanged (|delta| <= 0.05pp). Top movers:
message.row +4.11pp, message-row.deleted-human +3.25, long-inline-code +2.65,
md-wrap-task607 +2.22, composer.states +2.20, composer.as-task-selected +2.18,
files.list +1.76; only drop message-row.rich-content -4.70 (82.00%): the React row
reflowed with the new advances (now 386 px tall vs Flutter's 380), which
shifts every line below the change.

Production fonts vs upstream stub (previous row vs first row): the pass set
was unchanged (titlebar 99.32%, spinner 98.11%, composer.empty,
agent-detail.workspace). Per-case pixelPerfect: 72 cases improved, 10 got
worse, 10 unchanged (|delta| <= 0.05pp); largest gains button.states +1.70pp,
message.row +1.58, message-row.deleted-human +1.42, long-inline-code +1.35,
card.states +1.20; largest drops spinner -0.44, md-wrap-status606 -0.41,
md-wrap-task607 -0.37. Text is a small fraction of most captures and the
remaining gaps are layout/component differences, so correct fonts move scores
only slightly; the gain is that text comparisons are now letterform-true.

By theme: brutal-light 4/94, elegant-light 0/5, elegant-dark 0/0 (no official
case declares dark; the React host only renders brutal and `.elegant`).

Caveat on `screens.members.agent-detail.workspace` (basic-pass): it passes
only because both screens are mostly white; the Flutter screen
(FleetInspection "Workspace files") is visibly different from React's tabbed
agent page. The official metric counts exact pixel matches, so large blank
areas inflate full-viewport scores — read screen-level numbers with the
side-by-side images.

Not covered (7):

| case | gap | reason |
| --- | --- | --- |
| components.ui.badge.states | noFlutterSurface | no shared Badge widget; only private single-use labels |
| components.ui.status-dot.states | noFlutterSurface | no standalone status dot (only private avatar presence overlay) |
| components.thread.composer.pending-mention-actions | noFlutterSurface | no Add/Notify/Ignore pending-mention strip; send response field ignored |
| components.thread.comment-anchor | noFlutterSurface | no attachment comments surface/API use |
| components.members.avatar-management | noFlutterSurface | no agent avatar picker |
| screens.members.agent-detail.reminders | noFlutterSurface | FleetDetail has no reminders; nothing requests reminders |
| components.home.notification-center.states | invalidBaseline | React fixture renders an empty 390x844 box; an empty-vs-empty 100% would be hollow |

Reproducibility: two consecutive Flutter captures of all 92 cases were
byte-identical.

## Extension suite (raft-flutter additions, not official cases)

**Dark sampling (2026-10-11, owner decision).** Elegant-dark only re-skins
elegant-light, so `tool/parity-ext/run` writes `<out>/cases.sampled.json` with
ONE elegant-dark case per surface (first id per `components.<area>.<surface>`)
and runs/diffs/scores against it; brutal and elegant-light stay complete.
`PARITY_EXT_ALL_DARK=1` restores every dark case. With 738 cases this keeps 39
of 246 dark cases (531 total).

Surfaces the official 99-case set does not cover are compared on the **same
official framework** in a separate suite, so official and added coverage
never mix. The official manifest, specs and Source checkout are untouched;
everything below is generated from this repository.

| piece | file | role |
| --- | --- | --- |
| manifest | `build/parity-ext/cases.json`, generated on every `run` by the `tool/parity-ext/build-*.py` builders (ordered by `tool/parity-ext/builders.txt`; never committed) | `sharedCases.json` schema; ids `components.computers.<surface>.<theme>`; per-case `viewport` (desktop 1280 wide, density 1), `capture.selector` (React crop), `capture.androidKey` (the Flutter `ValueKey` of the same region), `capture.interactions` / `capture.androidInteractions` |
| fixture | `tool/parity-ext/fixtures/computers.json` | data both providers render (machines in every state, the two official agents placed on `computer-mbp`, workspaces, follow-up API routes) |
| React render host | `tool/parity-ext-web.mjs` + `tool/parity-ext/host/*.tsx` | the pinned official Vite host with generated, anchor-checked additions: the `parityTheme` root override (brutal-light / elegant-light / elegant-dark, as `tool/theme-parity-web.mjs`), the host files appended to a generated `VisualTestingCases.tsx` whose default export asks the extension registry first (official ids fall through unchanged), and the fixture as `virtual:parity-ext/computers` |
| React provider | generated copy of the official spec/config (same as `tool/parity`) plus three anchored patches | answer the fixture's `routes` and the case's machine list with `page.route`, a `hover` interaction, park the pointer after click-only interactions (Flutter taps leave no hover); `deviceScaleFactor` follows each case's density; `reuseExistingServer: false` |
| Flutter provider | `test/parity/parity_capture_test.dart` with `PARITY_MANIFEST` / `PARITY_EXT_FIXTURES`; builders in `test/parity/cases/ext_computers.dart` | desktop cases run with `TargetPlatform.linux` (pointer density); `capture.androidKey` selects the crop; `capture.androidInteractions` tap/hover keyed widgets |
| diff / site | official `cli.mjs diff` and `site` with `--manifest build/parity-ext/cases.sampled.json` | unmodified CLI |
| runner | `tool/parity-ext/run {run,summary,publish}` | reuses `tool/parity`; output `build/parity-ext/`; publish to `raft_flutter_parity_ext/<stamp>` + `latest` (never `raft_flutter_parity/`) |

```bash
tool/parity-ext/run run                          # builders -> manifest, React (shared cache) + Flutter, official diff + site
tool/parity-ext/run run --cases 'components.computers.detail.*' --refresh-react
tool/parity-ext/run publish
```

### Members / agents / activity / saved extension family (2026-10-11)

`tool/parity-ext/build-member-cases.py` (fixture `fixtures/members.json`, React host
`host/MemberCases.tsx`, Flutter `test/parity/cases/ext_members.dart`) adds 30 surfaces
x 3 themes = 88 sampled cases `components.members-ext.*`: members directory list
(default, group collapsed, selected human, row hover, empty, loading, error), human
profile (owner/admin/member/guest/self/no-description, external identity, edit role,
remove confirmation), agent detail tabs (profile, activity log empty/loading/error,
reminders, workspace, apps, MCP incl. empty/loading), reset-agent dialogs (restart,
session, full), profile edit dialogs (name, description, role), Invite human dialog
(default, guest role select), Activity empty/loading/error and Saved empty/loading/error.
`extFixture: "members"` pins the fixture file (the settings fixture's `GET /agents`
would otherwise shadow the roster). Final run: 74/88 at >=98 % non-text geometry,
84/88 at >=95 %, 22 at >=99.5 %; the rest is text anti-aliasing, the avatar
badge-dot, and loading-skeleton pulse phase (Activity/Saved loading elegant ~78 %).

No Flutter equivalent (so no case; not built here): report-issue dialog, agent
unavailable panel, role-permission help dialog, seat-limit banner in the invite dialog.
Flutter has agent migration (`agent_migration_view.dart`) but no extension case was
added for its dialogs/progress yet.

### Manifest generation (2026-10-11)

`tool/parity-ext/cases.json` is no longer committed (it was the one file every
parallel branch that added a family had to merge). Every `tool/parity-ext/run`
invocation runs all `tool/parity-ext/build-*.py` into `<out>/cases.json`
(`PARITY_EXT_MANIFEST`, `builders.py`) in the order of `builders.txt`; a
builder missing from the registry still runs, last and alphabetically, with a
warning. The dark-sampled `cases.sampled.json` is derived from it; the Flutter
capture reads it through `PARITY_MANIFEST` (`case_map.dart` never read the
file). Builders replace only their own `components.<area>.*` cases, so the
result is order independent apart from case order. The generated
`fixtures/*.json` stay committed: the Flutter capture (`PARITY_EXT_FIXTURES`),
the Vite host (`virtual:parity-ext/*`) and the spec's route table read that
directory directly, and the hand-written fixtures (announcements,
composer-attachments) live next to them; builders rewrite them in place, so a
changed fixture shows up in `git status` and is committed with its builder.

### Shared React capture cache (2026-10-11)

React captures are content addressed and shared by every worktree in
`/home/kevinzhow/github/raft-flutter-wt/.parity-cache/react/<key>.png`
(+ `.metadata.json`, `.key.json` with the key's inputs; `PARITY_EXT_CACHE`
overrides; `tool/parity-ext/react_cache.py`). The key hashes: the raft-source
commit and its uncommitted diff; the case JSON without Flutter-only fields
(`androidCaseHint`, `capture.androidKey/androidInteractions`, `notes`,
`tolerance`, `reactPathHint`); the fixture files read by the host file(s) that
render the case (other fixtures contribute only their route keys, because the
generated spec registers every fixture's routes for every case); those host
`.tsx` files plus any host file whose top-level declarations they use;
`tool/parity-ext-web.mjs`, the extension spec/config patches, `tool/parity` and
the helper modules that patch the official spec, `tool/reference-patches`,
`tool/parity-fonts`; the render flags (`TEXT_RENDER` Chromium args, density is
part of the case). A hit is copied into the results directory and Playwright
is skipped when every selected case hits; a miss is captured and stored
(temp file + rename, metadata last, so concurrent worktrees never see a partial
entry). `--refresh-react` recaptures and overwrites. A selected case's stale
results-dir image is deleted before capture, so a failed capture cannot pass
off an old image. `dom-dump` bypasses the cache.

### Non-text score and geometry pass (2026-10-11)

The official score counts a pixel only if its RGBA is exactly equal, so glyph
anti-aliasing noise decides many cases that are geometrically right.
`tool/parity-ext/analyze-diffs.py` (bucket classifier from
`cindy/parity-primitives`: fill, hairline, corner, offset, text, other) is run
on every captured pair by `run`/`summary`; `summary.json` / `summary.md` add per
case `nonTextSimilarity` (the score if the `text` bucket matched, i.e. dense
ink that no whole-pixel shift explains), `textShare`, `geometryPass`
(`nonTextSimilarity >= 99.5%`), and a per-area table (`byArea`). The official
`pixelPerfectSimilarity`, the 96% pass and the `site` are unchanged; the
geometry pass is an additional, informational verdict. Caveat: the `text`
bucket can also absorb a wrong glyph or a clipped line, so read `textShare`
beside it; a large share means check the text by eye once. Threshold: 99.5% leaves under half a percent of the
crop for non-text differences (a stray hairline or a few misplaced icon
pixels); on the first full run (531 cases) the count is 92 at 99.5%, 154 at 99%,
265 at 98% and 19 at 99.8%, and only 6 of the 92 are not already official 96%
passes. Text anti-aliasing is only ~1.5-3.5% of the crop on average, so the
residual in the 98-99.5% band is mostly hairlines and `other` pixels, which is
why geometry pass is stricter than the 96% pass for most cases (113 official
passes fail it). Results are memoised
by PNG content hash in `<out>/non-text-memo.json`. `run --cases` and
`summary --cases` report only the selected cases.

Text rendering uses the same Chromium flags as the official run (`--disable-lcd-text
--font-render-hinting=none`, see "Text rendering"), so remaining text
differences are layout or style, not rasteriser noise.

### Computers cases (41 surfaces x 3 themes = 123)

Derived from Web `Sidebar.tsx` computers mode + `ComputerRow`,
`MachineDetailPanel.tsx`, `AddMachineDialog.tsx` + `ComputerCommandGuide.tsx`
at raft-source 26f77ef:

* list (240x800 Sidebar column): rows, every row state (online current with
  description, outdated, offline, upgrading, low disk, legacy daemon), empty,
  loading, selected row, hovered row;
* detail (976-wide desktop detail column, 1280x2000 so nothing scrolls):
  whole panel, then one crop per section — header, identity, Name,
  Description, Info, Agents on this computer, Agent Workspaces, Computer
  service card, Recovery guide, Delete;
* detail states: offline (+ its recovery card crop), up to date, upgrading,
  low disk, legacy daemon, one-click upgrade (`remote_computer_upgrade_v2`);
* interactions: editing name / description, agent selection mode, all agents
  selected (bulk bar), scanned workspaces, recovery guide expanded, offline
  install/setup commands expanded, restart in progress;
* dialogs: restart/reset selected agents, stop agents, delete workspace,
  cannot delete (agents assigned), delete computer, Add Computer (type and
  connect steps);
* runtime usage (RuntimeAccountUsageChip, `computer-usage` fixture machine
  with a fresh Claude snapshot and no Codex snapshot, times relative to the
  fixture instant): Info section with the chip health Status, and the usage
  hover card after hovering the Claude chip.

Not covered on purpose: CreateAgentDialog
from "Create" (covered by the official create-agent cases), the Add
Computer "connected" step (needs a live socket event).

### Computers result (run 20261010T134947Z, ea1c3d5)

Report: <http://100.109.192.23:18931/raft_flutter_parity_ext/latest/>
(`raft_flutter_parity_ext/<stamp>`; the official `raft_flutter_parity/` is
untouched).

| | React | Flutter | passing (>96%) | failing | Flutter capture failed |
| --- | --- | --- | --- | --- | --- |
| before (pre-port UI, same suite) | 117 | 18 | 3 | 15 | 99 (no matching section / control) |
| after | 117 | 117 | 23 | 94 | 0 |

Before, the Computer detail was a Material `ListView` (Status / Hostname /
OS / version tiles and an action list) and the rail rows were one-line nav
items, so 99 section, state, interaction and dialog cases had nothing to
capture. After the port every case renders the same structure; all 117
crops have identical sizes on both sides.

Reading the numbers: the official metric is exact-pixel equality, so text
anti-aliasing (light-on-dark mono code, Chromium vs Skia stem darkening)
and Chromium's pixel snapping of borders at fractional layout positions
(the Description line box is 22.75px, so everything below it sits at .75)
keep text-dense crops near 86–95% even when geometry matches. The
remaining delta>24 mismatch per case is 0.5–11%; the highest are the
small row/agent crops (one row of text over a 50px crop) and the bulk bar.
Remaining channel deltas of 1-2 on flat translucent fills are Chromium's
blend arithmetic, not token values: Chromium quantises the colour to 8-bit
RGBA before compositing and its 8-bit pipeline truncates, while Flutter
blends in float and rounds. Checked numerically: brutal `bg-brutal-orange/10`
over white is (254,245,240) in Chromium = alpha 26/255 then truncation,
(254,246,241) in Flutter = alpha 0.1 rounded; elegant-dark `bg-info-soft`
over `layer-panel` is 29.53/46.58/49.78 exactly, Chromium (29,46,49), Flutter
(30,47,50).

### Live agent activity bar cases (8 surfaces x 3 themes = 24)

Derived from Web `components/layout/LiveAgentActivityBar.tsx`
(`LiveAgentActivityBarPresentation`), the raft-ui `liveAgentActivityBar`
recipe, `MainLayout.tsx` / `MobileBottomBarStack.tsx` (placement) and
`utils/liveAgentActivity.ts` (only `working` / `thinking` items show).
`tool/parity-ext/build-live-activity.py` appends the ids
`components.liveactivity.<platform>.<kind>.<theme>` to the generated manifest (registered
after `build-cases.py` in `builders.txt`); the React side is `host/LiveActivityCases.tsx`, the
Flutter side `test/parity/cases/ext_live_activity.dart`. The capture is the bar
itself (`[data-testid="live-agent-activity-bar"]` / `ValueKey
live-agent-activity-bar`) on the sidebar surface it sits in:

* desktop (240 wide, 1x): the Sidebar `bottomSlot`, inside `border-r` on the
  canvas (brutal: cream); kinds tool-finished, working, thinking, compacting,
  long (truncated);
* mobile (390 wide, 3x): `mobile-live-activity-slot`, elegant floating
  (`fixed inset-x-0 bottom-0`), brutal in flow above the tab bar; kinds
  tool-finished, thinking, long.

Web spec: one strip for the newest live item (`items[0]`, expiry 90 s,
heartbeat refreshes in place, terminal activity clears), flush with its
container (no outer margin). Elegant: `rounded-lg border border-line-muted
bg-layer-panel shadow-raft-md px-3 py-2` (dark: transparent border). Brutal:
`border-t-2 border-black bg-white px-3` (`md:bg-brutal-cream`), no radius or
shadow. Row `min-h-8 items-center gap-2`: 36px agent avatar (`size-9`, 1px
border, black in brutal, pixel art or image), 10px `Status` dot (elegant
semantic warning orange; brutal fixed busy `#FFD440` with a black border), one
ellipsised line of text (elegant 13px sans `foreground-muted`; brutal 14px
mono `black/60`). Nothing is tappable; the text has a hover tooltip. The
220 ms elegant enter/exit motion in raft-ui never runs in the product because
the connected wrapper unmounts instead of passing a null child. Production
Flutter now uses `RaftLiveAgentActivityBar` (`packages/raft_ui`), fed by
`NativeLiveAgentActivityBar` from `ChatAgentPresentation`.

| | before (old bar) | after |
| --- | --- | --- |
| mean pixel-perfect similarity | 70.96 % | 95.78 % |
| passing (basic-pass or better) | 0 / 24 | 11 / 24 |

What changed: floating card instead of a top-bordered strip, 36px avatar
(pixel art was missing before), status dot colours per theme (orange in
elegant, not a fixed yellow), 13px sans / 14px mono text. The remaining
difference is Chromium vs Skia text rasterisation (see "Text rendering").

### Conversation header cases (16 surfaces x 3 themes = 48)

`python3 tool/parity-ext/build-channel-header.py` appends
`components.channelheader.<platform>.<state>.<theme>` (run after
`build-cases.py`; other families are kept). Derived from Web
`ChatPanel.tsx` + `ui/PanelHeader.tsx`, `ChannelDescription.tsx`,
`OverflowSheet.tsx` (OverflowMenuTrigger), `ThreadPanel.tsx` and the raft-ui
`panelHeader` / `conversationPanel` / `panel` (attached edge) recipes.

* React (`host/ChannelHeaderCases.tsx`) mounts the real ChatPanel in the
  desktop main column (1280 - rail 64/56 - 240 sidebar) or the 390 page, and
  ThreadPanel `presentation="side"` in the 400px thread column (mobile: inside
  `.thread-side-column`, as MainLayout), clipped to a window at the top:
  header + Chat/Tasks/Files strip (120px; thread 64px).
* Flutter (`cases/ext_channel_header.dart`) mounts the real `WorkspaceView` at
  the case viewport, opens the channel / DM / thread through the controller
  and clips the same window.
* States: channel with short / long / no description, authored newline in the
  description (the reported bug), private, agent DM, human DM (desktop),
  side thread, hovered Search button (desktop).

Result (`cindy/channel-header`): before 9/48 passing (mean exact-pixel
similarity 0.798; the 3 hover cases had no keyed Search button), after
33/48 (mean 0.965). The 15 remaining are 0.92-0.96: text antialiasing on
Elegant text, sub-pixel baseline offsets (thread title, mobile meta line) and
the tooltip surface of the hover case. All 99 official values are unchanged.

### Settings cases (52 surfaces x 3 themes = 156)

`python3 tool/parity-ext/build-cases.py` also writes
`components.ext-settings.<surface>.<theme>` and
`tool/parity-ext/fixtures/settings.json`. Derived from Web
`layout/Sidebar.tsx` `settingsSidebarGroups` + `SettingsSidebarList.tsx`
(desktop Settings rail: Personal / Workspace / Resources), `SettingsPanel.tsx`
(every Workspace tab and AboutSection), `ReleaseNotesPanel.tsx`
(`/release-notes`) and `AboutFeedbackDialog.tsx` (the
`@botiverse/hands-feedback-react` My Feedback workspace).

* React (`host/SettingsCases.tsx`) mounts the real Sidebar in Settings mode
  (route primed before render) beside SettingsPanel / ReleaseNotesPanel in the
  1216px desktop frame (1280 minus the rail); props select tab, role
  (owner / member / guest) and the resolved server flags (Labs, AI Providers,
  IM Bridges). Flutter (`cases/ext_settings.dart`) mounts `WorkspaceSettings`.
* Crops: the rail (`settings-navigation`), the panel (`settings-panel`), About
  sections, single release cards; states: release notes loading / error /
  empty and feedback empty / loading / error through per-case `routeSets`
  (`{"$pending": true}` never answers, `{"$status": N}` fails) honoured by both
  providers.
* The fixture restates the official spec payloads for the Workspace tabs
  (billing, usage, members, invites, join links, agreement, translation,
  integrations) plus Labs, MCP, release notes and feedback tickets; unmatched
  Flutter requests get the official catch-all body, and Flutter answers flag
  evaluation from the case props. `PARITY_EXT_LOG_REQUESTS=<dir>` lists every
  `/api` request a React case makes.
* The QR code is encoded by `RaftQrMatrix`, a port of the `uqr` encoder Web
  uses (unit-tested module-for-module), from the React host's origin.
* The feedback workspace renders in `ui-sans-serif, system-ui`; product code
  names `system-ui` and the harness maps it to the host's Noto Sans (what
  Chromium's fontconfig picks).

Result (`cindy/parity-settings`):

| group | before | after |
| --- | --- | --- |
| Settings rail (18) | 0 passing, mean 0.810 | 4 passing, mean 0.883 |
| About (15) | 0 passing, 9 capture failures (no sections), mean 0.705 | 9 passing, mean 0.966 |
| Release Notes (24) | 6 passing, 9 capture failures, mean 0.864 | 14 passing, mean 0.970 |
| Feedback (15) | 1 passing, mean 0.795 | 9 passing, mean 0.971 |
| Server Profile, Labs, AI Providers, IM Bridges, MCP (30) | 8 passing | 28 passing, mean 0.979 |
| Plan & Billing, Administration, Applications (18) | 2 passing | 0 passing, mean 0.79 (not ported) |
| total (120) | 17 passing, 18 capture failures | 64 passing, 0 capture failures |

Plan & Billing and Applications (`cindy/settings-billing-apps`, 24 surfaces
x 3 themes = 72 ext cases, desktop + 390px mobile): Web `PlanSection` and
`IntegrationsSection` are ported (`settings_billing.dart`,
`settings_applications.dart`, app `billing_view.dart` / `integrations_views.dart`).
Before (WIP snapshot): 15 / 72 at >= 0.96, mean 0.916, 6 capture failures
(mobile Applications). After: 24 / 72 at >= 0.96, mean 0.936 (brutal 0.951,
elegant 0.936, elegant-dark 0.920), no capture failures. Measured Web facts
the port encodes: unadorned text in a Settings panel inherits Inter (the
heading family) while `font-sans` controls (buttons, selects) and every
Dialog portal render Geist (`RaftInheritedFont`); the recipe `Badge` and
`SegmentedControl` labels are Inter inside a panel; `Badge uppercase` only
transforms Brutal; Tailwind `space-y-*` keeps the margin of an empty grid
(empty marketplace / installed lists); `<details>` shows Blink's painted
triangle marker; translucent fills (`bg-primary-soft`, `bg-accent-soft` in
dark) must be composited over the panel because Flutter paints the outer
shadow under a translucent fill. Remaining delta is text rasterisation and
1px Blink baseline / border snapping.

The "before" Workspace tab numbers predate the fixture alignment (Flutter
then answered 404 where React had data), so they are not comparable to the
"after" column; Billing, Administration and Applications still render the
pre-port management pages. The remaining rail delta is text rasterisation and
a 1px sub-pixel heading offset; `nav.row-hover.elegant` (0.04) differs only by
one channel level everywhere in the `bg-fill-strong/80` hover fill (Chromium
quantises the alpha before blending, see the Computers result). Official
set: 98 values unchanged; `components.settings.root.page` (shared rail rows)
0.9743 -> 0.9905.

#### Administration (28 keys x 3 themes = 84)

`components.ext-settings.administration.<key>.<theme>`: the page and panel
crops, every section crop (Owners & Admins with picker / selected / admin
actor, System Channels, Pending Invites, Invite Links, Pre-join Agreement,
Onboarding, Server Translation, Product Analytics, Member Permissions, their
empty / disabled / warning states), the two ConfirmDialogs (revoke invite,
revoke invite link) and four 390px mobile sections. `routeSet`
`admin-hide-humans` / `admin-all-visible` prime the store-backed states
(`hideHumansFromMembers`, `#all` in the channel list) in both providers.

| | before | after |
| --- | --- | --- |
| page / panel (6) | 0 passing, mean 0.82 | 3 passing (brutal), mean 0.93 |
| all 84 cases | not ported | 25 passing, mean 0.944 (brutal 0.96, elegant 0.94, elegant-dark 0.92) |

Findings that apply to every Settings section:

* The oracle host wraps the page in `main.font-display`, so text that sets no
  family renders in the heading face (Inter in Elegant); `raftSettingsBody`
  mirrors that (plain `RaftTypography.body` is Geist in Elegant and 4% narrower).
* Blink keeps fractional layout but snaps box edges and baselines to device
  pixels: `RaftCssText` (baseline) and `RaftCssPixelSnap` (section origin).
* Elegant dark `shadow-raft-sm` carries inset highlights; `RaftSettingsCard.box`
  paints them (Flutter's `BoxShadow` has none).
* Remaining delta is text rasterisation (stem weight of Inter at 12-14px) and
  the Chromium-native date indicator / textarea resize grip.
### Search overlay cases (10 states x 3 themes = 30)

Derived from Web `SearchOverlay.tsx` + the overlay mode of `MessageSearchPage.tsx`
(raft-source 26f77ef): the desktop shell opens the same overlay from the rail Search
button and from Cmd/Ctrl+K. Host `tool/parity-ext/host/SearchOverlayCases.tsx`, fixture
`tool/parity-ext/fixtures/search-overlay.json`, generator
`tool/parity-ext/build-search-overlay-cases.py` (appends `components.search-overlay.*`,
every other id kept), Flutter builders `test/parity/cases/ext_search_overlay.dart`
(real `QuickSwitcherHost` over a fixture workspace; the harness gained the
`enterText` and `key` interactions). States: home (recent conversations), home-empty,
query, query-exact, query-selected, query-no-results, query-loading, query-error,
query-thread-group, filters-sender. Crop = the 720x640 card at 1280x800.

`tool/parity-ext/run dom-dump` writes the Web element rects and computed styles to
`build/parity-ext/react-dom/<id>.json` (`tool/parity-ext/dom-summary.py` prints an
outline); `PARITY_GEOMETRY_DUMP=1` does the same for Flutter. Box-for-box comparison
of the two replaced eyeballing: header/footer borders count in the box, the results
sit on the `SearchShellRoot` frame, hairline borders paint 1px at DSF 1, picker chips
use a 12px icon / 6px gap / 16px indicator slot, thread cards nest hits with their own
padding, the messages card paints without a heading while an error shows.

Remaining difference is text rasterisation and Chromium's truncating blend arithmetic
(1-2 level steps on every shadow/ring line, worst in elegant-dark), not geometry.

### Announcement modal cases (13 surfaces x 3 themes = 39)

Derived from Web `components/AnnouncementModal.tsx` (`Modal layer={1}
closeOnBackdrop` + `Card w-full max-w-xl`), `components/Modal.tsx` and
`store/announcementStore.ts`. `tool/parity-ext/build-announcements.py`
appends `components.announcements.<platform>.<kind>.<theme>` (run it after
`build-cases.py` and `build-live-activity.py`); data is
`tool/parity-ext/fixtures/announcements.json`. The React host
(`host/AnnouncementCases.tsx`) mounts the real `AnnouncementModal` with
`useAnnouncementStore.pending` primed; the Flutter builders
(`test/parity/cases/ext_announcements.dart`) mount the real `AnnouncementHost`
whose fixture client answers `GET /announcements/active` and the setup
projection (`phase: null`), so the modal opens exactly as on workspace entry.

* desktop (1280x800, 1x): single page, multi-page first / middle / last
  (`capture.interactions` press Next), rich Markdown (h2/h3, ordered list,
  bold/italic, inline code, link), long body (`max-h-[60vh]`), long title
  (`truncate`), and the whole viewport with the backdrop (`overlay`);
* mobile (390x844, 3x): single, multi-middle, rich, long, overlay.

Element cases crop the card (`[data-testid="announcement-modal"]` / `ValueKey
announcement-modal`), overlay cases the viewport.

Blink details reproduced in `packages/raft_ui/lib/src/announcement_modal.dart`
(each measured on the parity Chromium with element/range rects):

* the card is centred at a fractional y (e.g. 296.5) but painted at the whole
  CSS pixel (round half up); its layout rect keeps the fraction, and
  Playwright's element screenshot encloses it in whole CSS pixels. The
  harness now encloses extension element crops in CSS pixels before scaling
  (`parity_harness.dart`; no change for integer rects, the 9 mobile live
  activity cases score identically);
* text uses `RaftCssText` line boxes (22.75px `leading-relaxed` lines, Blink
  baseline); elegant InlineCode is `inline-flex` with `py-[1.5px]`, so a line
  holding it grows by `box descent - (line-height - css baseline)` (1.094px
  at 14px Geist), brutal InlineCode is an inline box (content area + 1px
  border) that never grows its line;
* `list-disc` markers are Blink's painted symbol: an `(A*2/3+1)/2` circle
  (5px for A = 14) ending 11px before the item content;
* the primary button is focused on open and keeps `:focus-visible` after it
  is clicked (Blink keeps it on a script-focused element).

| | first run | final |
| --- | --- | --- |
| mean pixel-perfect similarity | 92.0 % | 93.6 % |
| passing (>96 %) | 8 / 39 | 8 / 39 (overlay x6, mobile single/rich brutal) |
| capture size mismatches | 15 | 0 |

All 39 crops have identical sizes and the glyph positions match (checked by
row profiles and 5x zooms); what remains is Chromium vs Skia text
rasterisation (Chromium's glyphs are darker, see "Text rendering"), which
keeps text-dense cards at 89–96 %. Not covered: the failed-write error
notice (Web `toast.error`; Flutter uses a SnackBar), hover states.

### Thread, timeline, attachment and message-surface cases (`components.thread-ext.*`, 240 cases)

Three builders append to `cases.json` (run after the others, in this order):
`build-thread-cases.py` (thread panel, channel timeline states, inline replies,
Threads inbox; React `host/ThreadCases.tsx`, Flutter `cases/ext_thread.dart`,
data `fixtures/thread.json`), `build-thread-attachments.py` (preview hosts,
lightbox, comments panel; `host/ThreadAttachmentCases.tsx`,
`cases/ext_thread_attachments.dart`) and `build-thread-messages.py` (hover
toolbar, reaction picker, forwarded bundle, mermaid, notification banner, SOS;
`host/ThreadMessageCases.tsx`, `cases/ext_thread_messages.dart`).

* Thread / timeline: React mounts the real `ThreadPanel` (side) or `ChatPanel`
  in a column-sized box and clips `(winY, winH)`; the box is a CSS-transformed
  column so the mobile page's `fixed` header cannot leak into a bottom window.
  Flutter mounts the real `WorkspaceView`. Both providers answer the same
  `routes` / `routeSets` (messages, thread context); `{"$pending": true}` keeps
  a read open (loading states). Ids: `thread.<platform>.{panel,empty,loading,
  history-limited,composer,overflow-menu}`, `timeline.<platform>.{dates,empty,
  loading,history-limited,history-top,system-collapsed,system-expanded,
  back-to-bottom}`, `inline.<platform>.preview`, `inbox.desktop.empty`.
* Clock: the React provider pins `page.clock` to the fixture instant
  (2026-06-19T12:30Z). Flutter reads the same instant through
  `sourceTimeNow` (set by the builders); `props.clockIso` overrides both per
  case (the history-limit cases use 2026-06-24, after the Free trial, where
  the cutoff is 30 days). New interaction `scroll` (React wheel over the
  target, Flutter drag of a keyed list; `dy` is 20px larger than `y` because
  Flutter's drag consumes the touch slop).
* Product gaps found and fixed in Flutter: Web `HistoryLimitBanner` (plan days
  + "View Billing") for channels and for a thread whose replies all sit behind
  the cutoff (was a lock chip); thread history copy ("Older replies are
  limited by the current plan", "Loading older replies..."); an empty or
  history-limited thread has no history-top line or reply count; adjacent
  system messages collapse into the `SystemMessageGroup` disclosure
  (`systemMessageGrouping.ts` port, task / reminder / system summaries);
  thread overflow labels ("Search in thread", "Follow Thread"); menu panels
  no longer inherit the debug no-Material underline.

| family | cases | before (passing >96 %, mean) | after |
| --- | --- | --- | --- |
| thread panel (6 states x 2 platforms) | 36 | 14, 92.5 % | 15, 94.3 % |
| timeline (8 x 2) | 48 | 23, 83.5 % | 36, 97.0 % |
| inline replies | 6 | 6, 97.8 % | 6, 97.8 % |
| Threads inbox (empty) | 3 | n/a | 0, 93.8 % |
| attachments | 78 | 7, 54.7 % | 35, 94.7 % |
| message surfaces | 69 | n/a (see branch notes) | 4, 80.7 % |

What remains in the thread / timeline families is the text bucket (Skia vs
Chromium glyph rasterisation) plus: the elegant composer send button fill
(one channel level), a 1px header / overflow-menu vertical offset in the
elegant theme, the empty-thread history-limit banner sitting 13px higher than
Web's centred slot, and the narrow-row agent description ("K" before the time
on 390px rows). Not covered: thread agent followers popover, the "N new
updates" pill (needs a live update while scrolled), the quoted-permalink card
(no Flutter widget).
### Desktop notifications card cases (2 states x 3 themes = 6)

Derived from Web `SettingsPanel.tsx` `NotificationsSection` ->
`DesktopNativeNotificationsCard` (`settings.notifications.desktop.*`),
`utils/notificationChannel.ts` and `desktopNativeNotifications.ts`.
`python3 tool/parity-ext/build-notification-card.py` appends
`components.notifications.desktop.<available|unavailable>.<theme>` (run it
after the other builders; it keeps every other family). The card is private to
`SettingsPanel.tsx`, so `host/NotificationCardCases.tsx` renders the real
`SettingsPanel tab="notifications"` with the Electron marker
`window.raftDesktop.isDesktop = true` (the product's own channel switch) and,
for "unavailable", no `Notification` API. Flutter
(`cases/ext_notifications.dart`) mounts `NotificationSettingsView` with a
macOS desktop service (Web's hint names macOS). Capture: section header + card.

Flutter now follows Web on desktop (macOS / Linux / Windows): Bell header,
"Desktop notifications", system-managed pill, per-platform OS path hint,
one success "Send a test notification" button, no server read and no mute
form. Phones (Android / iOS) keep the same card with phone copy, an Enable
notifications action (opens system settings once the OS stops asking) and the
member mute form. The official `settings.notifications.page` compares Web's
browser Web Push card against the phone card and stays an intended difference.

| case | pixel-perfect |
| --- | --- |
| available brutal / elegant / elegant-dark | 89.8 / 84.7 / 83.6 % |
| unavailable brutal / elegant / elegant-dark | 93.7 / 89.6 / 88.3 % |

Sizes, colours, borders and spacing match. What remains is text: the macOS hint
names "Raft" (the app's display name) where Web says "Raft Desktop"; the `→`
glyph comes from a different fallback font in Chromium, which moves the hint's
line breaks; the description wraps one word differently because Chromium and
Skia advance widths differ by under 1px at the available width; and the usual
Chromium vs Skia glyph rasterisation.

#### Feedback write surfaces (`cindy/feedback-write`)

Twelve surfaces x 3 themes = 36 cases cover the write half of the My Feedback
workspace (`@botiverse/hands-feedback-react` 0.4.1 +
`web/src/feedback/handsFeedbackTransport.ts`): `feedback.new`, `new-filled`,
`new-submitting`, `new-error`, `ticket` (conversation + reply composer),
`ticket-reply`, `ticket-reply-error`, `ticket-closed` (no composer),
`close-menu` (the reason `DropdownMenuContent` crop), `close-confirm`,
`close-confirm-resolved` (inbox row, `completed`) and `close-error`. The
fixture adds the two ticket detail reads and per-case route sets whose
`POST /product-feedback`, `.../comments` and `.../close` stay pending or
fail with 503; no case reaches a server.

| group | mean | note |
| --- | --- | --- |
| New feedback (12) | 0.975 | placeholder text is narrower in Chromium (about 5%) |
| Ticket, reply, closed (12) | 0.964 | elegant-dark 0.927: the Web composer carries a wide soft shadow Flutter does not draw |
| Close menu / confirm / error (12) | 0.903 | small crops of dense text, sub-pixel glyph rasterisation; the menu also has 1px AA differences on the check glyph |

Known gaps: elegant-dark ticket composer shadow, the `In progress` chip and
timestamp widths (2-3% wider in Flutter), the reply placeholder width.
### Composer attachment cases (29 states x 3 themes = 87)

Derived from Web `MessageInput.tsx` (`SortableAttachment`, `<ComposerAttachments>`,
failed-upload alert rows, limit `Banner`, `isDraggingFiles` overlay, `addFiles`)
and the raft-ui `composerAttachment` recipe. `tool/parity-ext/build-composer-attachments.py`
appends `components.composerattachments.<platform>.<kind>.<theme>` (run it after
`build-announcements.py` and `build-search-overlay-cases.py`); the state of each
kind lives in `fixtures/composer-attachments.json` (`kinds`, `routeSets`), read
by both providers. The React host (`host/ComposerAttachmentCases.tsx`) mounts the
real `MessageInput`, puts the fixture files on the hidden file input (the same
`change` the picker fires) and answers `upload-capabilities` / `POST
/attachments/upload` from the fixture routes (ready, never answers, fails, quota,
4 KB ceiling); `data-visual-case` appears once the expected state is rendered.
Flutter (`cases/ext_composer_attachments.dart`) feeds the same bytes to the product
`attachSelection` over a fixture client, so checking / uploading / failed / limit
are produced by product code.

* desktop (760px column): one image, three images, file, long names + unknown
  type, mixed (wraps), checking, uploading (0 %, 42 %, 99 % "Finishing upload"),
  failed (alert rows), quota failure (chip + banner), over-size, 11 files, empty
  file, drag-over overlay, hover (remove badge), thread composer (no As Task);
* mobile (390 wide, 3x, `viewport.touch` = CDP touch emulation so the browser
  reports `(hover: none)` and the remove badge is always visible, 24px): the same
  states except empty file, finishing, drag (touch never fires drag events) and hover.

What changed in Flutter (all of it Web behaviour, none invented):

* pending files sit inside the composer root below its rule (they used to float
  above it as Material chips) with no "N attachments" label; `RaftComposerAttachments`
  draws 64px image thumbnails and 176x64 file cards (name + MIME, `file` fallback)
  from the recipe, checking / uploading / finishing / failed overlays, the 4px
  progress bar and the remove badge (`top:-6 right:-6`, hover on desktop, always
  on touch; its layout box carries the 6px overhang so hover and taps reach it);
* failed uploads leave the chips for a warning alert row with "Tap to retry"
  (not for the interrupted check) and remove; a billing-quota failure keeps its
  chip and shows its banner;
* `attachSelection` shows every file at once as a checking chip, decides on the
  server ceiling in selection order, drops empty / oversize / extra files with
  Web's singular and plural messages, uploads accepted files one at a time (each fenced by the authority of the selection), and
  marks a check whose scope changed as interrupted (not retryable);
* Send shows its spinner and tooltip while files are checked or uploaded, and a
  blocked Ctrl+Enter reports "Wait for ..." / "Remove or retry ..." in the banner;
* the media button is "Attach media" and picks images and videos
  (`image/*,video/*`), the file button anything; local images open in the lightbox;
* the drop overlay starts below the composer rule, uses Blink's dash fit and
  8-bit alpha; the warning banner honours dark.

Result (run `20261010T19*`, this branch): 87/87 captured, identical sizes, mean
pixel-perfect 95.8 % (brutal 97.9 %, elegant-dark 95.7 %, elegant 94.0 %), 41/87
above 96 %. Geometry, sizes, colours and spacing of the attachment surfaces match;
what remains is (a) the shared elegant composer card (ring and `shadow-sm` differ by
1-3 levels, rows y=86 and 177-181 of every elegant case; official brutal composer
cases are unaffected), (b) Chromium's 8-bit truncating blend of the translucent
overlays (1-level fills), (c) the frozen spinner frame and text rasterisation,
(d) Blink's dash phase on the drag-over frame. Official `components.thread.composer.*`:
all seven unchanged to four decimals (empty 98.40, states 97.22, pending-mention
96.83, as-task 97.20, member-suggestions 97.83, channel-suggestions 98.57,
image-preview 98.04).

Not ported: drag-to-reorder of chips (dnd-kit), the "recoverable uploads" banner
(needs the direct-upload session API), the billing link of the quota banner (no
billing page in Flutter), multi-image lightbox navigation from the composer.
### Channel and DM settings drawer cases (45 states x 3 themes = 135)

`python3 tool/parity-ext/build-channel-settings.py` appends
`components.channelsettings.<platform>.<state>.<theme>` (run it last, after the
search overlay builder) and writes `tool/parity-ext/fixtures/channelsettings.json`.
Derived from Web `ChannelOverflowMenu.tsx` + `ui/OverflowSheet.tsx` (the drawer),
`EditChannelDialog.tsx` (`presentation="panel"`), `ChannelPreferencesSection.tsx`,
`ConfirmDialog.tsx` and `ChatPanel.tsx` (which props the drawer gets).

**What the product shows.** Web mounts the settings only as the header gear's
`OverflowSheet`: identity header (`#name` + visibility badge + one truncated mono
description line), `MembersStrip`, then the flat panel (Info form with in-section
Cancel/Save, Guest access, Preferences, an Actions group whose only filled row is
Delete). The yellow "Channel / Settings / #name" sheet with filled orange action
buttons is `EditChannelDialog`'s legacy `presentation="sheet"`, which no Web
surface mounts; Flutter kept it only for the official `components.channel.settings.panel`
case (`ChannelSettings(isPanel: false)`, unchanged: 97.95 % before and after).
`ChannelSettings(isPanel: true)` is now the Web drawer (`RaftOverflowSheet`,
`RaftMembersStrip`, `RaftChannelInfoForm`, `RaftOverflowActions` in `raft_ui`); a DM
shows the same sheet with only the shared Preferences.

* React mounts the real `ChatPanel` and clicks the gear; Flutter mounts the real
  `WorkspaceView` and taps the keyed gear. Keys equal the Web `data-testid`s.
  `capture.androidKey` is the sheet, the ConfirmDialog surface or the unsaved prompt.
* Elegant drawer: 448 px, `rounded-xl`; brutal 544 px with a 2 px left border; phones
  390. The header is 62 px in both themes (`--shell-header-height` is set on the
  AppShell root, the portal falls back). Text is the sans face (portal outside
  `font-display`): Geist in Elegant.
* States: owner / admin / member / guest / not-joined / private / archived / #all,
  newline / no / long description, Guest access, prefs on, dirty draft, members
  overflow (+N) and loading, agent and human DM, four ConfirmDialogs + Hide #all, the
  unsaved prompt, and `-full` variants that capture tall drawers (the actions group is
  below the fold at 800/844).
* Not covered: the joint-channel sections and the Slack bridge field (neither renders
  in the fixtures), the members *page* inside the drawer (the strip opens the existing
  members modal, add tile straight into its add view) and the SOS dialog.

Result (`cindy/channel-settings`, 135 cases): before, the old sheet had no keyed
drawer, so every capture failed; after, mean exact-pixel similarity 93.3 %
(brutal 94.5, elegant 93.7, elegant-dark 91.7; DM 96.9-98.6, mobile 94-97). What is
left is text rasterisation (>16-level differences cover ~3 % of a full drawer, all
glyphs) plus 1-level colour noise on dark fills and the elegant button sheen, with the
ConfirmDialog/unsaved cards at 85-90 (card text and 1 px dialog offsets).

### Shell and navigation cases (components.shell.*, 156 ids = 52 surfaces x 3 themes)

`python3 tool/parity-ext/build-shell-cases.py` (last in the builder order) appends
`components.shell.<platform>.<surface>.<theme>` and writes
`tool/parity-ext/fixtures/shell.json` (channels, DMs, unread / drafts / mention,
sidebar-order presets, servers and cross-server unread, primitive samples). The
React host `host/ShellCases.tsx` mounts the real Web `LeftRail` + `Sidebar`
(AppShell slots, seeded stores, `Sidebar mobileInline` for the Home tab),
`ConfirmDialog`, `ui/Banner`, `ui/EmptyState`, `ui/BottomSheet`, the toast
provider and `ThreadsInbox`; the Flutter side
(`test/parity/cases/ext_shell.dart`) mounts the real `WorkspaceView` and the
raft_ui primitives. Menus and dialogs are opened by the same interaction on both
sides: Web `rightclick` (new `run` patch: a native right click, optionally at
`x`,`y` of the element) and Flutter `secondaryTap` (new harness step; the
keyed sidebar row carries its trailing margin, so `row: true` aims at the
button centre).

| group | desktop surfaces | mobile |
| --- | --- | --- |
| Sidebar + rail | default, empty, loading, custom sections, sorted, collapsed, row hover, sort menu | Home default, collapsed, sort menu |
| Menus | channel, muted channel, human DM, agent DM, section, custom section, surface, Move to section | channel row |
| Dialogs | new / rename section, delete section, archive channel, rail help menu, server switcher | |
| Activity framing | rail + inbox panel edge | left edge |
| Primitives | confirm (danger, warning, acknowledge), banner, empty state, bottom sheet, toast (success, error, info, plain), overflow sheet | same |

Result (extension suite policy: elegant-dark sampled to one case per
`components.shell.<platform>`; the table is light + Brutal, 100 captured of
104 evaluated, mean 86.8 %, 94.4 % without the toasts):

| group (cases) | first capture | now |
| --- | --- | --- |
| desktop sidebar (16) | 92.8 %, 4 passing | 94.1 %, 4 passing |
| desktop menus (16) | 45 % at the first capture (no menu in Flutter) | 96.1 %, 8 passing |
| desktop dialogs + help menu + server switcher (12) | 90.0 %, 0 passing | 92.1 %, 1 passing |
| confirm dialog primitive (12) | 94.0 %, 4 passing | 94.1 %, 4 passing |
| banner (4) | 74.8 %, 0 passing | 96.4 %, 2 passing |
| bottom sheet (4) | not covered | 91.5 %, 1 passing |
| empty state (8) | 96.1 %, 4 passing | 96.9 %, 4 passing |
| toast (16) | 41.9 %, 0 passing | 47.1 %, 1 passing |
| mobile Home sidebar / menu / sort (8) | not covered | 92.5 %, 1 passing |
| Activity framing (4) | not covered | 96.0 %, 2 passing |
| overflow sheet (4) | not covered | not covered |

(The first-capture column is the run after the cases existed; the very first
sidebar default capture was 90.1 / 90.4 / 89.6 % before the pinned-row, rail
header and avatar fixes.)

Official check: 46 official cases that use the touched shared widgets
(screens.home / components.home, slug input, avatar list row, members,
settings, thread header, channel) are identical to the same commit without
this change (max |delta| < 0.05 %).

What changed in Flutter (all measured against the Web DOM):

* Pinned rows follow `allowWrap`: 17.5px lines, 30 / 32 minimum height, no agent
  description, `items-start`; custom-section DMs and agents hide descriptions.
  Elegant conversation rows use `px-1.5`; touch density keeps Web's row box and
  only widens the hit area (RaftTouchTarget) instead of inflating rows to 48dp.
* Right click / long press menus (raft_ui `RaftSidebarContextMenu`, the message
  menu recipe at `w-48` / `w-64` / `w-56`) for channel, DM, agent rows, section
  headers and the sidebar surface, the Move to section submenu, the section
  dialog (`RaftSidebarSectionDialog`) and confirm dialogs, with the Source
  actions (sidebar-order patches, read-all / unread, notification-settings).
  The row whose menu is open keeps `bg-fill-muted`. Sort menu labels are Web's
  (Manual / Recent / A-Z).
* Rail: server avatar fill / ink per theme, Brutal 2px header border,
  other-server attention dot; agent presence dot on agent rows; the Web browser
  default for hide-empty sections (Electron / the Linux client turn it on).
* `RaftBanner`: Brutal 2px / Elegant 4px title gap and the action dropping to
  its own end-aligned row at or below 24rem (container query). `RaftToast`: icon
  cell, close button and the two empty-track column gaps of the Web grid.
  `RaftBottomSheet`: new (Card, `shadow-raft-xl` / `shadow-brutal-lg`).

Activity borders (owner report): Web draws the vertical line beside the rail on
the Activity page itself: the inbox panel is raft-ui `Panel edge="attached"`
(`border-l`, Brutal `!border-l`), the rail keeps only its Brutal divider (1px on
Activity: LeftRail `thinDivider`) and MainLayout hides the sidebar column on
that route. Flutter draws exactly these lines on desktop
(`components.shell.desktop.activity.frame`, and
`test/shell_border_placement_test.dart` asserts the owner and x of every
vertical border per page, theme and form factor).

Intended difference (owner decision 2026-10-11): on MOBILE the same Web panel
keeps its left border at x = 0 (checked with AppShellRoot + AppShellMainSlot
around ThreadsInbox at 390px, 3x), but Flutter does not draw it. The ext cases
`components.shell.mobile.activity.frame.*` therefore differ from Web by that
1px vertical line by design; the owner decision overrides the Web analysis.

Remaining gaps: the OverflowSheet (Drawer) shell, the emoji picker popover
(third-party grid), the Electron-only "Find a conversation" sidebar box, the
toast action variant (the Web toast manager ignores `actionProps` here), the
member / computers sidebar rails, and text rasterisation. Elegant (light) toasts
differ by a constant 2 levels in the blue channel of the translucent fill (the
dark theme is within 1), which zeroes exact-pixel equality over the whole fill;
the geometry matches (288 x 56 / 64).

### Outlier review (select-all, bulk-restart, workspace-scan)

The official `pixelPerfectSimilarity` (visual-testing
`src/sharp-image-diff.mjs`) flattens both PNGs on white, pads them to the
larger size and counts pixels whose RGBA is exactly equal; no threshold, no
alpha effect here (both captures are opaque, same size). An earlier
diagnostic here reported higher equality (76% vs 35.7% for select-all
elegant-dark) because it measured the luminance of the difference image,
which rounds single-channel 1-level differences to 0. Per-channel max delta
(after the fixes below):

| case | equal | delta 1-2 | delta 3-24 | delta >24 |
| --- | --- | --- | --- | --- |
| detail.select-all.elegant-dark | 35.7% | 51.4% | 9.0% | 3.8% |
| dialog.bulk-restart.elegant-dark | 71.4% | 21.3% | 3.9% | 3.5% |
| detail.workspaces-scanned.brutal | 74.2% | 16.6% | 3.9% | 5.3% |

* delta 1-2: the large selected/tinted fills (blend arithmetic above).
* delta 3-24: full-width single-pixel rows at border and fill edges. Total
  coverage is equal, distributed differently: Flutter paints the edge at the
  layout's .75 position (anti-aliased), Chromium snaps border and background
  edges to whole pixels. Same offset on every edge of a crop, so no layout
  drift.
* Real differences found and fixed: (1) elegant Avatar is `border-2
  border-transparent bg-clip-padding`; `RaftAvatarSlot` painted `fill-muted`
  under the transparent border, a visible ring on tinted rows (no official
  case changes: all 99 official values are identical with and without it);
  (2) the bulk-restart option cards (`Card` root `border-[0.5px] ...
  dark:border-transparent`) drew a 1px `line-muted` ring in elegant-dark and
  dropped the `shadow-raft-xs` inset top light. The card edge profiles now
  match Chromium to within 1 level.

## Known harness limitations

* React baseline fonts deviate from the official spec on purpose (production
  Google Fonts, see "Baseline fonts").
* Flutter captures are host `flutter test` rasters (software Skia, Linux), not
  Android device screenshots; Impeller/GPU antialiasing on a phone can differ
  slightly. Fonts are the app's bundled fonts; CJK/emoji come from the host's
  Noto files because flutter_test has no OS fallback chain (`sans-serif` is
  mapped to Noto Color Emoji to stand in for Android's emoji fallback).
* No injectable clock: product code that calls `DateTime.now()` renders with
  the host clock (TZ is pinned to Asia/Shanghai). Current fixtures' labels are
  unaffected, but relative-time labels could drift.
* `ctx.target` only wraps widgets the builder creates; rows deep inside a
  product composite (message rows in `RaftChatView`) are captured through a
  clipped window aligned to React's element rect, so style probes there
  include neighbouring paragraphs.
* The mobile nav, mobile home header, create-channel dialog and settings
  destination list are public product widgets (`WorkspaceMobileTabBar`,
  `WorkspaceMobileHomeHeader`, `CreateChannelDialog`, `WorkspaceSettings`)
  that both `WorkspaceView` and the builders mount; no builder copies app code.
* State substitutions are documented per case in `notes` and in metadata
  (`flutter.notes`), e.g. create-agent dialogs (React never selects a runtime
  because its host lacks the runtime-options mock), composer image preview
  (React baseline shows an upload-limit error state), lifecycle actions
  (Flutter has no "More actions" menu; its restart confirmation is captured).
* Several React baselines have fixture defects (raw markdown/HTML shown in
  mono in some `message-row.md-*` cases; notification-center empty). These
  are measured as-is; they lower scores without being Flutter gaps.
* The React baseline was captured from a raft-source checkout at 26f77ef with
  pre-existing local edits (additive diagnostic cases in
  `VisualTestingCases.tsx`); see `build/parity/react-source.json`.

### Tasks board and task detail cases (87 = 9 page + 78 detail, x 3 themes already counted)

`python3 tool/parity-ext/build-task-detail.py` (run last in the chain) appends
`components.taskspage.<platform>.<state>.<theme>` (states `board`, desktop-only
`expanded`) and `components.taskdetail.<platform>.<state>.<theme>` (states empty,
replies, replies-short, history-open, status-todo/in-progress/in-review/done/closed,
unassigned, assigned, long-title, description; desktop 1280x800 and mobile 390x844 @3x).
Data: `tool/parity-ext/fixtures/taskdetail.json` (board tasks, per-state detail tasks,
replies, history; `routes` + `routeSets` answer the API on both providers).

* React (`host/TaskDetailCases.tsx`) mounts the real `MainLayout` on `/s/visual/tasks`; a
  detail case adds `?task=<channel>:<message>` and the `taskModal` store slot, so the real
  RightPanel renders Modal + ThreadPanelWrapper (TaskModalBar, TaskModalHead, ThreadPanel).
  Desktop page cases crop `thread-main-column`; detail cases capture the viewport.
* Flutter (`cases/ext_task_detail.dart`) mounts the real `WorkspaceView` (section tasks;
  detail via `navigateTask`) with a fixture client that honours `/tasks/server?status=`.
* Web facts the cases pin: done/closed lanes start collapsed, mobile defaults to the list
  view, and on mobile the floating tab bar stays above the task modal composer.
* Mobile `expanded` is not covered (lazy Flutter list vs Playwright scroll offsets).
