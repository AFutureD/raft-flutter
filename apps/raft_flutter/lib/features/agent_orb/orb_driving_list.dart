import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'orb_driving.dart';
import 'orb_driving_surface.dart';
import 'orb_widget.dart';

/// The driving surfaces besides the deck, in the deck's own minimal style:
/// the cards of [OrbDrivingCard] (smaller, four to a page), plain lines for
/// what is not a card, the big buttons for what a thumb may press. The app
/// decides what is shown ([OrbDrivingSurface]); these only draw it.

// ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
Color _white(double alpha) => Colors.white.withValues(alpha: alpha);

/// A plain line on the scrim: the heading's small print, the pager, the note
/// of a new arrival.
class OrbPlainLine extends StatelessWidget {
  const OrbPlainLine(this.text, {super.key, this.strong = false});
  final String text;

  /// White and bold (a note to look at), else quiet.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Text(
      text,
      style: RaftTypography.body(
        t,
        size: 16,
        line: 22,
        weight: strong ? FontWeight.w700 : FontWeight.w600,
        // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
        color: strong ? Colors.white : _white(.65),
      ),
    );
  }
}

/// The heading of a list: its name and count in white, what to say quiet.
class OrbListHeading extends StatelessWidget {
  const OrbListHeading({super.key, required this.title, this.hint = ''});
  final String title, hint;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: title,
            style: RaftTypography.heading(
              t,
              size: 20,
              line: 26,
              // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
              color: Colors.white,
            ),
          ),
          if (hint.isNotEmpty)
            TextSpan(
              text: ' · $hint',
              style: RaftTypography.body(
                t,
                size: 16,
                line: 26,
                weight: FontWeight.w600,
                color: _white(.65),
              ),
            ),
        ],
      ),
    );
  }
}

/// One row of a list as a compact card of the deck's style: the small meta
/// line, a one-line headline, one quiet fact at the right.
///
/// [speaking]: the row the agent is on, raised and ringed in white. [mark]:
/// the row was dealt with ("已回复"): dimmed, ticked. [placeholder]: the row is
/// still being read.
class OrbListCard extends StatelessWidget {
  const OrbListCard({
    super.key,
    this.row,
    this.speaking = false,
    this.mark,
    this.onTap,
  });

  /// A card that is being read: grey bars where the words will be.
  const OrbListCard.placeholder({super.key})
    : row = null,
      speaking = false,
      mark = null,
      onTap = null;

  final OrbListRow? row;
  final bool speaking;
  final String? mark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final row = this.row;
    final card = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RaftSpace.x4,
        vertical: RaftSpace.x3,
      ),
      decoration: orbSurface(t, radius: 20),
      child: row == null ? _bars(t) : _words(t, row),
    );
    Widget out = Padding(
      padding: const EdgeInsets.all(RaftSpace.x1),
      child: card,
    );
    if (speaking) {
      out = Transform.translate(
        offset: const Offset(0, -3),
        child: DecoratedBox(
          key: const ValueKey('orb-list-speaking'),
          decoration: BoxDecoration(
            // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
            border: Border.all(color: Colors.white, width: 2),
            borderRadius: t.brutal
                ? BorderRadius.zero
                // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                : BorderRadius.circular(24),
          ),
          child: out,
        ),
      );
    }
    out = Opacity(opacity: mark == null ? 1 : .5, child: out);
    if (row == null || onTap == null) return out;
    return Semantics(
      button: true,
      label: '${row.meta} ${row.title}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: out,
      ),
    );
  }

  Widget _bars(RaftTokens t) {
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: t.muted.withValues(alpha: .3),
        // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bar(110, 12),
        const SizedBox(height: RaftSpace.x2),
        bar(200, 22),
      ],
    );
  }

  Widget _words(RaftTokens t, OrbListRow row) {
    final quiet = RaftTypography.body(
      t,
      size: 15,
      line: 20,
      weight: FontWeight.w600,
      color: t.muted,
    );
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RaftTypography.body(
                  t,
                  size: 14,
                  line: 20,
                  weight: FontWeight.w600,
                  color: t.muted,
                ),
              ),
              Text(
                row.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RaftTypography.heading(t, size: 24, line: 30),
              ),
            ],
          ),
        ),
        const SizedBox(width: RaftSpace.x2),
        if (mark != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RaftIcon(RaftGlyph.check, size: 16, color: t.muted),
              const SizedBox(width: RaftSpace.x1),
              Text(mark!, style: quiet),
            ],
          )
        else if (row.fact.isNotEmpty)
          Text(row.fact, style: quiet),
      ],
    );
  }
}

/// A list: its heading, the cards of the page, the pager. While the rows are
/// read there are grey cards and "正在读…".
class OrbDrivingList extends StatelessWidget {
  const OrbDrivingList({
    super.key,
    required this.surface,
    required this.onOpenRow,
  });
  final OrbDrivingSurface surface;

  /// A card was tapped: the index of the row in the list.
  final void Function(int index) onOpenRow;

