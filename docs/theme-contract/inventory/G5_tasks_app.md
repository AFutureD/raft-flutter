# G5 tasks + app features: Elegant vs Brutal, classified against the new mechanism (db40e0a7)

Scope: the 22 files in G5_tasks_app.files (all read at the brutal sites with context, plus a full old-vs-new diff of
task.dart, task_surface.dart, page_recipes.dart). Paths: OLD = a57b9dab export, NEW = db40e0a7 export.
File:line refs are OLD unless marked NEW. "lib" = apps/raft_flutter/lib/features, "ui" = packages/raft_ui/lib/src.
Survival column: in every pattern below the Elegant branch is **kept** in NEW unchanged (verified by diff/grep); only the
Brutal side was deleted. Exceptions are marked. None of my files is one of the 11 ported components, except where noted.

Classes: A = existing token fits. B = plain data but needs a new token/param. C = code (tree/painter/layout/bool).
Not counted as sites: ~12 pure comments that mention `theme-brutal:` (agent_apps_view, server_views, account_settings
alert/confirm colour) and unrelated copy edits in the diff ("Close Task", "Show More"...).

## 1. Colours

| what | Elegant | Brutal | n | samples | class | proposed token | note |
|---|---|---|---|---|---|---|---|
| Task status chip fill/text/border | `{info,accent,success,warning}-soft` bg + `-strong` text; closed = `fill-muted` / `foreground-strong`; no border | solid `color-brutal-{cyan,lavender,lime,orange,stone}` + black text + 1px ink border | 4 | ui/task.dart:70-80,89,110-117,640-655 | A | RaftSemanticColors `*Soft/*Strong`, `fillMuted`, `taskStatus*Strong` | whole brutal palette is a different colour family; Elegant side is already pure tokens |
| Role chip colours (owner/admin/guest/member) | `warning/accent/info-soft` bg, `-strong` ink, member `fill-muted`/`foreground-strong` | brutal orange/pink/cyan/lavender bg, black ink | 2 | lib/member_profile_view.dart:315-330 | A | same as above | |
| Page body / list surface fill | `layer-canvas-muted` (t.sidebar) for Saved, Activity, resource list, task viewport (transparent in dark) | `layer-panel` (white) | 6 | lib/resource_view.dart:2385,2393,2399,2798,5383; ui/page_recipes.dart:241 (brutal-cream vs sidebar) | A | `layerCanvasMuted`, `layerPanel` | the choice of WHICH layer role a page uses is code; both roles exist |
| Card / popover / frame fill | `layer-card`, `layer-popover` (legacy: canvas), `layer-panel` | pure white | 9 | ui/task_surface.dart:213,524,694; lib/source_channel_files_view.dart:202,207,645; ui/page_recipes.dart:26,305; lib/member_graph_view.dart:258 | A | `layerCard/layerPopover/layerPanel` | |
| Hard-coded black/white text -> semantic text | `foreground-strong`, `foreground-muted`, `foreground-placeholder` | `Colors.black`, black@.5/.6, `ink`, strong@.7 | 12 | ui/task_surface.dart:550,558,595,891,899; lib/source_channel_files_view.dart:292,298; ui/page_recipes.dart:51,93; lib/resource_view.dart:4004 | A | `foregroundStrong/Muted/Placeholder` | Brutal used alpha on black; Elegant uses real tokens |
| Border colour | `line-muted`, `line` (hover `line-strong`), `line-hairline` for rules; transparent in dark for search/file cards | black, black@.2/.3, `line-strong` (rules), ink | 14 | ui/task.dart:764-767,811; ui/task_surface.dart:180,219,301,526; lib/source_channel_files_view.dart:211,647; ui/page_recipes.dart:34-36,243,280,307; lib/resource_view.dart:3565 | A | `lineMuted/line/lineStrong/lineHairline` | dark-transparent is a `t.dark` branch, not brutal (kept) |
| Search hit highlight + selected line | bg `primary-400`@.7, text `primary-950`, normal weight; selected line `primary-400`; appearance-card selected `accent` | bg primary-400 opaque, text strong w700; selected line strong; selected card strong | 4 | lib/resource_search.dart:202-203; ui/page_recipes.dart:46-47,280 | A (+B for the .7 alpha) | `primary400`, `primary950`, `accent`; B: `highlight-alpha` | alpha .7 is a literal; only B if a pack must change it |
| Lane drop/idle fills | idle `fill-muted`@.3 (board empty: `layer-panel`), drop-active `primary-soft` | white@.3 / none | 2 | ui/task.dart:759-764,810-817 | A | `fillMuted`, `primarySoft`, `layerPanel` | alpha .3 literal |
| Tag chip bg/border (search home) | `card` / `line` | white / strong@.2 | 2 | ui/page_recipes.dart:305-307 | A | `layerCard`, `line` | |

