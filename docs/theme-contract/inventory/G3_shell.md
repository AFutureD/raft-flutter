# G3 shell: Elegant vs Brutal inventory (OLD a57b9dab -> NEW db40e0a7)

Scope: 37 files in G3_shell.files (mobile nav/tab bar, rail/sidebar/panels/edges, server switcher, channel header/footer/sheets/members, lists and resource cards/rows, quick switcher). All read via grep + context; no file read 100% line by line (large ones: channel_members_view 1494, panel_layout 1521, list_items 1396, channel_overflow_sheet 1106 were read at every branch site, not between them).

Counts are line-level `brutal`/`RaftRecipeTheme` hits (about 445 lines, roughly 330 distinct sites). Counts per pattern are approximate (+-20%).

How I classify (my reading of the task): A = both the Elegant and the Brutal value come from a field that already exists in the NEW schema (semantic colours, product colours, themeShadows, metrics fonts). B = Elegant value is a literal in code (1px, radius 6, alpha .55, 56px) and a pack would need a NEW token to change it. C = different widget tree / painter / recipe-class swap.
Brutal is always the "special" side: pure `Colors.black`, 2px borders, radius 0, hard offset shadows, cream/soft-signal/pink/cyan fills. Elegant is always semantic tokens + 1px + soft shadows. So most rows are one switch: "black/2px/0/hard" vs "token/1px/N/soft".

"Survived": kept = Elegant branch is verbatim in NEW (Brutal branch deleted). replaced = Elegant code replaced by a 0.7.1 port. drift = Elegant side also changed in NEW (not only a Brutal deletion).

## 0. Findings that matter before the tables

1. The NEW shell is Elegant with the Brutal half cut out. In these 37 files NEW has zero `brutal` references and Elegant literals are now plain constants (`width: 1`, `BorderRadius.circular(22)`, `Offset(8, rect.bottom - (1) + 4)`). Evidence: `diff` of mobile_navigation, list_items, resource_cards, server_switcher.
2. Only one place in my files was replaced by a 0.7.1 port: the detail-panel tab strip (panel_layout.dart RaftPanelTabBar now uses `raft/tabs.dart` RaftTabs underline; about 250 lines removed incl. the Elegant `tabs-list` h-12 gap-1 px-4 container). RaftCheckbox in workspace_mode_card.dart is the ported one (call site unchanged). Everything else is kept.
3. Drift that is NOT a Brutal branch but changes the old Elegant look (decision 0002, Title Case): old code uppercased eyebrows/badges and used tracking in BOTH themes (51 `uppercase/toUpperCase` hits, 17 `letterSpacing/trackingEm` hits in these files). NEW: 51 -> 4 hits, 17 -> 6. Examples: RaftSectionEyebrow (list_items.dart:435-473, uppercase + 1.2 tracking), archived badge (channel_header.dart:312-320), quick_switcher_results (12 hits -> 0), sidebar_menus.dart:213. Labels also became Title Case ('Search This Channel', 'Channel Settings'; channel_header.dart:186). A pack that wants old Elegant needs `text-transform` + `letter-spacing` tokens, and the strings differ (this is copy, not theme).
4. Possible Brutal leftover surviving in NEW (uncertain, not Brutal-gated in old either): `_SelectorPainter` (mobile_navigation.dart:610-637 old / ~540 new) paints a rotated black polygon with a hard 2px shadow behind the mobile server label in both themes, label colour `primary-strong` in Elegant. Only `compact` (viewport <= 600) gates it. I did not check Web to see if Elegant hides it. Treat as a C item that is "Brutal-looking Elegant".
5. Brutal-only structure that needs no Elegant equivalent (so nothing to port): in-flow tab bar with labels, rail border/padding, 2px tab dividers, 4px-narrower emoji picker.
6. Many theme differences in these files are NOT in the files themselves but in `design_primitives.dart` (RaftPanelHeaderRecipe, rail recipe: headerHeight 62/56, railWidth 64/56, glyph 18/16, rail bg primary-400 vs sidebar, header inset 20/16 vs 26..28, title 18/w700 vs 17/w500, iconRadius 0/6, `headerOverlaysContent`) and in generated recipes (`RaftRecipeTheme` is passed to Card/Badge/Kbd/Popover/PanelAction/AppRail/Search recipes: 35 sites). They belong to other groups; I note them where my files read them.

