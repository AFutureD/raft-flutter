# Development workflow

## Prerequisites

- Flutter **3.47.6** / Dart 3.13.5, pinned in `.fvmrc`. Always call Flutter through `tool/flutter`: it looks for `.fvm/flutter_sdk` or `~/flutter-sdks/versions/3.47.6`, honours `RAFT_FLUTTER_BIN`, and refuses any other SDK version. Install with `fvm install && fvm use 3.47.6`.
- Python 3.11+ for the full engineering checks (some tooling uses `hashlib.file_digest`); use UTF-8 mode on Windows (`PYTHONUTF8=1`). Node 24 / pnpm only for the parity and generator tools that read a raft-source checkout.
- Per platform: Android SDK (+ NDK only to regenerate ADPF bindings), the Flutter Linux desktop toolchain, Xcode and CocoaPods for macOS and iOS, or Visual Studio C++ desktop build tools and the Windows SDK for Windows x64.

## Set up

```sh
tool/flutter pub get --enforce-lockfile        # repository root; Dart pub workspace
(cd apps/raft_flutter/tool/bindings_generator && ../../../../tool/flutter pub get --enforce-lockfile)
```

The second command is a separate package that whole-project analysis needs; it needs no NDK (regenerating bindings does, see [Android Performance Hint](android-performance-hint.md)). `tool/check-project` runs it for you.

## Run the app

```sh
cd apps/raft_flutter
../../tool/flutter run -d linux     # Linux; run tool/prepare-media-linux first
../../tool/flutter run -d macos     # macOS (Apple Silicon)
../../tool/flutter run -d <serial>  # Android emulator (see the install warning below)
```

The app talks to the official API `https://api.raft.build` by default; pass `--dart-define=RAFT_ORIGIN=http://localhost:13041` for a local server (or any other origin), or edit the origin on the login screen (see [Self-deploy](deployment.md)). For a local server see [local server stack](local-test-stack.md): `tool/raft-stack start|stop|status|ports` wraps the raft-source `raftdev` launcher and needs a git-ignored `.local/stack.json`.

Never use `flutter run/drive/test/install` on a device that holds the real (formal) app; Flutter may uninstall and reinstall it. Use `tool/android-install` (see [AGENTS.md](../AGENTS.md) and [Android installation](android-installation.md)).

`packages/raft_ui` components each ship an SDK Widget Preview for reviewing themes and states (`brutal-light`, `elegant-light`, `elegant-dark`).

### Windows

Use PowerShell and Python 3. The wrapper also finds FVM's pinned SDK under `%USERPROFILE%\fvm\versions\3.47.6`; `RAFT_FLUTTER_BIN` may point to its `flutter.bat`.

```powershell
python tool/flutter pub get --enforce-lockfile
Set-Location apps/raft_flutter
python ../../tool/flutter build windows --release --no-pub
Start-Process -FilePath "$PWD/build/windows/x64/runner/Release/raft_flutter.exe"
```

