import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'marks.dart';

/// One line of thread progress: who, when, what.
class AgentQuoteData {
  const AgentQuoteData({
    required this.who,
    required this.time,
    required this.text,
  });
  final String who, time, text;
}

/// What one attention card says. Plain text only: the app decides the words.
class AgentCardData {
  const AgentCardData({
    required this.id,
    required this.rank,
    required this.priority,
    required this.reason,
    required this.wait,
    required this.headline,
    required this.askLine,
    required this.primaryLabel,
    this.approve = false,
    this.channel,
    this.thread,
    this.threadKind,
    this.waiting,
    this.progress = const [],
  });

  final String id;

  /// Position over all sections, from 1.
  final int rank;
  final AgentPriority priority;

  /// The one sticker: 点名找你 / 你派的任务 / 2 人在等 …
  final String reason;

  /// "等了 24 小时" / "5 小时没动".
  final String wait;
  final String headline;

  /// "验收「改名」": the line next to 要你做.
  final String askLine;

  /// Label of the main button when it is not 通过.
  final String primaryLabel;

  /// The main button is 通过 (and writes after a confirmation).
  final bool approve;
  final String? channel, thread, threadKind, waiting;

  /// Oldest first; the last one is the quote on the phone card.
  final List<AgentQuoteData> progress;

  AgentQuoteData? get quote => progress.isEmpty ? null : progress.last;
}

const _cream = Color(0xfffff0bd);
const _radius = 14.0;

double _r(RaftAgentTheme t) => t.cardRadius == 0 ? _radius : t.cardRadius;

Color _band(RaftAgentTheme t, AgentPriority p) =>
    t.cardFills?[p] ?? t.priority(p).withValues(alpha: .22);

Color _creamOf(RaftAgentTheme t) => t.stickerLabels ? _cream : t.chip;

Color _yellow(RaftAgentTheme t) => t.markHighlight;

List<BoxShadow> _hard(RaftAgentTheme t, double d) => t.stickerLabels
    ? [BoxShadow(color: t.line, offset: Offset(d, d))]
    : const [];

double _border(RaftAgentTheme t, [double brutal = 2.5]) =>
    t.stickerLabels ? brutal : t.cardBorderWidth;

/// A small boxed number (rank, count).
class _Box extends StatelessWidget {
  const _Box(this.text, {required this.size, this.fill, this.minWidth = 34});
  final String text;
  final double size;
  final Color? fill;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Container(
      constraints: BoxConstraints(minWidth: minWidth, minHeight: minWidth - 2),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill ?? t.layer,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: t.line, width: _border(t)),
        boxShadow: _hard(t, 2),
      ),
      child: Text(
        text,
        style: t.heading(size, weight: FontWeight.w900).copyWith(height: 1),
      ),
    );
  }
}

/// The "N" in "N 件等你决定": a coloured count badge.
class AgentCountBadge extends StatelessWidget {
  const AgentCountBadge(this.text, {super.key, required this.priority});
  final String text;
  final AgentPriority priority;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: _Box(
        text,
        size: 15,
        minWidth: 26,
        fill: t.cardFills?[priority] ?? t.priority(priority),
      ),
    );
  }
}

/// "3 件等你决定 · 1 件卡住了   另有 1 处点名你", the most urgent line and
/// the scope note.
class AgentAttentionSummary extends StatelessWidget {
  const AgentAttentionSummary({
    super.key,
    required this.decision,
    required this.blocked,
    required this.mention,
    required this.scope,
    this.urgent,
  });

  /// Counts as shown: "3", or "50+" when the source was capped.
  final String? decision, blocked, mention;
  final String? urgent;
  final String scope;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final style = t.body(16.5, weight: FontWeight.w800);
    Widget count(String key, String? n, AgentPriority p, String label) =>
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KeyedSubtree(
              key: ValueKey('attention-count-$key'),
              child: AgentCountBadge(n!, priority: p),
            ),
            const SizedBox(width: 6),
            Text(label, style: style),
          ],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (decision != null)
                count('decision', decision, AgentPriority.decision, '件等你决定'),
              if (decision != null && blocked != null)
                Text('·', style: style),
              if (blocked != null)
                count('blocked', blocked, AgentPriority.blocked, '件卡住了'),
              if (mention != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('另有', style: style),
                    const SizedBox(width: 6),
                    KeyedSubtree(
                      key: const ValueKey('attention-count-mention'),
                      child: AgentCountBadge(
                        mention!,
                        priority: AgentPriority.mention,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('处点名你', style: style),
                  ],
                ),
            ],
          ),
          if (urgent != null) ...[
            const SizedBox(height: 10),
            DecoratedBox(
              decoration: BoxDecoration(
                color: _creamOf(t),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.line, width: _border(t)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InkLabel('最急'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        urgent!,
                        style: t.body(13.5, weight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(scope, style: t.body(11.5, color: t.muted)),
        ],
      ),
    );
  }
}

