# G4 settings / computer / setup / auth / notification / appearance: Elegant vs Brutal inventory

Scope: 34 files from areas/G4_settings.files (OLD = a57b9dab, NEW = db40e0a7). I read all branch sites by grep plus the code around every distinct pattern. I did not read each of the 658 code sites one by one; repeated ones were checked by sampling. Counts below are approximate (+-10%).

Raw numbers: 819 grep hits, 658 outside comments. Multi-line ternaries (`t.brutal` on one line, `? A` / `: B` on the next) count as one site. Hits are mostly the same ~12 patterns repeated. About 85 % of the Elegant side are just semantic tokens that already exist.

Survived? In NEW every `t.brutal` branch in these files is gone. The Elegant side is "kept" at the call site (NEW still has `RaftRecipeTheme.elegant` hard-coded in agent_create_form.dart:49 and auth_page.dart:318/572, one leftover `color-brutal-red` lookup in settings_layout.dart:685). Exception: sites that feed one of the 11 ported 0.7.1 components (Button, Avatar, IconTile, Badge, Tabs, Checkbox ...). There the Elegant widget internals were "replaced"; I mark them "kept*" (call site kept, widget behind it replaced) or "replaced".

Hidden/implicit branching you will not find with grep for `brutal` in these files:
- `raftPanelInk(t, brutalAlpha, elegantColor)` in panel_layout.dart:40, called 22x here (black@alpha vs token). Class A.
- `t.recipeTheme` passed to generated recipes (`recipes/*.g.dart`), 23 call sites here (feedback_workspace 14, feedback_inbox 8, settings_billing 8 ...). The Elegant/Brutal data lives in the generated recipe tables, so it is already data. Class A (data), not counted below.
- OLD `RaftTokens` getters `border` (2/1, used 8x here), `line`, `radius` (0/8), `fieldRadius`, `focusShadows`. NEW fixes them to constants (1, line-muted, 8, 6). Same effect as class B.
- `t.dark` branches (~38 sites) are mode, not theme. They stay as code. Examples: dark uses `layer-card` instead of `layer-panel` (settings_layout:351,690; feedback_workspace:1040), dark border transparent (computer_surfaces:193), dark hover `ink-6` (computer_surfaces:372). A pack only works if its dark token set carries these; the "which token in dark" choice is code (class B, name `surface-card-dark`, or fix by making `layer-panel` itself carry the dark value).

Class legend: A = token already exists in NEW. B = plain data, needs a new token/param. C = structural (code).

## 1. Colours

