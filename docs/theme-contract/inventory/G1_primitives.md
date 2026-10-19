# G1 primitives: Elegant vs Brutal inventory

Scope: the 41 files in G1_primitives.files (OLD = a57b9dab), read against NEW = db40e0a7.
Total: 551 grep lines for `brutal|RaftFamily|RaftRecipeTheme` in these files. About 81 are comments, about 40 are the `theme.dart` getter/definition lines, and 44 only forward `recipeTheme` to the generated recipe tables. That leaves about 400 real branch sites. Rows below overlap, because one line can hit two patterns.

How I read it
- All sites were located with grep. Surrounding code was read for theme.dart, design_primitives.dart (about 80% of the contexts), components.dart (about 75%), and every smaller file. The unread parts are mid-file stretches with no branch.
- I did NOT read the generated `recipes/*.g.dart` tables (not in my list). 44 sites call `XRecipe.resolve(theme: t.recipeTheme, ...)`. Their Elegant values live in those tables as compiled constants. Colours go through `RaftTokenResolver` (a runtime hook). Paddings, radii and borders inside them are literal.
- Status column ("kept / replaced / deleted") was checked in NEW by grep and by reading the NEW code.
- Class A means: the value is a token the NEW schema already carries. That is a RaftSemanticColors role, RaftComponentColors, RaftProductColors, RaftThemeShadows xs..xl or RaftThemeMetrics. Class B means plain data with no token yet. Class C means structural code.
- Overall NEW status: nearly every Elegant branch was KEPT. It was kept by collapsing `brutal ? A : B` to the literal B. Example: `RaftShapes.control` is now `visualHeight < 32 ? 4 : 6`. So the Elegant look survives, but as hard-coded literals. Only the 11 ported components lost their Elegant implementation.
- NEW pins the recipe tables with `recipeTheme => RaftRecipeTheme.elegant` (recipe_surface.dart:20). They are still the 0.5.52 generated tables.

## 1. Colours

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Text ink roles | `t.strong` / `t.muted` / `foreground-muted` / `foreground-placeholder` | `Colors.black`, black at .4/.5/.6/.7/.75/.8 | ~45 | report_issue_dialog.dart:227-231; settings_controls.dart:992,1002; role_permission_help_dialog.dart:83-85 | A | RaftSemanticColors.foregroundStrong, foregroundMuted, foregroundPlaceholder | kept |
| Border / rule colour | `line-muted`, `line-hairline`, `line-strong` | `Colors.black` | ~25 | sheet.dart:50; presentation.dart:668; announcement_modal.dart:245 | A | RaftSemanticColors.lineMuted, lineHairline, lineStrong | kept. Black is also a `focusRing`, so see the focus row |
| Surface fill | `layer-panel` / `t.panel`, `layer-inset` | `Colors.white`, `gray-50` | ~15 | bottom_sheet.dart:57; announcement_modal.dart:317,799; settings_controls.dart:1345; indicators.dart:328 | A | RaftSemanticColors.layerPanel, layerInset | kept. The 'bg-white' name in `legacyCard` and legacy input is a recipe utility name per theme (components.dart:127-129; form_controls.dart:288-294) |
| Emphasis fill (primary/accent/selected) | soft tints: `primary-soft`, `accent-soft`, `fill-muted`, `card`, `panel` | saturated `primaryFill` / `accentFill` yellow, `color-soft-signal`, `brutal-pink` | ~35 | design_primitives.dart:216,531-536,254-259; announcement_modal.dart:252; selection_toolbar_recipe.dart:14; theme.dart:694,763,806 | A | RaftSemanticColors.primarySoft, accentSoft, fillMuted | kept. Selection and nav "active" fills are here |
| Hover / pressed fill | `button-*-hover`, `ink-4`, `fill-muted`, `fill-strong`, `ink-6` | no hover tint; or white, or primary at 30% | ~12 | design_primitives.dart:594-612; components.dart:675-690 | A | RaftComponentColors button*Hover; semantic ink-*, fill-* | kept. `.3`/`.8` alpha factors are literals (B) |
| Sticker palette (avatar, status, task chip, dots) | neutral and semantic: `fill-muted/strong`, `info`, `success`, `warning`, `primary-500`, `accent`, literal `0xffefb400` | `color-brutal-cyan/lavender/lime/orange/pink/red/stone` | ~30 | components.dart:485-490; mounted_task_chip.dart:40-80; indicators.dart:210-266; mounted_avatar_recipe.dart:96-136 | A, partly B | semantic + RaftProductColors; B: `task-status-*` literal colours | Elegant still uses brutal-named product colours (online lime, toast error red, action-note orange). A pack must keep those names. Status dot, attention dot and avatar: replaced. Task chip, nav and toast: kept |
| Focus ring colour | per variant: ink, `line-hairline`, danger, `primary-strong`, `accent-strong`, `line-strong` | transparent or black | ~8 | design_primitives.dart:500-508; components.dart:604-606; mounted_reaction_recipe.dart:30 | A | RaftSemanticColors.* | kept. Ring width is a literal (see shadows) |
| Field fill / placeholder / border | fill: `layer-panel` (dark `layer-card`), disabled `fill-muted`/50. Placeholder: alpha .7, disabled `foreground-disabled`. Border: `line-field`, hover `line-field-hover`, dark transparent | fill `panel`; placeholder plain; border `line-strong` | ~15 | theme.dart:255-283; combobox_panel.dart:170; form_controls.dart:696-704 | A (+B for alphas) | semantic fields exist. B: `opacity-placeholder`, `opacity-field-disabled` | **replaced**: NEW RaftFieldRecipe is the 0.7.1 Input (`layer-card`, `line-strong`, `foreground-hint`). The old Elegant field recipe is gone |
| Tooltip / scrim / refresh / skeleton | tooltip `layer-hud` or `popover`; scrim `layer-backdrop`; refresh `accent`; skeleton `foreground-strong`@.08 | `primary-400`; black .6; `t.strong`; black .1 | ~10 | tooltip.dart:30-41; dialog_card.dart:331-333; pull_to_refresh.dart:24; indicators.dart:692-700 | A | RaftSemanticColors.layerHud*, layerBackdrop | kept. `layer-hud` has a hard-coded literal fallback (tooltip.dart:35) |
| Toast icon tone | light only: `info/success/warning/brutalRed`; dark `foreground-muted` | `foreground-strong` | 1 | toast.dart:91-97 | A | semantic info/success/warning | kept |

