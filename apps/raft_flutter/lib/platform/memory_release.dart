import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Why rebuildable memory is released.
enum RaftMemoryTrim {
  /// The app has been hidden for [RaftMemoryRelease.backgroundDelay].
  backgrounded,

  /// The OS asked for memory (Android `onTrimMemory`, iOS memory warning).
  pressure,
}

typedef RaftMemoryTrimmer = void Function(RaftMemoryTrim reason);

/// Releases decoded images and other rebuildable caches when the app is not
/// being looked at (owner report 2026-10-13: finished media kept hundreds of
/// MB resident). Everything released is rebuilt on demand: a page that comes
/// back may decode again, never loses data.
///
/// * Memory pressure: Flutter already clears the global `ImageCache`; the
///   registered trimmers drop what the framework does not know about (our
///   own decoded-image repository).
/// * Hidden/paused for [backgroundDelay]: the `ImageCache` is cleared and the
///   trimmers run. Images that widgets still hold stay (no frame runs while
///   hidden, so a widget could not let go of them anyway).
///
/// The delay keeps a quick app switch free of re-decoding.
class RaftMemoryRelease with WidgetsBindingObserver {
  RaftMemoryRelease({
    this.backgroundDelay = const Duration(seconds: 30),
    ImageCache Function()? imageCache,
  }) : _imageCache = imageCache ?? (() => PaintingBinding.instance.imageCache);

  static final RaftMemoryRelease instance = RaftMemoryRelease();

  final Duration backgroundDelay;
  final ImageCache Function() _imageCache;
  final _trimmers = <RaftMemoryTrimmer>{};
  Timer? _timer;
  bool _installed = false;

  /// True once the app has stayed hidden for [backgroundDelay].
  bool get backgrounded => _backgrounded;
  bool _backgrounded = false;

  /// Starts observing the app lifecycle and memory pressure. Idempotent.
  void install() {
    if (_installed) return;
    _installed = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    _backgrounded = false;
  }

  /// Registers [trimmer]; the returned callback removes it.
  VoidCallback addTrimmer(RaftMemoryTrimmer trimmer) {
    _trimmers.add(trimmer);
    return () => _trimmers.remove(trimmer);
  }

  @override
  void didHaveMemoryPressure() => trim(RaftMemoryTrim.pressure);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // One-shot, positive delay; never re-armed from its own callback.
        _timer ??= Timer(backgroundDelay, _enterBackground);
      case AppLifecycleState.resumed:
        _timer?.cancel();
        _timer = null;
        _backgrounded = false;
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _enterBackground() {
    _timer = null;
    _backgrounded = true;
    trim(RaftMemoryTrim.backgrounded);
  }

  /// Runs every trimmer; also clears the framework image cache when
  /// backgrounded (pressure is already handled by the binding).
  void trim(RaftMemoryTrim reason) {
    final cache = _imageCache();
    if (!kReleaseMode) {
      debugPrint(
        '[raft-memory] ${reason.name}: image cache '
        '${cache.currentSize} images / ${cache.currentSizeBytes} B',
      );
    }
    if (reason == RaftMemoryTrim.backgrounded) cache.clear();
    for (final trimmer in List.of(_trimmers)) {
      try {
        trimmer(reason);
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'raft memory release',
          ),
        );
      }
    }
  }
}
