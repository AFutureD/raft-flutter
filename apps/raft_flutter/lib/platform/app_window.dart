import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Brings the app's window to the front. A desktop sign-in finishes in the
/// browser, which stays in front until the app takes the focus back.
///
/// Best effort: a desktop shell may refuse to raise a window the person's last
/// input did not start (Wayland compositors, Windows' foreground lock); it then
/// flashes the taskbar entry or the dock icon instead.
Future<void> presentAppWindow({
  TargetPlatform? platform,
  MethodChannel? channel,
}) async {
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.windows:
      // The notification channel's `present` (ShowWindow + SetForegroundWindow).
      await (channel ?? const MethodChannel('app.raft/windows-notifications'))
          .invokeMethod<void>('present');
    case TargetPlatform.linux || TargetPlatform.macOS:
      await (channel ?? const MethodChannel('app.raft/window'))
          .invokeMethod<void>('present');
    case TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia:
      break;
  }
}

/// Reads desktop activation without raising the window.
///
/// Flutter may not deliver a lifecycle event at background startup. Missing
/// runners, failed reads, and a one-second timeout return `false`.
Future<bool> isAppWindowActive({
  TargetPlatform? platform,
  MethodChannel? channel,
}) async {
  final name = switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.windows => 'app.raft/windows-notifications',
    TargetPlatform.linux || TargetPlatform.macOS => 'app.raft/window',
    _ => null,
  };
  if (name == null) return false;
  try {
    return await (channel ?? MethodChannel(name))
            .invokeMethod<Object?>('isActive')
            .timeout(const Duration(seconds: 1)) ==
        true;
  } catch (_) {
    return false;
  }
}
