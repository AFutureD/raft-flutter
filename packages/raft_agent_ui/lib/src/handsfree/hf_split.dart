import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

enum _SplitSlot { list, stage }

/// Marks the row the stage goes next to: the stage's top is the top of the
/// widget this wraps. Without one in the list, the stage sits at the top.
class HfStageAnchor extends SingleChildRenderObjectWidget {
  const HfStageAnchor({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderHfStageAnchor();
}

class RenderHfStageAnchor extends RenderProxyBox {
  RenderHfStageAnchor();
}

/// A list and, beside it, the stage of its current item: one page, so the
/// page scrolls them together. The list takes 53 parts of the width, the
/// stage 47, with [gap] between. The stage's top is level with the top of the
/// list's [HfStageAnchor] (the current row), so it stays by the item it is
/// about; the page is as tall as the longer of the two. Without a stage the
/// list has the whole width.
class HfSplit
    extends SlottedMultiChildRenderObjectWidget<_SplitSlot, RenderBox> {
  const HfSplit({
    super.key,
    required this.list,
    this.stage,
    required this.gap,
    this.snap = 0,
  });

  final Widget list;
  final Widget? stage;
  final double gap;

  /// A row this close to the top of the list (only a section label above it)
  /// takes the stage to the very top of the list: the stage is then as high
  /// on the page as it can be.
  final double snap;

  @override
  Iterable<_SplitSlot> get slots => _SplitSlot.values;

  @override
  Widget? childForSlot(_SplitSlot slot) => switch (slot) {
    _SplitSlot.list => list,
    _SplitSlot.stage => stage,
  };

  @override
  RenderHfSplit createRenderObject(BuildContext context) =>
      RenderHfSplit(gap: gap, snap: snap);

  @override
  void updateRenderObject(BuildContext context, RenderHfSplit renderObject) {
    renderObject
      ..gap = gap
      ..snap = snap;
  }
}

class RenderHfSplit extends RenderBox
    with SlottedContainerRenderObjectMixin<_SplitSlot, RenderBox> {
  RenderHfSplit({required double gap, double snap = 0})
    : _gap = gap,
      _snap = snap;

  double _snap;
  set snap(double value) {
    if (value == _snap) return;
    _snap = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  RenderBox? get _list => childForSlot(_SplitSlot.list);
  RenderBox? get _stage => childForSlot(_SplitSlot.stage);

  /// Where the stage is, in this box's coordinates; null without a stage.
  /// Valid after layout.
  Rect? get stageRect {
    final stage = _stage;
    if (stage == null || !stage.hasSize) return null;
    return (stage.parentData! as BoxParentData).offset & stage.size;
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  RenderHfStageAnchor? _anchorIn(RenderObject root) {
    RenderHfStageAnchor? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderHfStageAnchor) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  @override
  void performLayout() {
    final list = _list;
    final stage = _stage;
    if (list == null) {
      size = constraints.smallest;
      return;
    }
    final width = constraints.maxWidth;
    if (stage == null) {
      list.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
      (list.parentData! as BoxParentData).offset = Offset.zero;
      size = constraints.constrain(Size(width, list.size.height));
      return;
    }
    final room = math.max(0.0, width - _gap);
    final listWidth = room * 53 / 100;
    final stageWidth = room - listWidth;
    list.layout(
      BoxConstraints.tightFor(width: listWidth),
      parentUsesSize: true,
    );
    (list.parentData! as BoxParentData).offset = Offset.zero;
    stage.layout(
      BoxConstraints.tightFor(width: stageWidth),
      parentUsesSize: true,
    );
    var top = 0.0;
    final anchor = _anchorIn(list);
    if (anchor != null && anchor.hasSize) {
      top = MatrixUtils.transformPoint(
        anchor.getTransformTo(list),
        Offset.zero,
      ).dy;
    }
    if (top <= _snap) top = 0;
    (stage.parentData! as BoxParentData).offset = Offset(
      listWidth + _gap,
      math.max(0.0, top),
    );
    size = constraints.constrain(
      Size(width, math.max(list.size.height, top + stage.size.height)),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _list?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _list?.getMaxIntrinsicHeight(width) ?? 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in [_list, _stage]) {
      if (child == null) continue;
      context.paintChild(
        child,
        (child.parentData! as BoxParentData).offset + offset,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in [_stage, _list]) {
      if (child == null) continue;
      final offset = (child.parentData! as BoxParentData).offset;
      final hit = result.addWithPaintOffset(
        offset: offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    for (final child in [_list, _stage]) {
      if (child != null) visitor(child);
    }
  }
}