| what | Elegant | Brutal | n | samples (OLD file:line) | class | token | note |
|---|---|---|---|---|---|---|---|
| Strong text | `t.strong` / foreground-strong | black | ~94 | computer_detail:190, agent_dialogs:130, setup_steps:396 | A | RaftSemanticColors.foregroundStrong | kept |
| Muted/secondary text | foreground-muted (`t.muted`) | black @ .4 .45 .5 .55 .6 .65 .7 .8 | ~75 incl. 22 `raftPanelInk` | settings_layout:660, add_computer_dialog:453, settings_applications:1045 | A | foregroundMuted | kept. 8 Brutal alphas collapse to 1 Elegant token |
| Placeholder / hint / empty-state text | foreground-placeholder, foreground-hint | black @ .3 .4 .5 | ~12 | agent_profile:2262, computer_surfaces:439, settings_workspace:823 | A | foregroundPlaceholder / foregroundHint | kept |
| Edge / border colour | line-muted (cards), line-strong (selected, inputs), line-hairline (headers, auth, public) | black or black @ .1 .2 .3 | ~110 | agent_profile:2430, public_server:95, setup_steps:88, settings_layout:559 | A | lineMuted / lineStrong / lineHairline | kept. Elegant dark: card border transparent (computer_surfaces:193) is a mode branch |
| Panel / card fill | layer-panel (`t.panel`), dark often layer-card | white | ~65 | settings_layout:557, settings_app_editor:461, member_graph:648 | A | layerPanel / layerCard | kept; dark pick is code (see note above) |
| Muted / cream fills | layer-canvas-muted, layer-inset, fill-muted | brutal-cream, gray-50/100/200 (0xFFF9FAFB, F3F4F6, E5E7EB) | ~43 | public_server:101, settings_billing:500, computer_detail:1398, 1938 | A | layerCanvasMuted / layerInset / fillMuted | kept |
| Page / header fill (accent bar) | primary-soft, panel or layer-canvas-muted | soft-signal (periwinkle) | ~26 | auth_page:177, setup_resume_bar:41, computer_detail:764, notification_settings_card:60 | A | primarySoft | kept* (IconTile at computer_detail:764, public_server:762 replaced) |
| Status tints: success / info / warning / danger | success-soft + success-strong, info-soft, warning-soft, danger-soft(+strong) | brutal-lime / cyan / orange / red, often @ .15 .2 .3 .4 | ~72 | settings_workspace:805-813, computer_detail:2105-2121, setup_steps:960, slack_bridge_wizard:871-907 | A | success/info/warning/danger Soft+Strong | kept |
| Selected / highlighted row | accent-soft + line-strong edge | brutal-pink (or @ .2) + pink edge | ~14 | public_server:198, agent_profile:2092, slack_bridge_wizard:312 | A | accentSoft / accentStrong | kept |
| Accent link / emphasis | accent-strong | brutal-pink | ~6 | auth_page:687-798, public_server:187 | A | accentStrong | kept |
| Required star / error text | danger-strong | color-brutal-red | ~6 | agent_create_form:411,430, settings_administration:1341 | A | dangerStrong | kept; settings_layout:685 still reads `color-brutal-red` in NEW |
| Modal backdrop | layer-backdrop | black @ .6 | 4 (+1 comment) | add_computer_dialog:60,74, agent_create_form:59, computer_detail:658 | A | RaftSemanticColors.layerBackdrop | kept |
| Focus ring colour | ink @ .8 | black @ .8 | 1 | setup_steps:368 | A | foreground | kept |
| Notification icon fill by kind (light) | danger/warning/info/success @ .8 | brutal orange/yellow/lime | 1 block | notification_center:97-125 | A | semantic status colours | kept (rewritten; diff 152 lines) |
| Notification icon fill by kind (dark) | hard-coded washes `_NotificationPrimitives.*Muted` @ .28-.3 | n/a | 1 block | notification_center:115-125 | B | `status-wash-*` (4 kinds, dark) | kept; constants in code, not tokens |
| Notification bell dot | primary-400 fill, border = fill@.58 | accent-400, line-strong border | 1 | notification_center:203-217 | A | primary-400 | kept |
| Notification header fill | transparent (dark) / panel (light), surface = popover | brutal-cream header, panel surface | 1 | notification_center:88-95 | A | layerPopover / layerPanel | kept |
| Brutal-palette colours used in BOTH themes | same | same | ~8 | computer_surfaces:530 (dots), app_icon_choices:25-29 (swatches), settings_app_editor:1767 | A | RaftProductColors | not a difference, do not count |
| Alpha compositing model | `Color.alphaBlend` | premultiplied 8-bit, round-down Chromium emulation | 1 helper, 4 calls | slack_bridge_wizard:115, 303, 872 | C | none | Brutal pixel-parity hack. Elegant side is the plain blend; stays code, no pack need |

