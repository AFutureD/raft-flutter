# Route performance probe

The probe is retained for real-device investigations. It is **off by default**:

```bash
# Add to a normal ARM64 release/profile build through the pinned SDK.
--dart-define=RAFT_ROUTE_FRAME_DIAGNOSTICS=true
```

Without this define the binding installs no probe callback/timer, uses the
ordinary root `PipelineOwner`, and pages have no extra probe render object.
The switch does not enable snapshotting, change route animations, disable
stretch, change semantics or replace the renderer.

With the switch, `RAFT_ROUTE_PERF` JSON records contain only route categories
(such as `computer`, `channel` and `channel/thread`), monotonic times and frame
costs. There are no URI/entity IDs, account fields, tokens or message content.
Records are buffered with a fixed 800-record limit and exported every three
seconds. Each record gets a separate Android log line to avoid logcat's line
truncation. `probeFlush` records expose export duration and overflow counts.
Logging still perturbs a diagnostic build; this is not the acceptance gate.

## Read-only collection

Build and install using the [existing protected workflow](android-installation.md).
Open the app normally, then collect while reproducing the route behaviour:

```bash
python3 tool/performance/route_probe.py capture --device <serial> \
  --seconds 60 --out .local/performance/route-capture/<run>
python3 tool/performance/route_probe.py summarize <probe.jsonl-or-logcat.txt>
```

The tool reads the running process's ADB logs. It does not install, launch,
stop, navigate, send input or clear data. It saves only probe records. A missing
probe, restarted process, or interrupted log stream is an error; partial
artifacts remain available. The output directory must be new.

## Reading the measurements

`uiUs` measures the complete UI frame cycle, including semantics and callbacks.
`buildUs` is the engine's narrower build duration; `rasterUs` is the raster
thread's duration. Low build time alone does not prove a smooth transition.
The phase scopes measure build, layout, compositing-bit update, paint and
semantics; shell/page scopes are inclusive subsets, **not additional phases**.
Raster duration can include buffer/fence waits: investigate native CPU/GPU
timelines before attributing it to Dart work or shader compilation.

The analyzer matches UI/engine timestamps within 2 ms, counts unmatched and
dropped records, and excludes matched frames overlapping probe export from its
per-page statistics. Keep the raw records. Collection boundaries and asynchronous
engine timing delivery mean a capture can be partial even without overflow.
Old truncated batch logs are salvaged but explicitly marked malformed. Report
observed frames; never treat a partial capture as a complete percentile baseline.

Use the [isolated live-data performance lab](performance-lab.md) for repeatable
before/after comparisons with this probe disabled. That lab includes production
root routing, live CRUD/event replay, asynchronous reads, image decoding and
background SQLite writes; it complements formal-App physical gesture captures.
