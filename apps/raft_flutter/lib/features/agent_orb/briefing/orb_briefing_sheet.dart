import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'orb_briefing_models.dart';

/// Opens an item's real conversation, thread or task. The orb's host wires it
/// to the app's navigation ([OrbBriefItem.link] is an app route).
typedef OrbOpenItem = void Function(OrbBriefItem item);

/// The suggested action chip of a needs-you item was tapped. The sheet only
/// hands it up: whatever it does is confirmed by the host first.
typedef OrbItemAction = void Function(
  OrbBriefItem item,
  OrbSuggestedAction action,
);

/// The briefing as a sheet over the app (design frame 03): the overview, what
/// needs the person, the progress, and how many are routine. Items are the
/// Activity row recipe ([RaftConversationCard]); tapping one opens the real
/// conversation, the chip under a needs-you item runs its suggested action.
class OrbBriefingSheet extends StatelessWidget {
  const OrbBriefingSheet({
    super.key,
    required this.briefing,
    this.onOpen,
    this.onAction,
    this.onClose,
  });

  final OrbBriefing briefing;
  final OrbOpenItem? onOpen;
  final OrbItemAction? onAction;

  /// Defaults to popping the sheet's route.
  final VoidCallback? onClose;

  /// Shows [briefing] in a sheet (a dialog on a wide window) and completes
  /// when it closes.
  static Future<void> show(
    BuildContext context,
    OrbBriefing briefing, {
    OrbOpenItem? onOpen,
    OrbItemAction? onAction,
    double initialSize = .65,
  }) => showRaftPresented<void>(
    context,
    policy: RaftPresentationPolicy.picker,
    sheetInitialSize: initialSize,
    label: '简报',
    content: (context, form) => OrbBriefingSheet(
      briefing: briefing,
      onOpen: onOpen,
      onAction: onAction,
    ),
  );

  static const _padding = EdgeInsets.fromLTRB(
    RaftSpace.x4,
    0,
    RaftSpace.x4,
    RaftSpace.x4,
  );

