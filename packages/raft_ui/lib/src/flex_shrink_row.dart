import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A CSS `display:flex; align-items:center; gap` row whose items keep their
/// content width (flex-basis auto) and, when the row overflows, shrink in
/// proportion to that width (`flex-shrink: 1`) but never below their
/// min-content width (`min-width: auto`). Text inside a shrunk item wraps,
/// exactly like the metadata rows of the Web Saved/Activity/Search cards.
///
/// Flutter's Row + Flexible splits free space evenly instead, which wraps the
/// wrong item first.
class RaftFlexShrinkRow extends MultiChildRenderObjectWidget {
  const RaftFlexShrinkRow({
    super.key,
    this.gap = 0,
    this.spaceBetween = false,
    required super.children,
  });
  final double gap;

  /// `justify-between`: the row fills its width and free space goes between
  /// the items.
  final bool spaceBetween;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFlexShrinkRow(gap, spaceBetween);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFlexShrinkRow renderObject,
  ) => renderObject
    ..gap = gap
    ..spaceBetween = spaceBetween;
}

class _FlexShrinkParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFlexShrinkRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FlexShrinkParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FlexShrinkParentData> {
  _RenderFlexShrinkRow(this._gap, this._spaceBetween);
  double _gap;
  bool _spaceBetween;
  set spaceBetween(bool value) {
    if (value == _spaceBetween) return;
    _spaceBetween = value;
    markNeedsLayout();
  }

  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FlexShrinkParentData) {
      child.parentData = _FlexShrinkParentData();
    }
  }

  List<RenderBox> get _children {
    final out = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      out.add(child);
      child = childAfter(child);
    }
    return out;
  }

  List<double> _widths(double available) {
    final kids = _children;
    final basis = [
      for (final c in kids) c.getMaxIntrinsicWidth(double.infinity),
    ];
    final floor = [
      for (var i = 0; i < kids.length; i++)
        math.min(basis[i], kids[i].getMinIntrinsicWidth(double.infinity)),
    ];
    final widths = [...basis];
    final gaps = _gap * math.max(0, kids.length - 1);
    // Resolve flexible lengths: repeatedly shrink unfrozen items by their
    // scaled basis, freezing items that hit their min-content width.
    final frozen = List<bool>.filled(kids.length, false);
    for (var pass = 0; pass < kids.length + 1; pass++) {
      final used = widths.fold<double>(0, (a, b) => a + b) + gaps;
      final overflow = used - available;
      if (overflow <= 0.001 || available.isInfinite) break;
      var scaled = 0.0;
      for (var i = 0; i < kids.length; i++) {
        if (!frozen[i]) scaled += basis[i];
      }
      if (scaled <= 0) break;
      var clamped = false;
      for (var i = 0; i < kids.length; i++) {
        if (frozen[i]) continue;
        final next = widths[i] - overflow * basis[i] / scaled;
        if (next < floor[i]) {
          widths[i] = floor[i];
          frozen[i] = true;
          clamped = true;
        } else {
          widths[i] = next;
        }
      }
      if (!clamped) break;
    }
    return widths;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final kids = _children;
    return kids.fold<double>(
          0,
          (a, c) => a + c.getMinIntrinsicWidth(double.infinity),
        ) +
        _gap * math.max(0, kids.length - 1);
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final kids = _children;
    return kids.fold<double>(
          0,
          (a, c) => a + c.getMaxIntrinsicWidth(double.infinity),
        ) +
        _gap * math.max(0, kids.length - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _measure(BoxConstraints(maxWidth: width)).height;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      _measure(BoxConstraints(maxWidth: width)).height;

  @override
  Size computeDryLayout(BoxConstraints constraints) => _measure(constraints);

  Size _measure(BoxConstraints constraints) {
    final widths = _widths(constraints.maxWidth);
    var height = 0.0, width = 0.0;
    final kids = _children;
    for (var i = 0; i < kids.length; i++) {
      final size = kids[i].getDryLayout(
        BoxConstraints(minWidth: widths[i], maxWidth: widths[i]),
      );
      height = math.max(height, size.height);
      width += size.width;
    }
    width += _gap * math.max(0, kids.length - 1);
    return constraints.constrain(Size(width, height));
  }

  @override
  void performLayout() {
    final widths = _widths(constraints.maxWidth);
    final kids = _children;
    var height = 0.0;
    for (var i = 0; i < kids.length; i++) {
      kids[i].layout(
        BoxConstraints(minWidth: widths[i], maxWidth: widths[i]),
        parentUsesSize: true,
      );
      height = math.max(height, kids[i].size.height);
    }
    final content =
        kids.fold<double>(0, (a, c) => a + c.size.width) +
        _gap * math.max(0, kids.length - 1);
    final fill = _spaceBetween && constraints.hasBoundedWidth;
    final extra = fill && kids.length > 1
        ? math.max(0.0, constraints.maxWidth - content) / (kids.length - 1)
        : 0.0;
    var x = 0.0;
    for (final child in kids) {
      (child.parentData! as _FlexShrinkParentData).offset = Offset(
        x,
        (height - child.size.height) / 2, // items-center
      );
      x += child.size.width + _gap + extra;
    }
    size = constraints.constrain(
      Size(fill ? constraints.maxWidth : (kids.isEmpty ? 0 : content), height),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
