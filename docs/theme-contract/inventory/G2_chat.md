# G2 chat: Elegant vs Brutal inventory (OLD a57b9dab, judged against NEW db40e0a7)

Scope: 40 files in G2_chat.files (all under packages/raft_ui/lib/src). I read every brutal site with 1-5 lines of
context, and read in full the recipe files (composer_recipe, message_row_recipe, message_content_tokens,
rich_card_tokens, attachment_tokens) plus the quoted card, tab strip and media chrome. I did NOT read the large
bodies of message_body (2381 lines), media_browser, inline_media or video_controls beyond the branch sites.
Counts are lines that branch on brutal / RaftRecipeTheme, outside comments: about 523. Per-pattern counts are
approximate (+-25%). All file:line refs are OLD (a57b9dab) under packages/raft_ui/lib/src/.

Class key: A = existing new token. B = plain data, needs a new token/param. C = structural code.
NEW status: kept = the Elegant branch is unchanged in NEW (no brutal getter left, so Elegant values are now literals).

How to read the "A" rows: the Elegant side already reads semantic tokens (muted, strong, panel, line-muted ...).
The Brutal side used literal black/white/alpha. So for Elegant, colour is almost fully data. The hard part is geometry
(radius, border width, paddings) that is now a literal in the Elegant branch, not a token.

## 1. Colours

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Text and icon ink tiers | foreground-strong / -muted / -placeholder / -icon / -hint | black, black@.4-.8 | ~150 | message_content_tokens:28-40; agent_chat_view:183,239; thread_followers:237 | A | RaftSemanticColors.foreground* | kept | Largest group. Brutal's 6 alpha steps collapse onto 3-4 Elegant tiers. Fixed role to tier mapping, a pack gets it free. |
| Surface fills | layer-panel, layer-card, layer-popover, layer-canvas-muted, layer-inset, fill-muted | white, brutal-cream, black@.03 | ~60 | agent_chat_view:94,209; attachment_preview_shell:105; inline_thread_surface:48 | A | RaftSemanticColors.layer* / fill* | kept | Elegant choice of card vs panel vs canvas-muted is per-widget literal, matches Web. |
| Line colours | line-muted, line-hairline (forward header/note bars), line-strong | black, black@.15-.4 | ~70 | composer_recipe:43; forward_composer:98; runtime_usage_card:115 | A | RaftSemanticColors.line* | kept | One place falls back `colors['line'] ?? t.line` (message_body:1368). |
| Row hover / selected fill | ink-2 (message row), fill-muted, fill-strong@.8, primary-soft | panel, brutal-cyan@.15, soft-signal, white | ~15 | message_row_recipe:112; forward_composer:596-603; composer_tool_button:28-36 | A | RaftSemanticColors.ink-2 etc. | kept | highlighted row: info@.1 vs brutal-cyan@.25 (message_row_recipe:108). |
| Brutal-only accent palette vs semantic role | accent-strong, info, warning, warning-soft, success, primary-soft | brutalPink/Cyan/Orange/Lavender/Stone/Yellow, softSignal | ~17 | quoted_message_card:257,311; runtime_usage_card:278; attachment_transfer:107 | A | RaftSemanticColors accent/info/warning/success | kept | A pack that wants a loud palette supplies it through the same semantic names. Nothing new needed. |
| Dark-mode switches inside the Elegant branch | transparent border in dark, black@.35 content border, ink-4 divider, foreground-inverse on success | (Brutal has no dark) | ~14 | rich_card_tokens:59,106,129; message_row_recipe:176; chat_composition:879 | A/B | A where a token exists (ink-4, foreground-inverse); B for "no border in dark" = line-embed, line-embed-dark | kept | Dark is `tokens.dark ? X : Y` with literals (Colors.transparent, black@.35). A pack cannot say "no card border in dark" today. |
| Elegant literal colours not in the schema | black@.62 chip, black@.35/.18 progress track, white@.95, 0xB8000000 scrim, black gradient .8->0 / 0->.78, Color(0x120a0a09) shadow | white box, white track, black | ~12 | attachment_transfer:113,395; media_browser:1278; message_row_recipe:189; mermaid_fullscreen:112 | B | color-scrim, color-media-chrome, color-media-chrome-pressed, color-progress-track | kept | Media chrome is intentionally dark in both light and dark. The 0x120a0a09 one is documented as --theme-shadow-xs, so it is probably A (RaftThemeShadows.xs). |
| Focus ring colour on small actions | primary-500 spread .5 | transparent (hard shadow instead) | 3 | message_row_recipe:1128,1137; composer_recipe:195 | A | RaftSemanticColors.primary-500 | kept | |
| Reaction picker hover | accentSoft | brutal-pink@.2 | 1 | quick_reaction_picker:29 | A | accent-soft | kept | |

