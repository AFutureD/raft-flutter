# In-app auto-update (macOS and Windows)

macOS installs updates with **Sparkle 2**, Windows with **WinSparkle 0.9**.
Linux, Android and iOS have no in-app updater (see the end). Dart reaches both
through one small local plugin, `packages/raft_updater` (`app.raft/updater`
method channel), and one facade:

```dart
import 'package:raft_updater/raft_updater.dart';

AppUpdater.instance.available;          // bool: can update in place here
AppUpdater.instance.availability;       // ValueListenable<bool>
await AppUpdater.instance.checkAndInstall();
// -> AppUpdateOutcome.started          native Sparkle/WinSparkle UI took over
//    AppUpdateOutcome.openedReleasePage in-place update unavailable; browser opened
//    AppUpdateOutcome.failed           neither worked
```

This is separate from the lightweight update check (`build-manifest-<platform>-<arch>.json`
`buildNumber` comparison, which drives the red dot). The dot decides *when* to
show an update; on macOS/Windows its button calls `checkAndInstall()`, elsewhere
(or when `available` is false) it opens the release page. The updater does no
scheduled or startup checks and never prompts by itself.

## Decision: why a local plugin and not `auto_updater`

The `auto_updater` plugin (leanflutter 1.0.0, Oct 2024) was evaluated and not used:

- Its Windows half bundles **WinSparkle 0.8.1, which has no EdDSA**. The Sparkle
  signing key is ed25519, so updates could not be verified. 0.9.0 added it.
- Its macOS half is CocoaPods-only (unpinned `Sparkle` pod, a hand-edited
  `Podfile.lock` would be needed) while this app builds plugins with Swift
  Package Manager, starts the updater unconditionally at launch, and has no way
  to say "this build has no key".
- Neither half can report "unavailable", reads the key from the right place, or
  closes the app for the installer cleanly.

`packages/raft_updater` is ~150 lines of native code per platform on the same
frameworks: Swift + Sparkle 2.10.0 (Swift package, pinned exact, podspec
fallback) and C++ + WinSparkle 0.9.4 (downloaded by CMake, pinned by SHA-256).

## Feeds

| Platform | Feed (baked into the app) | Archive Sparkle fetches |
| --- | --- | --- |
| macOS ARM64 | `https://github.com/kevinzhow/raft-flutter/releases/latest/download/appcast-macos.xml` | the existing `raft-flutter-<tag>-macos-arm64.zip` |
| Windows x64 | `https://github.com/kevinzhow/raft-flutter/releases/latest/download/appcast-windows.xml` | `raft-flutter-<tag>-windows-x64-setup.exe` (new) |

`sparkle:version` is the **build number** (`GITHUB_RUN_NUMBER`, equals
`CFBundleVersion` on macOS and the `RAFT_APP_BUILD_NUMBER` define on Windows),
`sparkle:shortVersionString` the app version. Enclosure URL is the tagged release
asset; `length` and `sparkle:edSignature` come from the exact published bytes.
Windows enclosures also carry `sparkle:os="windows-x64"` and
`sparkle:installerArguments="/SILENT /SP- /NOICONS /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS"`.
`tool/appcast.py` renders them; appcast bytes are deterministic (the date is the
commit date), so publisher retries stay idempotent.

`releases/latest` ignores prereleases and drafts. Each platform publishes
independently, so for a short time (or permanently, if a platform job fails) the
latest release may lack its `appcast-<platform>.xml`; clients then get a 404, see
"no update" and retry the next time the user presses the button. Nothing is
overwritten to repair that: fix and rerun the failed publisher, or cut a new tag.

## Keys and CI (names are fixed)

| Name | Kind | Used by |
| --- | --- | --- |
| `SPARKLE_ED_PUBLIC_KEY` | Actions **variable** (public) | build jobs: macOS Info.plist `SUPublicEDKey`; Windows `--dart-define=RAFT_SPARKLE_ED_PUBLIC_KEY` -> `win_sparkle_set_eddsa_public_key` |
| `SPARKLE_ED_PRIVATE_KEY` | Actions **secret** | the tag-only publish job only, to sign the appcast enclosure |

Flow (`tool/release.py`):

1. **Build** (read-only token, no secret). `appcast.read_public_key` validates the
   variable (base64, a real 32-byte Ed25519 point) and stops the build on garbage.
   Non-empty -> `--dart-define=RAFT_AUTO_UPDATE=true`, plus the key define on
   Windows; macOS packaging writes `SUPublicEDKey` into Info.plist before signing.
   **Empty -> auto-update off**: no key in the bundle, `AppUpdater.available` is
   false, buttons open the release page. The receipt records `autoUpdate`.
