# Horizontal alignment audit (Flutter vs Web)

Run date 2026-10-11, base `70bdfa0` (`cindy/integration`), branch `cindy/alignment-audit`.
Tool: `tool/alignment-audit.py`. Corpus: the official 99 `tool/parity` cases and every
brutal `tool/parity-ext` case (592), 691 Flutter/Web pairs. Web captures come from the shared
React cache; nothing was refreshed.

## 1. The owner report: what the screenshots show

`/tmp/k-align-1.png` and `/tmp/k-align-2.png` (and the two Agent screenshots) are the **Web**
product in a Chrome window, not the Flutter client. Web's channel settings drawer opens the members
page as its own `ChannelMembers presentation="page"` mounted `bare` in `OverflowSheet`
(`ChannelOverflowMenu.tsx` view `"members"`). That page mixes insets by design:

| element | Web class | inset (css px) |
| --- | --- | --- |
| page header (back, title, count Badge) | `h-panel-header ... px-4` | 16 |
| roster search | `shrink-0 border-b px-4 py-3` | 16 |
| group header ("Humans · 1") | `SidebarSectionHeader` brutal `mt-3 mb-1 h-6 px-2`, disclosure `border-2 border-transparent`, chevron box `size-4.5`; `[--sidebar-row-inset-x:0px]` zeroes the RUI bleed | chevron box at 8+2 = 10, title at 34 (elegant 0+1) |
| member row, role tag right edge | `ChannelMemberRow px-3 py-2` | 12 |
| bottom "Add Member" button | `shrink-0 border-t-2 p-3` | 12 (wider than the search field) |
| add view (search, candidate card, confirm) | `flex min-h-0 flex-1 flex-col px-4 py-3` | 16 |

So the "slip" Kevin sees is Web's own geometry (search 16, rows/button 12, headers 10). The
instruction was to match Web, so Flutter now reproduces those insets and does not unify them.

Why Flutter did not match before: it had no such surface. Desktop opened a `max-w-sm` modal card
(`RaftChannelMembersModal`, the Web header-trigger presentation), the phone route used the same
card inside a 16px padded scroll view with a `Members (N)` title. None of the page structure
(count badge, chevron groups, role tags, fill-height add view, p-3 footer) existed.

Fixed in commit `e879172`:

* `packages/raft_ui/lib/src/channel_members_view.dart`: `_MembersPage` (header, search, collapsible
  groups, `ChannelMemberRow` with `MemberRoleTag`, hover remove, p-3 footer, fill-height add view).
* `RaftOverflowBareSheet` (channel_overflow_sheet.dart): the drawer frame without header. The
  desktop `ChannelSettings` keeps its root mounted (draft survives) and swaps the page in, like
  Web `view: "root" | "members"`. Member strip and the dashed + tile open it (add tile goes straight
  to the add view). `ChannelMembersButton` (channel header trigger) stays the modal, as on Web.
* `RaftMountedAvatarContext.membersRow` (AvatarSlot `members-row`: 28px, 8px badge).
* Regression test `channel_settings_panel_test.dart` ("members page keeps the Web column insets",
  brutal and elegant) asserts 16 / 12 / 12 / 16.
* New ext cases `components.channelsettings.{desktop,mobile}.members-page*` (all 6 pass the official
  96% bar; the audit finds 0 edge offsets, only the 2px start of the search icon glyph).

Left by design: the Web role actions (make/remove channel admin), profile page navigation from a
row, and the remove confirm are not ported (Flutter removes immediately as before).

## 2. Agent pages (second owner report)

Also Web screenshots. Desktop Agent detail tabs Profile, Activity, Reminders, Workspace, Apps and
MCP already matched (0-1 edge offsets, existing `members-ext.agent.*` cases). The **Chat** tab was a
plain list (`RaftAccessCard` rows) and had no desktop case. Web's tab mixes insets on purpose:

* eyebrow strip and both section headers `px-5` (20);
* channel cards `space-y-3 px-4 pb-4` (16), `SurfaceListItem` border;
* Agent DMs `p-4 space-y-3` with `ConversationPreviewCard` (`rounded-md border p-3`, its own
  `border-line-muted` / brutal `border-2 border-black/30`, not the SurfaceListItem border).

Commit `04a9266`: `RaftAgentChatView` + `RaftConversationPreviewCard`, archived memberships hidden,
"Show all N channels", inline empty states, combined empty state. Cases
`members-ext.agent.chat`, `chat-many`, `chat-empty`, `chat-sections-empty` (added to the builder;
fixture `members.json` routes `GET /agents/:id/channels` and `/agent-dms`). Result: 0 edge
offsets (only the 1-2px empty-state icon pair). The Reminders empty state of the screenshot is the
existing `agent.reminders` case and matches.

## 3. Method

