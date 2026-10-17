import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'briefing/orb_briefing_models.dart';
import 'orb_widget.dart';

/// Words that make an action one for when the car is parked.
final _risky = RegExp('批准|合并|删除|发布|approve|merge|delete|release');

/// Whether [item] has to wait until the car is parked: an approval, or an
/// action that approves, merges, deletes or releases.
bool orbNeedsParking(OrbBriefItem item) {
  if (item.reason == OrbReason.awaitingApproval) return true;
  final action = item.suggestedAction;
  return _risky.hasMatch('${action?.label ?? ''} ${action?.text ?? ''}');
}

/// The label of the big button: "停车后批准" for what waits until parked,
/// else "打开" — the button opens the item; the orb cannot send a reply yet,
/// so a suggested "回复：收到" would promise what it does not do.
String orbDrivingButtonLabel(OrbBriefItem item) {
  if (orbNeedsParking(item)) return '停车后批准';
  return '打开';
}

/// The big type of the driving card (a phone in a holder is read at arm's
/// length).
const orbDrivingTitleSize = 30.0;

/// The small "驾驶模式" tag at the top left of the layer.
class OrbDrivingTag extends StatelessWidget {
  const OrbDrivingTag({super.key});

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Container(
      key: const ValueKey('orb-driving-tag'),
      padding: const EdgeInsets.symmetric(
        horizontal: RaftSpace.x2,
        vertical: RaftSpace.x1,
      ),
      decoration: orbSurface(t, fill: t.brutal ? t.product.brutalLime : null),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
          Icon(Icons.directions_car_rounded, size: 16, color: _ink(t)),
          const SizedBox(width: RaftSpace.x1),
          Text(
            '驾驶模式',
            style: RaftTypography.body(
              t,
              size: 12,
              line: 16,
              weight: FontWeight.w700,
              color: _ink(t),
            ),
          ),
        ],
      ),
    );
  }
}

Color _ink(RaftTokens t) => t.brutal ? t.product.brutalBlack : t.strong;

/// One item of the briefing as a single big card, "第 1 件 / 共 N 件" above it
/// and one big button under it (design frame 07-driving). The card is for
/// reading at a glance: the big type is the item's title.
class OrbDrivingCard extends StatelessWidget {
  const OrbDrivingCard({
    super.key,
    required this.item,
    required this.index,
    required this.total,
    required this.onAct,
  });
  final OrbBriefItem item;

  /// Counted from 0.
  final int index;
  final int total;

  /// The big button was tapped (not called while it waits for the parking).
  final VoidCallback onAct;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final waits = orbNeedsParking(item);
    final meta = [item.who, if (item.where.isNotEmpty) item.where].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '第 ${index + 1} 件 / 共 $total 件',
          key: const ValueKey('orb-driving-progress'),
          style: RaftTypography.body(
            t,
            size: 16,
            line: 22,
            weight: FontWeight.w700,
            // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
            color: Colors.white.withValues(alpha: .8),
          ),
        ),
        const SizedBox(height: RaftSpace.x2),
        _Bar(count: total, at: index),
        const SizedBox(height: RaftSpace.x3),
        Container(
          key: const ValueKey('orb-driving-card'),
          padding: const EdgeInsets.all(RaftSpace.x4),
          decoration: orbSurface(t, radius: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                meta,
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
                item.title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: RaftTypography.heading(
                  t,
                  size: orbDrivingTitleSize,
                  line: orbDrivingTitleSize * 1.25,
                ),
              ),
              if (item.since.isNotEmpty) ...[
                const SizedBox(height: RaftSpace.x2),
                Row(
                  children: [
                    RaftIcon(RaftGlyph.clock, size: 16, color: t.muted),
                    const SizedBox(width: RaftSpace.x1),
                    Expanded(
                      child: Text(
                        item.since,
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
            ],
          ),
        ),
        const SizedBox(height: RaftSpace.x4),
        OrbBigButton(
          key: const ValueKey('orb-driving-primary'),
          label: orbDrivingButtonLabel(item),
          onTap: waits ? null : onAct,
          primary: true,
        ),
      ],
    );
  }
}