## 1. Colours

| What | Elegant | Brutal | Sites | Samples (OLD) | Class | Token/param | Survived | Note |
|---|---|---|---|---|---|---|---|---|
| Primary text ink (titles, row labels, header titles) | `strong` = foreground-strong | `Colors.black` | ~40 | channel_footer.dart:119; mobile_navigation.dart:692; sidebar_frame.dart:274 | A | RaftSemanticColors.foregroundStrong | kept | pure data swap |
| Secondary/muted text, hints, counts, subtitles | foreground-muted / -placeholder / -icon (opaque) | black at alpha .4 .45 .5 .55 .6 .7 | ~45 | panel_layout.dart:41 (raftPanelInk); list_items.dart:327; add_members_dialog_view.dart:276 | A | foregroundMuted, foregroundPlaceholder, foregroundIcon | kept | Brutal alpha ladder has no Elegant equivalent, tier choice is by role |
| Borders and dividers (panel edges, header/footer rules, card edges) | line-muted (also `line`) | `Colors.black` | ~45 | panel_edge.dart:68; channel_footer.dart:24; workspace_shell.dart:219 | A | RaftSemanticColors.lineMuted | kept | |
| Strong/field borders (checkbox, picker, selected row) | line-strong | black | ~10 | channel_members_view.dart:603; activity_scope.dart:591 | A | lineStrong | kept | |
| Soft hairlines inside sheets | line-muted | black @ .1 (also .15 .2 .25 .3) | ~12 | channel_settings_sheet.dart:133; channel_overflow_sheet.dart:286; add_members_dialog_view.dart:90 | A | lineMuted / lineHairline | kept | |
| Sidebar / drawer / header surfaces | layer-canvas-muted, layer-panel, layer-inset, primary-soft | brutal-cream, soft-signal (yellow), white | ~45 | adaptive_workspace.dart:381; channel_settings_sheet.dart:127; channel_header.dart:98 | A | layerCanvasMuted, layerPanel, layerInset, primarySoft | kept | Brutal uses product colours (RaftProductColors.brutalCream, softSignal) |
| Card/list surfaces | layer-card / layer-panel | white | ~16 | conversation_surface.dart:20; quick_switcher_results.dart:73; list_page_parts.dart:186 | A | layerCard, layerPanel | kept | |
| Rail background and selected rail tile | sidebar tone; selected from recipe | primary-400 blue rail, selected fill/ink | via design_primitives (not my file) + adaptive_workspace.dart:739 | adaptive_workspace.dart:739 | A | RaftSemanticColors.primary400 etc | kept | |
| Chips/badges tone (guest tag, member type, archived, error banner) | info-soft, accent-soft, warning@.3, danger-soft, primary-soft | brutal-cyan, lavender, orange@.2/.3, red@.2, soft-signal, stone | ~27 | sidebar_frame.dart:254; channel_members_view.dart:752; channel_header.dart:305 | A | infoSoft, accentSoft, warning, dangerSoft | kept | |
| Hover/active menu row | primary-soft bg + primary-strong ink | primary-400 bg + primary-950 ink (invite hover: brutalPink) | ~6 | server_switcher.dart:535-542, 806-818 | A | primarySoft, primaryStrong | kept | |
| Mobile nav item: selected / pressed / focus | selected: panel (light) or fill-muted (dark); pressed fill-strong; ring line-strong; text foreground-placeholder -> strong | primary-400 selected; pressed ink-6; black ring; black@.55 text | ~12 | mobile_navigation.dart:105-134 | A | panel, fillMuted, fillStrong, lineStrong, foregroundPlaceholder | kept | light/dark split already comes from the token set |
| Attention dot | accent fill, no border | brutal-pink + 1px black border | 2 | mobile_navigation.dart:652-655 | A + B | accent; border-width-badge (B) | kept | |
| Selected row tint and edge | `info` tint alpha .05 (dark .06), 3px info bar | brutal-cyan tint alpha .08, 4px black bar | 4 | resource_cards.dart:60-70 | A (colour) / B (alpha .05/.06, width 3) | selected-tint-alpha, selected-edge-width | kept | |
| Focus ring colour on cards/inputs | ink @ .8 (card), line-strong (nav) | black | ~5 | list_items.dart:266; sidebar_section.dart:240 | A | ink / lineStrong | kept | |
| Splash/canvas | canvas (dark safe) | brutal-cream | 1 | server_switcher.dart:469 | A | layerCanvas | kept | |
| Task timeline rail and markers | rail line-muted; hollow ring in tone colour | rail line-strong; filled marker, black-ish ring | 4 | task_timeline.dart:52,102,129 | A (colours) + C (hollow vs filled) | timeline-marker-filled (bool) | kept | |

