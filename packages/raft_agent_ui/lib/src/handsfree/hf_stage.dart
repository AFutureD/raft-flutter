import 'package:flutter/material.dart';

import 'hf_scope.dart';
import 'hf_tokens.dart';

/// The detail slot of a layer: what the current item looks like when it is
/// shown beside its list (a desktop window of 1280 or more, a TV). A layer's
/// [HfLayerBody] lays its list out in the left part and [stage] in the right
/// part, at the same place on every layer. A phone has no room beside the
/// list: its stage is a sheet under the layer ([HfStageSheet]).
///
/// What goes in the stage is the item in its third rendering: a component has
/// a row (the list), the same row highlighted while it is current (the
/// focused one), and a detail (the stage, and the full page after it).
class HfStageScope extends InheritedWidget {
  const HfStageScope({super.key, required this.stage, required super.child});

  /// The current item in its detail rendering, or null when there is none.
  final Widget? stage;

  static Widget? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HfStageScope>()?.stage;

  @override
  bool updateShouldNotify(HfStageScope old) => old.stage != stage;
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

/// A phone's stage: the current item's detail in the lower half of the
/// layer's area, always the same size and place. [child] is bounded, so a
/// long detail scrolls inside its card and its actions stay in view.
class HfStageSheet extends StatelessWidget {
  const HfStageSheet({super.key, required this.height, required this.child});
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('hf-stage-sheet'),
    height: height,
    child: child,
  );
}