## 2. Typography

No branch controls case (uppercase appears in both themes), opsz, or font features per theme. Tabular figures are used
by both (quoted_message_card:145; Elegant only for the stamp). So typography = size, weight, spacing, family role.

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Letter-spacing on message body, author, time, headings | -.14px (= -0.01em of 14px; `-fontSize*.01`) | 0 | ~7 | message_row_recipe:123,135; message_content_tokens:86,127 | B | letterspacing-body (em) | kept | Elegant tracking is a single em ratio, easy as data. |
| Letter-spacing on labels | suggestion title -.065, group -.055, rich badge .22, section divider 1.1 | 0, 1.2 (group), .5 (badge), 1 | ~9 | composer_recipe:135,162; rich_card_tokens:162; chat_composition:872 | B | letterspacing-label, letterspacing-caption | kept | |
| Weight of emphasis | w500 (author, rich header, show-more, suggestion), w600 (file badge), w400 (date header) | w700 / `RaftTypography.black` | ~13 | message_row_recipe:128; rich_card_tokens:118,141; attachment_tokens:109; chat_composition:456 | B | font-weight-title, font-weight-label, font-weight-badge | kept | Highest fidelity win: Elegant is visibly lighter. Needs 2-3 weight tokens (RaftThemeMetrics has only field/cardTitle weights). |
| Small text size and line height | suggestion 13/19.5, group 11/11, tab 13/19.5, date header 11/16.5, quoted meta 11/16, stamp lh 2.1 (21px), summary lh 21/12.5, system clock 11/16.5, badge 11/12 | 14/20, 12/16, 12/16, 10/15, 10/12, lh 1.43, 20/14, 12/16, 10/10 | ~20 | composer_recipe:129,154; chat_composition:454,866; quoted_message_card:166,184; rich_card_tokens:158 | B | text-size-caption/label + line-height-* (or a type-scale table in RaftThemeMetrics) | kept | Elegant line heights mostly inherit `leading-5.25` (21px); these are literals. |
| Header line box | author lh 1 (14px), headerLine 21, header uses baseline alignment | lh 20/14, headerLine 20, top alignment (visualHeight 20 vs 14) | 6 | message_row_recipe:88,127,134,676,649 | B + C | line-height-author; `baseline-header` bool | kept | The baseline flag changes the header layout widget; could stay a bool param. |
| Family role for timestamps and metadata | sans (bodyFont) for time, quoted stamp, system clock (w500 11px), rich-card metadata; mono for date header, thread clock | mono for the first group, bodyFont for date header | ~8 | message_row_recipe:132; system_message:22; inline_thread_surface:68; chat_composition:870 | A (stacks) + B (role map) | font-role-timestamp = sans/mono | kept | Stacks exist (RaftThemeMetrics.sansFont/monoFont). Only the role-to-family choice is hard-coded. |
| Message body face | headingFont for the mounted message body/author; bodyFont for markdown, headingFont for documents | same | 0 | message_row_recipe:119; message_content_tokens:84 | A | RaftThemeMetrics.headingFont | kept | Not a theme difference, listed to show no branch. |

## 3. Shape (radius)

Elegant radii are the NEW fixed getters (radius=8, fieldRadius=6) plus literals 4, 5.5, 999.

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Card / panel radius | 8 | 0 | ~14 | composer_recipe:53,115; quoted_message_card:387; forward_desktop_dialog:101; preview_unavailable:55 | B | radius-card (today fixed `radius`) | kept | |
| Control / field radius | 6 | 0 | ~16 | composer_tool_button:50; message_row_recipe:1107; thread_composition:516; forward_composer:629; composer_pending_mentions:175 | B | radius-control (today `fieldRadius`) | kept | |
| Small chip radius | 4 (file badge, comment card, attachment tag, video time tip), 5.5 (rich content) | 0 | ~7 | attachment_tokens:110; quoted_message_card:320; video_controls:968; rich_card_tokens:103 | B | radius-chip, radius-embed-inner | kept | |
| Pill / circle | 999 (rich badge, transfer chip), circle (video play badge, media chrome button, mermaid close) | 0 / square | ~7 | rich_card_tokens:168; attachment_transfer:399; video_controls:367; media_browser:814 | B | radius-full (= 999) | kept | `BoxShape.circle` vs rectangle becomes radius 999 on a square box. |