## 2. Typography

| what | Elegant | Brutal | n | samples | class | proposed token | note |
|---|---|---|---|---|---|---|---|
| Weight of search sender / summary / entity title / metadata / task badge label | w500 | w700 | 5 | ui/page_recipes.dart:52,72,99,105; ui/task.dart:47 | B | `font-weight-emphasis` (and badge variant) | RaftThemeMetrics only has field/card-title weights |
| Font family of role | body (sans) for timestamp and section title | `mono` | 2 | ui/page_recipes.dart:54-60,75-82 | B | `font-role-meta` (sans/mono/heading ref to existing stacks) | stacks exist; the role->stack mapping does not |
| Size/line-height | task badge 11/12; section title 12/16; detail term 11/11 w500 placeholder colour | 10/12; 10/15 mono; 12/16 | 3 | ui/task.dart:45; ui/page_recipes.dart:75-82; ui/task_surface.dart:604-617 | B | `text-size-badge`, `text-size-eyebrow`, `text-size-term` | |
| Letter-spacing | badge +0.22, snippet -0.14 | 0 / 0, section title +2 | 3 | ui/task.dart:49; ui/page_recipes.dart:94,75-82 | B | `letterspacing-badge`, `letterspacing-body-snippet`, `letterspacing-eyebrow` | |
| Text case | none (label as is) | UPPERCASE badge labels (recipe `textTransform`, `uppercase: true` on InlineBadgeEditor) | 2 | ui/task.dart:640,658-676; ui/task_surface.dart:658 | B | `text-transform-badge` (none/uppercase) | code already reads `badge.textTransform` from the recipe, so a param is cheap. `uppercase: true` call was deleted in NEW (status badge ported) |
| Hyperlink / opsz | no theme-specific value in my files | | 0 | | | | |

## 3. Shape (radius)

| what | Elegant | Brutal | n | samples | class | proposed token | note |
|---|---|---|---|---|---|---|---|
| Card / lane / file row / modal frame / thumbnails | 8 (legacy task modal 0) | 0 | 6 | ui/task_surface.dart:137; ui/task.dart:813; lib/source_channel_files_view.dart:209; ui/page_recipes.dart:23; `t.radius` getter old theme.dart:177 | B | `radius-card` | NEW `radius` is a const 8 getter, not a token |
| Search section | 10 | 0 | 1 | ui/page_recipes.dart:22 (+design_primitives.dart:2760 task section) | B | `radius-section` | |
| Pills/badges | 999 (task badge), 12 (search "warning" badge) | 0 | 2 | ui/task.dart:40; lib/resource_search.dart:740 | B | `radius-badge` / `radius-pill` | |
| Recipe-resolved radii (`rounded-lg` etc.) | baked in generated recipe class tables | | see 7 | | B | via utility table | see section 7 |

## 4. Borders