/// "就这些": every item is through; the routine count is all that is left.
class OrbDrivingDone extends StatelessWidget {
  const OrbDrivingDone({
    super.key,
    required this.routineCount,
    this.waitingTasks = 0,
  });
  final int routineCount;

  /// Tasks that wait for the person: one quiet line, "不急".
  final int waitingTasks;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Column(
      key: const ValueKey('orb-driving-done'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '就这些',
          style: RaftTypography.heading(
            t,
            size: orbDrivingTitleSize,
            line: orbDrivingTitleSize * 1.25,
            // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
            color: Colors.white,
          ),
        ),
        if (routineCount > 0) ...[
          const SizedBox(height: RaftSpace.x2),
          Row(
            key: const Key('orb-briefing-routine'),
            children: [
              RaftIcon(
                RaftGlyph.check,
                size: 16,
                // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
                color: Colors.white.withValues(alpha: .65),
              ),
              const SizedBox(width: RaftSpace.x2),
              Expanded(
                child: Text(
                  '其余 $routineCount 条是常规进度',
                  style: RaftTypography.body(
                    t,
                    size: 16,
                    line: 22,
                    // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
                    color: Colors.white.withValues(alpha: .65),
                  ),
                ),
              ),
            ],
          ),
        ],
        if (waitingTasks > 0) ...[
          const SizedBox(height: RaftSpace.x2),
          Text(
            OrbBriefing.waitingTasksTail(waitingTasks)!,
            key: const ValueKey('orb-driving-waiting-tasks'),
            style: RaftTypography.body(
              t,
              size: 16,
              line: 22,
              // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
              color: Colors.white.withValues(alpha: .65),
            ),
          ),
        ],
      ],
    );
  }
}

/// The hints "下一件" and "稍后", as big as a thumb: tapping one is the same
/// as saying it.
class OrbDrivingHints extends StatelessWidget {
  const OrbDrivingHints({
    super.key,
    required this.onNext,
    required this.onLater,
  });
  final VoidCallback onNext, onLater;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: OrbBigButton(
          key: const ValueKey('orb-driving-next'),
          label: '下一件',
          onTap: onNext,
        ),
      ),
      const SizedBox(width: RaftSpace.x3),
      Expanded(
        child: OrbBigButton(
          key: const ValueKey('orb-driving-later'),
          label: '稍后',
          onTap: onLater,
        ),
      ),
    ],
  );
}

/// A big touch target for the car: 64 dp high, 20 sp type. A null [onTap] is
/// a disabled one.
class OrbBigButton extends StatelessWidget {
  const OrbBigButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
  });
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final disabled = onTap == null;
    final fill = primary
        ? (t.brutal ? t.product.brutalYellow : t.accent)
        : null;
    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: disabled ? .5 : 1,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            // ds-allow: a touch target for the car, bigger than the 48 dp minimum (design frame 07-driving)
            constraints: const BoxConstraints(minHeight: 64),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(
              horizontal: RaftSpace.x3,
              vertical: RaftSpace.x2,
            ),
            decoration: orbSurface(t, fill: fill, radius: 16),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: RaftTypography.heading(
                t,
                size: 20,
                line: 26,
                color: primary && !t.brutal ? t.canvas : _ink(t),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of segments, the ones before and at [at] filled.
class _Bar extends StatelessWidget {
  const _Bar({required this.count, required this.at});
  final int count, at;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    return Row(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: RaftSpace.x1),
          Expanded(
            child: Container(
              // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
              height: 6,
              decoration: BoxDecoration(
                color: i <= at
                    // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
                    ? Colors.white
                    // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
                    : Colors.white.withValues(alpha: .25),
                // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