2. **Publish** (tag push only). Reads `SPARKLE_ED_PRIVATE_KEY` from the environment
   (never argv, never logged; GitHub also masks it), derives its public key and
   refuses to publish if it differs from the key built into the app, signs the
   archive with a stdlib-only Ed25519 (RFC 8032 vectors and the `cryptography`
   library cross-check it in tests) and uploads `appcast-<platform>.xml` with the
   other assets. A build that embeds a key but finds no secret fails loudly
   instead of shipping an app whose feed 404s.
3. The Windows build also produces the Inno Setup installer
   (`packaging/windows/raft.iss`, `tool/windows_installer.py`) as an extra
   artifact listed in the receipt, checksum file and manifest.

Pull requests and manual runs build with the variable but never publish and never
receive the secret.

### Generating or rotating the key (Kevin; commands only)

Done once already. On a Mac, with Sparkle's tools from
`https://github.com/sparkle-project/Sparkle/releases` (`Sparkle-2.10.0.tar.xz`, `bin/`):

```sh
./bin/generate_keys                         # new key in the login keychain; prints the public key
./bin/generate_keys -p                      # print the public key again
./bin/generate_keys -x sparkle_private.txt  # export the private key (base64 of the 32-byte seed)
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private.txt
gh variable set SPARKLE_ED_PUBLIC_KEY --body '<public key from generate_keys>'
rm -P sparkle_private.txt                   # keep only the keychain copy / your password manager
```

The same pair serves macOS and Windows (identical format). Only the 32-byte seed
export is supported; a legacy 96-byte key is rejected with a clear message.
**Rotation is not seamless**: an installed app only accepts updates signed by the
public key it shipped with (Sparkle checks the *old* key and, with no Apple
Developer ID, there is no second path). After changing the pair, existing installs
cannot update themselves and must reinstall once. If staged rotation is ever
needed, ship one release signed with the old key that already embeds the new
public key (needs a temporary publish override; not implemented).

Never commit a key. Local rehearsals use a throwaway pair:
`python3 tool/appcast.py keygen --out "$(mktemp -d)"`.

## macOS (Sparkle 2) in depth

Sandbox. The app is sandboxed, so Sparkle must install through its
`Installer.xpc` launcher service (`SUEnableInstallerLauncherService = YES` in
`Info.plist`) and the app needs the two mach-lookup names from
[Sparkle's sandboxing guide](https://sparkle-project.org/documentation/sandboxing/):
`app.raft.raftFlutter-spks` and `app.raft.raftFlutter-spki` under
`com.apple.security.temporary-exception.mach-lookup.global-name` in
`Release.entitlements` and `DebugProfile.entitlements`. They are literal strings,
not `$(PRODUCT_BUNDLE_IDENTIFIER)`: `codesign --entitlements` does not expand
build variables. `SUEnableDownloaderService` stays off because the app already
has `com.apple.security.network.client`. A temporary exception rules out the Mac
App Store, which is not a target.

Ad-hoc signing (no Developer ID, not notarized). From Sparkle's source
(`SUUpdateValidator`):

- The update is accepted when the archive's **EdDSA signature validates against the
  public key of the running (old) app**. Apple code-signing continuity is only an
  alternative path and cannot apply to ad-hoc signatures (designated requirement
  is a `cdhash`, different every build). Hence `SUPublicEDKey` is mandatory.
- If the update bundle is code signed (ad-hoc counts), its signature must be valid;
  removing a signature is rejected. Our packaging re-seals the whole app ad-hoc.
- Library validation is off: we never sign with `-o runtime`, so ad-hoc Sparkle
  loads into an ad-hoc app. **Do not add Hardened Runtime** without a real
  identity (Sparkle documents that ad-hoc + library validation cannot load it).
- Gatekeeper/quarantine: Sparkle downloads with its own session and its file
  manager strips `com.apple.quarantine` from the extracted update
  (`SUFileManager`), so the replaced app should not trigger "Open Anyway" again.
  Only the first manual install from the browser is quarantined.
- The replaced app must be where the user can write, normally `/Applications`
  (Sparkle asks for an administrator password if not). An app still sitting in
  Downloads or running from App Translocation cannot be updated: the checklist
  tells testers to move it first and `READ-ME-FIRST.txt` says so.
- **Largest risk: Keychain.** Each update has a new ad-hoc `cdhash`, so macOS may
  re-prompt for keychain access to the legacy-keychain session item created by the
  previous build (see [macos-evidence.md](macos-evidence.md); Data Protection
  Keychain needs a real team identity, unavailable here). If the user denies, the
  stored session is unreadable and they log in again. A stable signing identity
  (Developer ID, or at least a stable self-signed certificate) removes this and
  also gives Sparkle a second trust path. Treat auto-update as functional for
  ad-hoc but **not seamless** until that is decided.

Archive. Sparkle accepts `.zip`. Our ZIP is `ditto -c -k --keepParent` of a staged
folder holding `Raft.app` plus docs and `READ-ME-FIRST.txt`. Sparkle's installer
enumerates the extracted folder recursively and picks the app matching the running
app's bundle name (`Autoupdate/SUInstaller.m`, "Search subdirectories for the
application"), so this layout should work; confirm it on a Mac. If it does not,
publish a ZIP that contains only `Raft.app` for Sparkle.

Packaging (`tool/macos_release.py`). Sparkle.framework carries nested bundles the
old inventory rejected. They are now allowed only inside
`Contents/Frameworks/Sparkle.framework` (`Installer.xpc`, `Downloader.xpc`,
`Updater.app`), signed ad-hoc deepest-first as bundles (XPC services with
`--preserve-metadata=entitlements`), then the framework, then the app with
`Release.entitlements`. `verify` additionally checks: `SUPublicEDKey` equals the
release key (or is absent when the build has none), the launcher-service flag,
`Installer.xpc` present, nested bundle signatures.

### What CodexMac must verify on a real Mac

Unit tests here mock `codesign`/`ditto`; none of this has run on macOS.

1. `tool/flutter build macos --release` resolves Sparkle 2.10.0 through SwiftPM
   and `Raft.app/Contents/Frameworks/Sparkle.framework` exists (with
   `Versions/B/XPCServices/Installer.xpc`). If Xcode does not embed the xcframework
   transitively through `FlutterGeneratedPluginSwiftPackage`, add Sparkle to the
   Runner target's embedded frameworks (or disable SPM for this plugin so the
   podspec path runs, then commit `Podfile.lock` from `pod install` with CocoaPods 1.16.2).