| what | Elegant | Brutal | n | samples | class | proposed token | note |
|---|---|---|---|---|---|---|---|
| Width of card/section/frame borders | 1, or 0.5 hairline (search section, appearance card, file row) | 2 | 12 | ui/page_recipes.dart:37,278; ui/task.dart:768,810; ui/task_surface.dart:136,303; lib/source_channel_files_view.dart:216,648; lib/account_sign_in_recipe.dart:17 | B | `border-width-card`, `border-width-hairline` | `t.border` getter is const 1 in NEW. Elegant already uses two widths, so a pack needs both |
| Rules / dividers (header bottom, activity toolbar, details rule, panel left edge) | 1 `line-muted/line-hairline` | 2 black / line-strong | 6 | ui/task_surface.dart:180-185,301-304,524-527; lib/resource_view.dart:3091,3565; ui/panel_edge.dart:129 via lib/desktop_master_detail.dart:127 (`brutalThick`) | B | `border-width-rule` | `brutalThick` param is now dead in NEW but still passed |
| Dashed border (empty lane, search "frequently used") | 1px, colour line-muted/tag border | 2px (padding grows by +border) | 3 | ui/task.dart:810-817; lib/search_home.dart:176-183 | B | `border-width-card` (same) | dashed style is the same in both |
| Account sign-in divider | 2 `line-muted` (same in both; Brutal only recolours to black) | 2 black | 1 | lib/account_sign_in_recipe.dart:43-45 | A | `lineMuted` | colour comes from RaftSettingsText (G4) |

## 5. Shadows / elevation

| what | Elegant | Brutal | n | samples | class | proposed token | note |
|---|---|---|---|---|---|---|---|
| Task thread modal | `themeShadows.xl` (legacy panel `md`), painted under the frame | `RaftProductShadows.shadowBrutal` 4px 4px | 2 | ui/task_surface.dart:204-207,846-850 | A | `RaftThemeShadows.xl/md` | |
| Channel file row | light: 0 .5px ring `fill-strong`@.071 + 3 hover layers (alpha .012/.02/.039); dark: 3-layer black rings and lifts (alpha .4/.45/.15/.25/.22) | solid 4px 4px strong (hover 2px 2px) | 1 (a 60-line literal block) | lib/source_channel_files_view.dart:218-285 | B | `shadow-card`, `shadow-card-hover` (light and dark) | NOT in RaftThemeShadows; hard-coded literal in the app. Includes spread-ring (hairline) layers |
| Selected appearance card, assignee popover | none (Elegant `shadow-none`); popover `shadow-raft-md` class | `t.shadows` hard offset; `brutalProductShadow` flag | 3 | ui/page_recipes.dart:283; ui/task_surface.dart:777,846-850; ui/list_items.dart:915,1067 | A | `RaftThemeShadows.md` / none | |
| Dark inset layers, sheen overlays | none in my files | | 0 | | | | |

## 6. Spacing / density

| what | Elegant | Brutal | n | samples | class | proposed token | note |
|---|---|---|---|---|---|---|---|
| Search viewport / section inset, gap | viewport 12 (mobile L20 T12 R14 B12), section 12, gap 6 | 16, 0, 8 | 4 | ui/page_recipes.dart:15,21,24 | B | `space-page-inset`, `space-section-inset`, `gap-list` | mobile 20/14 is the Web `max-md:pl-5 pr-3.5` rule |
| Message header/body vertical inset | 10 | 12 | 2 | ui/page_recipes.dart:39-44 | B | `space-card-pad-y` | |
| Task viewport inset (mobile) | L20 T16 R14 B16 | 16 uniform (Brutal resets) | 2 | lib/resource_view.dart:4412 | B | `space-page-inset-mobile` | |
| Task badge inset | h10 v2 | h6 v2 | 1 | ui/task.dart:41 | B | `space-badge-x` | |
| Header / bar heights | thread header 53; agent header min 66; legacy panel `panelHeader` 56 | 54; 72; legacy `brutalPanelHeader` 62 | 3 | ui/task_surface.dart:291-295; lib/agent_detail_view.dart:870 | B | `height-panel-header`, `height-entity-header` | |
| Control heights | filter picker 28, search filter target `buttonSm` | `buttonMd` | 2 | lib/task_selection_filter.dart:74; lib/search_filter_bar.dart:125 | B | `height-control-sm` | |
| Sidebar group top gap | 6-2 and 12-2 | 6-4 and 12-4 (compensates 2px border) | 2 | lib/desktop_directory_view.dart:371,548 | B | derived from `border-width-rule` | falls out if border width is a token |
| Input padding on profile name | default Input padding | p-2 (8) | 1 | lib/account_settings.dart:355 | B | `space-field-pad` | Input is a PORTED component: Elegant impl **replaced** by NEW raft/input |
| Empty-lane padding | 12/20 + border | same + 2px border | 1 | ui/task.dart:820-830 | B | follows border width | |

