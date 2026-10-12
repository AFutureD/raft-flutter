# Startup theme flash (Android)

Report: with a non-default theme (Elegant) the app first shows the default look and then jumps.

## Entrypoint

`apps/raft_flutter/integration_test/theme_flash_main.dart` runs the production startup sequence (`RootErrorBoundary`, `deferFirstFrame`, `RaftApp.restore`) on perf-lab fixtures, without login, on REAL persisted `SharedPreferences`, so a cold start reads the stored appearance from disk. Profile/debug only.

```sh
cd apps/raft_flutter
../../tool/flutter build apk --profile --target-platform android-x64 \
  --android-project-arg=raftApplicationIdSuffix=.linkperf -t integration_test/theme_flash_main.dart
adb -s <emulator> install -r build/app/outputs/flutter-apk/app-profile.apk   # only the .linkperf package
# seed once: "<mode> <family> [icon] [nodefer]"
adb shell 'echo "dark elegant blue" > /data/local/tmp/raft-theme-flash.txt; chmod 644 /data/local/tmp/raft-theme-flash.txt'
adb shell am start -n app.raft.raft_flutter.linkperf/<enabled launcher alias>   # then: rm the seed file
adb shell am force-stop app.raft.raft_flutter.linkperf
adb shell screenrecord --time-limit 7 /sdcard/x.mp4 & adb shell am start -W -n <alias>   # cold start, record
```

The seed run also switches the launcher icon colour through `NativeAppIcon`, because a profile build cannot be toggled with `pm enable` from the shell.

## Cause (Android 17 emulator, 2026-10-12)

Frame extraction at 30 fps of cold starts (Elegant light, Elegant dark, Brutal; yellow and blue icon):

- The window shows the icon-colour splash (system splash on Android 12+, icon colour `#FBD23C` yellow or `#25CAEF` blue, with the mark) from process start until the first Flutter frame, then cross-fades (about 0.15 s) into the app. In dark Elegant that is yellow to `#0B0B09`.
- No Flutter frame is ever painted with the default family: the first frame is released only by `finishStartup()`, after `restore()` read `raft.mode` / `raft.light`. Even with `deferFirstFrame` removed (`nodefer`), the stored preferences are already loaded, so the first rendered frame is the stored theme.
- The window background (`setBackgroundDrawableResource`) is never visible after the first frame: the Flutter `SurfaceView` punches through it.

So the "default theme" the owner sees is the icon-colour splash (native), not a Flutter frame.

## Fix (Dart)

`storedAppearance()` reads `raft.mode` / `raft.light` synchronously from the preloaded `DevicePreferences`. `_RaftAppState.appearance` starts from it, so the first built `MaterialApp` has the stored family and mode on every path (the deferred first frame is no longer the only guard). Unknown stored values fall back per key instead of failing the restore. `RootErrorBoundary`'s fallback app uses the same reader. Tested in `test/startup_appearance_test.dart`.

## Splash

The icon-colour splash is an owner requirement for the icon feature and is unchanged. Options if the splash colour itself must not differ from the chosen theme are listed in the hand-off notes.
