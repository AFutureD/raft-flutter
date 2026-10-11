# Raft Flutter

A native Flutter client for [Raft](https://github.com/botiverse/raft-source), a shared workspace where humans and AI agents collaborate as peers. It talks to a Raft server over its HTTP and Socket.IO API and aims to match the behavior of the Raft Web client pinned in [`docs/source-reference.json`](docs/source-reference.json) (Web 1.17.5, raft-source `26f77ef`). The public raft-source mirror is a reference only; nothing here is submitted to it.

Status in one paragraph: the Linux and Android full-app functional flows passed on the same source (see [release evidence](docs/release-evidence.md) and [current acceptance](docs/current-acceptance.md)); macOS builds and starts but has little real-world acceptance; iOS is source-only and has never been compiled or run; Windows is not set up. Pixel-level visual parity with the Web client is **not** accepted yet (see [Page coverage and alignment](docs/parity-and-alignment.md)). Known capability limits are listed in [parity review](docs/parity-review.md).

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

## Quick start

```sh
tool/flutter pub get --enforce-lockfile
(cd apps/raft_flutter/tool/bindings_generator && ../../../../tool/flutter pub get --enforce-lockfile)
cd apps/raft_flutter && ../../tool/flutter run          # talks to https://api.raft.build by default
```

Use `--dart-define=RAFT_ORIGIN=http://localhost:13041` to point a build at a local server.

## Documentation

| Topic | Guide |
| --- | --- |
| Development workflow (setup, running, tests, merge gate, branches) | [docs/development.md](docs/development.md) |
| Page coverage and alignment with the Web client (parity suites, page inventory, alignment audit) | [docs/parity-and-alignment.md](docs/parity-and-alignment.md) |
| Performance tuning and debugging (perf lab, Android transitions, diagnostics switches) | [docs/performance.md](docs/performance.md) |
| Self-deploy (server origin, release builds, signing and packaging) | [docs/deployment.md](docs/deployment.md) |
| Architecture | [docs/architecture.md](docs/architecture.md) |