## 7. Component-level (structure)

| what | Elegant | Brutal | n | samples | class | proposed | note |
|---|---|---|---|---|---|---|---|
| Generated recipes selected by `RaftRecipeTheme` (taskCard, taskListSection, taskBoardColumn, tasksPanel, search, searchEntity) | Elegant tables | Brutal tables | 12 | ui/task.dart:202,380,464,629; lib/resource_search.dart:412,611; lib/resource_view.dart:3158,5119; lib/search_home.dart:105 | A for colours/shadows/fonts, B for geometry | `RaftRecipeTokens` already resolves colour, shadow, field/card-title numbers, font stacks (NEW recipes/token_binding.dart:12-90). Radius, border width, padding, `rounded-lg`, `px-3` are literals in the generated Tailwind utility table | a pack that changes only colours/shadows/fonts flows into all recipes for free. Geometry needs either a pack-aware utility table or regeneration (`tool/recipes/run`). NEW kept the `RaftRecipeTheme` enum with `.elegant` only |
| Canonical panel header (page_layout) | `RaftPanelHeaderBar`: 36px `fill-muted` tile, title+meta inline (gap 8), mobile hairline bottom, own mobile inset | recipe header: mono subtitle, thick bottom rule | 6 | lib/page_layout.dart:119,144,147,155,175,219 | C | could become enum `header-style` but only Elegant is needed | different widget tree and metrics (`elegantHeaderGap` 8, `elegantHeaderMetaGap` 4) |
| Mobile bottom nav | floating capsule (`mobileNavigationFloating: true`), list bottom padding 0 under it | in-flow bar with strip fill + system-inset padding | 3 | lib/workspace_view.dart:1831; lib/mobile_workspace_navigation.dart:167; lib/desktop_directory_view.dart:400 | C | bool `mobile-nav-floating` | layout/clearance logic differs; Elegant kept |
| Member-graph header icon tile | `fill-muted`, borderless, header fill `layer-canvas-muted` | soft-signal tile with border, white header | 3 | lib/member_graph_view.dart:258-294 | A | `fillMuted`, `layerCanvasMuted`; bool `borderless` already exists | |
| Section badge (list/board) | icon in strong status colour, no fill | fill + recipe svg colour + uppercase | 3 | ui/task.dart:640-655 | C->B | `badge-style` (soft/solid) | |
| Conversation tab surface (dark) | `card` in Elegant dark | transparent | 3 | lib/conversation_panel.dart:249; lib/resource_view.dart:2399 | A | `layerCard` | the `!brutal` part is dead in NEW; the `t.dark` part is the real condition |
| Settings colours `RaftSettingsText.edge/softEdge/alert/faint/panel` consumed by account/server/settings pages | Elegant tokens | black/white-alpha | ~6 uses (indirect) | lib/account_sign_in_recipe.dart:14,34,41,44; lib/settings_page.dart:184 | A | owned by G4 (`settings_layout.dart`) | no brutal branch in my files, but they depend on one |

## 8. Motion and icons

| what | Elegant | Brutal | n | samples | class | proposed | note |
|---|---|---|---|---|---|---|---|
| Hover on file row | ring + soft lift, 150ms | shadow offset 4 -> 2 | 1 | lib/source_channel_files_view.dart:218-250,695 | B | `shadow-card-hover` | duration identical |
| Picker icon size | 12 | 14 | 1 | lib/task_selection_filter.dart:270 | B | `icon-size-control-sm` | |
| Icon colour in avatar fallback | muted | ink | 1 | lib/resource_view.dart:4004 | A | `foregroundMuted` | |
| Stroke width, other motion | none found in my files | | 0 | | | | appearance picker hover-translate is in raft_ui (G4) |