## 2. Typography

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Notification title (eyebrow) | 14/20 w500, ink, ls 0, sentence case | 12/16 w700, strong@.6, ls 1.2, UPPERCASE | 1 (4 props) | notification_center:160-164, 350 | B | `eyebrow-font-size`, `eyebrow-weight`, `letterspacing-eyebrow`, `text-transform-eyebrow` | kept. Case change = C-param (enum none/upper) |
| Notification count | body 11/16.5 w500 placeholder | mono 12/16 strong@.4 | 1 | notification_center:165-177 | B | `count-font-family`, size | kept |
| Notification item title | w500 | w700 | 2 | notification_center:183, agent_dialogs:345 | B | `font-weight-title` (also RaftThemeMetrics.cardTitleFontWeight fits for cards) | kept |
| Notification body colour | muted | ink | 1 | notification_center:190 | A | foregroundMuted | kept |
| Notification action label font | body (actionFont) w500 | heading family (default weight) | 1 | notification_center:611-619 | B | `font-weight-button`, `font-family-button` | kept; Button is a replaced component, so this recipe subclass is orphaned |
| Identity panel label weight | w600, muted | w700, black | 1 | external_identity_panel:158 | B | `font-weight-label` | kept |
| Small-chip weights | w500/w700 | same | 0 | n/a | n/a | | not branched in my files |
| Variable-font `opsz` axis | `FontVariation('opsz', size clamp 14..32)` unless system fonts | none (Hanken has no opsz) | 1 here (+RaftTokens.fieldStyle shared) | settings_layout:444, theme.dart:189 | B | `font-opsz-axis` (bool or [min,max]) | kept |
| Empty-state heading | 14/20 w500 foreground (dark: muted) | 18/28 w600 strong@.6 | 1 | settings_workspace:1131-1146 | B | `empty-title-size`, weight | kept |
| Empty-state title line height | 20 | 28 | 1 | feedback_inbox:811 | B | `line-height-empty-title` | kept |
| Uppercase labels | uppercase in both themes for most eyebrows | same | ~20 unconditional | agent_create_form:218, computer_surfaces:274, member_graph:331 | n/a | | not a difference |
| Uppercase only in Brutal | sentence case | UPPERCASE | 2 | agent_avatar_picker:83, notification_center:350 | C | param `text-transform-heading` (enum) | kept |
| Line-box derived values | font-metric based (19.5/13, badge centre 11.17) | 20/14, badge centre 11.55 | ~6 | computer_surfaces:404 (`11*1.5` vs `11*20/14`), agent_profile:1189, feedback_workspace:1512 | B | derives from `body-line-height`; mostly follows from font stack | kept. Pixel-parity numbers, low value |
| Pixel snap rounding | ceil, none at dpr>1 | floor | 1 | root_error_fallback:195-196 | C | none | drop, parity detail |
| Font families (heading Inter vs Hanken, sans, mono) | RaftThemeMetrics.headingFont / monoFont | same getters | 0 branches here | uses `t.headingFont`, `t.monoFont` | A | RaftThemeMetrics.*FontStack | already data |

## 3. Shape (radius)

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Control / chip / inner box radius | 6 | 0 | ~26 | computer_surfaces:472,707, setup_steps:364, settings_administration:1773 | B | `radius-control` (NEW has `fieldRadius=6` as a fixed getter; make it a token) | kept |
| Card / dialog / banner radius | 8 | 0 | ~12 | root_error_fallback:65, server_access_denied:62, setup_resume_bar:46, slack_bridge_wizard:157,989, settings_administration:1982 | B | `radius-card` (NEW `RaftTokens.radius=8` fixed) | kept |
| Small inner element radius | 4 or 2 | 0 | ~4 | settings_applications:1005 (4), setup_steps:1061,1196 (2), appearance_picker:~256 | B | `radius-xs` / `radius-tag` | kept |
| Avatar / logo shape | circle (rounded-full) | square, border, shadow | 3 | agent_profile:303, settings_applications:830-845, feedback_workspace:978 | B | `radius-avatar` (full or px) | agent_profile site replaced (Avatar port); others kept |
| Clip behaviour | `Clip.antiAlias` | none | 1 | feedback_workspace:461 | C | none | follows from radius>0; automatic |
| "Plain" dialog card | recipe card (radius 8, shadow) | `card-brutal` (r0, line-muted) | 2 | agent_create_form:204,318 | B | `radius-card` | kept (flag now always recipe) |

