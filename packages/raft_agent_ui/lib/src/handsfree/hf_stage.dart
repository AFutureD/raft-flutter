import 'package:flutter/material.dart';

import 'hf_scope.dart';
import 'hf_tokens.dart';

/// The current item's detail, handed down to the layer that shows it.
///
/// A layer is one page that scrolls as a whole, so the detail is part of that
/// page rather than a pane of its own. It goes where the item is:
///
///  - beside the list (a desktop window of 1280 or more, a TV), at the height
///    of the current item's row ([HfSplit] lays it out there); and
///  - on a phone, right under the current item's row, in the flow.
///
/// Either way the item is an [AgentFocusable] whose `id` is [id]: it puts the
/// stage in its place and scrolls the page to show both.
///
/// What goes in the stage is the item in its third rendering: a component has
/// a row (the list), the same row highlighted while it is current (the
/// focused one), and a detail (the stage, and the full page after it).
class HfStageScope extends InheritedWidget {
  const HfStageScope({
    super.key,
    required this.stage,
    required this.id,
    required super.child,
  });

  /// The current item in its detail rendering, or null when there is none.
  final Widget? stage;

  /// The focus id (`layer#n`) of the item the stage is about.
  final String id;

  static HfStageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HfStageScope>();

  /// The stage, or null.
  static Widget? of(BuildContext context) => maybeOf(context)?.stage;

  @override
  bool updateShouldNotify(HfStageScope old) =>
      old.stage != stage || old.id != id;
}

/// The two small things a stage carries at the right of its heading: 展开
/// (go to the full detail) and a close mark. Either is left out when null.
class HfStageTools extends StatelessWidget {
  const HfStageTools({super.key, this.onExpand, this.onClose});
  final VoidCallback? onExpand, onClose;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    Widget pill(Key key, Widget child, VoidCallback onTap) => Semantics(
      button: true,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(
            minHeight: hf.sp(36),
            minWidth: hf.sp(36),
          ),
          padding: EdgeInsets.symmetric(horizontal: hf.sp(10)),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: HfColors.card,
            borderRadius: BorderRadius.circular(hf.sp(10)),
            border: Border.all(color: HfColors.ink, width: hf.sp(2.5)),
          ),
          child: child,
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onExpand != null)
          pill(
            const ValueKey('hf-stage-expand'),
            Text('展开', style: hf.type(HfType.body)),
            onExpand!,
          ),
        if (onExpand != null && onClose != null) SizedBox(width: hf.sp(8)),
        if (onClose != null)
          pill(
            const ValueKey('hf-stage-close'),
            Icon(Icons.close, size: hf.sp(20), color: HfColors.ink),
            onClose!,
          ),
      ],
    );
  }
}
