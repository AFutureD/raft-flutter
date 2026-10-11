# GitHub build and release

`.github/workflows/release.yml` builds on GitHub-hosted runners using the exact
Flutter version in `.fvmrc` and the checked-in pub lockfile. Windows x64 is enabled
by default. Builds use `lib/main.dart` and produce no private test fixtures or
test feature defines. This pipeline is separate from the local native-acceptance
packager `tool/build-deliverables`; compilation does not imply full-app acceptance.

## Trigger a release

1. Review and merge the source through the normal integration batch and
   `tool/check-project` gate.
2. Set `apps/raft_flutter/pubspec.yaml` to `version: X.Y.Z+N`. Increase `N` for each
   Android update; keep the same release keystore for all updates. Commit and merge
   the version change before tagging.
3. Push a matching version tag, e.g. `git tag v0.1.0 && git push origin v0.1.0`.
   Prerelease versions such as `0.1.0-rc.1+2` use tag `v0.1.0-rc.1`.

A mismatched tag stops before building. All enabled platforms must succeed before
the publication job runs. It verifies each artifact's SHA-256, architecture,
version and source commit, creates a draft, uploads every asset plus
`CHECKSUMS.txt` and `build-manifest.json`, then publishes it. Tags containing a
prerelease suffix become GitHub prereleases. Only the publish job has
`contents: write`; it uses the built-in `GITHUB_TOKEN`, without a personal token.
No second release-event workflow is needed.

Pull requests touching release tooling, the lockfile or Windows host run a Windows
build and retain artifacts for 14 days. **PR and manual runs never publish.** From
Actions → Build and release → Run workflow, leave `platforms` blank for the enabled
set, or select e.g. `windows,macos` to test builders before enabling them. Fork PRs
cannot access signing secrets; keep Android out of the default set until the
project's signing and contributor workflow is ready.

Concurrency is serialized per event/ref. Published assets are never overwritten.
If upload fails, a draft remains; inspect it, delete that incomplete draft (retain
the tag), then rerun the workflow. An existing published release must be corrected
with a new version/tag, rather than reusing a version for different bytes.
On repositories with immutable releases, the draft-first sequence also ensures
assets are present before publication locks them.

## Enable other platforms

Change `enabled` in `tool/release-platforms.json` after a manual build and platform
acceptance. The same matrix and publish job handle every enabled platform. Runner
labels and architecture metadata are in that file; changing architecture also
requires adjusting the corresponding native build and packaging implementation.

| Platform | Runner | Asset | Requirements / current limits |
| --- | --- | --- | --- |
| Windows x64 | `windows-2022` | Complete portable ZIP | No Authenticode signature or installer. Requires Windows App Runtime 1.7 x64. Keep all DLLs and `data/`; `RUN.txt` explains explicit notification registration. Fresh-machine and cold-click acceptance is still pending. |
| Android ARM64 | `ubuntu-24.04` | Signed split APK | SDK 37 / build tools 37.0.0, Java 17. Requires all signing secrets below; missing secrets fail instead of producing a debug-signed release. No Play Store/AAB upload. |
| Linux x64 | `ubuntu-26.04` | Relocatable `.tar.gz` | Uses existing pinned Ubuntu Resolute media preparation; package/hash drift fails. Bundles library notices/provenance and verifies ELF lookup. Ubuntu 26.04 glibc/GTK/drivers required; other distributions are unverified. Review media GPL terms and supply matching source before enabling distribution. |
| macOS ARM64 | `macos-15` | `.app` ZIP via `ditto` | Existing ad-hoc signing. No Developer ID/notarization; Gatekeeper distribution acceptance is pending. No Intel build. |

Android repository **Actions secrets**:

- `RAFT_ANDROID_KEYSTORE_BASE64`: base64 bytes of the persistent release JKS/keystore.
- `RAFT_ANDROID_STORE_PASSWORD`: keystore password.
- `RAFT_ANDROID_KEY_ALIAS`: signing key alias.
- `RAFT_ANDROID_KEY_PASSWORD`: key password.

The keystore is decoded into a temporary directory and removed after the build.
Passwords stay in environment variables and are never written to source or
artifacts. Gradle uses this keystore when supplied; local acceptance builds retain
their existing debug signing. Do not upload keys or secrets as build artifacts.
Device installation continues to use `tool/android-install` and its signature,
version and data-preservation checks; CI does not install on any device.

Developer ID/notarization, Windows certificate signing, installers, app stores and
iOS remain future extensions; this pipeline currently publishes GitHub assets.

Sources: [GitHub runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[Flutter SDK action / FVM pinning](https://github.com/subosito/flutter-action),
[GitHub CLI release creation](https://cli.github.com/manual/gh_release_create),
[release asset upload](https://cli.github.com/manual/gh_release_upload).