1. **Pixel edge matcher (primary, `tool/alignment-audit.py run --root build/parity[-ext]`).**
   Per case it reads `visual-testing-results/{react,android}/<id>.png` and the React metadata
   density, converts to css px and extracts
   * strong vertical edges: a column step above 40/255 that continues vertically for 18 css px
     (borders, field/button/card/avatar sides; glyph stems are shorter);
   * text start columns: ink clusters per line band with the long edges removed.
   Each Web edge is matched to the nearest Flutter edge of the same polarity with overlapping y
   range. |dx| <= 0.75 css px (AA / fractional) is aligned; 0.75 < |dx| <= 12 is reported as an
   offset; beyond 12 is "unmatched" (a layout difference). A uniform shift of all matches
   (`globalShift`) is a frame offset and is subtracted but reported. A near-miss pass lists
   left-edge columns 1..8px apart that both occur >= 3 times inside one image, for Web and
   Flutter, so Web's own mixed insets are visible as such. `show` / `overlays` draw the offsets on a
   side-by-side sheet for review. Reliable for borders and fills; pitfalls: edges that depend on
   text width (mono advance, button label width) move with the text, and a vertical layout
   difference can pair the wrong neighbour (seen in `taskdetail.mobile.*`), so every top family was
   looked at in an overlay.
2. **Widget test harness (regression guard).** `channel_settings_panel_test.dart` measures global
   rects of the header back button, search field, first member avatar, footer button and add-view
   controls against the drawer rect and asserts 16 / 12 / 12 / 16 per theme. Rects are exact, but
   only for widgets someone writes a test for, so it guards fixes rather than finding them.
3. **Code review for the same patterns** (ListTile defaults, hard-coded paddings): see section 6.

Pixel matching was chosen as the finder because it needs no per-surface test and compares against
the real Web render; the widget harness is the guard.

## 4. Results

| | before | after |
| --- | --- | --- |
| cases analysed | 687 | 687 (+6 new) |
| cases with >= 1 edge offset | 190 | 151 |
| edge offsets | 1429 | 628 |
| cases with a whole-frame shift >= 1px | 24 | 3 |
| cases with an offset >= 4px | 53 | 46 |

Official suite (`tool/parity run`, the 99 cases): 79 -> 84 passing (settings sub-pages
`account.page` 93.87 -> 97.73, `account.error-state` 94.37 -> 97.99, `appearance.page` 92.97 ->
97.52, `server.profile` 95.97 -> 98.44, `screens.settings.server-danger-modal` 95.00 -> 96.21 flip to
pass; `notifications.page` 89.63 -> 90.37).
Ext suite, the 217 re-run cases (settings, wp6 settings, channel settings, task detail, agent):
96% pass 87 -> 97, geometry pass 46 -> 55 (96% pass per family: `channelsettings.mobile` 3 -> 5 of
13, `billing` 6 -> 8 of 12, `wp6.settings` 16 -> 22 of 36, `administration` 9 -> 10 of 28). The apparent
`members-ext.agent.activity` drop is the React side being recaptured after the members fixture
changed (Flutter pixels identical).

## 5. Ranked list

Impact = cases x offset. `x` are css px from the left of the capture.

### Fixed

| # | surface | element | Flutter x vs Web x | delta | root cause | status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Settings sub-pages at phone width (account, appearance, notifications, server, billing, feedback, language, usage, bridges): 6 official + 22 ext cases | whole content column and header | 0 vs 2 (brutal) | 2 on every edge, and a 5-case pass flip | `RaftSettingsPanelFrame` drew the `Panel edge="attached"` left border (`border-l-2 border-black`, elegant `border-l border-line-muted`) only >= 768px; the recipe has no breakpoint | fixed (`settings_layout.dart`); phone half superseded by the owner decision 2026-10-12 (no left border on phone, see parity.md) |
| 2 | Channel / DM settings drawer on phone (13 cases) | whole sheet | 0 vs 2 | 2 | `_OverflowDrawerFrame` skipped `theme-brutal:border-l-2` for the full-width page | fixed (`channel_overflow_sheet.dart`); phone half superseded by the owner decision 2026-10-12 (no left border on phone, see parity.md) |
| 3 | Members page on phone | route content | 0 vs 2 | 2 | route rendered `ChannelMembers` without the drawer frame | fixed (`workspace_view.dart` wraps in `RaftOverflowBareSheet`); phone half superseded by the owner decision 2026-10-12 (no left border on phone, see parity.md) |
| 4 | Task detail modal, desktop (13 cases) and phone | everything below the title bar | left border 2 vs 4 (brutal), 1 vs 2 (elegant) | 2 on 19-24 edges per case | `ThreadPanelRoot` is `Panel edge="attached"`: a second left border inside the modal frame, not modelled | fixed (`task_surface.dart`); phone half superseded by the owner decision 2026-10-12 (no left border on phone, see parity.md) |
| 5 | Computer detail "Detected Runtimes", usage chips | chip with health dot and every chip after it | dot 6 vs 10 from label, chips drift 4 | 3-4, accumulating to 8 | Badge root `gap-1` (`gap-1.5` elegant) between label and `Status`; Flutter had none | fixed (`computer_surfaces.dart`) |
| 6 | Agent detail Chat tab, desktop | strip, headers, channel cards, DM cards | not ported | n/a | plain list instead of AgentChatTab (px-5 headers, px-4 cards, p-4 DM list) | fixed (commit `04a9266`) |
| 7 | Members / Add members drawer page | all | see section 1 | n/a | surface not ported | fixed (commit `e879172`) |

