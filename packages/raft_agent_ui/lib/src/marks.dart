import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'agent_theme.dart';

/// How a marker annotation is drawn.
enum AgentMarkStyle { circle, underline, highlight, arrow }

/// One annotation: [phrase] inside the item [itemId], drawn like a marker
/// pen. [note] is a few handwritten words next to an [AgentMarkStyle.arrow].
@immutable
class AgentMark {
  const AgentMark({
    required this.itemId,
    required this.phrase,
    this.style = AgentMarkStyle.circle,
    this.note,
  });

  final String itemId;
  final String phrase;
  final AgentMarkStyle style;
  final String? note;

  Map<String, Object?> toJson() => {
    'itemId': itemId,
    'phrase': phrase,
    'style': style.name,
    if (note != null) 'note': note,
  };

  static AgentMark? fromJson(Object? json) {
    if (json is! Map) return null;
    final item = json['itemId'], phrase = json['phrase'];
    if (item is! String || phrase is! String || phrase.isEmpty) return null;
    return AgentMark(
      itemId: item,
      phrase: phrase,
      style:
          AgentMarkStyle.values
              .where((s) => s.name == json['style'])
              .firstOrNull ??
          AgentMarkStyle.circle,
      note: json['note'] as String?,
    );
  }
}

/// The annotations on screen, at most [limit] at a time (oldest goes first).
class AgentMarkController extends ChangeNotifier {
  AgentMarkController({this.limit = 2});
  final int limit;
  final _marks = <AgentMark>[];

  List<AgentMark> get marks => List.unmodifiable(_marks);

  void add(AgentMark mark) {
    _marks.removeWhere(
      (m) => m.itemId == mark.itemId && m.phrase == mark.phrase,
    );
    _marks.add(mark);
    while (_marks.length > limit) {
      _marks.removeAt(0);
    }
    notifyListeners();
  }

  void clear() {
    if (_marks.isEmpty) return;
    _marks.clear();
    notifyListeners();
  }

  /// Mirrors annotations received from elsewhere (e.g. the phone, on a TV).
  void sync(List<AgentMark> marks) {
    _marks
      ..clear()
      ..addAll(marks.take(limit));
    notifyListeners();
  }
}

/// Makes [controller]'s annotations visible to [AgentMarkText] below.
class AgentMarks extends InheritedNotifier<AgentMarkController> {
  const AgentMarks({
    super.key,
    required AgentMarkController controller,
    required super.child,
  }) : super(notifier: controller);

  static AgentMarkController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentMarks>()?.notifier;
}

/// Which agent-addressable item the widgets below belong to.
class AgentItemScope extends InheritedWidget {
  const AgentItemScope({super.key, required this.id, required super.child});
  final String id;

  static String? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentItemScope>()?.id;

  @override
  bool updateShouldNotify(AgentItemScope old) => old.id != id;
}

/// Text the agent can annotate: marks on its item whose phrase it contains
/// are drawn over it with a hand-drawn stroke, animated as they appear.
class AgentMarkText extends StatefulWidget {
  const AgentMarkText(this.text, {super.key, this.style, this.maxLines});
  final String text;
  final TextStyle? style;
  final int? maxLines;

  @override
  State<AgentMarkText> createState() => _AgentMarkTextState();
}

