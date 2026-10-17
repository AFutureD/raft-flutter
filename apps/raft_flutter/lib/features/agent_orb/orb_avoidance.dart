import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../mobile_workspace_navigation.dart';

/// Where the orb must not rest: the bottom tab bar and the message composer.
///
/// Measured from the live widget tree, on demand (a route changed, the
/// keyboard moved, the user dropped the orb), never per frame: the walk skips
/// what is not on stage (a covered route, an offstage tab page).
abstract class OrbAvoidance {
  const OrbAvoidance();

  /// Widgets of these types are obstacles.
  factory OrbAvoidance.byType(List<Type> types) = _ByType;

  /// The app: the phone tab bar and the composer.
  factory OrbAvoidance.app() =>
      OrbAvoidance.byType(const [WorkspaceMobileTabBar, RaftComposer]);

  /// The window rectangles of the obstacles under [root].
  List<Rect> obstacles(BuildContext root);
}

class _ByType extends OrbAvoidance {
  _ByType(this.types);
  final List<Type> types;

  @override
  List<Rect> obstacles(BuildContext root) {
    final found = <Rect>[];
    void visit(Element e) {
      final widget = e.widget;
      if (widget is Offstage && widget.offstage) return;
      if (widget is TickerMode && !widget.enabled) return;
      if (types.contains(widget.runtimeType)) {
        final box = e.renderObject;
        if (box is RenderBox && box.attached && box.hasSize) {
          found.add(box.localToGlobal(Offset.zero) & box.size);
        }
        return;
      }
      e.visitChildren(visit);
    }

    (root as Element).visitChildren(visit);
    return found;
  }
}