  @override
  Widget build(BuildContext context) {
    final list = surface.list!;
    if (list.loading) {
      return Column(
        key: const ValueKey('orb-list-loading'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrbListHeading(title: list.title, hint: '正在读…'),
          const SizedBox(height: RaftSpace.x3),
          for (var i = 0; i < orbListPageSize; i++) ...[
            if (i > 0) const SizedBox(height: RaftSpace.x2),
            OrbListCard.placeholder(key: ValueKey('orb-list-placeholder-$i')),
          ],
        ],
      );
    }
    final rows = surface.pageRows;
    final first = surface.page * orbListPageSize;
    final speaking = surface.speaking;
    return Column(
      key: const ValueKey('orb-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OrbListHeading(
          key: const ValueKey('orb-list-heading'),
          title: list.heading,
          hint: rows.isEmpty ? '' : '说「第 ${rows.length > 1 ? 2 : 1} 个」打开',
        ),
        const SizedBox(height: RaftSpace.x3),
        if (rows.isEmpty)
          OrbPlainLine(list.say ?? '', strong: true)
        else
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: RaftSpace.x2),
            OrbListCard(
              key: ValueKey('orb-list-card-$i'),
              row: rows[i],
              speaking: speaking == first + i,
              mark: surface.markOf(rows[i]),
              onTap: () => onOpenRow(first + i),
            ),
          ],
        if (_foot(list) case final foot when foot.isNotEmpty) ...[
          const SizedBox(height: RaftSpace.x3),
          OrbPlainLine(foot, key: const ValueKey('orb-list-foot')),
        ],
      ],
    );
  }

  String _foot(OrbList list) {
    final left = list.total - (surface.page + 1) * orbListPageSize;
    if (left > 0) return '还有 $left 条，说「下一批」';
    final routine = list.routine > 0 ? '其余 ${list.routine} 条是常规进度' : '';
    if (list.total > orbListPageSize) {
      return routine.isEmpty ? '就这些' : '就这些 · $routine';
    }
    return routine;
  }
}

/// One row, large: the card of the deck (meta, headline, a sentence and how
/// long), then the big buttons. "回复" speaks, so tapping it asks; "稍后" puts
/// the row aside (back to the list); "下一个" is the next row's detail.
class OrbDrivingDetail extends StatelessWidget {
  const OrbDrivingDetail({
    super.key,
    required this.surface,
    required this.onPrimary,
    required this.onLater,
    required this.onNext,
    this.primaryLabel = '打开',
  });
  final OrbDrivingSurface surface;
  final VoidCallback? onPrimary;
  final VoidCallback onLater, onNext;
  final String primaryLabel;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final row = surface.detailRow!;
    final list = surface.list!;
    return Column(
      key: const ValueKey('orb-detail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${list.title} ${list.total} · 第 ${surface.detailIndex! + 1} 个',
          key: const ValueKey('orb-detail-progress'),
          style: RaftTypography.body(
            t,
            size: 16,
            line: 22,
            weight: FontWeight.w700,
            color: _white(.8),
          ),
        ),
        const SizedBox(height: RaftSpace.x3),
        Container(
          key: const ValueKey('orb-detail-card'),
          padding: const EdgeInsets.all(RaftSpace.x4),
          decoration: orbSurface(t, radius: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.meta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: RaftTypography.body(
                  t,
                  size: 15,
                  line: 20,
                  weight: FontWeight.w600,
                  color: t.muted,
                ),
              ),
              const SizedBox(height: RaftSpace.x2),
              Text(
                row.title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: RaftTypography.heading(
                  t,
                  size: orbDrivingTitleSize,
                  line: orbDrivingTitleSize * 1.25,
                ),
              ),
              if (row.summary.isNotEmpty) ...[
                const SizedBox(height: RaftSpace.x2),
                Text(
                  row.summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: RaftTypography.body(
                    t,
                    size: 18,
                    line: 25,
                    weight: FontWeight.w600,
                  ),
                ),
              ],
              if (row.fact.isNotEmpty) ...[
                const SizedBox(height: RaftSpace.x2),
                Row(
                  children: [
                    RaftIcon(RaftGlyph.clock, size: 16, color: t.muted),
                    const SizedBox(width: RaftSpace.x1),
                    Expanded(
                      child: Text(
                        row.fact,
                        style: RaftTypography.body(
                          t,
                          size: 16,
                          line: 22,
                          weight: FontWeight.w600,
                          color: t.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (row.clipped) ...[
                const SizedBox(height: RaftSpace.x2),
                Text(
                  '停车后看原文',
                  key: const ValueKey('orb-detail-clipped'),
                  style: RaftTypography.body(
                    t,
                    size: 15,
                    line: 20,
                    weight: FontWeight.w700,
                    color: t.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: RaftSpace.x4),
        OrbBigButton(
          key: const ValueKey('orb-detail-primary'),
          label: primaryLabel,
          onTap: onPrimary,
          primary: true,
        ),
        const SizedBox(height: RaftSpace.x3),
        Row(
          children: [
            Expanded(
              child: OrbBigButton(
                key: const ValueKey('orb-detail-later'),
                label: '稍后',
                onTap: onLater,
              ),
            ),
            const SizedBox(width: RaftSpace.x3),
            Expanded(
              child: OrbBigButton(
                key: const ValueKey('orb-detail-next'),
                label: '下一个',
                onTap: onNext,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// What can be said on the screen now: two or three phrases under the content.
class OrbDrivingSayHint extends StatelessWidget {
  const OrbDrivingSayHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: RaftTypography.body(
        t,
        size: 14,
        line: 20,
        weight: FontWeight.w600,
        color: _white(.65),
      ),
    );
  }
}

/// The phrases to say on [surface].
String orbSayHintOf(OrbDrivingSurface surface) => switch (surface.kind) {
  OrbSurfaceKind.deck => '说「打开」「下一件」「稍后」',
  OrbSurfaceKind.list =>
    surface.hasNextPage ? '说「第 2 个」「下一批」「返回」' : '说「第 2 个」「返回」',
  OrbSurfaceKind.detail => '说「回复」「稍后」「下一个」「返回」',
};