## 2. Typography

| What | Elegant | Brutal | Sites | Samples | Class | Token/param | Survived | Note |
|---|---|---|---|---|---|---|---|---|
| Card body/metadata font family | heading font (Inter), saved items body font | body font | 3 | resource_cards.dart:96,107 | A | RaftThemeMetrics.headingFont / sansFont | kept | role mapping is in code; B if a pack wants a per-role family: `font-family-card` |
| Member-section title weight and tracking | w500, letter-spacing 0 | w700, letter-spacing 1.2 (0.1em) | 1 cluster (3 props) | channel_members_view.dart:1128-1132 | B | font-weight-eyebrow, letterspacing-eyebrow | kept | |
| Member-section count face | body font w500 same ink | mono w500 black@.7 | 1 | channel_members_view.dart:1133-1146 | B | font-family-count | kept | |
| Timeline entry title | body font w500 | heading font default weight | 1 | task_timeline.dart:71 | B | font-weight-label | kept | |
| Archived badge / eyebrows: caps and tracking | caps + 0.025em tracking (old, both themes) | same | ~51 caps sites, 17 tracking sites | list_items.dart:468; channel_header.dart:314 | C (text-transform) | text-transform-eyebrow (enum none/upper), letterspacing-eyebrow | drift (dropped in NEW) | shared by both themes in OLD; not a Brutal branch |
| Mobile nav label text | no label (icon only, tooltip) | 10px/15 label under glyph, tracking .5 | 1 widget | mobile_navigation.dart:315,327-337 | C | nav-show-labels (bool) | deleted (Brutal only) | also hidden at viewport <= 600 |
| Selector label colour | primary-strong | brutal-yellow | 1 | mobile_navigation.dart:454 | A | primaryStrong | kept | |
| Font size/weight of header title | 17 / w500 (design_primitives) | 18 / w700 | via design_primitives | design_primitives.dart:233-235 | B | font-size-panel-title, font-weight-title | kept | not in my files |

No `opsz` / FontVariation sites in these files.

## 3. Shape (radius)

| What | Elegant | Brutal | Sites | Samples | Class | Token/param | Survived | Note |
|---|---|---|---|---|---|---|---|---|
| Chips, tags, badges, danger buttons | 2 or 4 | 0 | ~8 | channel_header.dart:307; sidebar_frame.dart:265; add_members_dialog_view.dart:433 | B | radius-xs (2), radius-sm (4) | kept | |
| Cards, banners, rows, computer cards, skeletons | 6 (4 for skeleton) | 0 | ~14 | mobile_computer_list.dart:81,144,200; resource_cards.dart:83; list_page_parts.dart:187 | B | radius-md (6) | kept | |
| Saved-item card | 8 | 0 | 1 | resource_cards.dart:83 | B | radius-lg (8) | kept | |
| Overflow drawer (desktop) | 12 (phone page 0) | 0 | 1 | channel_overflow_sheet.dart:248 | B | radius-sheet (12) | kept | |
| Mobile nav item / capsule | item 22, capsule 1000 (pill) | 0 / none | 2 | mobile_navigation.dart:142,396 | B | radius-nav-item, radius-pill | kept | |
| Badge capsule in resource rows | 9999 | recipe radius | 1 | resource_rows.dart:267 | B (or via Badge recipe) | radius-pill | kept (recipe path, not the new Badge port) | |

Brutal is always 0, so a pack could use one `radius-scale` multiplier plus the six named radii above.

## 4. Borders