## 4. Borders

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Card / control border width | 1 | 2 (some 1.5) | ~35 | composer_pending_mentions:379; inline_media:609; runtime_usage_card:265; quoted_message_card:318 | B | border-width-card (today fixed `border`=1) | kept | |
| Rules and dividers (header bottoms, section rules, panel tops) | 1 (hairline tone) | 2 black | ~30 | agent_chat_view:116; attachment_lightbox:136; attachment_preview_shell:153; composer_expand:302; thread_composition:75 | B | border-width-rule | kept | Several places already take `borderWidth` as a parameter (lightbox header). |
| Hairline | 0.5 device-pixel snapped (raftCssBorderWidth(.5)) | 1 or 2 | ~4 | rich_card_tokens:62; message_row_recipe:181 | B | border-width-hairline | kept | Needs the existing devicePixelRatio snap code to stay (code, but already generic). |
| Border absent (Elegant) vs boxed (Brutal) | no border: ring made by shadow, file-badge, transfer chip, composer shell, inline-thread (outside dark) | 2px black | ~10 | composer_recipe:59; attachment_tokens:111; inline_thread_surface:39 | B | border-width-* = 0 plus shadow-ring (section 5) | kept | Elegant draws a 1px outer ring with a spread BoxShadow so content bounds do not move. |
| Dashed vs solid | no theme difference found (dashed drop frame in both) | | 0 | composer_drop_overlay:48 | - | - | kept | Only colour differs (accent vs brutal-pink). |
| Left rule on blockquote / comment quote | 2px, line-muted | 2px, black@.2-.4 | 2 | message_content_tokens:226 area; attachment_comments:376 | A | line-muted | kept | |

## 5. Shadows and elevation

No dark inset layers or sheen overlays in these files (composer actions set `overlayGradient: null` and
`insetHighlightAlpha: 0` in both themes). Those live in the generic RaftControl, not in G2.

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Card shadow | none, or themeShadows.xs/sm (soft) | RaftShadowSet.brutalSm, `tokens.shadows` / focusShadows (hard offset) | ~20 | composer_pending_mentions:103; inline_media:893; document_preview:344; preview_unavailable:56 | A where code reads themeShadows.xs/sm; B where it reads `tokens.shadows` (fixed = sm.outer) | shadow-card (replace getter `shadows`), shadow-card-focus | kept | The RaftThemeShadows xs..xl schema already holds the Elegant values. |
| Ring as spread shadow | light: themeShadows + ink-6 spread 1; dark: no shadow, focused accent-400@.7 spread .5 | black 2px border + hard shadow, focusShadows when focused | 3 | composer_recipe:60-69,116-122; composer_attachments (card ring-1 ink10) | B | shadow-ring, ring-color, ring-color-focus-dark | kept | |
| Message toolbar shadow | light: Color(0x120a0a09) 0.5 offset (hairline); dark: tokens.shadows | tokens.shadows | 1 | message_row_recipe:184-190 | A (probably xs) | RaftThemeShadows.xs | kept | Literal duplicates a schema value. |
| Hover/press shadow motion on small buttons | none | offset 2,2 -> 4,4 hover -> 1,1 press, black | 4 | composer_recipe:241-250; composer_tool_button:64; thread_composition:553 | C -> param | `press-shadow` on the control recipe | kept | Also see Motion. |
| Highlight / popup-open message shadow | none | shadowBrutal / shadowBrutalSm | 1 | message_row_recipe:157 | A | shadow-card (token) | kept | |
| Failure/danger chip shadow | none | xs outer | 2 | attachment_transfer:400; attachment_tokens:117 | A | RaftThemeShadows.xs | kept | |

