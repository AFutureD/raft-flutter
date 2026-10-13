# raft_updater

Method-channel bridge to Sparkle 2 (macOS) and WinSparkle 0.9 (Windows), a
pure-Dart zsync delta updater for Linux AppImages (`AppUpdater.appImage`), and
the Dart facade, `AppUpdater`. Everything about keys, CI signing, appcasts and
platform verification is in `docs/auto-update.md`.

```dart
final updater = AppUpdater.instance;
if (updater.available) { /* native in-place update */ }
await updater.checkAndInstall(); // native UI, or opens the release page
```

On Linux, `available` is true only for a writable AppImage that embeds update
information and after the app calls `configureAppImage` with its proxy-aware
HTTP client; the Updates card then drives `appImage.install(...)` and
`appImage.restart()` and renders `appImage.status`.