2. `python3 tool/release.py build macos` with `SPARKLE_ED_PUBLIC_KEY=<throwaway
   public key>` passes its own verification; `codesign --verify --deep --strict`
   passes; `codesign -d --entitlements :- Raft.app` shows the `-spks`/`-spki` names;
   `plutil -p Raft.app/Contents/Info.plist` shows `SUPublicEDKey`,
   `SUEnableInstallerLauncherService`. Without the variable: no `SUPublicEDKey`.
3. Keyless build: app launches, `AppUpdater.instance.available == false`, button
   opens the release page, no Sparkle dialog, no console errors about Sparkle.
4. Rehearsal with a throwaway key: install build N (`/Applications`), build N+1
   (higher build number) with the same key, write `appcast.xml` with
   `python3 tool/appcast.py sign ... --url <https URL of the N+1 zip>`, point the old
   build at it (`--dart-define=RAFT_UPDATE_FEED_URL=...`; use HTTPS, or loopback
   `http://127.0.0.1` with a temporary `NSAllowsLocalNetworking`), press the
   button: Sparkle offers N+1, downloads, verifies, quits, replaces, relaunches
   as N+1. Check Console for `Sparkle` / `Installer` / `spks` errors; a sandbox
   denial for `mach-lookup` means the entitlement names are wrong.
5. Negative: tamper one byte of the archive, or sign with a different key: Sparkle
   must refuse ("improperly signed"). Appcast with a lower `sparkle:version`: "up to date".
6. After the update: Gatekeeper does not prompt again; `spctl -a -vv` result is
   unchanged from a fresh install; `xattr -l Raft.app` has no `com.apple.quarantine`.
7. Keychain: log in on N, update to N+1, record whether macOS prompts for keychain
   access and whether denying it logs the user out (the risk above).
8. Running from `~/Downloads` or from the extracted ZIP folder: the failure must
   be understandable, and the release-page fallback must be reachable.
9. Confirm the zip layout is accepted (see Archive) and that the ZIP still opens
   normally for first-time users.

## Windows (WinSparkle) in depth

WinSparkle downloads an **installer** (`.exe` / `.msi`) and runs it; it never unpacks
a ZIP. The portable ZIP stays for people who want it, and the minimal mature
addition is an **Inno Setup** per-user installer (`packaging/windows/raft.iss`):