class _AgentMarkTextState extends State<AgentMarkText>
    with SingleTickerProviderStateMixin {
  final _text = GlobalKey();
  late final _draw = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    value: 1,
  );
  List<AgentMark> _mine = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final item = AgentItemScope.of(context);
    final all = AgentMarks.of(context)?.marks ?? const <AgentMark>[];
    final mine = [
      for (final m in all)
        if (m.itemId == item && widget.text.contains(m.phrase)) m,
    ];
    final added = mine.any((m) => !_mine.contains(m));
    _mine = mine;
    if (added) _draw.forward(from: 0);
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final text = Text(
      widget.text,
      key: _text,
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
      style: widget.style,
    );
    if (_mine.isEmpty) return text;
    return CustomPaint(
      foregroundPainter: _MarkPainter(
        paragraph: _text,
        text: widget.text,
        marks: _mine,
        draw: _draw,
        ink: t.markInk,
        highlight: t.markHighlight,
        noteStyle: t.body(14, color: t.markInk, weight: FontWeight.w800),
      ),
      child: text,
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter({
    required this.paragraph,
    required this.text,
    required this.marks,
    required this.draw,
    required this.ink,
    required this.highlight,
    required this.noteStyle,
  }) : super(repaint: draw);

  final GlobalKey paragraph;
  final String text;
  final List<AgentMark> marks;
  final Animation<double> draw;
  final Color ink, highlight;
  final TextStyle noteStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final render = paragraph.currentContext?.findRenderObject();
    if (render is! RenderParagraph || !render.hasSize) return;
    for (var i = 0; i < marks.length; i++) {
      final mark = marks[i];
      final start = text.indexOf(mark.phrase);
      if (start < 0) continue;
      final boxes = render.getBoxesForSelection(
        TextSelection(
          baseOffset: start,
          extentOffset: start + mark.phrase.length,
        ),
      );
      if (boxes.isEmpty) continue;
      // Only the newest stroke animates; earlier ones are already drawn.
      final progress = i == marks.length - 1 ? draw.value : 1.0;
      final seed = mark.phrase.hashCode ^ mark.style.index;
      final rects = [for (final b in boxes) b.toRect()];
      switch (mark.style) {
        case AgentMarkStyle.highlight:
          _highlight(canvas, rects, progress);
        case AgentMarkStyle.underline:
          _underline(canvas, rects, progress, seed);
        case AgentMarkStyle.circle:
          _stroke(
            canvas,
            _roughEllipse(_union(rects).inflate(7), seed),
            progress,
          );
        case AgentMarkStyle.arrow:
          _underline(canvas, rects, progress, seed);
          _arrowNote(canvas, _union(rects), progress, seed, mark.note, size);
      }
    }
  }

  Rect _union(List<Rect> rects) => rects.reduce((a, b) => a.expandToInclude(b));

  Paint get _pen => Paint()
    ..color = ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _stroke(Canvas canvas, Path path, double progress) {
    if (progress <= 0) return;
    for (final PathMetric metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * progress), _pen);
    }
  }

  void _highlight(Canvas canvas, List<Rect> rects, double progress) {
    final paint = Paint()
      ..color = highlight.withValues(alpha: .55)
      ..blendMode = BlendMode.multiply;
    for (final r in rects) {
      final band = Rect.fromLTRB(
        r.left - 2,
        r.top + r.height * .35,
        r.left - 2 + (r.width + 4) * progress,
        r.bottom + 1,
      );
      canvas.drawRect(band, paint);
    }
  }

  void _underline(Canvas canvas, List<Rect> rects, double progress, int seed) {
    final random = math.Random(seed);
    final path = Path();
    for (final r in rects) {
      final y = r.bottom + 2;
      path.moveTo(r.left - 2, y + random.nextDouble() * 1.5);
      const steps = 6;
      for (var s = 1; s <= steps; s++) {
        path.lineTo(
          r.left - 2 + (r.width + 4) * s / steps,
          y + (random.nextDouble() - .5) * 2.4 - s * .25,
        );
      }
    }
    _stroke(canvas, path, progress);
  }

  /// A loop that overshoots where it started, like a quick pen circle.
  Path _roughEllipse(Rect r, int seed) {
    final random = math.Random(seed);
    final path = Path();
    const points = 18;
    final start = -math.pi * .65 + random.nextDouble() * .3;
    final sweep = math.pi * 2 * 1.08;
    Offset at(int i) {
      final a = start + sweep * i / points;
      final wobble = 1 + (random.nextDouble() - .5) * .08;
      return Offset(
        r.center.dx + r.width / 2 * wobble * math.cos(a),
        r.center.dy + r.height / 2 * wobble * math.sin(a),
      );
    }

    final pts = [for (var i = 0; i <= points; i++) at(i)];
    path.moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length - 1; i++) {
      final mid = Offset.lerp(pts[i], pts[i + 1], .5)!;
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  void _arrowNote(
    Canvas canvas,
    Rect target,
    double progress,
    int seed,
    String? note,
    Size size,
  ) {
    final tip = Offset(target.center.dx, target.bottom + 6);
    final tail = tip + const Offset(18, 30);
    final path = Path()
      ..moveTo(tail.dx, tail.dy)
      ..quadraticBezierTo(tip.dx + 14, tip.dy + 16, tip.dx, tip.dy)
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + 9, tip.dy + 3)
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + 1, tip.dy + 10);
    _stroke(canvas, path, progress);
    if (note == null || note.isEmpty || progress < .6) return;
    final painter = TextPainter(
      text: TextSpan(text: note, style: noteStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    canvas.save();
    canvas.translate(tail.dx + 4, tail.dy - 2);
    canvas.rotate(-.06);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.marks != marks || old.text != text || old.ink != ink;
}
