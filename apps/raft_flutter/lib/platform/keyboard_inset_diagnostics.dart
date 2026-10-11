import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Debug / profile only: logs `viewInsets.bottom` transitions so a keyboard
/// inset that the engine leaves non-zero after the IME closed (flutter#118761)
/// can be confirmed on a device (`adb logcat -s flutter | grep raft-inset`).
///
/// No per-frame work beyond one comparison in [didChangeMetrics]: only a
/// zero / non-zero transition and a settled value (300 ms after the last
/// change) are printed. Release builds register nothing.
///
/// Mix into a `State` that also mixes in [WidgetsBindingObserver]:
/// `with WidgetsBindingObserver, KeyboardInsetLogger<MyWidget>`.
mixin KeyboardInsetLogger<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  static const settleDelay = Duration(milliseconds: 300);
  double _inset = 0;
  Timer? _settle;

  /// Test hook; defaults to [debugPrint].
  @visibleForTesting
  void Function(String message)? insetLog;

  bool get _enabled => kDebugMode || kProfileMode;

  void _emit(String message) => (insetLog ?? debugPrint)('raft-inset $message');

  @override
  void initState() {
    super.initState();
    if (_enabled) WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!_enabled) return;
    final view = View.maybeOf(context);
    if (view == null || view.devicePixelRatio == 0) return;
    final next = view.viewInsets.bottom / view.devicePixelRatio;
    if (next == _inset) return;
    if ((next == 0) != (_inset == 0)) {
      _emit(next == 0 ? 'keyboard hidden' : 'keyboard shown: $next dp');
    }
    _inset = next;
    _settle?.cancel();
    _settle = Timer(settleDelay, () {
      if (mounted) {
        _emit('settled viewInsets.bottom=${_inset.toStringAsFixed(1)} dp');
      }
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    if (_enabled) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
