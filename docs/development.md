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

`tool/ds-audit` is an AST-based scan of `apps/raft_flutter/lib` for Material widgets, literal dimensions, fonts, radii and colors. It compares per-file and per-category counts with the checked-in `tool/ds-audit-baseline.json`; `--check` fails if any count grew and passes (with a "baseline can lower" note) when counts went down, so feature branches never edit the baseline; the integration owner runs `--update-baseline` after merges and commits it separately; and `// ds-allow: <reason>` marks reviewed platform-only code. Rules: [design-system migration](ds-migration.md).

## Merge gate: `tool/check-project`

`python3 tool/check-project` is the whole-project gate. It records the `tool/source-hash` of the tree, then runs (1) the Python host tests in `tool/tests`, (2) `pub get --enforce-lockfile` for the bindings generator, (3) all Dart tests of `apps/raft_flutter` plus `raft_client`, `raft_sync`, `raft_ui`, and (4) `flutter analyze --no-pub`. It writes logs and `.local/engineering-run.json` and fails if the source changed while it ran. It is slow; it does **not** run `tool/ds-audit`, so run that separately.

## Branches and batches

Work on one branch per task, ideally in its own `git worktree`. While iterating run only the tests, `analyze` and `ds-audit` relevant to the change. A batch of reviewed branches is merged into an integration branch, `tool/check-project` runs once for the batch, and only then does it go to the main line. Conventions for contributors and agents (UI rules, data lifecycle, performance bar) are in [AGENTS.md](../AGENTS.md).