| What | Elegant | Brutal | Sites | Samples | Class | Token/param | Survived | Note |
|---|---|---|---|---|---|---|---|---|
| Panel/header/footer/sidebar edge width | 1 | 2 | ~35 | panel_edge.dart:69; adaptive_workspace.dart:385; workspace_shell.dart:47,220 | B | border-width-panel (RaftTokens.border is a fixed 1 today) | kept | most frequent B |
| Card / chip / checkbox border width | 1 (saved item .5) | 2 (tag 1.5 device-pixel floor) | ~15 | channel_members_view.dart:604; sidebar_frame.dart:258; resource_cards.dart:80 | B | border-width-control, border-width-card | kept | |
| Dashed border (add-computer, add tile) | 1px dashed line-muted/strong | 2px dashed black@.4/1 | 2 | mobile_computer_list.dart:140-148; channel_overflow_sheet.dart:813 | B (colour A) | border-width-dashed | kept | |
| Which edges draw: rail divider, drawer border-l, tab dividers | rail on right gets 1px divider when sidebar hidden; drawer none | rail draws own divider + padding; drawer border-l-2; 2px divider between tabs | ~8 | adaptive_workspace.dart:281,658-670; panel_edge.dart:72-76; panel_layout.dart:846 | C (param: edge set) | panel-edge-style (enum) | kept (tabs: replaced) | |
| Inner-border compensation | padding +1 | padding +2 (`12.0 + (brutal?2:1)`) | ~6 | add_members_dialog_view.dart:84,168; mobile_computer_list.dart:153; server_switcher.dart:188-191 | B | derive from border-width-* | kept | disappears once width is a token |
| Mobile bar edges | none (capsule) | top+bottom 2px black, 2px right divider per item | 3 | mobile_navigation.dart:390-395,371 | C | see nav row in section 8 | deleted (Brutal) | |

## 5. Shadows and elevation

| What | Elegant | Brutal | Sites | Samples | Class | Token/param | Survived | Note |
|---|---|---|---|---|---|---|---|---|
| Card/popover/picker shadow | RaftThemeShadows.sm / md outer layers | hard black offset (brutalSm / shadowBrutal) | ~10 | channel_members_view.dart:370; mobile_computer_list.dart:201; channel_overflow_sheet.dart:1058 | A | RaftThemeShadows.sm / md | kept | `shadow-brutal` is a product shadow (RaftProductShadows) in OLD |
| Hover/pressed card shadow | hover adds `t.shadows` (xs/sm) + line-strong; pressed fills canvas-muted | pressed drops shadow, fills cream | ~6 | list_items.dart:246-266 | A (shadow) + C (state logic) | RaftThemeShadows.sm | kept | |
| Selected rail tile | none | 2x2 solid black offset | 1 | adaptive_workspace.dart:759 | B | shadow-rail-selected | kept (Elegant: none) | |
| Mobile capsule root shadow | 3 layers light, 3 layers dark (hand-tuned alpha/blur/spread) | none | 1 (6 layers total) | mobile_navigation.dart:60-97 | B | shadow-nav-capsule (light+dark RaftShadow) | kept | not an xs..xl tier |
| Selected nav item shadow stack | light 6 layers; dark 4 layers | none | 1 | mobile_navigation.dart:176-229 | B | shadow-nav-item-selected | kept | |
| Sheen overlay on selected nav item | light: vertical gradient white .12 -> black .06; dark: inset highlight alpha .06 | none | 2 | mobile_navigation.dart:149-158 | B (RaftControlRecipe already has overlayGradient and insetHighlightAlpha hooks) | nav-item-sheen, nav-item-inset-highlight-alpha | kept | |
| Notification trigger shadow | themeShadows.sm layers (all modes) | same | 1 | mobile_navigation.dart:828 | A | RaftThemeShadows.sm | kept | not brutal-gated |
| Card root shadow in recipes | RaftCardRecipe elegant (shadow-raft-xs) | recipe brutal (shadow-md hard) | 2 | resource_cards.dart:263 | A (recipe) | RaftThemeShadows.xs | kept | NEW hard-codes `RaftRecipeTheme.elegant` |
| Rail attention glow | radial ShaderMask tint + status primary variant | status accent variant, no mask | 2 | rail_attention.dart:30,53 | C | rail-attention-style (enum glow/solid) | kept | |

## 6. Spacing and density

