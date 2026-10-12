import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'theme.dart';

/// Link identity survives Markdown's TextSpan flattening. The Markdown state
/// owns and disposes this recognizer, including non-interactive export links.
class MessageLinkRecognizer extends TapGestureRecognizer {}

/// An inline underlined run. [color] overrides the text colour (a recipe's
/// `decoration-*`); [active] is false for a hover-only underline at rest.
class RaftUnderlineSpan extends TextSpan {
  const RaftUnderlineSpan({
    super.text,
    super.children,
    super.style,
    super.recognizer,
    super.mouseCursor,
    super.onEnter,
    super.onExit,
    super.semanticsLabel,
    this.color,
    this.active = true,
  });

  final Color? color;
  final bool active;

  /// RenderParagraph keeps its old span when a new one compares identical, so
  /// an underline that toggled (hover) must report a paint difference.
  @override
  RenderComparison compareTo(InlineSpan other) {
    final base = super.compareTo(other);
    if (other is RaftUnderlineSpan &&
        (other.color != color || other.active != active)) {
      return base.index < RenderComparison.paint.index
          ? RenderComparison.paint
          : base;
    }
    return base;
  }

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is RaftUnderlineSpan &&
      other.color == color &&
      other.active == active;

  @override
  int get hashCode => Object.hash(super.hashCode, color, active);
}

/// A standalone `Text` with the unified underline. [underline] false is the
/// resting state of a hover-only underline; [underlineColor] defaults to the
/// text colour.
class RaftUnderlinedText extends StatelessWidget {
  const RaftUnderlinedText(
    this.data, {
    super.key,
    this.style,
    this.underline = true,
    this.underlineColor,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.softWrap,
    this.strutStyle,
  });

  final String data;
  final TextStyle? style;
  final bool underline;
  final Color? underlineColor;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final bool? softWrap;
  final StrutStyle? strutStyle;

  @override
  Widget build(BuildContext context) => RaftUnderlines(
    child: Text.rich(
      RaftUnderlineSpan(text: data, color: underlineColor, active: underline),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      softWrap: softWrap,
      strutStyle: strutStyle,
    ),
  );
}