## 4. Borders

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Border width | 1 | 2 | ~90 (55 same-line + ~35 multi-line) | agent_profile:899, computer_surfaces:219,473, setup_steps:66, 89 | B | `border-width` (NEW `RaftTokens.border` fixed 1) | kept. Many paddings (12+border, 6+border) and heights follow it automatically |
| Section/panel rules | line-muted, 1 | black @ .1 (composited), 2 | ~12 | agent_profile:520, settings_app_editor:1862 | A colour + B width | lineMuted + `border-width` | kept; `raftPanelRuleColor` collapsed to one line in NEW |
| Header bottom rule | line-hairline 1 | black 2 | 4 | auth_page:187,1591, public_server:579, settings_billing:494 | A + B | lineHairline + `border-width` | kept |
| No border on Elegant | none | black 2 | 3 | settings_billing:1218, feedback_workspace:982 (avatar), computer_detail:765 (tile `borderless`) | B | `border-width-<surface>` = 0 | kept* |
| Dashed outline | dashed 2px, line-muted | dashed 2px, black@.3 | 1 | member_graph:874 | A | lineMuted | only colour differs |
| Selected-card ring | extra 1px ring `line-muted@.45` + sm shadow, border transparent | border black + pink fill | 1 | computer_surfaces:200-208 | C | param `selected-ring` | kept; structural state model |
| Header border placement | border drawn by container | drawn inside switcher | 1 | public_server:924 | C | none | layout detail; stays code |
| Filter-tab dividers | none (active indicator Stack) | left 2px divider on tabs > 0 | 2 | feedback_inbox:407,425 | C | none | **replaced** (NEW uses ported RaftTabsList) |

## 5. Shadows / elevation

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Card shadow | `themeShadows.sm.outer` (+ `sm.inset` highlights in dark) | `shadowBrutalSm` (hard 4px black) | ~25 | settings_layout:562,590, settings_billing:484, member_graph:654, external_agent_setup:454 | A | RaftThemeShadows.sm (.outer/.inset) | kept; dark inset painter `RaftLayeredDecoration` kept |
| Setup/dialog card | `themeShadows.md` | `shadowBrutal` | 2 | setup_steps:73, cindy_setup_screen:241 | A | RaftThemeShadows.md | kept |
| Error card | `themeShadows.lg` | `shadowBrutal` | 2 | root_error_fallback:68, server_access_denied:63 | A | RaftThemeShadows.lg | kept |
| Chip selected | `themeShadows.xs` | `shadowBrutalSm`; none when pressed | 2 | setup_steps:346,384, appearance_picker:261 | A | RaftThemeShadows.xs | kept. "no shadow on press" is Brutal-only (C-param) |
| Avatar tile shadow | none | `shadowBrutalLg` / Sm | 5 | auth_page:963, cindy_setup_screen:114, setup_steps:464, settings_applications:952 | B | `shadow-avatar` (none/sm) | kept* (Avatar replaced) |
| Which step per surface | hard-coded sm/md/lg/xs in call sites | n/a | ~35 | see above | B | `shadow-card`, `shadow-dialog`, `shadow-chip`, `shadow-popover` pointing at RaftThemeShadows steps | step choice is code today |
| Hover / selected list-item shadow | hover sm, selected ring+sm (mobile: hover md) | brutalSm on selected+hover | 3 | computer_surfaces:200-208, 389-395 | C | none | state model, kept |
| Dark inset highlight layers | `themeShadows.sm.inset` painted under border (dark only) | none | 1 | settings_layout:590-620 | A | RaftShadow.inset | kept |
| Sheen / inset on bell dot | native inset 0 .5px 1px white@.55 painter | none | 1 | notification_center:217,650-700 | C | none | kept; painter is code, could be `shadow-inset` data |