CMake downloads Microsoft.WindowsAppSDK 1.7.250310001 from official NuGet and verifies its pinned SHA-256. The bundle includes the bootstrap DLL and Raft notification icons; it still requires Windows App Runtime 1.7 x64, including its notification singleton dependencies. This machine already had that runtime; fresh-machine installation has not been verified. See [Microsoft's deployment guide](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/tutorial-unpackaged-deployment).

If notification clicks offer to find an app for `raft-notification`, the explicit registration step below was verified on this machine. Run it from an **administrator PowerShell**, at the repository root, after building and verifying the complete bundle:

```powershell
$raftExe = (Resolve-Path 'apps/raft_flutter/build/windows/x64/runner/Release/raft_flutter.exe').Path
$raftSha = (Get-FileHash -LiteralPath $raftExe -Algorithm SHA256).Hash
./tool/windows-notification-register.ps1 -ExecutablePath $raftExe -ExpectedSha256 $raftSha
```

The script registers only Raft's machine protocol, validates the bundle/hash and refuses an existing key owned by another application. Repeat after moving the bundle. The app never triggers this administrator step automatically. Use Settings → Notifications → send a test notification to check display and return behavior; cold-click and full Windows acceptance remain pending ([evidence](windows-notifications.md)).

## Test and analyze

```sh
tool/flutter analyze --no-pub
tool/flutter test packages/raft_client/test packages/raft_sync/test packages/raft_ui/test --no-pub
cd apps/raft_flutter && ../../tool/flutter test test/<file>_test.dart --no-pub   # app tests
python3 -m unittest discover -s tool/tests -p 'test_*.py'                         # Python host tests
tool/ds-audit --check                                                            # design-system drift
```

Native flows: `tool/native-linux` (runs `integration_test/workspace_test.dart` on Linux) and `tool/native-test emulator-5580` (Android). Both need an isolated local server and a private fixture identity in the ignored `.local/test-user.json`; never put login data in source, assets or build arguments.

`tool/ds-audit` is an AST-based scan of `apps/raft_flutter/lib` for Material widgets, literal dimensions, fonts, radii and colors. It compares per-file and per-category counts with the checked-in `tool/ds-audit-baseline.json`; `--check` fails if any count grew, `--update-baseline` lowers the baseline, and `// ds-allow: <reason>` marks reviewed platform-only code. Rules: [design-system migration](ds-migration.md).

## Merge gate: `tool/check-project`

`python3 tool/check-project` is the whole-project gate. It records the `tool/source-hash` of the tree, runs `pub get --enforce-lockfile` for the bindings generator, then runs three independent checks **concurrently**: (1) the Python host tests in `tool/tests`, (2) `flutter analyze --no-pub`, and (3) every Dart test of `apps/raft_flutter`, `raft_client`, `raft_sync` and `raft_ui`, split into balanced shards that each run as one `flutter test` process from `apps/raft_flutter`. It fails if the source changed while it ran. It does **not** run `tool/ds-audit`, so run that separately. Run it behind `flock /tmp/raft-flutter-check.lock` so only one gate uses the machine at a time.

- **Sharding.** Test files are assigned longest-first to shards using the per-file seconds of the previous run (`.local/check-durations.json`, falling back to the main checkout's copy, then to file size). The default shard count is one per 3 CPUs not already busy (the 1-minute load average is subtracted), at most 8, with `-j 2..4` test processes per shard. Override with `RAFT_CHECK_SHARDS`, `RAFT_CHECK_JOBS`; `RAFT_CHECK_SHARD_TIMEOUT_MINUTES` (default 60) kills a whole shard that stops producing a result.
- **A shard passes only if** `flutter test` exited 0, its log ends with `All tests passed!`, no test failed, and every file it was given produced a result. A shard that stalls and is killed by the watchdog (or crashes) fails, and the files that never ran are listed by name in `check-summary.txt`.
- **No retries.** A failed or timed-out test fails the gate. Nothing is re-run to hide flakiness; if a test only fails under load, lower `RAFT_CHECK_SHARDS` and fix the test.
- **Per-test timeout.** Plain `test()` cases are bounded by `dart_test.yaml` (60 s). `testWidgets` is bounded by `test/flutter_test_config.dart` in `apps/raft_flutter` and `packages/raft_ui`, which sets the binding's `defaultTestTimeout` to 60 s (`RAFT_TEST_TIMEOUT_SECONDS` overrides). `flutter_test` passes an explicit 10 minute timeout to every `testWidgets`, which silently overrides `dart_test.yaml`, so the config file is required. A test that legitimately needs longer must say so with `timeout: const Timeout(Duration(minutes: 3))` (or `Timeout.factor(2)`) on that test. A hanging test fails after a minute, including a hang in a tear-down. Because every test file now has the binding before its `main` runs, a test file cannot construct its own `AutomatedTestWidgetsFlutterBinding` subclass: use `RaftTestBinding.showShadows()` / `RaftTestBinding.semanticsBuilderFactory` from `test/flutter_test_config.dart`, and set `HttpOverrides.global = null;` in a plain `test()` that talks to a real loopback server (the binding installs flutter_test's always-400 mock client). Awaiting a future in a tear-down that was created in the `testWidgets` FakeAsync zone never completes, because its microtasks are not flushed once the body returns; that was the cause of the hangs fixed by `RaftClient.dispose` (it now waits for session writes only while some are pending).
- **Outputs in `.local/`.** `host-collector-tests.txt`, `bindings-generator-pub-get.txt`, `analyze-all.txt`; `test-shard-N.txt` (expanded log) and `test-shard-N.json` (JSON event stream) per shard; `all-project-tests.txt` (aggregate that ends in `All tests passed!` only when every shard passed); `check-summary.txt` (counts, failed test names, slowest 20 tests); `check-durations.json` (per-file seconds including suite compile time, the slowest 20 tests, and the wall time, used to balance the next run); `engineering-run.json` (`sourceHash`, `completed`, `checks` with one `test-shard-N.txt` entry per shard, `shards`, `failedTests`). The stdout JSON (`passed`, `sourceChanged`, `checks`) is unchanged apart from the extra shard keys.
- **Wall time.** Measured on a 16-CPU shared machine: a green run of 515 test files (4,412 tests) plus analysis takes about 5.5 minutes (4 shards of 4.5 to 5.5 minutes each, analysis and host tests alongside), against 35 to 60 minutes for the former serial run. The slowest single test takes about 15 seconds, so the 60 s per-test bound has wide margin.

## Branches and batches

Work on one branch per task, ideally in its own `git worktree`. While iterating run only the tests, `analyze` and `ds-audit` relevant to the change. A batch of reviewed branches is merged into an integration branch, `tool/check-project` runs once for the batch, and only then does it go to the main line. Conventions for contributors and agents (UI rules, data lifecycle, performance bar) are in [AGENTS.md](../AGENTS.md).
