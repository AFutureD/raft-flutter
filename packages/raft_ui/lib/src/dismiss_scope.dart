import 'package:flutter/widgets.dart';

/// Escape closes the surface, whatever holds focus inside it.
///
/// Web `Modal` / `Lightbox` / `OverflowSheet` listen for Escape on the
/// document. A Flutter modal route only gets that for free when its
/// `barrierDismissible` is true, and the Web layers (`showRaftModal`, the
/// settings drawer, the confirm dialog) must not close on a scrim tap. This
/// scope binds the framework's `DismissIntent` (Escape in `WidgetsApp`'s
/// default shortcuts) for the whole subtree: a nested popup, select or text
/// field that handles Escape itself still wins, because the intent bubbles
/// from the focused node upwards and stops at the first enabled action.
///
/// [onDismiss] defaults to `Navigator.maybePop`, so `PopScope(canPop: false)`
/// (a busy submit, an unsaved draft guard) keeps deciding whether the close
/// happens. The nested [FocusScope] holds the route's initial focus, so
/// Escape reaches the action before the user has focused anything; a field
/// with `autofocus` inside still takes focus first.
class RaftDismissScope extends StatelessWidget {
  const RaftDismissScope({
    super.key,
    required this.child,
    this.onDismiss,
    this.enabled = true,
  });
  final Widget child;

  /// Replaces `Navigator.maybePop` (a guarded close that confirms first).
  final VoidCallback? onDismiss;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            if (onDismiss != null) {
              onDismiss!();
            } else {
              Navigator.maybePop(context);
            }
            return null;
          },
        ),
      },
      child: FocusScope(autofocus: true, child: child),
    );
  }
}

/// The system back gesture closes a transient popup instead of the page
/// under it.
///
/// A menu, select or picker lives in an `OverlayPortal`, so it is not a route
/// and Android Back would pop the page beneath it (or leave the app). While
/// this widget is mounted (build it only while the popup is open) it adds a
/// `LocalHistoryEntry` to the enclosing route: the navigator pops local
/// history before it consults any `PopScope`, so Back lands on [onDismiss]
/// once and the route stays put. Closing the popup any other way removes the
/// entry again.
///
/// An `OverlayEntry` builds above the routes; pass the opener's context as
/// [routeContext] there.
class RaftBackDismiss extends StatefulWidget {
  const RaftBackDismiss({
    super.key,
    required this.onDismiss,
    required this.child,
    this.routeContext,
  });
  final VoidCallback onDismiss;
  final Widget child;
  final BuildContext? routeContext;

  @override
  State<RaftBackDismiss> createState() => _RaftBackDismissState();
}

class _RaftBackDismissState extends State<RaftBackDismiss> {
  ModalRoute<dynamic>? _route;
  LocalHistoryEntry? _entry;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attach());
  }

  void _attach() {
    if (_gone || !mounted || _entry != null) return;
    final route = ModalRoute.of(widget.routeContext ?? context);
    if (route == null || !route.isCurrent) return;
    final entry = LocalHistoryEntry(
      onRemove: () {
        if (_entry == null) return;
        _entry = null;
        // Back popped the entry: the popup closes itself.
        if (!_gone) widget.onDismiss();
      },
    );
    _route = route;
    _entry = entry;
    route.addLocalHistoryEntry(entry);
  }

  @override
  void dispose() {
    _gone = true;
    final entry = _entry, route = _route;
    _entry = null;
    if (entry != null && route != null) {
      // Removing it re-enters the route's state; do that after the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          route.removeLocalHistoryEntry(entry);
        } catch (_) {
          // The route is already gone (it was popped with the popup open).
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// [builder] wrapped so the popup it builds closes on the system back gesture
/// (see [RaftBackDismiss]); for `OverlayPortal.overlayChildBuilder`.
Widget Function(BuildContext) raftBackDismissed(
  VoidCallback onDismiss,
  Widget Function(BuildContext) builder,
) =>
    (context) => RaftBackDismiss(onDismiss: onDismiss, child: builder(context));