## 2. Typography

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Control / label face | `bodyFont` (Geist) | `headingFont` (Hanken) | ~3 | design_primitives.dart:657; theme.dart:549-550 (labelLarge `heading: t.brutal`) | A | RaftThemeMetrics.sansFont / headingFont | kept (theme.dart collapsed to `heading: false`) |
| Optical size axis | `FontVariation('opsz', size.clamp(14,32))`; fields opsz 14 | none | 3 | theme.dart:189,503; design_primitives.dart:334 | B | `font-opsz-heading` (min/max/on) | **deleted** in NEW: no `opsz` left in theme.dart or design_primitives.dart. It needs variable-font assets |
| Weight | 500, 400, 600 (embed author, tab 500) | 700 (tab 600, menu 500) | ~25 | design_primitives.dart:235,1523,1738-1743,2768,2997; theme.dart:550; tooltip.dart:47; components.dart:1103,1397,1403; mounted_task_chip.dart:125 | B | `font-weight-title`, `-label`, `-control`, `-meta`. Only RaftThemeMetrics.cardTitleFontWeight and fieldFontWeight exist | kept |
| Size / line-height | panel title 17/21.25; menu 13/19.5; nav saved 13/19.5; channel title 13 | 18/22.5; 14/20; 14/20; 14 | ~10 | design_primitives.dart:233-234,1521-1522; components.dart:480-486,1100 | B | `font-size-menu`, `-title`, `-nav` | kept as literals |
| Letter-spacing | -0.065 (menu 13px, tooltip 13px), -0.06 (picker 12px) | 0 | 3 | design_primitives.dart:1525,2999; tooltip.dart:48 | B | `letterspacing-menu`, `-tooltip`, `-control` (em based) | kept |
| Case | normal | UPPERCASE: Done chip, DialogTitle (via recipe `textTransform`), badge `uppercase: true`, departure label, composer group labels | ~12 | action_card.dart:130; overlays/dialog.dart:342; components.dart:1665,2699,3410; inline_badge_editor.dart:153 | B (helper needed) | `text-transform-heading`, `-label`, `-badge` (none/uppercase) | kept. Elegant side kept normal case. Recipe-driven ones live in the tables |
| Line-height quirks | `leading-none` / 1 | measured 20/14, 14/10, 13*1.25 | ~5 | components.dart:1648,1691; mounted_task_chip.dart:20,124 | B | `line-height-meta` | kept (pixel-measured against the Web; weak candidates) |
| Muted italics, readonly text | `t.muted`, `foreground-muted` | black/.7, .6 | ~4 | design_primitives.dart:2594; settings_controls.dart:1109 | A | see ink row | kept |