## 6. Spacing / density

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Settings sidebar row overhang | 6 (rows hang past padding) | 0 | 1 (+3 users) | settings_layout:76,107 | B | `sidebar-row-inset-x` | kept |
| Notification header/row gaps | header top 10, row gap 10 | 8, 8 | 2 | notification_center:146,149 | B | `notification-header-pad`, `row-gap` | kept |
| Computer list item size | minHeight 66, vertical pad 6 | 68, 4 | 2 | computer_surfaces:457,469 | B | `list-item-min-height`, `list-item-pad-y` | kept |
| Feedback composer | spacing 16 / gap 6 / tool gap 6 / min editor 64 / bottom pad +160 | 12 / 8 / 4 / 20 / 0 | 6 | feedback_workspace:363,428,477,1052,1234 | B | per-surface spacing params | kept |
| Page rhythm spacers | 10, 4 | 7, titleGap null | 4 | settings_administration:1323, slack_bridge_wizard:1011, public_server:834 (0 vs 4), root_error_fallback:91 | B | `density-*` or derive from border width | kept; some are artefacts of Chromium baseline math |
| Radio/check dot | 14 | 16 | 1 | agent_dialogs:42 | B | `control-indicator-size` | **replaced** (Checkbox port) |
| Responsive compact mode | compact message item < 768 | always desktop | 1 | feedback_workspace:800 | C | param `compact-breakpoint` | kept |

## 7. Component-level differences (widget tree / painter / layout)

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| List-item state model (computer sidebar) | panel fill, hover fill-muted/ink-6, selected ring+sm | pink fill, black border, hover white | 1 | computer_surfaces:350-395 | C | could be data per state (fill, border, shadow) but is code | kept |
| Copy-code action | ghost 24px icon button (RaftRecipeButton iconXs) | outline `RaftPanelIconButton` | 2 | agent_profile:1075, agent_create_form:356 | C-param | enum `icon-button-variant` | **replaced** (Button port) |
| Empty state | 36 icon in 8px-padded rounded tile (fill-muted/layer-inset) | bare 36 icon | 1 | settings_workspace:1109-1127 | C | bool `empty-state-icon-tile` | kept |
| Panel header icon tile | borderless fill-muted | soft-signal + border | 3 | computer_detail:764, public_server:762, agent_profile:339 | B | `icon-tile-fill`, `icon-tile-border` | **replaced** (IconTile port) |
| Avatar slot shape/background | rounded-full, clip-padding | square + softSignal for server | 2 | agent_profile:303-345 | C | param | **replaced** (Avatar) |
| Filter tabs | indicator Stack | divider per tab, sticker | 1 | feedback_inbox:407-440 | C | | **replaced** (Tabs) |
| Feedback conversation + composer | overlay composer, baseline header | stacked footer, center header | 4 | feedback_workspace:817,1040-1135 | C | stays code | kept |
| Notification bell dot | inset sheen painter | flat + border | 1 | notification_center:217 | C | bool | kept |
| App logo tile | circle, 2 padding, sm shadow | square soft-signal, 2 border, shadow | 1 | settings_applications:812-850 | C | shape param | kept |
| Public-server header | no inner rule | rule inside switcher | 1 | public_server:920 | C | | kept |
| Settings panel header (attached) | 1px line inside box | recipe border-b-2 | 1 | settings_layout:398 | C | | kept |
| Appearance picker | not needed in NEW | theme chooser with per-family preview cards | whole file | appearance_picker.dart (21 sites) | C | | **deleted** (NEW: Light/Dark/System segmented control). If packs return, rebuild a chooser |
| Icon stroke / size | 1.5 stroke, 16 glyph, offset (-1,1) | 2, 14, 0 | 1 | feedback_workspace:1512-1538 | B | `icon-stroke-width`, `icon-size-sm` | kept |

## 8. Motion

No theme-branched animation, duration or curve found in my files. Only hover lift in appearance_picker (deleted) is identical in both families.

