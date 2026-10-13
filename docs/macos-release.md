# macOS Release CI

Version-tag pushes include macOS ARM64 in the existing release matrix. Manual
`Build and release` runs can select `macos` to build an artifact without publishing
a GitHub Release. Version and build number use the same rules as other platforms.

The macOS job uses Flutter pinned in `.fvmrc`, CocoaPods 1.16.2 and Ruby JSON 2.18.0 and Swift Package Manager.
It signs native code and frameworks inside out with ad-hoc signatures, then signs
the app with the checked-in Release entitlements. No Apple signing secret is needed.
Packaging rejects development provisioning profiles, wrong architectures, changed
entitlements and invalid signatures. The ZIP is extracted and verified again before
upload; its receipt and SHA-256 accompany the artifact. Native UI acceptance is
separate from these build and package checks.

Extract the ZIP and copy `Raft.app` to Applications. These public packages are not
notarized. macOS may block the first launch: after attempting to open the app, a
user who trusts the download can use **System Settings → Privacy & Security →
Open Anyway**. Managed Macs may disallow this exception. Instructions also ship in
`READ-ME-FIRST.txt`. See [Apple's guidance](https://support.apple.com/en-gb/102445).

An existing provisioned development installation needs its original signing
identity and Keychain configuration to retain its session. This CI does not replace
that local update procedure; see [local macOS evidence](macos-evidence.md).

## Auto-update

The app embeds Sparkle 2 (`Sparkle.framework` with `Installer.xpc`, `Downloader.xpc`,
`Updater.app`). Those nested bundles are the only ones packaging accepts, all
signed ad-hoc inside out. The Release entitlements add the two Sparkle
mach-lookup exceptions, and `SUPublicEDKey` is injected from the
`SPARKLE_ED_PUBLIC_KEY` variable before signing. Do not enable Hardened Runtime.
See [auto-update.md](auto-update.md) for ad-hoc/sandbox behaviour and the Mac
verification checklist.
