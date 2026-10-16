import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'marks.dart';

/// The current item of a screen: the one thing on it that the person and the
/// agent are both looking at ("第二个", "这个", a tap). Voice (`spotlight`,
/// `expand_item`) and taps all set the same one, and what 通过 / 打开讨论 /
/// 稍后 do is done to it.
///
/// Nothing is lifted or copied: the row of the current item stays where it is
/// and is highlighted ([AgentSpotlight.isCurrent]), and the screen shows the
/// item in its detail slot (the pane beside a list, or a sheet on a phone).
/// It stays current until another one is, the layer changes, or it is
/// released.
class AgentSpotlightController extends ChangeNotifier {
  String? _focused;
  bool _enter = false;

  /// The current item, `layer#n`.
  String? get focused => _focused;

  /// The current item was just added to a screen that is being composed.
  bool get entering => _enter && _focused != null;

  void focus(String id, {bool enter = false}) {
    if (_focused == id) return;
    _focused = id;
    _enter = enter;
    notifyListeners();
  }

  void release() {
    if (_focused == null) return;
    _focused = null;
    _enter = false;
    notifyListeners();
  }

  /// Mirrors a current item received from elsewhere (e.g. the phone, on a
  /// TV).
  void sync(String? id, {bool enter = false}) =>
      id == null ? release() : focus(id, enter: enter);
}

/// Tells everything below it which item is current, from [controller].
class AgentSpotlight extends StatelessWidget {
  const AgentSpotlight({
    super.key,
    required this.controller,
    required this.child,
  });

  final AgentSpotlightController controller;
  final Widget child;

  /// The current item's id (`layer#n`) as seen from [context], or null.
  static String? currentOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CurrentScope>()?.focused;

  /// Whether the [AgentFocusable] [context] sits in is the current item.
  static bool isCurrent(BuildContext context) {
    final id = AgentItemScope.of(context);
    return id != null && id == currentOf(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, child) =>
        _CurrentScope(focused: controller.focused, child: child!),
    child: child,
  );
}

class _CurrentScope extends InheritedWidget {
  const _CurrentScope({required this.focused, required super.child});
  final String? focused;

  @override
  bool updateShouldNotify(_CurrentScope old) => old.focused != focused;
}

/// A component the agent can point at, with the id the agent names it by
/// (`layer#n`). While it is the current item the widgets in it can draw the
/// highlight ([AgentSpotlight.isCurrent]), and a list that scrolls brings it
/// into view.
class AgentFocusable extends StatefulWidget {
  const AgentFocusable({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  State<AgentFocusable> createState() => _AgentFocusableState();
}

class _AgentFocusableState extends State<AgentFocusable> {
  bool _was = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final now = AgentSpotlight.currentOf(context) == widget.id;
    if (now && !_was) {
      // Only what is cut off moves; a row that is in view stays where it is.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || Scrollable.maybeOf(context) == null) return;
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 200),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      });
    }
    _was = now;
  }

  @override
  Widget build(BuildContext context) =>
      AgentItemScope(id: widget.id, child: widget.child);
}