/// The one underline of the app: Web's hyperlink `underline decoration-2
/// underline-offset-2` (a 2px stroke whose top sits 2px below the alphabetic
/// baseline). Every underlined run (links, @mentions, text buttons, hover-only
/// affordances) is painted by [RaftUnderlines]; Flutter's built-in
/// `TextDecoration.underline` hugs the glyphs and has no offset, so it is not
/// used outside this file (guarded by `raft_underline_guard_test.dart`).
///
/// Three ways to mark text:
///  * [RaftUnderlinedText]: a standalone `Text`;
///  * [RaftUnderlineSpan]: an inline run inside any `Text.rich` that is wrapped
///    in [RaftUnderlines] (mentions, chips, announcement/auth links);
///  * a `TextSpan` carrying a [MessageLinkRecognizer] (Markdown links).
///
/// Paints the underline of every [RaftUnderlineSpan] and
/// [MessageLinkRecognizer] span below it without changing paragraph layout,
/// selection, hit testing or semantics. Wrapped lines get one stroke per line.
/// A nested [RaftUnderlines] owns its own paragraphs, so nothing is drawn twice.
class RaftUnderlines extends SingleChildRenderObjectWidget {
  const RaftUnderlines({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRaftUnderlines(RaftUnderlineMetrics.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderRaftUnderlines renderObject,
  ) {
    renderObject.metrics = RaftUnderlineMetrics.of(context);
    renderObject.invalidate();
  }
}

class _RenderRaftUnderlines extends RenderProxyBox {
  _RenderRaftUnderlines(this._metrics);
  RaftUnderlineMetrics _metrics;
  List<_ParagraphUnderlines>? _paragraphs;
  int _debugGeometryBuildCount = 0;

  @visibleForTesting
  int get debugGeometryBuildCount => _debugGeometryBuildCount;

  set metrics(RaftUnderlineMetrics value) {
    if (value == _metrics) return;
    _metrics = value;
    _paragraphs = null;
  }

  /// Strokes in their paragraph's coordinates, with the line's baseline, the
  /// colour and the paragraph's global origin.
  @visibleForTesting
  List<({Rect rect, double baseline, Color color, Offset origin})>
  get debugUnderlines => [
    for (final lines in _paragraphs ??= collectStrokes())
      for (final stroke in lines.strokes)
        (
          rect: stroke.rect,
          baseline: stroke.baseline,
          color: stroke.paint.color,
          origin: lines.owner.localToGlobal(Offset.zero),
        ),
  ];

  void invalidate() {
    _paragraphs = null;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    super.performLayout();
    _paragraphs = null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final paragraphs = _paragraphs ??= collectStrokes();
    for (final lines in paragraphs) {
      // Inner table scrolling changes paint transforms without text layout.
      // Keep cached geometry local to its paragraph and honor its viewport.
      final origin =
          lines.owner.localToGlobal(Offset.zero, ancestor: this) + offset;
      if (lines.clips.isNotEmpty) context.canvas.save();
      for (final clip in lines.clips) {
        final rect = clip.parent.describeApproximatePaintClip(clip.child);
        if (rect == null) continue;
        context.canvas.clipRect(
          MatrixUtils.transformRect(
            clip.parent.getTransformTo(this),
            rect,
          ).shift(offset),
        );
      }
      for (final stroke in lines.strokes) {
        context.canvas.drawRect(stroke.rect.shift(origin), stroke.paint);
      }
      if (lines.clips.isNotEmpty) context.canvas.restore();
    }
  }

  List<_ParagraphUnderlines> collectStrokes() {
    assert(() {
      _debugGeometryBuildCount++;
      return true;
    }());
    final paragraphs = <_ParagraphUnderlines>[];
    void visit(RenderObject object) {
      if (object is _RenderRaftUnderlines && object != this) return;
      if (object is RenderParagraph) {
        final strokes = <({Rect rect, Paint paint, double baseline})>[];
        collectRuns(strokes, object);
        if (strokes.isNotEmpty) {
          final clips = <({RenderObject parent, RenderObject child})>[];
          RenderObject child = object;
          while (child.parent != null && child.parent != this) {
            final parent = child.parent!;
            if (parent.describeApproximatePaintClip(child) != null) {
              clips.add((parent: parent, child: child));
            }
            child = parent;
          }
          paragraphs.add(_ParagraphUnderlines(object, strokes, clips));
        }
      }
      object.visitChildren(visit);
    }

    if (child != null) visit(child!);
    return paragraphs;
  }

  void collectRuns(
    List<({Rect rect, Paint paint, double baseline})> strokes,
    RenderParagraph paragraph,
  ) {
    var position = 0;
    final runs = <({TextSelection range, TextStyle style, Color? color})>[];
    // A marker covers its text and its children's; an inner marker inside an
    // active one is already covered (no double paint).
    void visit(InlineSpan span, TextStyle inherited, bool covered) {
      if (span is TextSpan) {
        final style = inherited.merge(span.style);
        final start = position;
        final paints =
            !covered &&
            (span is RaftUnderlineSpan
                ? span.active
                : span.recognizer is MessageLinkRecognizer);
        position += span.text?.length ?? 0;
        span.children?.forEach((c) => visit(c, style, covered || paints));
        if (paints && position > start) {
          runs.add((
            range: TextSelection(baseOffset: start, extentOffset: position),
            style: style,
            color: span is RaftUnderlineSpan ? span.color : null,
          ));
        }
      } else if (span is PlaceholderSpan) {
        position++; // WidgetSpan occupies one object-replacement code unit.
      }
    }

    visit(paragraph.text, const TextStyle(), false);
    if (runs.isEmpty) return;
    // The first line's baseline anchors every line: a forced strut (Markdown,
    // banners) or a single font keeps top-to-baseline constant per line.
    // ignore: invalid_use_of_protected_member
    final firstBaseline = paragraph.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    for (final run in runs) {
      final fontSize = run.style.fontSize ?? 14;
      final scale = paragraph.textScaler.scale(fontSize) / fontSize;
      final paint = Paint()..color = run.color ?? run.style.color!;
      // An actual stroke, unlike TextStyle.decorationThickness (a multiplier
      // of each font's metrics) and TextDecoration's fixed glyph-hugging offset.
      final lineBoxes =
          paragraph
              .getBoxesForSelection(
                run.range,
                boxHeightStyle: ui.BoxHeightStyle.max,
              )
              .where((box) => box.right > box.left)
              .toList()
            ..sort((a, b) {
              final line = a.top.compareTo(b.top);
              return line != 0 ? line : a.left.compareTo(b.left);
            });
      Rect? segment;
      void drawSegment() {
        if (segment == null) return;
        final baseline = firstBaseline + segment.top;
        final top = (baseline + _metrics.offset * scale).roundToDouble();
        strokes.add((
          rect: Rect.fromLTWH(
            segment.left,
            top,
            segment.width,
            _metrics.thickness * scale,
          ),
          paint: paint,
          baseline: baseline,
        ));
      }

      for (final box in lineBoxes) {
        final next = box.toRect();
        if (segment != null &&
            next.top == segment.top &&
            next.left <= segment.right + .01) {
          segment = segment.expandToInclude(next);
        } else {
          drawSegment();
          segment = next;
        }
      }
      drawSegment();
    }
  }
}

class _ParagraphUnderlines {
  const _ParagraphUnderlines(this.owner, this.strokes, this.clips);
  final RenderParagraph owner;
  final List<({Rect rect, Paint paint, double baseline})> strokes;
  final List<({RenderObject parent, RenderObject child})> clips;
}
