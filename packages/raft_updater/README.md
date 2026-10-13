# raft_updater

Method-channel bridge to Sparkle 2 (macOS) and WinSparkle 0.9 (Windows), plus a
Dart facade, `AppUpdater`. Everything about keys, CI signing, appcasts and
platform verification is in `docs/auto-update.md`.

```dart
final updater = AppUpdater.instance;
if (updater.available) { /* native in-place update */ }
await updater.checkAndInstall(); // native UI, or opens the release page
```
