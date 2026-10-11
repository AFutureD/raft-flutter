import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether the platform reports the soft keyboard as visible right now.
/// `null` means unknown; callers must then trust the engine value.
typedef ImeVisibility = Future<bool?> Function();

const _channel = MethodChannel('app.raft/ime');

/// Android: asks the activity's root window insets whether the IME is shown.
Future<bool?> nativeImeVisible() async {
  try {
    return await _channel.invokeMethod<bool>('visible');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Reconciles a stale keyboard inset on resume (flutter#118761).
///
/// With the keyboard open, backgrounding the app closes the IME, but the
/// engine can keep reporting the old `viewInsets.bottom` after the app comes
/// back. Every keyboard-aware surface then reserves a keyboard-sized blank
/// gap. When the app resumes with a non-zero inset while the platform says the
/// IME is hidden, this guard remembers that inset as stale and reports it as 0
/// (and gives the system bar back to `padding`) until the engine reports a
/// different value or focus changes, so a keyboard that really reopens, even at
/// the same height, is never hidden.
///
/// Placed once above the app content (inside the `MaterialApp` builder) so all
/// consumers, including overlays, see the reconciled metrics.
class KeyboardInsetGuard extends StatefulWidget {
  const KeyboardInsetGuard({super.key, this.imeVisible, required this.child});

  /// Platform IME probe. `null` disables the guard (web, desktop, iOS).
  final ImeVisibility? imeVisible;
  final Widget child;

  @override
  State<KeyboardInsetGuard> createState() => _KeyboardInsetGuardState();
}

class _KeyboardInsetGuardState extends State<KeyboardInsetGuard>
    with WidgetsBindingObserver {
  /// Raw engine `viewInsets.bottom` (physical px) known to be stale, or null.
  double? _staleInset;
  int _checks = 0;

  double _rawInset() => View.of(context).viewInsets.bottom;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reconcile());
  }

  @override
  void didChangeMetrics() {
    // Any new engine value ends the stale episode.
    if (_staleInset != null && _rawInset() != _staleInset) _clear();
  }

  void _focusChanged() {
    // A focus change may reopen the IME with the same height as the stale one.
    if (_staleInset != null) _clear();
  }

  void _clear() {
    if (_staleInset == null) return;
    setState(() => _staleInset = null);
  }

  Future<void> _reconcile() async {
    final probe = widget.imeVisible;
    final raw = _rawInset();
    if (probe == null || raw <= 0) return;
    final check = ++_checks;
    final visible = await probe();
    if (!mounted || check != _checks || visible != false) return;
    // The inset may have changed while the platform answered.
    if (_rawInset() != raw) return;
    setState(() => _staleInset = raw);
  }

  @override
  Widget build(BuildContext context) {
    final stale = _staleInset;
    final media = MediaQuery.of(context);
    if (stale == null || View.of(context).viewInsets.bottom != stale) {
      return widget.child;
    }
    return MediaQuery(
      data: media.copyWith(
        viewInsets: media.viewInsets.copyWith(bottom: 0),
        // The engine derives padding as max(0, viewPadding - viewInsets): with
        // no keyboard it is the full system bar again.
        padding: media.padding.copyWith(bottom: media.viewPadding.bottom),
      ),
      child: widget.child,
    );
  }
}

/// The guard for the running platform (Android only).
ImeVisibility? get platformImeVisibility =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? nativeImeVisible
    : null;
