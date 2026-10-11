# Reuse held channel activity during responsive rebuilds

`WorkspaceView.sidebarGroups` read `ledger.messages` and parsed every held
message's creation timestamp on every sidebar build. A native resize CPU trace
on accepted row-extent revision 7402de5 put sidebarGroups in 246 of 4,227 phase
samples and DateTime parsing in 168 inclusive / 43 exclusive samples. Inclusive
counts overlap; they cannot be added or treated as independent frame costs.

The ledger now exposes `latestCreatedAt(channelId)`, with a channel-scoped
DateTime/null cache. It scans unsorted held rows once, then reuses the result
until that channel changes. Ingress, updates, deletion and revocation invalidate
that channel; changing server clears all results. Unknown channel IDs are not
cached. Values retain only timestamps, not extra message maps or text. Sidebar
projection still receives current channels, preferences, agents, unread and
draft inputs; ordering follows timestamps rather than sparse sequence numbers.
No rendering, route, semantics or platform code changed.

## Checks

- An uncached extraction of the original date scan into the new API (before
  adding caching) failed 3 of 4 new unit cases; the 600-row/20-read case observed
  12,000 date conversions rather than 600. This is an extracted baseline, not an
  unchanged original-source run. Caching passes all four cases.
- 11 related sync tests passed, including invalid/null/timezone timestamps,
  sequence/date disagreement, unaffected-channel reuse, ingress/update/remove,
  revoke/reingress and stale-server generation isolation.
- 13 related app tests passed. Three new mounted WorkspaceView cases exercise
  600 held dates, 12 wide viewport changes, recent sorting after a timestamp
  edit/deletion/revoke, and current unread/draft indicators in all three themes.
- Focused analysis and design-system audit passed without increased counts.

## Native gate remains open

The clean row-extent baseline app was restored from its saved bundle and all
143 bundled file hashes verified. The same continuous diagnostic harness is
unchanged (SHA256
`2086c4e8a8b51152d1b96b262075d3a3a09ab32b169ed8bb274cf69e3819f735`).
Computer Use launched the app in the background, but binding by both exact app
path and bundle ID repeatedly returned `cgWindowNotFound`. App diagnostics
confirmed a running process with no fixture errors and no continuous-operation
receipts. No scroll/resize operation was triggered, no foreground fallback was
used, and no new native frame result was accepted.

The deterministic work reduction is proven. Its actual frame-time effect and
the original broad 120Hz acceptance requirement remain unverified. The earlier
row-extent baseline's resize UI p99 was 14.724ms; total p99 was 52ms, so there is
no basis to claim stable 120fps. Resume a matched baseline/candidate profile
pair when Computer Use can bind the background Lab window. This branch is
available for code review; native performance acceptance stays open.
