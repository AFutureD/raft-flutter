import 'package:flutter/material.dart';

import 'system_inset.dart';
import 'components.dart';
import 'design_primitives.dart';
import 'dialog_card.dart';
import 'feedback_inbox.dart' show RaftDashedBorderPainter;
import 'icons.dart';
import 'indicators.dart';
import 'panel_layout.dart';
import 'theme.dart';

/// MobileComputersPanel's scrolling card body. The workspace owns its header,
/// accepted rows, loading state, permissions and navigation.
class RaftMobileComputerList extends StatelessWidget {
  const RaftMobileComputerList({
    super.key,
    required this.rows,
    this.loading = false,
    this.error,
    required this.emptyTitle,
    required this.emptyDetail,
    this.onRetry,
    this.onAdd,
    required this.addLabel,
    required this.retryLabel,
  });
  final List<Widget> rows;
  final bool loading;
  final String? error;
  final String emptyTitle, emptyDetail, addLabel, retryLabel;
  final VoidCallback? onRetry, onAdd;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final children = <Widget>[
      if (error != null)
        Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(error!, style: RaftTypography.body(t, size: 14, line: 20)),
              if (onRetry != null)
                RaftButton(label: retryLabel, onPressed: onRetry),
            ],
          ),
        ),
      if (loading && rows.isEmpty)
        for (var i = 0; i < 4; i++)
          ExcludeSemantics(
            child: Container(
              constraints: const BoxConstraints(minHeight: 68),
              padding: const EdgeInsets.all(12),
              decoration: _card(t),
              child: const RaftSkeletonRow(
                avatar: true,
                avatarSize: 40,
                gap: 12,
                lineFractions: [.4, .6],
              ),
            ),
          )
      else
        ...rows,
      if (!loading && rows.isEmpty && error == null)
        RaftEmptyState(
          title: emptyTitle,
          detail: emptyDetail,
          glyph: RaftGlyph.monitor,
        ),
      if (!loading && onAdd != null)
        RaftInteractive(
          key: const ValueKey('computers-add-row'),
          semanticLabel: addLabel,
          onPressed: onAdd,
          builder: (context, state) {
            final border = t.brutal
                ? Colors.black.withValues(alpha: state.hovered ? 1 : .4)
                : t.colors[state.hovered ? 'line-strong' : 'line-muted']!;
            return ClipRRect(
              borderRadius: BorderRadius.circular(t.brutal ? 0 : 6),
              child: CustomPaint(
                foregroundPainter: RaftDashedBorderPainter(
                  border,
                  t.brutal ? 2 : 1,
                ),
                child: Container(
                  color: t.panel,
                  // `p-3` inside the border box (the dashed border adds to it).
                  padding: EdgeInsets.all(12.0 + (t.brutal ? 2 : 1)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      RaftIcon(RaftGlyph.plus, size: 16, color: t.muted),
                      const SizedBox(width: 8),
                      Flexible(
                        child: RaftCssText(
                          addLabel,
                          style: RaftTypography.body(
                            t,
                            size: 14,
                            line: 20,
                            weight: FontWeight.w700,
                            color: t.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
    ];
    return ColoredBox(
      color: t.canvas,
      child: ListView(
        key: const Key('mobile-computers-list'),
        padding: raftScrollPadding(context, const EdgeInsets.all(16)),
        children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const SizedBox(height: 10),
            child,
          ],
        ],
      ),
    );
  }

  BoxDecoration _card(RaftTokens t) => BoxDecoration(
    color: t.panel,
    border: Border.all(
      color: t.brutal ? Colors.black : t.colors['line-muted']!,
      width: t.brutal ? 2 : 1,
    ),
    borderRadius: BorderRadius.circular(t.brutal ? 0 : 6),
    boxShadow: t.brutal ? RaftShadowSet.brutalSm : t.themeShadows.sm.paintOrder,
  );
}