## 6. Spacing and density

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Message row box | flat row, margin 0, padding (28/16 h, 14/8 top, 12/6 bottom, continuation 6/6), gutter 36/32, gap 12/8 | margin 12/6/12/4, padding 6x4, gutter 36, gap 12 | ~14 | message_row_recipe:62-89 | B | message-row-padding, message-row-margin, message-row-gutter, message-row-gap | kept | Elegant numbers switch on viewport (mobile <768), so a pack needs a record per breakpoint. |
| Header and body gaps | headerGap 6, bodyGap 6/4, translation lift 1 | 8, 0, 2.6 | 5 | message_row_recipe:87-97 | B | message-header-gap, message-body-gap | kept | |
| Hover toolbar | top 4, right 29, button 28, gap 2, padding 4x2 | top -14, right 8, button 24, gap 0, padding 0 | ~8 | message_row_recipe:100-106,1081 | B (numbers) + C (floating vs inset placement) | message-toolbar-offset, message-toolbar-button | kept | |
| Composer host and shell | shell inset 0, editor inset (12,12,12,0), toolbar inset (10,4,10,10) + paint offset 4, toolbar gap 8, action gap 6, action 28 | shell inset 8, editor 0, toolbar 0, gap 12/8, action 26 | ~12 | composer_recipe:51,81,95-103 | B | composer-* insets | kept | |
| Suggestion popup | max 204, bottom gap 4, inset 4, group inset 12x8 | 192, 8, 2, 12x6 | ~6 | composer_recipe:108-125 | B | suggestion-* | kept | |
| Composer icon button padding / size | pad 7, 28 | pad 4, 26 | 5 | composer_tool_button:53; composer_recipe:103,229,291 | B | control-icon-padding | kept | |
| Conversation tab strip | tab 40 mobile / 28, list 40 / 48, gap 4, inset 16/12, bottom border 0 or 1, indicator 1-2px | 28/28, gap 0, inset 22/16, bottom 2 | ~12 | chat_composition:364-408,808 | B | tab-height, tab-inset | replaced (now RaftTabButton, tabs.dart) | Old numbers deleted with the strip. |
| Rich card header/footer, badge | header h 14/12 (width>=640), footer 14/12; badge height/inset/gap Elegant constants; embed inset 2 | header 10, footer 12; badge Brutal constants; inset 0 | ~12 | rich_card_tokens:66-82,170-178 | B | embed-inset, embed-header-inset, badge-* | kept | |
| Quoted card paddings | outer 10-12 x 8-10, header 14x6, content 14x14, chip 8x4 | header 10-12 x 8-10 with divider, content 10-12, chip 6x2 | ~8 | quoted_message_card:306,332,348,389 | B | quoted-* insets | kept | |
| Thread header/summary | header inset start 20/36, gap 8, action gap 2 (mobile), summary gap 6 | 20, 12, 6, 0 | ~8 | thread_composition:52-59; inline_thread_surface:37 | B | thread-header-inset ... | kept | |
| Progress bar height | edge 4, inline 6 | edge 10, inline 12 | 2 | attachment_transfer:101,104 | B | progress-height | kept | |
| Media chrome | bottom pad 12, bar height = topBar | pad 6, +2 for rule | 3 | media_browser:1203,1339 | B | | kept | |
| Pending-mention action button | 16 square | 24 square | 1 | composer_pending_mentions:436 | B | | kept | |