## 3. Shape (radius)

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Control radius | 6 (height >= 32) / 4 | 0 | ~12 | design_primitives.dart:445-456,626-642,2979 | B | `radius-control`, `radius-control-sm` | kept as literals |
| Panel / field radius | 8 / 6 | 0 | ~10 | theme.dart:177-178 (`radius`, `fieldRadius`); theme.dart `shape()` x10 (dialog 8, menus 6, chip 4, checkbox 2) | B | `radius-panel`, `radius-field`, `radius-chip` | NEW getters are fixed constants (8/6) and Input is now fixed 8 (theme.dart:549). Not tokens |
| Small row / suggestion / menu item radius | 2 | 0 | ~6 | design_primitives.dart:2537; components.dart:3128 | B | `radius-item` | kept |
| Sheet top corners | 16 (`RaftSpace.x4`) | 0 | 1 | sheet.dart:43 | B | `radius-sheet` | kept |
| Popover / tooltip / picker radius | 6 | 0 | ~5 | popover_surface.dart:43; tooltip.dart:23; design_primitives.dart:2979 | B | `radius-popover`, `radius-tooltip` | kept |
| Task section / header icon / attachment | 10 / 6 / 6 | 0 | ~5 | design_primitives.dart:226,262-263,2760 | B | `radius-card-section`, `radius-icon-tile` | kept |
| Avatar shape | circle (`size/2`) | square | ~8 | components.dart:478; mounted_avatar_recipe.dart:94,236; settings_controls.dart:1161-1169,1198 | B (`radius-avatar: full|px`) | `radius-avatar` | **replaced**: NEW sticker avatar has radius 4 (mounted_avatar_recipe.dart:101); the old circle is gone |
| Task chip | pill 999 | 0 | 1 | mounted_task_chip.dart:35 | B | `radius-chip` | kept |
| `clip: !t.brutal` on recipe boxes | clip to rounded corners | no clip | ~4 | search_input.dart:102; form_controls.dart:641; overlays/dialog.dart:220 | A | derived from radius > 0, so no token needed | kept |

## 4. Borders

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Control edge | no border; a 1px SPREAD shadow in `line-muted` or the variant edge (`button-default-fill`, `primary-edge`...) | 2px solid black border | ~12 | design_primitives.dart:722-725,775-806; components.dart:735 | B | `border-width-control` (0 or n), plus the edge colour as `ring` | kept. Elegant draws edges as shadows, not borders |
| Surface border width | 1 | 2 | ~28 | sheet.dart:51; presentation.dart:678; announcement_modal.dart:246; settings_controls.dart:1109,1349; indicators.dart:344; theme.dart (`t.border`, 8 uses) | B | `border-width` (NEW getter is fixed 1) | kept |
| Hairline | .5 | 1 | ~5 | design_primitives.dart:1722; mounted_task_chip.dart:22; theme.dart:765 | B | `border-width-hairline` | kept |
| Menu / popover frame | none (shadow ring) | 2px black | ~4 | design_primitives.dart:1501-1504; popover_surface.dart:42; tooltip.dart:659 | B | `border-width-popup` | kept |
| Separator rule | 9px gap with .5px `line-hairline`; row divider 1px `line-muted` | 2px black; 1px black/10 | ~4 | design_primitives.dart:2212-2218,2541 | B | `divider-height`, `divider-thickness` | kept; theme.dart divider 1 vs 2 as well |
| Dashed inner border | dashed left/right in code block (`_DashedSides` painter) | solid box | 1 | copyable_code.dart:78-122 | C (could be bool `code-inner-dashed`; stays painter code) | | kept |
| Nav / chip border | transparent 1px (the box keeps the size) | 2px black/transparent | ~6 | components.dart:524,735,749 | B | `border-width-nav` | kept |