/// White on ink label ("最急", "要你做").
class _InkLabel extends StatelessWidget {
  const _InkLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.stickerLabels ? t.line : t.foreground,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        child: Text(
          text,
          style: t.body(
            11.5,
            weight: FontWeight.w800,
            color: t.stickerLabels ? t.layer : t.canvas,
          ),
        ),
      ),
    );
  }
}

/// "等你决定 [3] ········ 你的事".
class AgentSectionHeader extends StatelessWidget {
  const AgentSectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.priority,
    this.hint,
  });
  final String title, count;
  final AgentPriority priority;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Row(
        children: [
          Text(title, style: t.heading(15, weight: FontWeight.w900)),
          const SizedBox(width: 8),
          AgentCountBadge(count, priority: priority),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 3,
              child: CustomPaint(painter: _Dots(t.line.withValues(alpha: .45))),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Text(hint!, style: t.body(11, color: t.muted)),
          ],
        ],
      ),
    );
  }
}

class _Dots extends CustomPainter {
  const _Dots(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var x = 1.5; x < size.width; x += 6) {
      canvas.drawCircle(Offset(x, size.height / 2), 1.5, p);
    }
  }

  @override
  bool shouldRepaint(_Dots old) => old.color != color;
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Transform.rotate(
      angle: t.stickerLabels ? -.035 : 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.layer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: t.line, width: _border(t)),
          boxShadow: _hard(t, 2),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
          child: Text(text, style: t.body(12, weight: FontWeight.w800)),
        ),
      ),
    );
  }
}

class _Band extends StatelessWidget {
  const _Band({required this.data, this.big = false});
  final AgentCardData data;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _band(t, data.priority),
        border: Border(
          bottom: BorderSide(color: t.line, width: t.cardBorderWidth),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: big ? 10 : 7),
        child: Row(
          children: [
            _Box('${data.rank}', size: big ? 24 : 21),
            const SizedBox(width: 10),
            Flexible(child: _Tag(data.reason)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                data.wait,
                textAlign: TextAlign.end,
                style: t.body(12.5, weight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "#频道 › 「讨论标题」任务 #1" and "谁在等你".
class _Where extends StatelessWidget {
  const _Where({required this.data, this.size = 12});
  final AgentCardData data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data.channel != null)
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: t.layer,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: t.line, width: 2),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '#${data.channel}',
                    style: t.body(size, weight: FontWeight.w800),
                  ),
                ),
              ),
              if (data.thread != null) ...[
                Text('›', style: t.body(size, color: t.muted)),
                Text('「${data.thread}」', style: t.body(size)),
              ],
              if (data.threadKind != null)
                Text(data.threadKind!, style: t.body(size, color: t.muted)),
            ],
          ),
        if (data.waiting != null) ...[
          const SizedBox(height: 4),
          Text(data.waiting!, style: t.body(size)),
        ],
      ],
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote(this.q);
  final AgentQuoteData q;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: t.line.withValues(alpha: .25), width: 4),
        ),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: [q.who, q.time].where((s) => s.isNotEmpty).join(' · '),
              style: t.body(12.5, color: t.muted, weight: FontWeight.w800),
            ),
            if (q.text.isNotEmpty)
              TextSpan(text: '  ${q.text}', style: t.body(12.5, color: t.hint)),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.ghost = false,
  });
  final String label;
  final VoidCallback? onTap;
  final bool primary, ghost;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final side = BorderSide(
      color: t.line,
      width: t.stickerLabels ? 3 : t.cardBorderWidth,
      style: ghost ? BorderStyle.none : BorderStyle.solid,
    );
    final body = Container(
      padding: EdgeInsets.symmetric(horizontal: ghost ? 10 : 13, vertical: 5),
      decoration: ShapeDecoration(
        color: primary ? _yellow(t) : (ghost ? null : t.layer),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: ghost ? BorderSide.none : side,
        ),
        shadows: ghost ? null : _hard(t, 3),
      ),
      child: Text(
        label,
        style: t.body(
          14,
          weight: ghost ? FontWeight.w800 : FontWeight.w900,
          color: ghost ? t.muted : t.foreground,
        ),
      ),
    );
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ghost
            ? CustomPaint(
                foregroundPainter: _Dashed(t.line, 11),
                child: body,
              )
            : body,
      ),
    );
  }
}