## 7. Component-level differences (widget tree / painter / layout)

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Message row hover look | transparent row, ink-2 tint on hover, no border, toolbar floats inside row | boxed card: transparent border becomes 2px strong/black on hover, hard shadow when highlighted/popup | ~4 | message_row_recipe:111-117,160-166 | B (border, shadow, margin from sections 4-6) | `row-border-on-hover` bool | kept | Reproducible as parameters, same widget tree. |
| Header layout | baseline-aligned (`baseline: !brutal`) 14px line, author control 14 high | top-aligned, 20 high | 2 | message_row_recipe:649,676 | C -> bool param | header-align | kept | |
| Quoted message card | outer card holds header row (padding) and an INNER bordered rounded card (panel, line-muted) | header with black@.15 bottom divider and borderless content; attachment chip lavender | ~8 | quoted_message_card:333-352,384-400 | C | could become `inner-card` bool + header-divider token | kept | Different child tree. |
| Rich card (forwarded snapshot) | 2px framed embed, content has own .5px rounded border, header/footer transparent, show-more not underlined | flush, header/footer filled with divider lines, underlined | ~12 | rich_card_tokens:54-147 | B mostly + C | embed-inset, `show-more-underlined`, header-fill | kept | Mostly decoration data; structure is the same widgets. |
| Transfer progress bar painter | pill track (r = h/2), rounded fill, translucent track | square, black ink rule above/around, black end cap on the fill | 1 painter (~14 lines) | attachment_transfer:231-324 | C | `pill` + `ink-rule-width` params possible; end-cap geometry stays code | kept | `brutal:` constructor flag is gone from NEW. |
| Transfer chip | dark translucent pill, white text | white box, 2px border, hard shadow | 1 | attachment_transfer:383-400 | B | radius-full, color-media-chrome | kept | |
| Composer attachment chip | Stack with positioned meta, outer ring shadow (ring-1 ink10), 64x64 slot | Column body, 2px border on image chip, size 100% | ~8 | composer_attachments:240,529,551,598,609 | C (+ generated recipe data) | `attachment-layout` enum | kept (call pinned to RaftRecipeTheme.elegant) | The generated table composer_attachment.g.dart still holds both themes: closest thing to a data pack today. |
| Conversation tabs | underline tabs, 2px indicator under selected, no separators | filled selected tab, 2px black separators and right-edge bar | ~6 | chat_composition:608,690,703 | C | | replaced (Tabs 0.7.1) | |
| Date header divider | opacity .7, 1px hairline, mono 11 | 2px black@.15 shifted 1.5px, bodyFont 10 bold | 6 | chat_composition:866-928 | B | divider-width | kept | |
| Composer as-task checkbox | 14px, 1px line-strong, strong fill | 2px black | 5 | chat_composition:1026-1045 | B | border-width-control | kept | A separate Checkbox was ported, this bespoke one was not. |
| Media browser chrome | gradient scrims (black .8->0 and 0->.78), round translucent buttons | solid black bars with white 2px rule, square white buttons + hard shadow | ~8 | media_browser:814,1200-1342 | C (DecoratedBox variants) | `chrome-style` enum, or tokens for the two gradient colours | kept | |
| Mermaid fullscreen backdrop and close | black@.72 + blur sigma 2, `_RoundClose` | layer-backdrop flat, RaftCloseButton | 2 | mermaid_fullscreen:81,109 | C (BackdropFilter) | backdrop-blur (B: number), close-button style (C) | kept | |
| Video play badge / time tip | circle, 1px white@.9; tip radius 4, white@.25 border | square, 2px; tip square, white@.9 1.5px | ~4 | video_controls:367,966 | B | radius-full, border-width-control | kept | |
| Context menu separator | -mx-1 my-1 1px hairline (bleeds into padding) | border-t-2 black, no margin | 1 | message_context_menu:73-90 | A (generated recipe) | RaftContextMenu recipe data | kept | Already data driven through the generated recipe, pinned to theme. |
| Inline thread surface | card fill + border (transparent in dark); hover fill widget-supplied | black@.03 fill, no border, hover black@.08 | ~5 | inline_thread_surface:38-48,137,345 | A/B | line-embed, radius-card | kept | |
| Lightbox / preview shell chrome | border-b 1 (preview) or 2 (image lightbox) in line-muted, panel | always 2 black, white | ~15 | attachment_lightbox:136-146,260; attachment_preview_shell:153 | B | border-width-rule | kept | Elegant already has a 1 vs 2 per call site, not purely theme. |
| Live agent activity bar | rounded-lg bordered card, shadow-md, 13px sans, fade+rise motion (never runs) | top rule bar, 14px mono, fixed status colours | 3 (+ recipe) | live_agent_activity_bar:19-32,121,135 | C | | deleted (widget removed from NEW package; .g recipe remains) | |
| Badge on quoted / thread replies / pending banner | recipe theme `elegant` | recipe theme `brutal` | 3 | thread_replies:230; composer_pending_mentions:452; composer_attachments:241 | A | generated recipes (RaftBadgeRecipe etc.) | kept, but call sites hard-pinned to elegant | Badge / Avatar themselves are the ported 0.7.1 components. |

## 8. Motion

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Press translate on small controls | none (`transformsOnInteraction` false) | translate with the hard shadow | 2 | thread_composition:514; message_row_recipe (action recipe false for both) | C -> bool | `press-translate` | kept | |
| Live bar enter/exit 220ms fade + 8px rise | Elegant only, not run in the product | none | 1 | live_agent_activity_bar:30 | C | | deleted | |
| Opacity of date header | .7 | 1 | 1 | chat_composition:887 | B | | kept | |

No other theme-dependent motion found in these files (progress sweep, pulse and 300ms comments sheet are the same for both).

## 9. Icons

| what | Elegant | Brutal | n | samples | class | token / param | NEW | note |
|---|---|---|---|---|---|---|---|---|
| Glyph stroke in tabs | 1.5 | 2.5 | 1 | chat_composition:407 | B | icon-stroke-width | replaced (Tabs) | |
| Icon sizes | same (13/14/18) | same | 0 | | | | | Only the toolbar button extent changes (section 6). |
| Message-media icon colour | t.muted .6 on fill-muted | black@.38 on cream | 1 | attachment_transfer:353-360 | A | | kept | |

