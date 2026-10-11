# Android page-transition measurements

Measures the push/pop and tab transitions of the real mobile `WorkspaceView` in profile mode on a device, one frame list per transition, in the two light themes.

## One command

Connect the device with `adb connect`, then from the repository root (macOS or Linux):

```sh
python3 tool/performance/android_transitions.py --device 10.77.0.24:38213 \
  --out .local/performance/android-transitions/before
```

Optional: `--themes brutal-light`, `--scenarios nav-members-agent,nav-tabs`, `--allow-noisy` (measure although the host is busy; the run is labelled NOISY), `--apk <prebuilt>`. The command takes 10 to 15 minutes, including the build.

Send back `<out>/run.tar.gz` (the same data is in `<out>/run/`). Use a new `--out` per run; existing directories are refused.

## Isolation

- The APK is built from `integration_test/perf_lab_test.dart` with `--android-project-arg=raftApplicationIdSuffix=.linkperf`, so its application id is `app.raft.raft_flutter.linkperf`. `build.gradle.kts` appends the suffix only when this property is set; a normal build keeps `app.raft.raft_flutter`.
- The run goes through `tool/performance/lab.py`, which accepts only an APK whose real package is `app.raft.raft_flutter.linkperf`, forces `--keep-app-running` (no automatic uninstall), and compares the real App's package identity, install time and data directories before and after. A change fails the run; nothing is reinstalled, cleared or uninstalled.
- Fixtures are synthetic (mock HTTP adapter, loopback PNG server): five agents on two computers, 15 channels, an Activity inbox of six channel entries, 600-row channel histories. The owner's account and data are not used.

## Scenarios

Each scenario repeats the transition three times (Settings twice), forward and back. Every transition is one `opens` entry in the raw JSON with its frames, so the summary reports the worst UI and raster frame inside each transition. Each step waits for the destination, then dwells 900 ms so the route animation and any follow-up work fall inside the interval.

| Scenario | Transition |
|---|---|
| `nav-members-agent` | Members tab, tap an agent row (detail), system back |
| `nav-home-channel` | Home list, tap a channel, back |
| `nav-channel-thread` | Channel, open a thread (same controller call as the thread-summary tap), back |
| `nav-settings-sub` | Settings tab, tap Appearance, back |
| `nav-home-activity` | Home, Activity list, back |
| `nav-activity-item` | Activity list, tap an entry (channel), back |
| `nav-tabs` | Home, Tasks, Members, Settings, Home, Members, Tasks, Home through the bottom bar |

Themes: `brutal-light` and `elegant-light`. Default semantics mode `platform` (Android: on only with an accessibility service).

## Reading the output

`run/summary.md` has per-scenario UI/raster p50/p90/p99/max, frames over 8.33 ms, and a per-transition table. `<theme>-<scenario>.json` holds every frame (build start, UI time, raster time, framework phase times). `<theme>-<scenario>.attribution.json` holds Dart CPU samples of the five worst UI frames and engine timeline events of the five worst raster frames. Compare two runs with `python3 tool/performance/lab.py compare <before>/run <after>/run`.

## Functional check without a device

`--device emulator-5580 --abi x64` runs the same flow on an x86_64 emulator. Its timings are not evidence for phone jank (different CPU, software rendering).
