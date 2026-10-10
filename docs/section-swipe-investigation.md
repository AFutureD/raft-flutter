# Mobile section swipe investigation (2026-10-11)

## Tag color: reproduced and fixed

The reproducer is directional: fully accept Tasks, then hold a reverse drag exposing Chat. The retained Chat used `presentationActive ? callback : null` for footer task chips. Once Tasks became active, the null callback applied the control's disabled opacity (0.6). Inline references remained enabled, which made the mismatch conspicuous.

The fix keeps the chip's visual state enabled and guards the callback against inactive presentation and changed workspace/task authority. The pager still excludes inactive-page input, focus and semantics. No shader workaround or extra color layer is needed. An earlier ColorFiltered experiment was withdrawn after this reproduction established the actual cause.

Native screenshots measured the cyan fill changing from RGB (39, 204, 243) to (125, 224, 248), exactly the disabled color over white. Every decoded frame of two 30-second Android videos was inspected; this was not a sample of every nth frame. H.264 comparisons allow a three-channel tolerance of three.

| Theme | Before: frames / dimmed | After: frames / dimmed |
|---|---|---|
| brutal-light | 3556 / 639 | 3591 / 0 |
| elegant-light | 3555 / 643 | 3595 / 0 |

Local artifacts are under `.local/performance/section-drag/return-before` and `return-after`: `*-return.mp4`, `tag-video-colors.json`, per-frame color JSON and held-reverse screenshots. The after videos include the color and lazy-task fixes; later owner/selection optimizations did not change the chip fix.

## Performance changes

- Task status sections now use `RaftSliverTaskSection` with lazy per-card slivers. The previous list lazily mounted a whole status group containing 120 cards. Visible retained cards dropped from 120 to 11 in the native fixture. CSS fill, padding, borders and shadows remain the same; box/sliver rectangle comparisons cover all three themes.
- Conversation pages reuse at most three visited owner widgets. Authority/controller/selection-handle changes clear them; callback proxies read the current parent. File display preferences invalidate the file owner. Business controllers continue to own live data.
- Resource pages observe the TickerMode activity notifier directly, avoiding a page rebuild solely for section activity. Pending reads still resume when the page becomes active.
- Empty message selections no longer project the entire message window on unrelated controller notifications. Active selection and authority checks remain intact.

## Populated Android measurements

The isolated profile application uses 600 messages carrying task metadata, 600 tasks across five populated statuses, and 240 PNG attachments. Preconditions require actual task cards, at least five visible footer task tags, and at least five decoded file thumbnails before measurement (11 thumbnails in the forward/cycle runs). Images use the real loopback download/decode path. The fixture is synthetic, not the user's account.

Device: XT2603-1, ARM64, 120 Hz, 1264×2780, DPR 3; FVM Flutter 3.47.6. Android logs confirmed Impeller/Vulkan. Host M1 Pro metadata describes the machine driving the run, not the phone GPU. Semantics remained enabled. All these runs were labelled **NOISY HOST**; they are exploratory comparisons, not quiet certified baselines.

| Gesture / theme | Before UI max (ms) | After UI max (ms) | Before → after frames above 8.33 ms |
|---|---:|---:|---|
| Chat held toward Tasks / brutal | 23.58 | 10.04 | 1.2% → 0.5% |
| Chat held toward Tasks / elegant | 28.76 | 8.78 | 1.8% → 0.5% |
| Chat → Tasks → Files → Tasks → Chat / brutal | 121.00 | 30.97 | 4.8% → 1.0% |
| Chat → Tasks → Files → Tasks → Chat / elegant | 117.43 | 31.59 | 4.9% → 0.9% |
| Accepted Tasks held back toward Chat / brutal | 20.95 | 12.52 | 3.7% → 1.4% |
| Accepted Tasks held back toward Chat / elegant | 22.06 | 12.31 | 6.7% → 1.0% |

Forward/cycle comparisons are `return-before` → `retained-after`. The final empty-selection optimization was added afterwards; its forward/cycle effect has not been separately measured. Exact reverse comparisons are `back-before` → `back-after` and include all final fixes. Eight-second reverse stutter counts fell from 37 to 13 and 61 to 10; GC counts fell from 99/94 to 20/20. No reverse UI or raster frame exceeded 16.7 ms after the fix, but some frames still exceeded the 120 Hz budget and skipped vsync. Cycle acceptance still has approximately 31 ms tails. **The strict no-stutter gate is still failing; this is not a claim of flawless 120 fps.**

Recorded video/screenshot setup occurs outside the performance intervals. Earlier sparse runs and the run with video overlapping measurement are retained locally but excluded from these comparisons. Formal application version, first-install time and credential/device data-directory inodes were verified unchanged across isolated profiling.

## Coverage

- Component checks: lazy mounting, collapse/reopen, semantics, exact original/sliver geometry in three themes; pager keyboard/focus/semantics; task typography (20 passing tests).
- Related app checks: resource authority, files, warm tasks, filters, mobile paging, populated conversation and inactive callback behavior (51 passing tests).
- Empty selection, copy links and selection privacy checks (10 passing tests). One existing widget interaction emitted a hit-test warning; this is not native pointer acceptance.
- SDK task-section previews cover all three themes and collapsed/empty states. App and design-system analysis passed; design-system audit passed without baseline changes.
- Native profiling and recorded color evidence cover two Android light themes. macOS release build/signature/ARM64/background launch were checked; native UI automation was unavailable. Native Linux/iOS/Windows accessibility and lifecycle were not tested here.

The lazy list and retained-widget choices follow Flutter's [performance guidance](https://docs.flutter.dev/perf/best-practices). Remaining frame-budget failures need a separate targeted investigation rather than being hidden by a looser gate.
