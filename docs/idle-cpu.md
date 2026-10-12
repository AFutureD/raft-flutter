# Idle CPU and frame scheduling

Trigger: 6785f8f2 (idle message preparation starved Windows input). A task submitted with
`SchedulerBinding.scheduleTask(..., Priority.idle)` is rejected while any ticker runs, and Flutter retries
it through `Timer.run` (zero delay). One pending task plus one running animation is a hot event-loop spin:
about 4,000 zero-delay timers per second on Linux desktop, about 37,000 on the Android emulator.

## Rules

- Never use `Priority.idle`/`scheduleTask`, and never re-arm a zero-delay timer. Deferred work uses
  `RaftIdleTimer` (positive delay, waits out animation and frames, backs off while its gate stays shut).
- Polls and clocks that only matter on screen use `RaftForegroundPeriodic`; it stops on
  hidden/paused/detached and does not fire on resume (owners already refresh on resume).
- A perpetual animation must use a State `vsync` (TickerMode mutes hidden subtrees; `Offstage` does not) and
  stop under reduced motion. Hidden-but-retained subtrees wrap `TickerMode(enabled: visible)`.
- Both helpers live in `packages/raft_ui/lib/src/idle_work.dart`.

## Guards

- `apps/raft_flutter/test/idle_work_guard_test.dart` scans all workspace `lib/` code for scheduleTask,
  Priority.idle, Timer.run, zero-delay timers, scheduleMicrotask, `.repeat(`, Timer.periodic, frame requests,
  self-registering post-frame callbacks and raw tickers. Each use needs an allowlist entry with an exact count
  and a reason.
- `apps/raft_flutter/test/idle_frames_test.dart`: real WorkspaceView on the desktop fixture, two minutes of
  app time per screen; no running ticker, at most the known data polls request a frame, and nothing polls
  while the app is hidden.
- `packages/raft_ui/test/idle_work_test.dart`: helper behaviour and "hidden or TickerMode-off or reduced
  motion means no ticker" for every perpetual raft_ui animation.

## Measuring

`tool/idle-cpu/run.sh <label> [seconds] [scenario,...]` builds `apps/raft_flutter/tool/idle_cpu_lab.dart` as a
Linux profile app (Xvfb when `DISPLAY` is unset) and prints one JSON line per scenario: process CPU %
(`/proc/self/stat`), frames/s, `Priority.idle` admission retries/s, timers/s by creation site. It is a plain
app on purpose: `flutter_test` live bindings schedule a frame after every frame and hide this bug class.
On Android pass the same settings with `--dart-define-from-file` (see the header of the lab file) and build
with `--android-project-arg=raftApplicationIdSuffix=.linkperf` (isolated app id, AGENTS.md).

Focused text fields blink their caret (2 frames/s); that is expected and excluded from the zero-frame rule.
