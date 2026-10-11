# Raft Flutter

A native Flutter client for [Raft](https://github.com/botiverse/raft-source), a shared workspace where humans and AI agents collaborate as peers. It talks to a Raft server over its HTTP and Socket.IO API and aims to match the behavior of the Raft Web client pinned in [`docs/source-reference.json`](docs/source-reference.json) (Web 1.17.5, raft-source `26f77ef`). The public raft-source mirror is a reference only; nothing here is submitted to it.

Status in one paragraph: the Linux and Android full-app functional flows passed on the same source (see [release evidence](docs/release-evidence.md) and [current acceptance](docs/current-acceptance.md)); macOS builds and starts but has little real-world acceptance; iOS is source-only and has never been compiled or run; Windows is not set up. Pixel-level visual parity with the Web client is **not** accepted yet (see [Page coverage and alignment](#page-coverage-and-alignment)). Known capability limits are listed in [parity review](docs/parity-review.md).

## Supported platforms

| Platform | Status | Minimum OS / architecture | Build command (run in `apps/raft_flutter`) |
| --- | --- | --- | --- |
| Android | Verified: full-app flows on a real build and an emulator, background notification fallback, released-APK smoke test | `minSdk` = max(Flutter default, 24), `compileSdk`/`targetSdk` 37; ARM64 for devices (`tool/android-install` refuses other ABIs); x86_64 emulator used for functional checks only | `../../tool/flutter build apk --release` |
| Linux | Verified: full-app flows on X11/GTK, relocated-archive smoke test | x86_64 only; the pinned media runtime (`tool/prepare-media-linux`) supports Ubuntu amd64 only. Wayland and other distributions are not verified | `../../tool/flutter build linux --release` after `tool/prepare-media-linux` |
| macOS | Builds, signs and starts to the login screen; login, Keychain, upload, notifications and media are configured but not accepted on a Mac ([evidence](docs/macos-evidence.md)) | macOS 12+, Apple Silicon (ARM64) only; x86_64 is excluded in the Xcode project and Pods | `../../tool/flutter build macos --release` |
| iOS | **Source only.** The host in `apps/raft_flutter/ios` exists (background fetch, Keychain, UIScene) but has not been compiled or run; no `Podfile` is checked in, no iOS media_kit libs are in `pubspec.yaml`, signing is unset | Xcode project deployment target 15.0 (`ios/Flutter/AppFrameworkInfo.plist` says 14.0 and `docs/background-inbox.md` says 14+; the project setting is the effective one) | `../../tool/flutter build ios` on a Mac with Xcode (untested) |
| Windows | **Not supported.** There is no `apps/raft_flutter/windows` host and `pubspec.yaml` describes the app as "Linux, Android and macOS". Nothing has been built or verified | - | - |

Platform boundaries worth knowing:

- Android and iOS refresh unread Activity periodically (WorkManager / BGAppRefresh) and show local notifications. FCM, APNs and UnifiedPush are not registered, and the server's desktop message push is not wired up. See [background inbox](docs/background-inbox.md).
- In-app PDF preview: Android uses `PdfRenderer`, Linux uses the system `poppler-utils`; macOS falls back to download. Native sharing is Android only.
- Independent native workspace windows are not implemented.
- Widget Preview never substitutes for platform tests (accessibility, IME, lifecycle, notifications).

## Project structure

| Path | What it is |
| --- | --- |
| `apps/raft_flutter` | The product app: `lib/` (features, `lib/platform` native adapters such as secure session storage, file picking, notifications, sharing), host folders `android/ ios/ linux/ macos/`, `test/` (about 300 widget/unit test files, plus `test/parity/` for the visual parity provider), `integration_test/` (native flows, `perf_lab_test.dart`), `test_driver/` (`flutter drive` drivers for the perf lab), `tool/bindings_generator` (Android Performance Hint FFI bindings, separate package), `third_party/android` (NDK headers) |
| `packages/raft_ui` | Design system: generated tokens (`lib/src/tokens/*.g.dart`), component recipes (`lib/src/recipes/`), components and standalone SDK Widget Previews. No API, database or OS-service dependencies |
| `packages/raft_client` | Pure Dart client: human auth, HTTP, Socket.IO, secure-storage interface, typed errors |
| `packages/raft_sync` | Sync reducers (seq/epoch/dedupe/gap repair, read state) ported from the Web client |
| `packages/flutter_chat_ui` | Vendored chat UI package (see its `UPSTREAM.json`) |
| `tool/` | Pinned-SDK wrapper `tool/flutter`, gates (`check-project`, `ds-audit`, `source-hash`), parity (`parity`, `parity-ext/`, `alignment-audit.py`), performance (`performance/`), packaging (`prepare-media-linux`, `build-deliverables`, `android-install`), generators (`gen-tokens`, `gen-glyphs`, `recipes/`, `gen-macos-icon`), local server stack (`raft-stack`), `tests/` (Python host tests) |
| `docs/` | Architecture, evidence and audit documents. Start with [architecture](docs/architecture.md); the rest are indexed by topic below |
| `.github/workflows/performance.yml` | Message-performance CI (Python guards on hosted runners; Linux profile run on a self-hosted runner) |

Generated, do not edit by hand: `packages/raft_ui/lib/src/tokens/*.g.dart` (`tool/gen-tokens`, from vendored raft-ui 0.5.27 CSS, see [design tokens](docs/design-tokens.md)), `packages/raft_ui/lib/src/recipes/*.g.dart` (`tool/recipes/run`, see [component recipes](docs/component-recipes.md)), glyph geometry (`tool/gen-glyphs`), Android ADPF bindings. Private acceptance data lives in the git-ignored `.local/`; `build/` is also ignored.

Design-system rules: tokens and recipes are shared, sizes come from them rather than literals in app code ([design dimensions](docs/design-dimensions.md), [component acceptance](docs/widget-acceptance.md)). `tool/ds-audit` enforces this on `apps/raft_flutter/lib`. Persistence: the login session uses the system secure store; the workspace cache is Drift SQLite.

More docs: [feature parity matrix](docs/feature-parity.csv) · [local server stack](docs/local-test-stack.md) · [mobile navigation](docs/mobile-navigation.md) · [attachments](docs/attachment-evidence.md) · [sharing](docs/sharing-evidence.md) · [notifications and content links](docs/notification-content-evidence.md) · [Linux media runtime](docs/linux-media-runtime.md) · [third-party notices](THIRD_PARTY_NOTICES.md).

## Development workflow

### Prerequisites

- Flutter **3.47.6** / Dart 3.13.5, pinned in `.fvmrc`. Always call Flutter through `tool/flutter`: it looks for `.fvm/flutter_sdk` or `~/flutter-sdks/versions/3.47.6`, honours `RAFT_FLUTTER_BIN`, and refuses any other SDK version. Install with `fvm install && fvm use 3.47.6`.
- Python 3 for the `tool/` scripts. Node 24 / pnpm only for the parity and generator tools that read a raft-source checkout.
- Per platform: Android SDK (+ NDK only to regenerate ADPF bindings), the Flutter Linux desktop toolchain, Xcode and CocoaPods for macOS and iOS.

### Set up

```sh
tool/flutter pub get --enforce-lockfile        # repository root; Dart pub workspace
(cd apps/raft_flutter/tool/bindings_generator && ../../../../tool/flutter pub get --enforce-lockfile)
```

The second command is a separate package that whole-project analysis needs; it needs no NDK (regenerating bindings does, see [Android Performance Hint](docs/android-performance-hint.md)). `tool/check-project` runs it for you.

### Run the app

```sh
cd apps/raft_flutter
../../tool/flutter run -d linux     # Linux; run tool/prepare-media-linux first
../../tool/flutter run -d macos     # macOS (Apple Silicon)
../../tool/flutter run -d <serial>  # Android emulator (see the install warning below)
```

The app talks to the official API `https://api.raft.build` by default; pass `--dart-define=RAFT_ORIGIN=http://localhost:13041` for a local server (or any other origin), or edit the origin on the login screen (see [Self-deploy](#self-deploy)). For a local server see [local server stack](docs/local-test-stack.md): `tool/raft-stack start|stop|status|ports` wraps the raft-source `raftdev` launcher and needs a git-ignored `.local/stack.json`.

Never use `flutter run/drive/test/install` on a device that holds the real (formal) app; Flutter may uninstall and reinstall it. Use `tool/android-install` (see [AGENTS.md](AGENTS.md) and [Android installation](docs/android-installation.md)).

`packages/raft_ui` components each ship an SDK Widget Preview for reviewing themes and states (`brutal-light`, `elegant-light`, `elegant-dark`).

### Test and analyze

```sh
tool/flutter analyze --no-pub
tool/flutter test packages/raft_client/test packages/raft_sync/test packages/raft_ui/test --no-pub
cd apps/raft_flutter && ../../tool/flutter test test/<file>_test.dart --no-pub   # app tests
python3 -m unittest discover -s tool/tests -p 'test_*.py'                         # Python host tests
tool/ds-audit --check                                                            # design-system drift
```

Native flows: `tool/native-linux` (runs `integration_test/workspace_test.dart` on Linux) and `tool/native-test emulator-5580` (Android). Both need an isolated local server and a private fixture identity in the ignored `.local/test-user.json`; never put login data in source, assets or build arguments.

`tool/ds-audit` is an AST-based scan of `apps/raft_flutter/lib` for Material widgets, literal dimensions, fonts, radii and colors. It compares per-file and per-category counts with the checked-in `tool/ds-audit-baseline.json`; `--check` fails if any count grew, `--update-baseline` lowers the baseline, and `// ds-allow: <reason>` marks reviewed platform-only code. Rules: [design-system migration](docs/ds-migration.md).

### Merge gate: `tool/check-project`

`python3 tool/check-project` is the whole-project gate. It records the `tool/source-hash` of the tree, then runs (1) the Python host tests in `tool/tests`, (2) `pub get --enforce-lockfile` for the bindings generator, (3) all Dart tests of `apps/raft_flutter` plus `raft_client`, `raft_sync`, `raft_ui`, and (4) `flutter analyze --no-pub`. It writes logs and `.local/engineering-run.json` and fails if the source changed while it ran. It is slow; it does **not** run `tool/ds-audit`, so run that separately.

### Branches and batches

Work on one branch per task, ideally in its own `git worktree`. While iterating run only the tests, `analyze` and `ds-audit` relevant to the change. A batch of reviewed branches is merged into an integration branch, `tool/check-project` runs once for the batch, and only then does it go to the main line. Conventions for contributors and agents (UI rules, data lifecycle, performance bar) are in [AGENTS.md](AGENTS.md).

## Page coverage and alignment

Visual parity is measured against the real Web client, rendered from a raft-source checkout, using raft-source's own visual-testing tool. Flutter plugs in as a provider and the official CLI does the diff and scoring.

Requirements (the scripts have maintainer-machine defaults that you must override): a read-only raft-source checkout (`PARITY_RAFT_SOURCE`), a text file listing absolute paths of Node 24 and pnpm binaries (`PARITY_TOOLCHAIN_PATHS`; `tool/raft-stack` can create one), and for publishing a reports directory (`PARITY_REPORTS_ROOT`) and base URL (`PARITY_BASE_URL`). The raft-source checkout is never edited.

### Official suite: `tool/parity`

```sh
tool/parity run [--cases <id|glob>[,...]] [--refresh-react] [--shards N]
tool/parity summary
tool/parity publish [--no-verify]
```

`run` captures the Web side (cached unless `--refresh-react`), captures Flutter through `apps/raft_flutter/test/parity`, runs the official diff and site generation, and writes everything to `build/parity/` (`PARITY_OUT`), including `summary.json`. It covers the official 99 phone cases. Details and history: [parity](docs/parity.md).

### Extension suite: `tool/parity-ext/run`

The extension suite adds cases for pages the official set lacks (ids `components.<area>.*`, several hundred brutal-light cases).

```sh
export PARITY_EXT_WEB_PORT=4xxx                       # unique per run; default 4396
tool/parity-ext/run run --cases 'components.<area>.*' # comma list / globs; --refresh-react to recapture
tool/parity-ext/run summary
```

- Cases are generated on every run by the builders listed in `tool/parity-ext/builders.txt` into `build/parity-ext/cases.json` (never committed); Flutter-side cases live in `apps/raft_flutter/test/parity/cases/`. Adding or fixing a surface: [extension quickstart](docs/parity-ext-quickstart.md).
- Theme sampling: `brutal-light` (the default theme) runs every case; `elegant-light` and `elegant-dark` run one or two cases per surface (rule in `tool/parity-ext/sampling.py`). `--cases` only sees the sampled set; `PARITY_EXT_ALL_THEMES=1` runs everything, `PARITY_EXT_ALL_DARK=1` keeps every elegant-dark case.
- Web captures are cached across worktrees (`PARITY_EXT_CACHE` overrides the location) and recaptured only when their inputs change.
- Output goes to `build/parity-ext/` (`PARITY_EXT_OUT`): `summary.md` (per-case and per-area tables) and `site/index.html`.

### What "pass" means

- **Official pass**: the official diff status is `same`, `pass` or `basic-pass` (pixel-perfect similarity above 96%); "strict" pass is above 99%.
- **Geometry pass** (the extension suite's target): the "non-text" similarity in `summary.md` is at least 99.5%, counting pixels classified as text glyph anti-aliasing as matching. `tool/parity-ext/analyze-diffs.py --cases <glob> --viz DIR` shows where the remaining difference is (fill, hairline, corner, offset, text, other).
- Text anti-aliasing differences between Chromium and Skia are ignored; fix layout, color, spacing, borders, radii and whole-pixel glyph positions instead.
- A case existing means coverage, not that Flutter passes it.

### Page inventory

[`docs/parity-page-inventory.md`](docs/parity-page-inventory.md) lists every Web page, modal and state with desktop/phone coverage (`ok`, `partial`, `wip`, `MISSING`, `n/a`, `excluded`) and a priority. It is generated from rows in `tool/parity-ext/inventory.py`: edit the rows, run `python3 tool/parity-ext/inventory.py` to regenerate, and `python3 tool/parity-ext/inventory.py --check` to verify (the unit tests fail on a stale document). Note that running it without `--check` rewrites the document.

### Alignment audit

`tool/alignment-audit.py` compares strong vertical edges and text start columns between the Web and Flutter captures of each case and reports offsets in CSS px:

```sh
tool/alignment-audit.py run --root build/parity --root build/parity-ext [--cases GLOB] [--out DIR]
tool/alignment-audit.py show --root build/parity-ext --case <id> --out overlay.png
tool/alignment-audit.py overlays --out DIR     # overlays of every flagged case
tool/alignment-audit.py selftest
```

`--root` is a parity output directory. Results go to `--out` (default `.local/alignment/audit`) and never into the root. An offset within 0.75 CSS px counts as aligned; up to 12 px is reported as an offset; beyond that is a layout difference. A near-miss pass flags mixed insets and tells you whether the Web page has them too. Method, results and the open list: [alignment audit](docs/alignment-audit.md).

### Where reports land

`build/parity/` and `build/parity-ext/` locally. `tool/parity publish` and `tool/parity-ext/run publish` copy the site into `$PARITY_REPORTS_ROOT/raft_flutter_parity/<stamp>` (extension: `raft_flutter_parity_ext/`) with a `latest` link and, unless `--no-verify`, check the served URLs. Do not publish from a task branch; the lead publishes per batch. Functional evidence reports go through `tool/publish-report`.

## Performance tuning

Goal: every frame's UI and raster work within 8.33 ms (120 Hz budget); the current Linux gate is no frame over 16.7 ms and no stutter. Scrolling, opening and resizing smoothness has priority over pixel parity ([AGENTS.md](AGENTS.md)).

### Perf lab

`apps/raft_flutter/integration_test/perf_lab_test.dart` runs fixed scenarios (chat scrolling and row mounting, transitions, mobile `nav-*` flows through the production `RaftApp` with background data replay) in **profile mode** with synthetic fixtures; no real account is used. `tool/performance/lab.py` drives it:

```sh
python3 tool/performance/lab.py run --out .local/performance/lab/<name> [--themes brutal-light,elegant-light] [--scenarios 'steady-scroll,mount-*'] [--semantics platform|on|off] [--no-trace]
python3 tool/performance/lab.py compare .local/performance/lab/<before> .local/performance/lab/<after>
python3 tool/performance/lab.py summarize .local/performance/lab/<name>
```

The runner refuses to start on a noisy host (1-minute load above 0.35 x CPUs; `--allow-noisy` overrides and labels the run NOISY), and `compare` flags regressions in UI/raster p90/p99, over-budget frame counts and stutter. `--device macos` runs the lab on a Mac. Linux needs an X11 session (`DISPLAY`, `GDK_BACKEND=x11`). Scenarios, metrics, outputs and baselines: [performance lab](docs/performance-lab.md). Other probes: `tool/performance/run.py` (message-scroll benchmark P01 used by CI, [message performance](docs/message-performance.md)), `capture_sections.py`, `activity_preview.dart`, `cache_codec_benchmark.dart`.

### Android: page transitions on a device

```sh
python3 tool/performance/android_transitions.py --device <adb serial> \
  --out .local/performance/android-transitions/<run> [--themes brutal-light] [--scenarios nav-home-channel,nav-tabs]
```

This builds `integration_test/perf_lab_test.dart` as an ARM64 profile APK with the Gradle property `raftApplicationIdSuffix=.linkperf`, so its application id is `app.raft.raft_flutter.linkperf` and it never touches the real app. `lab.py` accepts only that package, forces `--keep-app-running` (no automatic uninstall) and fails if the real app's install time or data directories change. Do not invent other ways to run profile tests on a device. Pass `--abi x64 --device emulator-5580` for a functional check on an emulator only; its timings are not evidence for phones. Compare two runs with `lab.py compare <before>/run <after>/run`. See [Android transitions](docs/android-transitions.md) and [Android installation](docs/android-installation.md).

### Switches and probes

- `RAFT_ANDROID_PERFORMANCE_HINT` (`--dart-define`, default `true`): the Android Performance Hint (ADPF) session for the Dart UI thread; `false` disables it. Debug and non-Android builds never load it. To judge it, build two APKs from the same source (`true`/`false`; `android_transitions.py --define RAFT_ANDROID_PERFORMANCE_HINT=false`) and compare with the isolated `.linkperf` app. A run with zero reported sessions proves nothing. No real-phone gain is established yet ([Android Performance Hint](docs/android-performance-hint.md)).
- `RAFT_ROUTE_FRAME_DIAGNOSTICS=true`: off by default; logs per-route frame costs (route categories only, no IDs or content) for real-device investigations; collect with `tool/performance/route_probe.py` ([route performance probe](docs/route-performance-probe.md)).
- Profile builds only: debug-mode numbers are not meaningful. Compare identical fixtures, engine, renderer, view size and semantics mode.

Audits and findings: [Android performance audit](docs/android-performance-audit.md), [mobile route investigation](docs/mobile-route-performance-investigation.md), [macOS investigation](docs/mac-performance-investigation.md), [message performance](docs/message-performance.md).

## Self-deploy

This repository builds the **client**. You need a Raft server for it to talk to; run your own from [raft-source](https://github.com/botiverse/raft-source) (`pnpm install && ./raftdev start`, which needs Node 24, pnpm and Docker; see that repository). The client does not need a server-side change.

### Point the client at your server

- Login screen: the server origin is editable (scheme `http` or `https` and host only, no path, such as `https://raft.example.com`). Prefer HTTPS.
- Compile-time default: `--dart-define=RAFT_ORIGIN=<origin>` (default `https://api.raft.build`, the official API). Related defines: `RAFT_FRONTEND_ORIGIN` (the Web frontend origin used for browser hand-off and content links), `RAFT_DEPLOYMENT_ENV` (`production` default; `staging` and `slockdev` switch the Raft Computer install commands), `RAFT_APP_VERSION` (label shown in settings). Do not pass credentials or test fixtures as defines.
- Android blocks cleartext HTTP except for three development hosts (`network_security_config.xml`); a public deployment must use HTTPS. Android backup is disabled and local state is excluded from cloud and device-transfer backups.
- The `raft:` URL scheme (OAuth callback and content links) is registered on Android, macOS, iOS and in the Linux desktop entry.

### Build release artifacts

Run from `apps/raft_flutter` with `../../tool/flutter` and the pinned SDK. Release builds use `--target=lib/main.dart` (the default) and must not include the test defines used by the native test scripts.

```sh
../../tool/flutter build apk --release --dart-define=RAFT_ORIGIN=https://raft.example.com           # Android universal APK
../../tool/flutter build apk --release --split-per-abi --target-platform android-arm64 --build-number <n>  # ARM64 split APK
../../tool/prepare-media-linux && ../../tool/flutter build linux --release                          # Linux (x86_64 bundle)
../../tool/flutter build macos --release                                                            # macOS app Raft.app (arm64)
```

### Signing and packaging

- **Android**: `android/app/build.gradle.kts` signs release builds with the **debug key** (the project's own TODO). Current artifacts are acceptance builds and are not store-ready. Before distributing, add your own signing config (keep the keystore and passwords outside the repository) and a unique application id; the id is currently `app.raft.raft_flutter`. Updating an installed app needs the same signing key and a higher version code; use `tool/android-install --device <serial> --apk <arm64.apk> --check-only` and then `--launch`, which checks identity, architecture, version and signature and never uninstalls or clears data.
- **Linux**: `tool/build-deliverables` is the local acceptance packager. It requires a passing `tool/check-project` and native runs for the same source hash, then builds the Linux bundle and APK, rewrites ELF RPATHs to be relocatable with a pinned local `patchelf`, checks dependencies, and writes `build/deliverables/raft-flutter-linux-x64.tar.gz`, `raft-flutter-android.apk`, `CHECKSUMS.txt` and `build-manifest.json`. The bundle needs a compatible glibc, GTK and graphics drivers, and `poppler-utils` for PDF preview. An example desktop entry for the `raft:` scheme is in `linux/packaging/`. Media libraries include GPL components; read [Linux media runtime](docs/linux-media-runtime.md) before redistributing.
- **macOS**: sandboxed (entitlements in `macos/Runner/`), local development signing only. Developer ID signing, notarization and DMG/store packaging are not set up ([macOS evidence](docs/macos-evidence.md)).
- **iOS**: no signing team, provisioning, push or release setup; configure signing in Xcode on a Mac. Compilation has never been verified.
- **Windows**: no host and no packaging.

Verification of the delivered Android and Linux artifacts (hashes, install and relocation smoke tests, what they do not prove): [release evidence](docs/release-evidence.md).