class _Dashed extends CustomPainter {
  const _Dashed(this.color, this.radius);
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashed old) => old.color != color;
}

/// "要你做 验收「改名」" and the actions: 通过 / 打开讨论 / 稍后.
class AgentAskBox extends StatelessWidget {
  const AgentAskBox({
    super.key,
    required this.data,
    this.onApprove,
    this.onOpen,
    this.onLater,
  });
  final AgentCardData data;
  final VoidCallback? onApprove, onOpen, onLater;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final id = data.id;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _creamOf(t),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.line, width: _border(t)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const _InkLabel('要你做'),
                Text(
                  data.askLine,
                  style: t.body(15.5, weight: FontWeight.w900),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 9,
                    runSpacing: 8,
                    children: [
                      if (data.approve) ...[
                        _Btn(
                          key: ValueKey('attention-approve-$id'),
                          label: '通过',
                          primary: true,
                          onTap: onApprove,
                        ),
                        _Btn(
                          key: ValueKey('attention-open-$id'),
                          label: '打开讨论',
                          onTap: onOpen,
                        ),
                      ] else
                        _Btn(
                          key: ValueKey('attention-open-$id'),
                          label: data.primaryLabel,
                          primary: true,
                          onTap: onOpen,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 9),
                _Btn(
                  key: ValueKey('attention-later-$id'),
                  label: '稍后',
                  ghost: true,
                  onTap: onLater,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The phone card: band (rank, reason, wait), a full sentence, where it is,
/// the latest progress as a grey quote, and what to do about it.
class AgentAttentionCard extends StatelessWidget {
  const AgentAttentionCard({
    super.key,
    required this.data,
    this.onApprove,
    this.onOpen,
    this.onLater,
  });
  final AgentCardData data;
  final VoidCallback? onApprove, onOpen, onLater;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final radius = BorderRadius.circular(_r(t));
    final quote = data.quote;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 5, 12, 11),
      child: DecoratedBox(
        key: ValueKey('attention-card-${data.id}'),
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: radius,
          border: Border.all(color: t.line, width: t.cardBorderWidth),
          boxShadow: t.cardShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_r(t) - t.cardBorderWidth),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Band(data: data),
                Padding(
                  padding: const EdgeInsets.fromLTRB(13, 11, 13, 13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: onOpen,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AgentMarkText(
                              data.headline,
                              style: t.heading(16.5, weight: FontWeight.w900),
                            ),
                            const SizedBox(height: 7),
                            _Where(data: data),
                            if (quote != null) ...[
                              const SizedBox(height: 8),
                              _Quote(quote),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 11),
                      AgentAskBox(
                        data: data,
                        onApprove: onApprove,
                        onOpen: onOpen,
                        onLater: onLater,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact list row for the wide master list.
class AgentAttentionRow extends StatelessWidget {
  const AgentAttentionRow({
    super.key,
    required this.data,
    required this.selected,
    this.onTap,
  });
  final AgentCardData data;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final radius = BorderRadius.circular(_r(t));
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 3, 8, 9),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? _creamOf(t) : t.card,
          borderRadius: radius,
          border: Border.all(color: t.line, width: t.cardBorderWidth),
          boxShadow: t.cardShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_r(t) - t.cardBorderWidth),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 54,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _band(t, data.priority),
                        border: Border(
                          right: BorderSide(
                            color: t.line,
                            width: t.cardBorderWidth,
                          ),
                        ),
                      ),
                      child: Text(
                        '${data.rank}',
                        style: t.heading(24, weight: FontWeight.w900),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.headline,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: t.heading(14.5, weight: FontWeight.w900),
                            ),
                            const SizedBox(height: 5),
                            Row(
                              children: [
                                if (data.channel != null)
                                  Flexible(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: t.layer,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: t.line,
                                          width: 2,
                                        ),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        child: Text(
                                          '#${data.channel}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: t.body(
                                            11.5,
                                            weight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    data.reason,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.body(12, color: t.muted),
                                  ),
                                ),
                                Text(
                                  data.wait,
                                  style: t.body(12, weight: FontWeight.w900),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The wide detail pane: the same card, larger, with the last progress lines.
class AgentAttentionDetail extends StatelessWidget {
  const AgentAttentionDetail({
    super.key,
    required this.data,
    this.onApprove,
    this.onOpen,
    this.onLater,
  });
  final AgentCardData data;
  final VoidCallback? onApprove, onOpen, onLater;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final lines = data.progress.length > 3
        ? data.progress.sublist(data.progress.length - 3)
        : data.progress;
    return DecoratedBox(
      key: const ValueKey('attention-detail'),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(_r(t) + 6),
        border: Border.all(color: t.line, width: t.cardBorderWidth),
        boxShadow: _hard(t, 6),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_r(t) + 6 - t.cardBorderWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Band(data: data, big: true),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.headline,
                    style: t.heading(22, weight: FontWeight.w900),
                  ),
                  const SizedBox(height: 10),
                  _Where(data: data, size: 13),
                  if (lines.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: t.layer,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: t.line, width: _border(t)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            child: Text(
                              '最近 ${lines.length} 条进展',
                              style: t.body(12, weight: FontWeight.w800),
                            ),
                          ),
                          for (final l in lines)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: t.line.withValues(alpha: .3),
                                  ),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  9,
                                  12,
                                  9,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 120,
                                      child: Text(
                                        [l.who, l.time]
                                            .where((s) => s.isNotEmpty)
                                            .join(' '),
                                        style: t.body(
                                          11.5,
                                          color: t.muted,
                                          weight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        l.text,
                                        style: t.body(13.5),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  AgentAskBox(
                    data: data,
                    onApprove: onApprove,
                    onOpen: onOpen,
                    onLater: onLater,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "↑↓ 切换 ↵ 通过 S 稍后" under the detail pane.
class AgentKeyHints extends StatelessWidget {
  const AgentKeyHints({super.key, required this.hints});

  /// Each hint is (key, label), e.g. ('↑↓', '切换').
  final List<(String, String)> hints;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          for (final (key, label) in hints)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.layer,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: t.line, width: 2),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    child: Text(key, style: t.body(12, weight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(width: 6),
                Text(label, style: t.body(12, color: t.muted)),
              ],
            ),
        ],
      ),
    );
  }
}

/// The collapsed "团队进度 N 件（不需要你）" row; [children] show when open.
class AgentTeamRow extends StatelessWidget {
  const AgentTeamRow({
    super.key,
    required this.count,
    required this.expanded,
    required this.onTap,
    this.children = const [],
  });

  /// "12" or "50+".
  final String count;
  final bool expanded;
  final VoidCallback onTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final green = t.cardFills?[AgentPriority.progress] ??
        t.priority(AgentPriority.progress);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: CustomPaint(
        foregroundPainter: _Dashed(t.line, _r(t)),
        child: Material(
          color: green.withValues(alpha: .22),
          borderRadius: BorderRadius.circular(_r(t)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                key: const ValueKey('attention-team'),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
                  child: Row(
                    children: [
                      _Box(
                        count.replaceAll('+', ''),
                        size: 14,
                        minWidth: 26,
                        fill: green,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '团队进度 $count 件（不需要你）',
                              style: t.body(14, weight: FontWeight.w800),
                            ),
                            Text(
                              '别人创建、别人验收的任务，点开可看',
                              style: t.body(11.5, color: t.muted),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        expanded ? Icons.expand_less : Icons.chevron_right,
                        color: t.foreground,
                      ),
                    ],
                  ),
                ),
              ),
              if (expanded) ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// One line inside the open team row.
class AgentTeamLine extends StatelessWidget {
  const AgentTeamLine({super.key, required this.text, this.channel});
  final String text;
  final String? channel;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 4, 13, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: t.body(13), maxLines: 2),
          ),
          if (channel != null && channel!.isNotEmpty)
            Text('#$channel', style: t.body(11.5, color: t.muted)),
        ],
      ),
    );
  }
}
