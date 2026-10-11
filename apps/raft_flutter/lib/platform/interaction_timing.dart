import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Reads the macOS mouse setting without gating input or opening any window.
Future<Duration> platformDoubleClickInterval() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
    return kDoubleTapTimeout;
  }
  try {
    final seconds = await const MethodChannel('app.raft/interaction')
        .invokeMethod<Object?>('doubleClickInterval');
    if (seconds is num && seconds.isFinite && seconds >= 0.001) {
      return Duration(microseconds: (seconds * 1000000).round());
    }
  } on MissingPluginException {
    // Other hosts and older native shells retain Flutter's default.
  } on PlatformException {
    // A failed settings read must not make the first click wait.
  }
  return kDoubleTapTimeout;
}
