# Mac performance evidence coverage

Target integration revision: `7a42e91ed55673b777cad3f74252ccc8dc9e9c62`. This is an evidence audit, not a 120fps completion claim.

The accepted comparisons cover many routes, but do not establish the entire objective on the current integration revision. Sparse actions, continuous scrolling, programmatic resize and actual human live resize are separate evidence types.

| Evidence set | Native actions | Changed / missing / unenumerated target libraries | Native frame scope |
| --- | ---: | ---: | --- |
| recipe-cached-v4 | 32 | 16 / 0 / 31 | Sparse background wheel / page actions |
| sidebar-frozen-v4 | 13 | 12 / 0 / 3 | Sparse background wheel / page actions |
| continuous-row-extent-v4 | 2 | 10 / 0 / 3 | 8s timeline scroll + 10s programmatic native resize |

“Unenumerated” means not present in that archived manifest; it does not assert the file was newly introduced. Every current tracked production library prefix was included in this hash audit.

Source differences require a fresh matched baseline/candidate run; an older capture cannot certify the current code merely because most files match. These comparisons also used a synthetic workspace, not live account data.

| Required scope | Strongest selected evidence | Current acceptance gap |
| --- | --- | --- |
| Chat steady scroll | 959 frames over 8.008s, enabled semantics, 120Hz display | Current integration and sidebar date-cache candidate unmeasured; raster still has over-budget frames |
| Cold / long-distance chat scroll and realtime insertion | Sparse cold/short/live captures in two matched sets | Cold build and raster peaks exceed 8.33ms; sustained gesture coverage missing |
| Channels and settings / chat return | Matched repeated sparse entry/return captures | Peaks still exceed budget; repeated continuous transition capture on current code missing |
| Channel settings sheet | Matched open/close captures | Closing raster peaks exceed budget; current source unmeasured |
| Tasks, files, members, computers, Activity, search | Entry and sparse scroll captures in 32-action set | Current source and sustained scroll/resize acceptance missing |
| Registered apps and MCP | Entry and sparse scroll captures in 32-action set | Registered-app entry sample has only 2 frames; insufficient stable performance evidence |
| Thread / agent / computer detail transitions | Fixture supports data, but no dedicated action in selected matched sets | Add direct open/back, scroll and resize scenarios; fixture availability alone is not coverage |
| Billing / feedback / other settings | Earlier supplemental functional/native checks documented in investigation | Not in these selected complete matched sets; current source needs dedicated measurement |
| Native window resize | 832 frames over 10.024s, 356 inactive non-key window size steps | UI p99 14.724ms / total p99 52ms; requested 120 steps/sec not achieved; human NSWindow.inLiveResize not measured |
| Semantics and visual/input invariants | Enabled semantics and mounted behavior regressions | Must preserve meaningful native accessibility and unchanged visible rows on current revision; frame timing alone is insufficient |

## Open execution gate

Background Computer Use cannot currently bind the Lab (`cgWindowNotFound`). The baseline process is running without any continuous-operation receipts; no new test action or frame result was accepted. Do not raise windows, switch Spaces or use global/CLI input to bypass this gate. Resume when background targeting becomes available.

## Next matched run

1. Freeze a fresh current-integration baseline and the candidate with identical fixture, theme, fonts, DPR, viewport, semantics and clean Profile AOT harness. Verify all production source bytes and the binary before launch.
2. Run paired continuous chat scroll and guarded native resize, then direct thread/detail routes and repeated settings/channel transitions. Retain runtime errors, fixture misses, actual routes, raw phase intervals, frame cadence and background restoration receipts.
3. Extend sustained scroll/resize checks to directory, tasks/files/Activity/search and relevant settings surfaces. Keep cold and warm results distinct. Capture real live resize only through a safely bound background native window, otherwise leave that scope open.
4. Use trace attribution to change the next bottleneck, repeat meaningful behavior checks and the affected native pair. No aggregate percentage or stable120fps statement from isolated passing cases.