- `PrivilegesRequired=lowest`, installs to `%LOCALAPPDATA%\Programs\Raft`: silent
  updates need no UAC prompt and no administrator.
- Fixed `AppId`, so each installer upgrades the previous install in place.
- WinSparkle starts it silently; `CloseApplications=yes` plus WinSparkle's own
  shutdown callback (the plugin posts `WM_CLOSE` to the main window) let it replace
  files; the `[Run]` entry (no `skipifsilent`) relaunches Raft afterwards.
- Unsigned (no Authenticode certificate). Files WinSparkle downloads carry no
  Mark-of-the-Web, but a *manual* download of the setup exe can trigger
  SmartScreen. Authenticode is future work, as for the ZIP.
- The installer does not install the Windows App Runtime 1.7 prerequisite; same
  requirement as the ZIP.

Portable vs installed. In-app update requires the installed copy: Dart treats a
Windows build as installed when `unins000.exe` (Inno's uninstaller) sits next to
the exe. A ZIP-extracted copy reports `available == false` and opens the release
page, so it never silently installs a second copy elsewhere.

Native details (`packages/raft_updater/windows`). `configure` calls
`win_sparkle_set_eddsa_public_key` (rejects invalid keys -> unavailable),
`set_appcast_url`, an explicit registry path, `set_app_details`,
`set_app_build_version(<build number>)` (so `sparkle:version` compares with the CI
run number), disables scheduled checks (no first-run prompt), installs the
shutdown callbacks and calls `win_sparkle_init`. `checkForUpdates` is
`win_sparkle_check_update_with_ui`. WinSparkle.dll is bundled through the plugin's
`_bundled_libraries`.

### What CodexWin must verify on Windows

Nothing in `packages/raft_updater/windows`, the CMake fetch, Inno Setup, or the
installer flow has been compiled or run (this host is Linux).

1. `tool/flutter build windows --release` compiles; `WinSparkle.dll` sits beside
   `raft_flutter.exe` in the bundle and the ZIP; CMake fetched WinSparkle with the
   pinned hash (a zip with a stray `__MACOSX` folder: the `WinSparkle-*` glob in
   the plugin CMake handles it, confirm).
2. `python tool/windows_installer.py` through `tool/release.py build windows`: ISCC
   is found (`choco install innosetup --version=6.4.3` is untested; pin may need
   changing), the setup exe is produced and listed in the receipt.
3. Install the setup exe as a normal user (no UAC); `unins000.exe` is next to the
   exe; Start menu entry exists; uninstall works.
4. Build with `SPARKLE_ED_PUBLIC_KEY=<throwaway public key>`; installed copy:
   `AppUpdater.instance.available == true`; ZIP copy: false -> release page.
5. Rehearsal: install N, build N+1 with the same key and a higher build number,
   create `appcast.xml` with `python tool/appcast.py sign --platform windows --url ...`
   (HTTPS or `http://127.0.0.1`), point N at it with `RAFT_UPDATE_FEED_URL`, press
   the button: WinSparkle UI -> download -> signature check -> app closes ->
   installer runs silently -> N+1 relaunches; version in About is N+1 and user
   data/session survived.
6. Negative: tampered installer or wrong key -> WinSparkle refuses; lower
   `sparkle:version` -> "up to date"; an appcast `sparkle:installerArguments`
   change should not trigger a visible installer UI loop.
7. The shutdown path works with the app minimised / with an open dialog; the app
   exits (no orphaned `raft_flutter.exe`) and the installer can overwrite files.
8. Windows Defender/SmartScreen behaviour for the unsigned installer.
9. Confirm `HKCU\Software\app.raft\Raft\WinSparkle` is written and nothing needs
   elevation.

## Verified here (Linux) vs not

Verified: Ed25519 signer against RFC 8032 and the `cryptography` library; appcast
XML shape, signature, URLs, determinism; publish flow with extra artifacts, missing
or mismatched secret, no-key builds and idempotent retries; macOS inventory,
signing order and plist checks against a mocked `codesign`; Inno script settings;
Dart `AppUpdater` behaviour and fallbacks (`flutter test`, `flutter analyze`).
Not verified: any native compile (Swift, C++), Sparkle/WinSparkle behaviour, Inno
Setup output, SwiftPM embedding of Sparkle, real GitHub secrets/variables, the
Keychain re-prompt. Those are the checklists above.

## Other platforms

Linux (AppImage could use AppImageUpdate later), Android (red dot opens the APK
link) and iOS have no in-app update; `AppUpdater.available` is false and
`checkAndInstall()` opens the release page. Intel Macs have no build.
