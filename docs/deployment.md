# Self-deploy

This repository builds the **client**. You need a Raft server for it to talk to; run your own from [raft-source](https://github.com/botiverse/raft-source) (`pnpm install && ./raftdev start`, which needs Node 24, pnpm and Docker; see that repository). The client does not need a server-side change.

## Point the client at your server

- Login screen: the server origin is editable (scheme `http` or `https` and host only, no path, such as `https://raft.example.com`). Prefer HTTPS.
- Compile-time default: `--dart-define=RAFT_ORIGIN=<origin>` (default `https://api.raft.build`, the official API). Related defines: `RAFT_FRONTEND_ORIGIN` (the Web frontend origin used for browser hand-off and content links), `RAFT_DEPLOYMENT_ENV` (`production` default; `staging` and `slockdev` switch the Raft Computer install commands), `RAFT_APP_VERSION` (label shown in settings). Do not pass credentials or test fixtures as defines.
- Android blocks cleartext HTTP except for three development hosts (`network_security_config.xml`); a public deployment must use HTTPS. Android backup is disabled and local state is excluded from cloud and device-transfer backups.
- The `raft:` URL scheme (OAuth callback and content links) is registered on Android, macOS, iOS and in the Linux desktop entry.

## Build release artifacts

Run from `apps/raft_flutter` with `../../tool/flutter` and the pinned SDK. Release builds use `--target=lib/main.dart` (the default) and must not include the test defines used by the native test scripts.

```sh
../../tool/flutter build apk --release --dart-define=RAFT_ORIGIN=https://raft.example.com           # Android universal APK
../../tool/flutter build apk --release --split-per-abi --target-platform android-arm64 --build-number <n>  # ARM64 split APK
../../tool/prepare-media-linux && ../../tool/flutter build linux --release                          # Linux (x86_64 bundle)
../../tool/flutter build macos --release                                                            # macOS app Raft.app (arm64)
```

## Signing and packaging

- **Android**: `android/app/build.gradle.kts` signs release builds with the **debug key** (the project's own TODO). Current artifacts are acceptance builds and are not store-ready. Before distributing, add your own signing config (keep the keystore and passwords outside the repository) and a unique application id; the id is currently `app.raft.raft_flutter`. Updating an installed app needs the same signing key and a higher version code; use `tool/android-install --device <serial> --apk <arm64.apk> --check-only` and then `--launch`, which checks identity, architecture, version and signature and never uninstalls or clears data.
- **Linux**: `tool/build-deliverables` is the local acceptance packager. It requires a passing `tool/check-project` and native runs for the same source hash, then builds the Linux bundle and APK, rewrites ELF RPATHs to be relocatable with a pinned local `patchelf`, checks dependencies, and writes `build/deliverables/raft-flutter-linux-x64.tar.gz`, `raft-flutter-android.apk`, `CHECKSUMS.txt` and `build-manifest.json`. The bundle needs a compatible glibc, GTK and graphics drivers, and `poppler-utils` for PDF preview. An example desktop entry for the `raft:` scheme is in `linux/packaging/`. Media libraries include GPL components; read [Linux media runtime](linux-media-runtime.md) before redistributing.
- **macOS**: sandboxed (entitlements in `macos/Runner/`), local development signing only. Developer ID signing, notarization and DMG/store packaging are not set up ([macOS evidence](macos-evidence.md)).
- **iOS**: no signing team, provisioning, push or release setup; configure signing in Xcode on a Mac. Compilation has never been verified.
- **Windows**: x64 Release builds produce the complete `apps/raft_flutter/build/windows/x64/runner/Release` directory. Keep its DLLs, `data/`, `raft.ico` and `notification_icon.png` together. Windows App Runtime 1.7 x64 is an external runtime requirement; the bundled bootstrap DLL does not include the full runtime. No signed installer or store package is configured. The explicit Raft notification protocol-registration step and fresh-machine limits are documented in [Windows development setup](development.md#windows) and [notification evidence](windows-notifications.md).

Verification of the delivered Android and Linux artifacts (hashes, install and relocation smoke tests, what they do not prove): [release evidence](release-evidence.md).