## 5. Shadows and elevation

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Default elevation | `themeShadows.sm.outer` (dark xs) | hard 2px black offset; hover 4px; pressed 1px | ~25 | theme.dart:203-207; design_primitives.dart:742-760,1528-1560; components.dart:822-830 | A for xs/sm/md/xl; B for literals | RaftThemeShadows.xs..xl exist | **partly deleted**: the `dark -> xs` rule is gone (NEW theme.dart:208 is always `sm`) |
| Menu panel shadow | light: `0 3 12 black/.1` + 1px `line-muted` ring; dark: 3 layers | 4px,4px black | 1 | design_primitives.dart:1528-1560 | B | `shadow-menu` | kept as a literal list instead of a token |
| Tooltip shadow | light: soft; dark: 3 layers | 2px offset `line-strong` | 1 | tooltip.dart:51-80 | B | `shadow-tooltip` | kept |
| Popover / sheet / card | `xl` with dark inset layers (top light and ring); legacy card `shadow-raft-md`; sheet `xl` | `lg`; `shadowBrutal`; `shadowBrutalLg` | ~6 | popover_surface.dart:46-53; bottom_sheet.dart:58; components.dart:127-130 | A | RaftThemeShadows.xl/md + RaftShadow.inset | kept |
| Dark-only insets | field insets (2 inset + 1 outer), switch, tooltip `_TooltipInset`, tab, picker highlight .045/.05 | none | ~8 | theme.dart:285-315; design_primitives.dart:761-775; tooltip.dart:665; switch.dart:264 | A (popover xl insets); B for the rest | `inset-highlight-alpha` | field and switch: **replaced**. Tooltip and picker: kept |
| Button sheen | top-to-bottom white gradient .08/.10/.04; outline black .01; inset highlight alpha .12/.05/.04 | none | 3 | design_primitives.dart:615-657 | C (painter) -> could become param `button-sheen` | | kept in RaftControlRecipe. **replaced** in RaftButton (0.7.1) |
| Focus ring | spread 1/2/3 ring in ring colour (dark 60% alpha) | `shadow-md` lift; no ring | ~6 | design_primitives.dart:1454-1466,3025; theme.dart:207,212 | B | `ring-width`, `ring-alpha` | kept. NEW `focusShadows => shadows` |
| Toast saturate | `ColorFiltered(saturate 1.5)`, light only | none | 1 | toast.dart:215-217 | B (a number) | `filter-saturate-toast` | kept |

## 6. Spacing and density

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Panel header / rail sizes | header 56; rail 56, glyph 16 | 62; 64 (50 on short screens), 18 | ~8 | design_primitives.dart:99-107,246-247 | B | `panel-header-height`, `rail-width`, `rail-glyph` | kept; `brutalPanelHeader` (62) constant is still used by two NEW callers (channel_overflow_sheet.dart:74, channel_members_view.dart:814) |
| Row / control heights | menu row 31.5 / 27.5; picker 28; saved action 32; channel row 34/30; task chip 19 | 36/28; 32; 28; 40/32; 16.25 | ~12 | design_primitives.dart:1507-1513,1360,3055; components.dart:884-891 | B | `height-menu-row`, `height-picker`, `height-nav-row` | kept |
| Horizontal paddings | nav 6 (saved 6), picker 10, count 4, task chip 8, suggestion icon gap 10 | 8, 12, 6, 4, 8 | ~15 | components.dart:515,788,3163; design_primitives.dart:2991 | B | `space-control-x`, `space-item-x` | kept |
| Vertical paddings / insets | embed item 14; task section inset 12; menu inset 4; sidebar bottom 68 | 8; 0; 0; 52 | ~12 | design_primitives.dart:1726,2743,1504; components.dart:1189 | B | `space-item-y`, `inset-menu` | kept |
| Gaps | popupGap 6; banner title 4; banner action 4; code-block gap | 4; 2; 8 | ~8 | design_primitives.dart:1516; banner.dart:128,221; copyable_code.dart:68 | B | `gap-popup`, `gap-banner` | kept |
| Shell layout | floating header overlays content; sidebar insets 26/28/18/28; body `sidebar` colour; mobile bottom capsule clearance | in-flow header 16; insets 8/12; cream body | ~12 | design_primitives.dart:138-186 | C (structural; the header overlay is a layout mode) | could be bool `header-overlay` | kept, then the Brutal side was removed |
| Dialog layout | unpadded popup with header/body/footer px-6; `gap 0` | padded content, `gap-4` | ~3 | settings_controls.dart:891; overlays/dialog.dart:220 | C (from recipe tables) | | kept |

