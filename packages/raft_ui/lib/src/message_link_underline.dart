import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'message_content_tokens.dart';

/// Link identity survives Markdown's TextSpan flattening. The Markdown state
/// owns and disposes this recognizer, including non-interactive export links.
class MessageLinkRecognizer extends TapGestureRecognizer {}

/// Paints Markdown link decorations without changing paragraph layout,
/// selection, hit testing or semantics. Markdown's forced strut supplies a common
/// line box for all font runs, including CJK fallback runs.
class MessageLinkUnderlines extends SingleChildRenderObjectWidget {
  const MessageLinkUnderlines({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMessageLinkUnderlines();

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMessageLinkUnderlines renderObject,
  ) {
    renderObject.invalidate();
  }
}

class _RenderMessageLinkUnderlines extends RenderProxyBox {
  List<_ParagraphUnderlines>? _paragraphs;
  int _debugGeometryBuildCount = 0;

  @visibleForTesting
  int get debugGeometryBuildCount => _debugGeometryBuildCount;

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
      if (object is RenderParagraph) {
        final strokes = <({Rect rect, Paint paint})>[];
        collectLinks(strokes, object);
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

  void collectLinks(
    List<({Rect rect, Paint paint})> strokes,
    RenderParagraph paragraph,
  ) {
    var position = 0;
    final links = <({TextSelection range, TextStyle style})>[];
    void visit(InlineSpan span) {
      if (span is TextSpan) {
        final start = position;
        position += span.text?.length ?? 0;
        if (span.recognizer is MessageLinkRecognizer && position > start) {
          links.add((
            range: TextSelection(baseOffset: start, extentOffset: position),
            style: span.style!,
          ));
        }
        span.children?.forEach(visit);
      } else if (span is PlaceholderSpan) {
        position++; // WidgetSpan occupies one object-replacement code unit.
      }
    }

    visit(paragraph.text);
    if (links.isEmpty) return;
    for (final link in links) {
      final scale =
          paragraph.textScaler.scale(link.style.fontSize!) /
          link.style.fontSize!;
      final paint = Paint()..color = link.style.color!;
      // Use an actual 2px stroke inside the common line box, unlike
      // TextStyle.decorationThickness (a multiplier of each font's metrics).
      final lineBoxes =
          paragraph
              .getBoxesForSelection(
                link.range,
                boxHeightStyle: ui.BoxHeightStyle.strut,
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
        final top =
            segment.bottom -
            (MessageContentPrimitive.linkUnderlineBottomInset +
                    MessageContentPrimitive.linkUnderlineWidth) *
                scale;
        strokes.add((
          rect: Rect.fromLTWH(
            segment.left,
            top,
            segment.width,
            MessageContentPrimitive.linkUnderlineWidth * scale,
          ),
          paint: paint,
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
  final List<({Rect rect, Paint paint})> strokes;
  final List<({RenderObject parent, RenderObject child})> clips;
}