## 10. Count table (approximate, branch lines in my files; one site may count once)

| area | files | sites | A | B | C |
|---|---|---|---|---|---|
| Message rows, content, system, context menu, reactions | message_row_recipe, message_content_tokens, message_body, system_message, message_context_menu, quick_reaction_picker | ~75 | ~45 | ~25 | ~5 |
| Composer (shell, suggestions, tools, attachments, pending, drop, expand) | composer_* (8 files) | ~105 | ~50 | ~45 | ~10 |
| Chat shell: tab strip, date header, agent chat list, live bar | chat_composition, agent_chat_view, live_agent_activity_bar | ~63 | ~30 | ~20 | ~13 |
| Attachments, media, preview, lightbox, video, mermaid | attachment_*, inline_media, media_browser, document_preview, preview_unavailable, video_*, mermaid_fullscreen | ~136 | ~70 | ~45 | ~21 |
| Threads, forwards, quoted card, rich cards, runtime usage | thread_*, inline_thread_surface, forward_*, forwarded_bundle, quoted_message_card, rich_card_tokens, runtime_usage_card | ~144 | ~70 | ~55 | ~19 |
| Total | 40 files | ~523 | ~265 (50%) | ~190 (36%) | ~68 (13%) |

By property (all areas, approximate): colour ~270 (A almost all), border width ~70 (B), radius ~45 (B), spacing ~90 (B),
shadows ~25 (A/B), typography ~55 (B), component structure ~30 (C or bool).

NEW status of the Elegant side: kept for about 95% of sites. Replaced: conversation tab strip (Tabs 0.7.1). Deleted:
live_agent_activity_bar.dart. Bespoke items inside the 11 ported component areas (Badge in quoted card and thread
replies, Avatar in forward / pending mentions, Checkbox in forward) now call the ported widgets, so their old Elegant
code is not in these files at all. RaftRecipeTheme.brutal still exists in NEW (recipes/recipe_runtime.dart:541) and the
generated recipe tables still carry both themes; call sites are pinned to elegant.

## 11. Top 8 most visible Elegant vs Brutal differences in G2

1. Message row: Elegant is a flat full-width row with a soft ink-2 hover tint and a floating 28px toolbar; Brutal is a
   boxed card (12px margin, 2px border on hover, hard shadow when highlighted). Mix of B tokens (margin, border, shadow).
2. Radius everywhere: 8 (cards, composer shell, popups, quoted card) and 6 (controls) vs 0. B: radius-card, radius-control, radius-full.
3. Border weight and colour: 1px line-muted/hairline vs 2px black on every panel rule, header, composer top, lightbox.
   B: border-width-card, border-width-rule (colour is A).
4. Ink and surface colours: Brutal's black-alpha text and white/cream fills vs Elegant semantic tiers. A, so this is the cheapest 40% of the look.
5. Elevation: Elegant uses a 1px ring made of a spread shadow plus a soft shadow (composer shell, suggestion popup); Brutal
   uses hard offset shadows. Needs shadow-ring and a variable shadow-card.
6. Composer geometry: Elegant shell has no inset, editor inset 12/12/12/0, bottom toolbar 10/4/10/10 with 28px actions;
   Brutal pads the shell 8 and keeps 26px actions. B (about 12 numbers).
7. Quoted card and rich card structure: Elegant nests an inner rounded card and a 2px framed embed; Brutal uses divider-separated flat sections.
   Mostly C, could become a bool plus tokens.
8. Typography feel: Elegant is lighter and tighter (w500 vs w700, -0.01em tracking, 11/13px small text, sans timestamps)
   against Brutal's bold, mono-accented labels. B: font-weight-*, letterspacing-*, a small type-scale.

Also visible but outside the top 8: conversation tabs (underline vs boxed, replaced in NEW), media chrome (gradient scrims and
round buttons vs black bars), mermaid fullscreen blur.

## 12. Honest limits

- Counts are by grep lines, so one conceptual site may appear 2-3 times (for example radius + border + fill in one BoxDecoration).
- message_body.dart, media_browser.dart, inline_media.dart and video_controls.dart were read only around their branch lines.
- Generated recipe tables (recipes/*.g.dart) were not audited here; they carry both themes already and may hold more Elegant data.
- I judged "A" by the Elegant side using a named semantic colour that exists in NEW; I did not verify each key against the final token values.
- Dark mode: many Elegant literals (Colors.transparent borders, black@.35) are dark-specific; a data pack would need a per-mode value for them.