  @override
  Widget build(BuildContext context) => RaftSheet(
    header: _Header(onClose: onClose ?? () => Navigator.of(context).maybePop()),
    headerExtent: 44,
    body: Padding(
      padding: _padding,
      child: _Body(briefing: briefing, onOpen: onOpen, onAction: onAction),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RaftSpace.x4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '简报',
              style: RaftTypography.heading(t, size: 20, line: 28),
            ),
          ),
          RaftIconButton(
            glyph: RaftGlyph.x,
            tooltip: '关闭',
            visualSize: 32,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.briefing, this.onOpen, this.onAction});
  final OrbBriefing briefing;
  final OrbOpenItem? onOpen;
  final OrbItemAction? onAction;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final b = briefing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          b.overview,
          key: const Key('orb-briefing-overview'),
          style: RaftTypography.body(
            t,
            size: 15,
            line: 22,
            weight: FontWeight.w600,
          ),
        ),
        if (b.needsYou.isNotEmpty) ...[
          _SectionLabel(
            '需要你',
            trailing: RaftResourceBadge(
              label: '${b.needsYou.length}',
              variant: RaftBadgeRecipeVariant.danger,
            ),
          ),
          for (final (i, item) in b.needsYou.indexed) ...[
            if (i > 0) const SizedBox(height: RaftSpace.x2),
            _NeedsYouCard(item: item, onOpen: onOpen, onAction: onAction),
          ],
        ],
        if (b.progress.isNotEmpty) ...[
          const _SectionLabel('进展'),
          for (final (i, item) in b.progress.indexed) ...[
            if (i > 0) const SizedBox(height: RaftSpace.x2),
            _ProgressRow(item: item, onOpen: onOpen),
          ],
        ],
        if (b.routineCount > 0) ...[
          const SizedBox(height: RaftSpace.x4),
          Row(
            key: const Key('orb-briefing-routine'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RaftIcon(RaftGlyph.check, size: 14, color: t.muted),
              const SizedBox(width: RaftSpace.x2),
              Expanded(
                child: Text(
                  '其余 ${b.routineCount} 条是常规进度',
                  style: RaftTypography.body(
                    t,
                    size: 13,
                    line: 18,
                    color: t.muted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: RaftSpace.x4, bottom: RaftSpace.x2),
      child: Row(
        children: [
          Text(
            label,
            style: RaftTypography.body(
              t,
              size: 12,
              line: 16,
              weight: FontWeight.w700,
              color: t.muted,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: RaftSpace.x2),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// The person (or agent) an item is from: a pixel avatar for an agent, a
/// letter avatar for a person, a bell for the system.
Widget _avatar(OrbBriefItem item, double size) {
  if (item.whoKind == 'system') {
    return Builder(
      builder: (context) => SizedBox.square(
        dimension: size,
        child: Center(
          child: RaftIcon(
            RaftGlyph.bell,
            size: size * .7,
            color: RaftTokens.of(context).muted,
          ),
        ),
      ),
    );
  }
  final agent = item.whoKind == 'agent';
  return RaftAvatar(
    name: item.who,
    size: size,
    kind: agent ? RaftAvatarKind.agent : RaftAvatarKind.human,
    mountedContext: RaftMountedAvatarContext.compactList,
    content: RaftAvatarContent(
      name: item.who,
      kind: agent ? RaftAvatarContentKind.agent : RaftAvatarContentKind.human,
      fallback: RaftMountedAvatarFallback(
        avatarContext: RaftMountedAvatarContext.compactList,
        identity: agent
            ? RaftMountedAvatarIdentity.agent
            : RaftMountedAvatarIdentity.human,
      ),
    ),
  );
}

/// What needs the person: the Activity row recipe, with the suggested action
/// under it.
class _NeedsYouCard extends StatelessWidget {
  const _NeedsYouCard({required this.item, this.onOpen, this.onAction});
  final OrbBriefItem item;
  final OrbOpenItem? onOpen;
  final OrbItemAction? onAction;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final recipe = RaftConversationCardRecipe(t);
    final action = item.suggestedAction;
    final meta = [
      if (item.where.isNotEmpty) item.where,
      if (item.why.isNotEmpty) item.why,
    ].join(' · ');
    return RaftConversationCard(
      key: Key('orb-needs-${item.id}'),
      onOpen: () => onOpen?.call(item),
      semanticLabel: '${item.who}：${item.title}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (meta.isNotEmpty) Text(meta, style: recipe.metadata),
          const SizedBox(height: RaftSpace.x1),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(item, 24),
              const SizedBox(width: RaftSpace.x2),
              Expanded(child: Text(item.title, style: recipe.titleStyle(true))),
            ],
          ),
          if (item.since.isNotEmpty) ...[
            const SizedBox(height: RaftSpace.x1),
            Row(
              children: [
                RaftIcon(
                  RaftGlyph.clock,
                  size: 12,
                  color: recipe.titleIconColor,
                ),
                const SizedBox(width: RaftSpace.x1),
                Expanded(
                  child: Text(
                    item.since,
                    style: recipe.body.copyWith(color: recipe.senderColor),
                  ),
                ),
              ],
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: RaftSpace.x3),
            Align(
              alignment: Alignment.centerLeft,
              child: RaftButton(
                key: Key('orb-action-${item.id}'),
                label: action.label,
                glyph: action.kind == 'reply'
                    ? RaftGlyph.reply
                    : RaftGlyph.arrowUpRight,
                visualHeight: 32,
                onPressed: () => onAction?.call(item, action),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One line of progress: who, what happened, a chevron.
class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.item, this.onOpen});
  final OrbBriefItem item;
  final OrbOpenItem? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final recipe = RaftConversationCardRecipe(t);
    return RaftConversationCard(
      key: Key('orb-progress-${item.id}'),
      onOpen: () => onOpen?.call(item),
      semanticLabel: '${item.who}：${item.title}',
      child: Row(
        children: [
          _avatar(item, 20),
          const SizedBox(width: RaftSpace.x2),
          Expanded(
            child: Text(
              '${item.who}：${item.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: recipe
                  .titleStyle(true)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          RaftIcon(
            RaftGlyph.chevronRight,
            size: 14,
            color: recipe.titleIconColor,
          ),
        ],
      ),
    );
  }
}