## 7. Component-level (widget trees and painters)

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Switch | pill track, round thumb, drop shadows, dark layers, pressed scale .96 | square 2px frame, square thumb | ~14 | switch.dart:22-80,185-361 | C (painter) | | **replaced** (raft/switch.dart 50x30) |
| Checkbox | `ElegantCheckboxGraphic` rect + check icon, radius 3 / circle | recipe box with lucide Check stroke 4 | ~4 | indicators.dart:419-470 | C | | **replaced** (raft/checkbox.dart) |
| Badge / StatusDot / AttentionDot | borderless; `bg-accent`, `bg-warning` dots | 1px black border, brutal-pink/orange | ~8 | indicators.dart:228-273 | C | | **replaced** |
| Button (RaftButton) | sheen overlay, edge ring, `button-*` fills | border + hard shadow | ~3 | components.dart:295 and RaftControlRecipe | C | | RaftButton **deleted/replaced**; RaftControlRecipe (still used) kept as Elegant |
| Tabs / segmented | tab fills from `primary`/`fill-muted`; inset shadows | `tab` has no shadow | ~6 | design_primitives.dart:578-592,780-806 | B | | `_SegmentedItem` **deleted**; tab recipe kept |
| Spinner | 2.5/24 stroke, round cap, dash cycle 1400ms, spin 1600ms | 2px ring, 90 deg arc, 1000ms | 8 | design_primitives.dart:1580-1690 | C | could be `spinner-style` enum | kept (still RaftSpinner in NEW). New RaftPixelSpinner exists beside it |
| Tooltip arrow | arrow painted | none | 3 | tooltip.dart:28,550 | C -> bool `tooltip-arrow` | | kept (NEW `hasArrow => true`) |
| Press motion | `scale .985` | translate (+1,+1) press / (-1,-1) hover, with growing shadow | 3 | design_primitives.dart:1002-1012,1124-1135 | C -> enum `press-effect` | | kept (scale branch) |
| Copyable code | dashed inner span, ghost icon-xs button, line 20 | solid box, outline icon-sm, line 16 | ~5 | copyable_code.dart:68-110 | C | | kept |
| Inline code | atomic `inline-flex` WidgetSpan with 1.5px y-padding, `layer-inset` fill | plain inline, white | ~5 | announcement_modal.dart:685,782-805,863-875 | C | | kept |
| Suggestion list | no frame on icons; group separator is spacing only; extra `gap-2` | framed 20px icon, 2px black separator rule | ~6 | components.dart:2686-2710,3251-3290 | C (small; could be `suggestion-framed-icon`) | | kept |
| Dialog close / dialog title | ghost icon-sm, glyph 16; title normal case | outline icon-md, glyph 20; uppercase | ~6 | overlays/dialog.dart:420-430; settings_controls.dart:921-931 | C (from recipe tables) | `dialog-close-style` | kept |
| Legacy card / input chrome | `shadow-raft-md/xs/sm`, `line-field`/`line-strong` | hard shadow + black border | 2 | components.dart:119-142; form_controls.dart:285-330 | A (shadows xs/sm/md exist) | | kept |
| Skeleton | themed rounded fill (line pill 999, block 6) | hard pulse | ~2 | indicators.dart:692-700 | B | `radius-skeleton` | kept |
| Server profile tile / avatars | circle, transparent 2px padding | square, bordered | ~3 | settings_controls.dart:1161-1203 | C | | partly **replaced** |
| ActionCard badge, nav pointer | normal-case "Done" | "DONE" | 1 | action_card.dart:130 | B | `text-transform-label` | kept |

## 8. Motion

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Press scale vs offset | scale .985 | translate and shadow growth | see press row | design_primitives.dart:1002-1012 | C | `press-effect` | kept |
| Spinner timing | 1600 ms spin + 1400 ms dash | 1000 ms spin | 1 | design_primitives.dart:1580 | B | `spinner-duration` | kept (`Duration(1600)` literal) |
| Backdrop blur | 2px blur on scrims | none | 2 | dialog_card.dart:331; overlays/dialog.dart:612 | B | `backdrop-blur` | kept |
| Indeterminate progress | 1.6 s | 1.4 s | 0 (not implemented) | indicators.dart:512 | B | | known gap in OLD too |
| Switch / checkbox easing | via the painter | | | | C | | replaced |

## 9. Icons

| what | Elegant | Brutal | n | samples | class | token | note |
|---|---|---|---|---|---|---|---|
| Icon size | nav 18 (generic), menu 16, picker 12, saved 16, toast 18, rail 16, empty state 18, spinner 14 | 12, 14, 14, 14, 16, 18, 36, 16 | ~13 | components.dart:497,880; design_primitives.dart:2313,2565,1369; toast.dart:128; product_empty_state.dart:47 | B | `icon-size-nav`, `-menu`, `-toast`, `-empty` | kept |
| Stroke width | 1.5 (menu, toast) | 2, 2.5 | 3 | design_primitives.dart:2566; toast.dart:130; indicators.dart:432 | B | `icon-stroke` | kept |
| Icon colour | `foreground-icon`, `foreground-placeholder`, `t.muted` | `t.strong`, black | ~8 | components.dart:497,503 | A | RaftSemanticColors.foregroundIcon | kept |

