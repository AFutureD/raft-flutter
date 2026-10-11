# Android Performance Hint in Flutter

The App can give Android a CPU performance target for the thread executing Dart UI frames without rebuilding Flutter's engine. The binding calls `gettid()` on that thread, opens an NDK ADPF session, reports each frame's elapsed work immediately, and closes the session when the App leaves the foreground or frame work stops for 400 ms.

This implementation covers the Dart frame cycle: animation callbacks, the intervening microtasks, build, layout, paint and semantics, measured from `handleBeginFrame` to the end of `handleDrawFrame`. It excludes raster/GPU work and work before the frame callbacks. It does not claim an end-to-end graphics pipeline session or a fixed 120fps result. Android remains responsible for scheduling, thermal limits and whether it honors a hint.

## API and compatibility

- The NDK session/duration functions are available from API 33. Android 16 (API 36) adds `notifyWorkloadReset`, used once when a new UI burst starts, with CPU=true and GPU=false. Android 17 can use these APIs too. Missing symbols, a null manager/session, or service errors cause a fallback to ordinary scheduling. No permission or custom Flutter engine is required for threads belonging to this process.
- The target duration follows the display refresh rate, with 60 Hz fallback if unknown. Reports use a monotonic Stopwatch; they do not use `addTimingsCallback`, whose release-mode timing delivery is batched and too late for per-cycle feedback.
- Flutter's Android UI/platform runners are merged by default in current versions. We nevertheless capture the running thread rather than infer it from a name or configuration. This session does not include the raster thread.
- `RAFT_ANDROID_PERFORMANCE_HINT=false` disables native loading and sessions. Debug and non-Android builds never load this backend.
- Background lifecycle transitions close immediately. Unsupported devices do not retry every frame. Optional reset rate limiting is tolerated; other service failures close and disable the session for this binding's lifetime.

Official sources: [NDK Performance Hint API](https://developer.android.com/ndk/reference/group/a-performance-hint), [Flutter architectural overview](https://docs.flutter.dev/resources/architectural-overview), [Dart Native symbol resolution](https://api.dart.dev/dart-ffi/Native-class.html). Engine reference: Flutter 3.47.6 / engine 692136cb6582dbfc5af3fb33c2515a069f2f66d0; framework `scheduler/binding.dart` documents timing batching.

## Binding generation

Native declarations are generated from the unmodified Android NDK 30 headers retained under `apps/raft_flutter/third_party/android/`, including their original licenses. Only seven native functions and required opaque types are emitted. Nothing new is compiled or packaged as a native library.

The FFIgen 23 tool has its own package and lockfile, so the App's existing native build dependencies do not change. From the App directory:

```sh
(cd tool/bindings_generator && dart pub get)
RAFT_ADPF_NDK=/path/to/ndk/30.0.15729638 dart run tool/ffigen.dart
```

All functions record their usage; generated usage maps are retained. FFIgen 23's `Visitor` API replaces the older `Functions.recordUse` configuration. Its dynamic wrapper style emits `RecordUse` on instance methods, which Dart 3.13.5 rejects; the generator therefore uses top-level `Native` declarations. The current-process symbol check guards all calls. Native lookup falls back to the process as documented by Dart; if a device's linker namespace does not expose these symbols, this backend safely remains unavailable. Generated files are never edited manually.

## Verification and measurement

Unit tests cover target changes, burst reuse, foreground/background, unsupported hardware, reset rate limits, service failure, invalid durations and idle release. The integration performance lab uses the same binding mixin as production and reports enabled/backend/session/report/error counters in its hello/done messages.

Compare builds from the same source and lockfile, one with `RAFT_ANDROID_PERFORMANCE_HINT=true` and one with `false`, using the isolated `.linkperf` application and the same scenarios/themes. Preserve each run's refresh rate, fixture failures, thermal/load status, raw timings and formal-App protection checks. A run with zero sessions/reports is not evidence that ADPF improved anything. A/B order, thermal drift and adaptive display changes can confound results; UI and raster distributions must be assessed separately.

Android 17 phone capability verification succeeded: UI TID equals the process main TID, the system accepted 3 sessions and 4,904 duration reports without errors. `dumpsys performance_hint` also shows an existing platform HWUI session containing the main thread, RenderThread and hwuiTask workers; absence of explicit Flutter-engine integration does not imply the App has no system-owned ADPF session. Our UI-only session has `GraphicsPipeline: false`. No real-phone performance gain has yet been established. Existing Computer Use background constraints still apply; this document does not authorize installation or automated real UI interaction.

## Android 17 device results (2026-10-11)

Same source and ARM64 Profile engine, two scenarios in brutal-light, ON → OFF → ON using the same ON APK twice. Native libraries are byte-identical between modes except the Dart AOT `libapp.so`. All three functional runs passed, with no missing fixture routes. Formal App version 8031, install time and data inodes were preserved in every run. Display metadata was 120 Hz and semantics was enabled. Both enabled runs accepted UI reports (4,904 and 4,954), with zero API errors; disabled mode created zero sessions.

| Scenario | Mode/order | Measured frames | UI p99 / max ms | Raster p99 ms | Frames >16.7 ms UI / raster |
|---|---|---:|---|---:|---|
| nav-home-channel | on-1 | 669 | 13.66 / 37.58 | 11.94 | 6 / 1 |
| nav-tabs | on-1 | 745 | 2.77 / 17.25 | 3.24 | 1 / 0 |
| nav-home-channel | off-1 | 671 | 13.89 / 38.66 | 11.94 | 6 / 2 |
| nav-tabs | off-1 | 748 | 3.23 / 15.11 | 3.15 | 0 / 0 |
| nav-home-channel | on-2 | 675 | 13.08 / 41.96 | 13.09 | 6 / 4 |
| nav-tabs | on-2 | 748 | 2.58 / 22.62 | 2.64 | 1 / 0 |

These 4,256 measured frames / 39 transitions establish API functionality, not a stable jank improvement. Every run was marked NOISY by the existing host-load gate. UI p99 was lower in enabled samples, but page first-frame maxima and raster tails did not improve consistently. All three runs failed the strict 60 Hz gate, so none demonstrates 120fps. Short runs showed thermal status 0 and battery temperature 33°C; battery cost and other devices/Android 16 have not been validated. The feature defaults on for supported release/profile Android backends and retains the compile-time off switch; it remains a reviewable code change, with no deployment of the formal App.

A final functional cleanup run, after adding only `tearDownAll` frame-loop shutdown to the live test binding, passed both scenarios and 5,065 more native duration reports without API errors. A subsequent system-service read confirmed the UI-only Tag 4 session was gone; only the system HWUI Tag 2 session remained. This fourth run validates cleanup and is not included in the three-run comparison table. The integration test App remains installed/running as required by the harness, with no continuous test frame loop or UI hint session.