| What | Elegant | Brutal | Sites | Samples | Class | Token/param | Survived | Note |
|---|---|---|---|---|---|---|---|---|
| Mobile nav item height / bottom space | 44, `max(8,inset)` | 51 (31 on short screens), `min(inset,34)` | 3 | mobile_navigation.dart:52-58 | B | nav-item-height, nav-bottom-inset-rule | kept | |
| Members section header geometry | top 16, bottom 0, height 32, h-pad 0 | top 12, bottom 4, height 24, h-pad 8 | 1 cluster (5 props) | channel_members_view.dart:1152-1160 | B | space-section-top, space-section-height | kept | |
| Panel overflow drawer width | 448 | 544 | 1 | channel_overflow_sheet.dart:64 | B | drawer-width | kept | |
| Shell header / rail width | 56 / 56 | 62 / 64 (50 on short) | via design_primitives | design_primitives.dart:97-107 | B | shell-header-height, rail-width | kept | |
| Menu offsets compensate border | -1 / 0 | -2 / +2 | 3 | server_switcher.dart:188-191 | B | derive from border-width-panel | kept | |
| Bottom preview dock heading gap | 4 | 12 | 1 | mobile_tabbar_config.dart:371 | B | space-preview-gap | kept | |
| Search field line box | 16+8+2 | 16+8+4 | 1 | list_items.dart:1010 | B | derive from border-width | kept | |
| Emoji picker width | full | width - 4 | 1 | sidebar_section_dialog.dart:112 | B | derive from border-width | kept | |
| Attention/badge dot offsets | top -8/-4, right -4 | top -3/4, right 8 | 3 | mobile_navigation.dart:293,346-347 | B | nav-badge-offset | kept | |
| Sidebar section chevron opacity | .55 | 1 | 1 | channel_members_view.dart:1178 | B | icon-opacity-chevron | kept | |

## 7. Icons

| What | Elegant | Brutal | Sites | Samples | Class | Token/param | Survived | Note |
|---|---|---|---|---|---|---|---|---|
| Tab icon stroke width | 2 | 2.5 (from recipe) | 1 | panel_layout.dart:833 | B (recipe-driven) | icon-stroke-tab | replaced (Tabs port) | |
| Glyph size/stroke elsewhere | same in both (checkbox check size 10 / stroke 4, nav glyph 18) | same | 0 branches | channel_members_view.dart:611 | n/a | | kept | no icon branches except colours (A) and the rail glyph 16/18 (design_primitives) |

## 8. Component-level (different tree / painter / layout)

| What | Elegant | Brutal | Sites | Samples | Class | Token/param | Survived | Note |
|---|---|---|---|---|---|---|---|---|
| Mobile tab bar | Floating capsule: Stack of 44x44 icon items at fixed offsets, radius 1000, 3-layer shadow, tooltips, overlays content (`mobileNavigationFloating` bool already exists, workspace_view.dart:1831) | In-flow full-width Row, Expanded items with glyph + label, 2px dividers, top/bottom 2px black borders, reserves height | ~30 lines | mobile_navigation.dart:287-445; adaptive_workspace.dart:870-1000 | C, could be a param (enum `nav-style: floating/docked`, bool `nav-labels`) but both trees stay in code | nav-style, nav-labels | kept (Elegant); Brutal tree deleted | biggest single visual difference |
| Desktop rail | no own border, sidebar tone | own border + side padding, 2x2 selected shadow, bordered tile | ~6 | adaptive_workspace.dart:658-670,754-765 | C/B | panel-edge-style, shadow-rail-selected | kept | |
| SurfaceListItem card | Recipe re-resolved with swapped utility classes (border, bg-info-muted, shadow-raft-sm, hover border-line-strong) | `brutalDecoration` override: white, 2px black, cyan tint, hard shadow | 4 | list_items.dart:99-163 | C (class-list manipulation of the recipe engine) | would need recipe-class overrides as data | kept | |
| Option card pressed/hover | line-strong border + shadow on hover; canvas-muted pressed | brutal drops shadow when pressed, cream fill | 3 | list_items.dart:225-277 | C | | kept | |
| Server menu panel | explicit panel fill + 1px line-muted replacing popover recipe | uses popover recipe as is | 1 | server_switcher.dart:374-395 | B (CSS literals) | popover-border, popover-fill | kept | |
| Prompt card (`card-brutal`) | plain Container panel, 1px line-muted, md shadow, square | `RaftRecipeCard` brutal recipe | 1 | channel_overflow_sheet.dart:1018-1050 | C | | kept | |
| Panel tab strip | `tabs-list` h-12 px-4 hairline floor, h-7 tabs | plain Row, 2px dividers inside tabs | 5 | panel_layout.dart:673-700,846 | C | | replaced (RaftTabs port) | |
| Timeline marker | hollow ring, tone colour | filled disc on line-strong | 1 | task_timeline.dart:129 | C -> bool param | timeline-marker-filled | kept | |
| Custom checkbox in members view | white/panel fill, 1px line-strong, strong check | black fill, 2px black | 1 | channel_members_view.dart:595-615 | A + B (width) | | kept (not the ported RaftCheckbox) | |
| Rail attention | radial gradient mask | solid accent status | 1 | rail_attention.dart:53 | C | | kept | |
| Mobile server selector | rotated black polygon + hard shadow (ungated), primary-strong label | brutal-yellow label | 1 | mobile_navigation.dart:610 | C | | kept (uncertain, see 0.4) | |
| Badge in resource rows, saved toggle, kbd, entity icon, popover | recipe with `RaftRecipeTheme.elegant` | `.brutal` | 8 | resource_rows.dart:113,235; quick_switcher.dart:58; resource_cards.dart:263 | A if the recipe engine reads a runtime token set | recipe-theme token set | kept (NEW passes `.elegant`/`t.recipeTheme`) | generated recipes would need the pack too |