### Left for the owner (measured, not fixed)

| # | surface | element | Flutter x vs Web x | delta | likely cause | note |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `components.ui.button.states.elegant` (official) | one button's right edge | 134 vs 123 | 11.3 | Elegant button state width (single case) | needs the case rendered by hand |
| 2 | `components.thread-ext.attachment.doc.*` (csv, xlsx, comments; 9 cases) | spreadsheet preview columns | column starts 3-12px apart | 3-12 | table column sizing (Web min-content `table-auto`, Flutter fixed measure), plus a table border the Flutter table lacks | own widget, not a shared inset |
| 3 | `thread-ext.message.mermaid-toolbar.mobile` | toolbar buttons | 18 vs 8, ... | 10 | toolbar wraps differently; capture heights differ (44 vs 62) | layout difference |
| 4 | `wp6.settings.feedback-new-mobile` / `ext-settings.feedback.new*` | Idea / Bug segmented control | 134 vs 126 | 3-8 | segment widths | segmented control widths |
| 5 | `computers.detail.select-all`, `.panel`, `.runtime-usage.*` | icon + label buttons (Clear All, Stop, Restart) | 2px narrower each | 2-6 | icon/label width (Web `px-2` + border + 14px icon + gap-1 + text) | button sizing, check `RaftRecipeButton` icon+label |
| 6 | `components.thread.files.list` (official) | row overflow (kebab) button | 357 vs 362 | 5 | right inset of the collapsed actions | `SourceChannelFileRow` |
| 7 | `home.search.*`, `search-overlay.query*` | result rows | 3-6px | 3-6 | result row inner indent | search result row |
| 8 | `shell.desktop.server.menu` | drag grip, count badge | 2-3 | 2-3 | grip glyph weight / width | server switcher row |
| 9 | `taskdetail.mobile.*` | composer and bottom tab bar | 10-12 | 10-12 | not an alignment slip: Flutter's phone task modal covers the tab bar Web keeps; scroll state differs | layout difference |
| 10 | `thread-ext.timeline.*.back-to-bottom` | new-updates pill | 1-4 | 1-4 | pill width | |
| 11 | `home.create-channel.dialog` | visibility segmented control | 1.7-3.7 | 2-4 | segment widths | same family as 4 |
| 12 | `channelsettings.desktop.*` (20 cases) | one control right edge | 2 | 2 | action row | minor |
| 13 | `settings.account.*` | "VERIFIED" badge after the mono email | 2.3 | 2.3 | 14 mono glyphs 0.17px each | font advance |
| 14 | `wp6.settings.feedback-mobile` | cards | Web content overflows to the right | n/a | Web bug (cards wider than the viewport, clipped) | Web side |

### Code-review candidates (no parity case at that width, not measured)

Material `ListTile` / `CheckboxListTile` keep their own default insets (the app theme sets
`listTileTheme.contentPadding` horizontal 8) in `provider_views.dart`, `fleet_views.dart`,
`joint_channel_views.dart`, `sidebar_preferences_view.dart`, `mcp_views.dart`,
`account_connections_view.dart`, `forward_messages_dialog.dart`, `server_views.dart`,
`channel_conversion_section.dart`. They have no Web-derived inset and are the likeliest next
alignment slips; adding ext cases for them would put them in the audit.

## 6. Why these slips happened (patterns)

1. **A responsive condition the Web recipe does not have** (items 1, 2): the left edge border of
   `Panel edge="attached"` and of the drawer was coded as desktop-only.
2. **A raft-ui primitive's second border** (4): `ThreadPanelRoot` is itself a Panel; the modal frame
   border plus the panel border make a 4px stripe, invisible until edges are measured.
3. **Missing gap between flex children that a Web recipe supplies** (5): Badge `gap-1`.
4. **A surface rebuilt from a different Web presentation** (6, 7): the modal presentation was used
   where Web mounts the drawer page, so the page's mixed 16 / 12 / 10 insets could not exist.
5. **Web's own mixed insets** (reported screenshots): `px-4` containers around `px-3` rows and a
   `p-3` footer; these are reproduced, never "fixed".

## 7. Re-running

```
tool/parity-ext/run run --cases '*.brutal'            # or any glob; unique PARITY_EXT_WEB_PORT
python3 tool/alignment-audit.py run --root build/parity-ext --out .local/alignment/audit
python3 tool/alignment-audit.py overlays --out .local/alignment/audit
python3 tool/alignment-audit.py show --root build/parity-ext --case <id> --out sheet.png
```

Before/after screenshots of the two reported panels (desktop width, brutal, zh and en, with the
Web capture and the owner's screenshots) are in `.local/alignment/` (not committed).