## 9. Theme selection and persistence at a57b9dab

- **Types** (ui/theme.dart:7-18): `enum RaftFamily {brutal, elegant}`; `RaftAppearance{mode: ThemeMode = system, light: RaftFamily = brutal}`. So the DEFAULT was Brutal.
- **Token set choice** (theme.dart:21-25): `raftThemeId(family, dark)`: dark -> `elegantDark` always; else `brutal` or `elegantLight`. Generated from `docs/theme-tokens/{brutal-light,elegant-light,elegant-dark}.json` by `tool/gen-tokens`. Dark forces Elegant in 3 places: theme.dart:102 (`RaftTokens.theme`), :442 (`raftTheme`), app_root.dart:2210.
- **Persisted** as two SharedPreferences strings: `raft.mode` = ThemeMode.name (system|light|dark) and `raft.light` = RaftFamily.name (brutal|elegant). There is no stored "dark family" key. Write: lib/app_root.dart:2047-2054 `setAppearance` (setState, two `setString`, then `NativeLaunchTheme.instance.set`).
- **Read**: lib/data/device_preferences.dart:81-104 `storedAppearance()` (synchronous, per-key fallback to defaults). Called at app_root.dart:250 (initial state), :704 (after prefs are adopted, also re-sends it to native "heals the splash"), lib/root_error_boundary.dart:259-270 (error app uses the stored light family + Elegant dark).
- **Applied**: app_root.dart:2156-2211 `themed(family,{dark})` -> `raftTheme(...)`; `theme: themed(appearance.light)`, `darkTheme: themed(elegant, dark:true)`, `themeMode: appearance.mode`. Everything else reads `RaftTokens.of(context)`, an extension on ThemeData (theme.dart:208).
- **Selection UI**: ui/appearance_picker.dart (`RaftAppearancePicker`): mode segmented control Light/Dark/System (line ~101), "Light appearance" group with cards `RaftFamily.values` (Brutal, Elegant), "Dark appearance" group with Elegant only (line 37), "Current" chip. Each card renders a live mini preview built from `raftTheme(family, dark)` (line 176-180) and branches on `brutal` ~15 times (G4 covers). Hosted by lib/appearance_section.dart -> workspace_settings.dart:200-204 -> workspace_view.dart:3970; callback `onAppearance` = `setAppearance`. Test keys `appearance-{light|dark}-theme-{family}`.
- **Other readers of the family**: lib/chat_view.dart:3184 `rowExtentScope` puts `tokens.family.name` into the row-height cache key (a runtime pack must change this key or heights go stale); lib/page_alignment_previews.dart:206; ui/font_warm_up.dart:43,84,174 (font cache keyed by family); lib/platform/oauth_return_page.dart:159 builds the web return page CSS from `RaftTokens.theme(RaftFamily.elegant, dark)` (always Elegant, ignores selection); ui/feedback_workspace.dart:64 and ui/previews.dart:15-29 (previews).
- **Native launch theme** (outside lib, read via git show a57b9dab, not exported): lib/platform/launch_theme.dart:19-24 sends `{mode, light}` over channel `app.raft/launch-theme`; Android `LaunchTheme.kt:31-48,72-80` maps to 5 kinds (BRUTAL_LIGHT, ELEGANT_LIGHT, DARK, SYSTEM_BRUTAL, SYSTEM_ELEGANT) and compiled styles `RaftSplash_<kind>_<icon>` (values-v33/raft_splash_themes.xml, 20 entries) with canvas colours in res/values/raft_launch_colors.xml (#FFFFFF brutal, #F8F8F7 elegant light = `layer-canvas-muted`, #0D0D0B dark; -night qualifier for system). iOS `SceneDelegate.swift:45` reads `flutter.raft.light` and picks named colour `LaunchBackground` (Brutal) vs `LaunchBackgroundElegant`. macOS `MainFlutterWindow.swift:174-186` ignores the family (dark #141411, light white). These are static resources: a runtime pack cannot recolour the Android 13+ system splash or the iOS LaunchScreen; only an app-drawn view (iOS startup view, Android windowBackground) can take an arbitrary canvas colour. This is my reading of the code, not tested.
- **Pack implication**: replacing `raft.light` (2 values) by a pack id/blob needs changes in: storedAppearance, setAppearance, themed(), picker, rowExtentScope key, font warm-up key, oauth page, launch_theme channel payload (send canvas hex, not family name), Kotlin/Swift/macOS.

## 10. Counts (sites in my files, approximate; comments excluded)

| area | A | B | C | total |
|---|---|---|---|---|
| colours | 48 | 1 | 0 | ~49 |
| typography | 0 | 15 | 0 | ~15 |
| shape | 0 | 10 | 0 | ~10 |
| borders | 1 | 20 | 0 | ~21 |
| shadows | 5 | 1 | 0 | ~6 |
| spacing/density | 0 | 19 | 0 | ~19 |
| component/structure | 4 | 2 (+12 recipe dispatch, mixed A/B) | 12 | ~30 |
| motion/icons | 1 | 2 | 0 | ~3 |
| **total** | **~59** | **~70** | **~12** | **~153** |

By file: ui/task_surface.dart 37, ui/task.dart 31, ui/page_recipes.dart 30, lib/resource_view.dart 18, lib/source_channel_files_view.dart 11, lib/resource_search.dart 9, page_layout / search_home / server_views / account_sign_in_recipe 6 each (server_views is comments only), account_settings / desktop_directory_view / member_graph_view 5, member_profile_view 3, rest 1-2. These are raw grep hits (they include some comment lines and non-branch lines like imports); the table counts above are branch sites.

## 11. Top 8 visible Elegant-vs-Brutal differences in these files

1. Borders and radius: Elegant 8px rounded cards, 1px or 0.5px hairlines; Brutal square boxes with 2px black borders (all task lanes, cards, modal, file rows).
2. Task status chips: Elegant soft tinted pill (`*-soft` + `*-strong`, radius 999, 11px w500) vs Brutal square solid colour block (cyan/lime/orange...), black text, black outline, UPPERCASE.
3. Hard offset shadows: Brutal 4px 4px black on file rows, task modal and selected appearance card; Elegant hairline ring plus soft lift (literal in source_channel_files_view.dart:218-285).
4. Page surfaces: Elegant lists sit on `layer-canvas-muted` (#F8F8F7) with white cards; Brutal is flat white everywhere.
5. Search results typography: Elegant sans w500 12-14px, muted greys, letter-spacing -0.14; Brutal w700, mono timestamps and 10px mono 2px-tracked section titles.
6. Panel header: Elegant 36px muted icon tile + inline title/meta (page_layout.dart:119) vs Brutal recipe header with mono subtitle and thick rule.
7. Mobile bottom navigation: Elegant floating capsule vs Brutal in-flow full-width bar (workspace_view.dart:1831).
8. Densities: Elegant search viewport inset 12 (mobile 20/14) and gap 6 vs Brutal 16/8; headers 53/66 vs 54/72; filter pickers 28px vs 32px.

## 12. Honest limits

- Counts are approximate; grep totals include comment lines. resource_view.dart (5.9k lines) and workspace_view.dart (4k) have few brutal tokens but many `t.dark` branches that I did not classify (23 `recipeTheme`/`.dark` hits in lib/features).
- Indirect brutal behaviour inside raft_ui helpers used by my files (RaftSettingsText, RaftPanelEdge, RaftMobileNavRecipe, RaftSelectionPopover, RaftTaskSectionRecipe in design_primitives.dart) belongs to other groups; I only noted it.
- Generated recipe tables (ui/recipes/*.g.dart) were checked structurally (token_binding.dart), not value by value.
- Native Android/iOS/macOS files were read through `git show a57b9dab:` (read-only), not from the export.
- The Elegant look is already almost entirely data in my files: colours (A) and shape/border/spacing numbers (B) are all simple scalars. The only real code splits are the panel header tree, the mobile nav layout and the file-row shadow literal.