## 9. Motion

No brutal-gated motion in these files. Only state logic: Brutal drops hover shadow on press (list_items.dart:254-260); mobile nav `transformsOnInteraction=false` in both. Chevron rotate 150 ms is shared. Class n/a.

## 10. Counts (approximate)

| Area | Files | Line hits | A | B | C |
|---|---|---|---|---|---|
| Mobile nav, tab bar config, page header, computer list | 4 | 69 | 28 | 16 | 25 |
| Shell: adaptive workspace, panel layout/edge, sidebar*, rail, workspace shell/card, editor groups, surface | 13 | 82 | 50 | 24 | 8 |
| Server switcher | 1 | 17 | 11 | 4 | 2 |
| Channel header/footer/sheets/members/create/add/archived/joint | 9 | 154 | 105 | 41 | 8 |
| Lists and resource cards/rows, activity, timeline, profile card | 7 | 106 | 68 | 25 | 13 |
| Quick switcher + results | 2 | 17 | 11 | 5 | 1 |
| Total | 37 | ~445 | ~273 (61%) | ~115 (26%) | ~57 (13%) |

Per pattern class: roughly 60% of sites are the "black vs semantic token" colour switch (A); another quarter are literals (border width 2 vs 1, radius 0 vs N, fixed sizes) that need only a handful of new numeric tokens (B): `border-width-panel/control/card`, `radius-xs/sm/md/lg/sheet/pill`, `shadow-nav-capsule`, `shadow-nav-item-selected`, nav sheen, `drawer-width`, `shell-header-height`, `rail-width`, `font-weight-eyebrow`, `letterspacing-eyebrow`. About 13% needs code: the tab bar, rail edges/attention, list-item recipe overrides, timeline marker, prompt card.

## 11. Top 8 visible Elegant-vs-Brutal differences in these files

1. Mobile tab bar: floating pill capsule with 44px icon-only items and layered shadow vs full-width docked bar with labels and black dividers (C).
2. Edge weight: 1px soft line-muted vs 2px black on every panel, header, footer, sidebar, card and chip (B, ~50 sites).
3. Corners: 2/4/6/8/12/22/pill radii vs square everywhere (B, ~25 sites).
4. Elevation: soft layered shadows (themeShadows sm/md) vs hard offset black block shadows on cards, members popover, computer cards, selected rail tile (A/B).
5. Palette of surfaces: neutral layer-panel / canvas-muted / primary-soft vs cream sidebar and drawers, yellow soft-signal headers, white cards (A, ~60 sites).
6. Text colour: foreground-strong / muted tiers vs pure black with alpha ladder (A, ~85 sites).
7. Selected list row: info border + soft shadow + 3px info bar vs 2px black border, cyan tint, hard shadow, 4px black bar (C + B).
8. Rail and section headers: 56px neutral rail and 17px/w500 titles, sentence-case section toggles (w500, no tracking, 32px) vs 64px primary-400 rail, 18px/w700 titles, tracked bold 24px section toggles (B).

Not in the top list but relevant to "reproduce old Elegant": the caps + tracking eyebrows and the mobile selector polygon are in OLD Elegant too and are gone or ungated in NEW (section 0, items 3 and 4).