## 10. theme.dart (Material mapping) in one place

The old Material ThemeData is covered by the rows above. Elegant values: label weight 500 (labelLarge, not heading), dialog title 14/20 w500, popup elevation 3, no hover overlay except `fill-strong`@.3, `outlined` button transparent, chip selected `accent-soft`, divider 1, tooltip radius 4, input focus colour `primaryFill`@1px, checkbox side 1.
- In NEW these became literal Elegant values, and `fieldBorder` is fixed 1.5px at radius 8 (0.7.1 Input).
- Elegant `fieldStyle` opsz 14 is deleted.

## Counts (approximate, overlapping)

| area | A | B | C | total |
|---|---|---|---|---|
| colours | ~175 | ~15 | 0 | ~190 |
| typography | ~5 | ~55 | 0 | ~60 |
| shape | ~4 | ~50 | 0 | ~55 |
| borders | 0 | ~50 | 1 | ~50 |
| shadows | ~12 | ~25 | ~8 | ~45 |
| spacing / density | 0 | ~75 | ~12 | ~87 |
| component-level | ~3 | ~10 | ~45 | ~55 |
| motion | 0 | ~4 | ~5 | ~9 |
| icons | ~8 | ~16 | 0 | ~24 |
| **sum** | **~207** | **~300** | **~71** | ~575 (overlap; real sites about 400) |

Status of the Elegant side in NEW:
- Kept (as literals): about 85% of sites.
- Replaced by 0.7.1 ports: about 10% (switch, checkbox, badge/status/attention dot, avatar, field recipe/Input, button, `_SegmentedItem`).
- Deleted: opsz axis, dark `xs` shadow rule, old Elegant field insets and `fieldBorder` insets.

## Top 8 most visible Elegant-vs-Brutal differences

1. **Shadows and edges.** Hard offset black shadows and 2px black borders (Brutal) vs soft layered shadows with 1px ring edges (Elegant), on controls, menus, tooltips, cards and sheets. This is the single biggest feel difference. Part is A (xs..xl); the menu, tooltip and control layers are B (literals now).
2. **Fill colours.** Saturated yellow/pink primary, accent and selection fills vs soft tints (`primary-soft`, `accent-soft`, `fill-muted`). A (tokens exist).
3. **Corner radius.** Everything square (0) vs 4/6/8/16, with circular avatars. B, because NEW radius getters are fixed constants. Avatars were replaced anyway.
4. **Type.** Bold 700 Hanken headings vs 500 Geist/Inter with opsz and slight negative tracking. B (weight, size and tracking tokens). Opsz is deleted in NEW.
5. **Case.** UPPERCASE dialog titles, badges, "DONE" and group labels vs normal case. B plus a small helper.
6. **Shell metrics.** Header 62 vs 56 with a floating overlay header, rail 64 cream vs 56 sidebar-coloured, sidebar insets, row heights 40/32 vs 34/30, menu rows. B for numbers, C for the overlay-header layout.
7. **Interaction.** Offset-and-shadow press motion vs scale .985, plus the Elegant top sheen gradient and dark-mode inset highlights. C (could be params `press-effect`, `button-sheen`).
8. **Status and identity chrome.** Sticker palette (cyan/lavender/lime avatars, bordered dots, pink count badges) vs neutral fills and borderless dots. Mostly A for colours, and the shape parts were replaced by the 0.7.1 ports.

## Bottom line for a data-only theme pack
- Colours: nearly all in A. A pack that sets `RaftSemanticColors` and the component colours gets them. Keep the brutal-named product colours that Elegant still uses.
- Geometry (radius, border widths, paddings, heights, font weights/sizes, tracking, icon size/stroke, hard shadow lists): all B. They are literals in NEW today. About 300 sites would need to read new tokens (about 25-30 distinct token names).
- Structural bits (C, about 70 sites, mostly the replaced components, plus shell layout, tooltip arrow, press motion, sheen, dashed code border, spinner): these stay code, or become 4-5 enum/bool params.
- Recipe-driven components (44 `recipeTheme` sites) use compiled per-theme tables. Their literals are not reachable from a runtime pack without making the recipe tables data.
