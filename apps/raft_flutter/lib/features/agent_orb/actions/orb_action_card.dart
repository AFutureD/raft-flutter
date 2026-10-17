import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../orb_driving.dart' show OrbBigButton;
import '../orb_widget.dart';
import 'orb_actions.dart';

/// The confirm card of the orb's layer: what will happen, who and where and
/// the exact words, and the two big buttons. [big] is the driving size: the
/// card is the only thing on the screen then.
class OrbConfirmCard extends StatelessWidget {
  const OrbConfirmCard({
    super.key,
    required this.action,
    required this.busy,
    required this.onConfirm,
    required this.onCancel,
    this.big = false,
  });
  final OrbPendingAction action;

  /// It is being carried out: the buttons are off.
  final bool busy;
  final VoidCallback onConfirm, onCancel;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final valueSize = big ? 22.0 : 18.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('orb-confirm-card'),
          padding: const EdgeInsets.all(RaftSpace.x4),
          decoration: orbSurface(t, radius: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                busy
                    ? '正在做…'
                    : action.sensitive
                    ? '敏感操作 · 第 ${action.step}/${action.total} 次确认'
                    : '要我这样做吗？',
                style: RaftTypography.body(
                  t,
                  size: 14,
                  line: 20,
                  weight: FontWeight.w700,
                  color: t.muted,
                ),
              ),
              const SizedBox(height: RaftSpace.x2),
              Text(
                action.summary,
                maxLines: big ? 4 : 5,
                overflow: TextOverflow.ellipsis,
                style: RaftTypography.heading(
                  t,
                  size: big ? 26 : 22,
                  line: big ? 32 : 28,
                ),
              ),
              const SizedBox(height: RaftSpace.x3),
              for (final row in action.rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: RaftSpace.x2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.label,
                        style: RaftTypography.body(
                          t,
                          size: 13,
                          line: 18,
                          weight: FontWeight.w600,
                          color: t.muted,
                        ),
                      ),
                      Text(
                        row.value,
                        maxLines: big ? 4 : 6,
                        overflow: TextOverflow.ellipsis,
                        style: RaftTypography.body(
                          t,
                          size: valueSize,
                          line: valueSize * 1.3,
                          weight: FontWeight.w600,
                        ),
                      ),
                      if (row.from.isNotEmpty)
                        Text(
                          '原来：${row.from}',
                          style: RaftTypography.body(
                            t,
                            size: 13,
                            line: 18,
                            color: t.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              if (action.heard && !busy && !action.sensitive)
                Text(
                  '听到你说确认了',
                  key: const ValueKey('orb-confirm-heard'),
                  style: RaftTypography.body(
                    t,
                    size: 14,
                    line: 20,
                    weight: FontWeight.w600,
                    color: t.muted,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: RaftSpace.x3),
        Row(
          children: [
            Expanded(
              child: OrbBigButton(
                key: const ValueKey('orb-confirm-cancel'),
                label: '取消',
                onTap: busy ? null : onCancel,
              ),
            ),
            const SizedBox(width: RaftSpace.x3),
            Expanded(
              child: OrbBigButton(
                key: const ValueKey('orb-confirm-yes'),
                label: '确认',
                onTap: busy ? null : onConfirm,
                primary: true,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// What happened to the card: done, the error, cancelled, or "停车后再做".
class OrbActionOutcomeView extends StatelessWidget {
  const OrbActionOutcomeView({
    super.key,
    required this.outcome,
    this.big = false,
  });
  final OrbActionOutcome outcome;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final done = outcome.kind == OrbOutcomeKind.done;
    final bad =
        outcome.kind == OrbOutcomeKind.failed ||
        outcome.kind == OrbOutcomeKind.refused;
    final size = big ? 22.0 : 16.0;
    return Container(
      key: const ValueKey('orb-action-outcome'),
      padding: const EdgeInsets.symmetric(
        horizontal: RaftSpace.x3,
        vertical: RaftSpace.x2,
      ),
      decoration: orbSurface(
        t,
        fill: done ? (t.brutal ? t.product.brutalLime : t.accent) : null,
        radius: 16,
      ),
      child: Row(
        children: [
          RaftIcon(
            bad ? RaftGlyph.circleAlert : RaftGlyph.check,
            size: size,
            color: done && !t.brutal ? t.canvas : t.strong,
          ),
          const SizedBox(width: RaftSpace.x2),
          Expanded(
            child: Text(
              outcome.text,
              style: RaftTypography.heading(
                t,
                size: size,
                line: size * 1.3,
                color: done && !t.brutal ? t.canvas : t.strong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
