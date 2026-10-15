import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The runner owns the icon and persisted window preference. Dart only supplies
/// labels/unread and consumes visibility events; message authority stays shared.
class WindowsTray {
  WindowsTray({TargetPlatform? platform, MethodChannel? channel, bool? lab})
    : supported =
          !kIsWeb &&
          (platform ?? defaultTargetPlatform) == TargetPlatform.windows,
      _channel = channel ?? nativeChannel,
      lab = lab ?? const bool.fromEnvironment('RAFT_WINDOWS_NOTIFICATION_LAB');

  static const nativeChannel = MethodChannel('app.raft/windows-tray');
  final bool supported, lab;
  final MethodChannel _channel;
  void Function()? onHidden;
  bool _closed = false;
  String? _labels;

  Future<void> initialize(String Function(String) localize) async {
    if (!supported || _closed) return;
    _channel.setMethodCallHandler((call) async {
      if (!_closed && call.method == 'hidden') onHidden?.call();
    });
    await configure(localize);
  }

  Future<void> configure(String Function(String) localize) async {
    if (!supported || _closed) return;
    final labels = {
      'lab': lab,
      'open': localize('Open Raft'),
      'hide': localize('Hide window'),
      'quit': localize('Quit Raft'),
      'unread': localize('unread'),
    };
    final key = labels.toString();
    if (_labels == key) return;
    // Remember the attempted copy before awaiting the optional shell service.
    // Workspace changes must not retry failures or overlap pending calls; the
    // runner independently restores the icon after TaskbarCreated.
    _labels = key;
    try {
      await _channel
          .invokeMapMethod<String, dynamic>('configure', labels)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Optional shell service: without a registered icon, Close still exits.
    }
  }

  Future<WindowsTrayState> readState() async =>
      WindowsTrayState.from(await _invoke('state'));

  Future<WindowsTrayState> setCloseToTray(bool enabled) async =>
      WindowsTrayState.from(
        await _invoke('setCloseToTray', {'enabled': enabled}),
      );

  Future<Map<String, dynamic>?> _invoke(String method, [Object? args]) async {
    if (!supported || _closed) return null;
    return _channel
        .invokeMapMethod<String, dynamic>(method, args)
        .timeout(const Duration(seconds: 2));
  }

  static Future<void> writeUnread(int count) => nativeChannel
      .invokeMethod<void>('setUnread', {'count': count})
      .timeout(const Duration(seconds: 2));

  /// Explicit exit uses the same native request as the tray menu and updater.
  Future<void> quit() async {
    if (!supported || _closed) return;
    await _channel
        .invokeMethod<void>('quit')
        .timeout(const Duration(seconds: 2));
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    onHidden = null;
    if (!supported) return;
    _channel.setMethodCallHandler(null);
    try {
      await _channel
          .invokeMethod<void>('dispose')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

class WindowsTrayState {
  const WindowsTrayState({this.available = false, this.closeToTray = true});
  factory WindowsTrayState.from(Map<String, dynamic>? value) =>
      WindowsTrayState(
        available: value?['available'] == true,
        closeToTray: value?['closeToTray'] != false,
      );
  final bool available, closeToTray;
}