## 9. Counts (non-comment sites, approximate)

Area | files | sites | A | B | C | obsolete
---|---|---|---|---|---|---
Settings pages (app editor, applications, layout, workspace, admin, billing, member graph, resources, notif settings card) | 9 | 222 | 150 | 62 | 10 | 0
Computer / agent surfaces (computer_*, agent_*, external_*, add_computer) | 10 | 170 | 108 | 40 | 22 | 0
Setup wizards (setup_steps, slack wizard, resume bar, cindy setup) | 4 | 113 | 70 | 36 | 7 | 0
Auth / public / error (auth, public_server, invite, root_error, access_denied, error_presentation) | 6 | 71 | 45 | 21 | 5 | 0
Notification center | 1 | 32 | 15 | 9 | 8 | 0
Appearance picker + app icon choices | 2 | 27 | 2 | 0 | 2 | 23
Feedback inbox / workspace | 2 | 23 | 7 | 8 | 8 | 0
Total | 34 | 658 | ~397 (60 %) | ~176 (27 %) | ~62 (9 %) | ~23 (4 %)

By property (all areas): colours ~355 (A), border width ~90 (B), radius ~60 (B), shadows ~45 (A values, B step choice), typography ~30 (B), spacing ~25 (B), structural ~60 (C).

Plus hidden: 22 `raftPanelInk` and 23 `recipeTheme` call sites (class A, not in the table above).

## 10. Answer for the "pure data theme pack" question (this area)

- Colour: nearly all Elegant colours here are already semantic tokens read from the token map. A pack that replaces the colour map re-skins ~60 % of these sites with no code.
- With six new numeric tokens (`border-width`, `radius-control`, `radius-card`, `radius-xs`, `shadow-card/dialog/avatar` mapping, eyebrow typography group) most remaining B sites (~27 %) become data. They are the main gap: NEW hard-codes 1px / 6 / 8 as constants in `RaftTokens`.
- ~9 % (C) is real structure: list-item state model, feedback composer layout, empty-state tile, bell sheen painter, avatar shape, header border placement. Some could become enums/bools (text-transform, icon-button-variant, empty-state-icon-tile, avatar-shape). The feedback layout and list-item model stay code.
- Uncertainty: counts are from regex plus sampling. I did not read every one of the ~400 colour sites; the Brutal-to-token mapping in the table is the dominant pattern in every file I read. Modal/dialog/popover sites that sit in shared files (panel_layout.dart, design_primitives.dart, dialog_card.dart) are outside this list and belong to other groups.

## 11. Top 8 most visible Elegant-vs-Brutal differences (my files)

1. Hard 4px black offset shadows plus 2px black borders vs soft layered shadows (sm/md/lg) plus 1px hairlines, on every card, dialog, error card, setup card (A + B).
2. Square corners vs radius 6 (controls, chips, cards) and 8 (dialogs, banners, error cards) (B).
3. Fill palette: white/cream/pink/lime/cyan/orange blocks and pure black text vs layer-panel/canvas-muted/soft tints and foreground-strong/muted tokens (A).
4. Selected/hover list items (computer sidebar, public server rows, wizard steps): pink fill + black frame + hard shadow vs panel fill + ring + soft shadow, with dark-mode ink-6 hover (C).
5. Eyebrow and section headings: uppercase, bold, tracked (ls 1.2, w700) vs sentence case w500 (notification title) (B + C-param).
6. Avatars, app logos, icon tiles: square bordered with hard shadow vs circular/borderless (B/C; Avatar and IconTile replaced).
7. Header bars: soft-signal periwinkle (auth, resume bar) and cream (notification header, settings cards) with 2px black bottom rule vs panel with 1px line-hairline (A + B).
8. Status/pill colouring (computer status badge, MCP oauth badge, wizard step pills): saturated lime/cyan/red + black text + 2px edge vs `*-soft` fill + `*-strong` text + 1px line-muted (A + B).
