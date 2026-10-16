import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'entity_common.dart';
import 'entity_model.dart';
import 'marks.dart';
import 'surface_cards.dart';

/// One thing the app holds, drawn from its own data by id.
///
/// The model gives only [entity] (kind and id), an optional [handle] ("①",
/// the number the person says to point at it), [emphasis], [tone] and
/// [density]. What the card says comes from the [AgentEntityScope] resolver,
/// so it follows the data when it changes, and an id that cannot be read is
/// drawn as a small "找不到" stub and reported (never invented).
class AgentEntityCard extends StatelessWidget {
  const AgentEntityCard({
    super.key,
    required this.entity,
    this.handle,
    this.emphasis = AgentEmphasis.normal,
    this.tone = AgentTone.neutral,
    this.density = AgentCardDensity.compact,
    this.onTap,
  });
  final AgentEntityRef entity;
  final String? handle;
  final AgentEmphasis emphasis;
  final AgentTone tone;
  final AgentCardDensity density;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => AgentEntityBuilder(
    entity: entity,
    builder: (context, resolution) {
      final Widget body;
      switch (resolution) {
        case AgentEntityFound(:final data):
          body = _FoundCard(
            data: data,
            handle: handle,
            emphasis: emphasis,
            tone: tone,
            compact: density == AgentCardDensity.compact,
          );
        case AgentEntityLoading():
          body = _Stub(entity: entity, handle: handle, text: '读取中…');
        case AgentEntityMissing():
          body = _Stub(
            entity: entity,
            handle: handle,
            text: '找不到${agentEntityKindLabels[entity.kind]}',
            missing: true,
          );
      }
      if (onTap == null) return body;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: body,
      );
    },
  );
}

class _Stub extends StatelessWidget {
  const _Stub({
    required this.entity,
    required this.text,
    this.handle,
    this.missing = false,
  });
  final AgentEntityRef entity;
  final String text;
  final String? handle;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Semantics(
      container: true,
      label: '$text ${entity.id}',
      child: AgentEntityFrame(
        key: ValueKey('entity-stub-${entity.kind.name}-${entity.id}'),
        dashed: true,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            if (handle != null) ...[
              AgentHandleBadge(handle!),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                '$text  ${entity.id}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.body(
                  entityMinText,
                  weight: FontWeight.w800,
                  color: missing ? t.foreground : t.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a card prints, before sizes: filled in per kind.
class _Parts {
  _Parts({
    required this.headline,
    this.lead,
    this.pill,
    this.pillFill,
    this.extraPills = const [],
    this.metaLine = const [],
    this.statusDot,
    this.statusText,
    this.body,
    this.facts = const [],
    this.avatar,
    this.avatarName,
    this.thumb,
    this.semantics = '',
    this.headlineLines = 2,
  });
  final String headline;

  /// Small text left of the pill ("#98").
  final String? lead;
  final String? pill;
  final Color? pillFill;
  final List<(String, Color)> extraPills;

  /// The one meta line of the compact card.
  final List<String> metaLine;
  final Color? statusDot;
  final String? statusText;

  /// Text shown under the headline on the detail card (the message).
  final String? body;

  /// Label / value rows of the detail card.
  final List<(String, String)> facts;
  final AgentAvatarBuilder? avatar;
  final String? avatarName;
  final Widget Function(bool compact)? thumb;
  final String semantics;
  final int headlineLines;
}

_Parts _partsOf(
  BuildContext context,
  RaftAgentTheme t,
  AgentEntityData d,
  bool compact,
) {
  final progress = agentPriorityFill(t, AgentPriority.progress);
  switch (d) {
    case AgentMessageData():
      final meta = [
        d.author,
        ?d.time,
        if (d.channel != null && d.channel!.isNotEmpty) '#${d.channel}',
        if (d.attachmentCount > 0) '附件 ${d.attachmentCount}',
      ];
      return compact
          ? _Parts(
              headline: d.text,
              metaLine: meta,
              avatar: d.avatar,
              avatarName: d.author,
              semantics: '消息，${d.author} 说：${d.text}',
            )
          : _Parts(
              headline: d.author,
              metaLine: meta.skip(1).toList(),
              body: d.text,
              avatar: d.avatar,
              avatarName: d.author,
              headlineLines: 1,
              semantics: '消息，${d.author} 说：${d.text}',
            );
    case AgentTaskData():
      final assignee = d.assignee == null || d.assignee!.isEmpty
          ? null
          : d.assignee;
      final channel = d.channel == null || d.channel!.isEmpty
          ? null
          : '#${d.channel}';
      return _Parts(
        lead: d.number == null ? null : '#${d.number}',
        pill: agentTaskStatusLabels[d.status] ?? d.status,
        pillFill: _taskFill(t, d.status),
        headline: d.title,
        headlineLines: compact ? 2 : 3,
        metaLine: [
          ?(assignee == null ? null : '负责人 $assignee'),
          ?channel,
          ?d.updated,
        ],
        facts: [
          if (assignee != null) ('负责人', assignee),
          if (channel != null) ('频道', channel),
          if (d.updated != null) ('更新', d.updated!),
        ],
        semantics:
            '任务${d.number == null ? '' : ' ${d.number}'}，${agentTaskStatusLabels[d.status] ?? d.status}，${d.title}',
      );
    case AgentAgentData():
      final activity = d.activity == null || d.activity!.isEmpty
          ? null
          : d.activity;
      final computer = d.computer == null || d.computer!.isEmpty
          ? null
          : d.computer;
      return _Parts(
        pill: agentWorkStateLabels[d.state],
        pillFill: agentWorkStateColor(t, d.state),
        headline: d.name,
        headlineLines: 1,
        avatar: d.avatar,
        avatarName: d.name,
        statusDot: agentWorkStateColor(t, d.state),
        metaLine: [?activity, ?(computer == null ? null : '在 $computer')],
        facts: [
          if (activity != null) ('在做', activity),
          if (computer != null) ('电脑', computer),
          if (d.since != null && d.since!.isNotEmpty) ('持续', d.since!),
        ],
        semantics: '${d.name}，${agentWorkStateLabels[d.state]}',
      );
    case AgentChannelData():
      return _Parts(
        headline: d.label,
        headlineLines: 1,
        extraPills: [
          if (d.unread > 0) ('未读 ${d.unread}', progress),
          if (d.mentions > 0)
            ('@我 ${d.mentions}', agentPriorityFill(t, AgentPriority.mention)),
        ],
        metaLine: [if (d.lastActivity != null) '最近 ${d.lastActivity}'],
        facts: [
          ('未读', '${d.unread}'),
          ('@我', '${d.mentions}'),
          if (d.lastActivity != null) ('最近活动', d.lastActivity!),
        ],
        semantics: '${d.direct ? '私聊' : '频道'} ${d.label}，未读 ${d.unread}',
      );
    case AgentMemberData():
      final dot = switch (d.presence) {
        AgentPresence.online => progress,
        AgentPresence.away => agentPriorityFill(t, AgentPriority.blocked),
        AgentPresence.offline => t.hint.withValues(alpha: .35),
      };
      return _Parts(
        headline: d.name,
        headlineLines: 1,
        pill: d.role == null || d.role!.isEmpty ? null : d.role,
        pillFill: t.chip,
        avatar: d.avatar,
        avatarName: d.name,
        statusDot: dot,
        statusText: agentPresenceLabels[d.presence],
        facts: [
          if (d.role != null && d.role!.isNotEmpty) ('角色', d.role!),
          ('状态', agentPresenceLabels[d.presence]!),
        ],
        semantics: '成员 ${d.name}，${agentPresenceLabels[d.presence]}',
      );
    case AgentComputerData():
      final runtimes = d.runtimes.join('、');
      return _Parts(
        headline: d.name,
        headlineLines: 1,
        statusDot: d.online ? progress : t.hint.withValues(alpha: .35),
        statusText: d.online ? '在线' : '离线',
        metaLine: [
          if (runtimes.isNotEmpty) runtimes,
          '${d.agentCount} 个 Agent',
        ],
        facts: [
          if (runtimes.isNotEmpty) ('运行环境', runtimes),
          ('Agent', '${d.agentCount} 个'),
        ],
        semantics: '电脑 ${d.name}，${d.online ? '在线' : '离线'}',
      );
    case AgentFileData():
      final meta = [
        if (d.type != null && d.type!.isNotEmpty) d.type!,
        if (d.size != null && d.size!.isNotEmpty) d.size!,
      ];
      return _Parts(
        headline: d.name,
        headlineLines: 2,
        metaLine: meta,
        facts: [
          if (d.type != null && d.type!.isNotEmpty) ('类型', d.type!),
          if (d.size != null && d.size!.isNotEmpty) ('大小', d.size!),
        ],
        thumb: (compactSize) => _FileThumb(data: d, compact: compactSize),
        semantics: '${d.isImage ? '图片' : '文件'} ${d.name}',
      );
  }
}

Color _taskFill(RaftAgentTheme t, String status) => switch (status) {
  'in_review' => agentPriorityFill(t, AgentPriority.decision),
  'in_progress' || 'done' => agentPriorityFill(t, AgentPriority.progress),
  'todo' => t.chip,
  _ => t.hint.withValues(alpha: .35),
};

class _FileThumb extends StatelessWidget {
  const _FileThumb({required this.data, required this.compact});
  final AgentFileData data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final size = compact
        ? const Size(72, 72)
        : const Size(double.infinity, 168);
    final radius = BorderRadius.circular(t.cardRadius == 0 ? 0 : 10);
    final picture = data.isImage && data.thumbnail != null;
    return DecoratedBox(
      key: ValueKey(picture ? 'entity-thumb' : 'entity-file-icon'),
      decoration: BoxDecoration(
        color: t.chip,
        borderRadius: radius,
        border: Border.all(color: t.line, width: 2.5),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: size.width.isFinite ? size.width : null,
          height: size.height,
          child: picture
              ? LayoutBuilder(
                  builder: (context, box) => data.thumbnail!(
                    context,
                    Size(
                      box.maxWidth.isFinite ? box.maxWidth : size.height,
                      size.height,
                    ),
                  ),
                )
              : Center(
                  child: Icon(
                    data.isImage
                        ? Icons.image_outlined
                        : Icons.insert_drive_file_outlined,
                    size: compact ? 34 : 56,
                    color: t.muted,
                  ),
                ),
        ),
      ),
    );
  }
}

class _FoundCard extends StatelessWidget {
  const _FoundCard({
    required this.data,
    required this.handle,
    required this.emphasis,
    required this.tone,
    required this.compact,
  });
  final AgentEntityData data;
  final String? handle;
  final AgentEmphasis emphasis;
  final AgentTone tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final p = _partsOf(context, t, data, compact);
    final high = emphasis == AgentEmphasis.high;
    final headlineSize = compact ? entityHeadlineCompact : entityHeadlineDetail;
    final metaSize = compact ? entityMetaCompact : entityMinText + 1;
    final hasTop =
        handle != null ||
        p.lead != null ||
        p.pill != null ||
        p.extraPills.isNotEmpty;
    final avatarSize = compact ? 56.0 : 44.0;
    final thumbBeside = p.thumb != null && compact;
    final thumbAbove = p.thumb != null && !compact;

    final meta = <String>[...p.metaLine];
    final showMetaLine = compact || data is AgentMessageData;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasTop)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                if (handle != null) ...[
                  AgentHandleBadge(handle!),
                  const SizedBox(width: 10),
                ],
                if (p.lead != null)
                  Text(
                    p.lead!,
                    style: t.heading(
                      entityMetaCompact,
                      weight: FontWeight.w900,
                    ),
                  ),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (p.pill != null)
                        AgentEntityPill(p.pill!, fill: p.pillFill ?? t.chip),
                      for (final (i, e) in p.extraPills.indexed)
                        AgentEntityPill(e.$1, fill: e.$2, order: i + 1),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.statusDot != null && p.avatarName == null) ...[
              Padding(
                padding: EdgeInsets.only(top: headlineSize * .4),
                child: AgentStatusDot(p.statusDot!, size: compact ? 18 : 14),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: AgentMarkText(
                p.headline,
                maxLines: p.headlineLines,
                style: t
                    .heading(
                      headlineSize,
                      weight: high ? FontWeight.w900 : FontWeight.w800,
                    )
                    .copyWith(height: 1.18),
              ),
            ),
          ],
        ),
        if (showMetaLine && (meta.isNotEmpty || p.statusText != null))
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              children: [
                if (p.statusDot != null && p.avatarName != null) ...[
                  AgentStatusDot(p.statusDot!, size: 14),
                  const SizedBox(width: 6),
                ],
                if (p.statusText != null)
                  Padding(
                    padding: EdgeInsets.only(right: meta.isEmpty ? 0 : 8),
                    child: Text(
                      p.statusText!,
                      style: t.body(metaSize, weight: FontWeight.w800),
                    ),
                  ),
                if (meta.isNotEmpty)
                  Expanded(
                    child: Text(
                      meta.join(' · '),
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.body(metaSize, color: t.muted),
                    ),
                  ),
              ],
            ),
          ),
        if (!compact && p.body != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: AgentMarkText(
              p.body!,
              maxLines: 8,
              style: t.body(entityMetaCompact, color: t.foreground),
            ),
          ),
        if (!compact && p.facts.isNotEmpty && data is! AgentMessageData)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (label, value) in p.facts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 84,
                          child: Text(
                            label,
                            style: t.body(
                              entityMinText,
                              weight: FontWeight.w800,
                              color: t.muted,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(value, style: t.body(entityMetaCompact)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );

    final Widget content;
    if (p.avatarName != null) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AgentEntityAvatar(
            name: p.avatarName!,
            size: avatarSize,
            builder: p.avatar,
          ),
          const SizedBox(width: 12),
          Expanded(child: text),
        ],
      );
    } else if (thumbBeside) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          p.thumb!(true),
          const SizedBox(width: 12),
          Expanded(child: text),
        ],
      );
    } else if (thumbAbove) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [p.thumb!(false), const SizedBox(height: 10), text],
      );
    } else {
      content = text;
    }

    return Semantics(
      container: true,
      label: handle == null
          ? p.semantics
          : '${agentHandleGlyph(handle!)} ${p.semantics}',
      child: AgentEntityFrame(
        key: ValueKey('entity-card-${data.kind.name}'),
        tone: tone,
        emphasis: emphasis,
        child: content,
      ),
    );
  }
}

/// One entity as a single line: handle and name. For a table cell or a
/// timeline row; an unreadable one says "找不到" and is reported like a card.
class AgentEntityInline extends StatelessWidget {
  const AgentEntityInline({
    super.key,
    required this.entity,
    this.handle,
    this.size = 18,
  });
  final AgentEntityRef entity;
  final String? handle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return AgentEntityBuilder(
      entity: entity,
      builder: (context, resolution) {
        final (text, color) = switch (resolution) {
          AgentEntityFound(:final data) => (data.label, t.foreground),
          AgentEntityLoading() => ('读取中…', t.muted),
          AgentEntityMissing() => (
            '找不到${agentEntityKindLabels[entity.kind]} ${entity.id}',
            t.muted,
          ),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (handle != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  agentHandleGlyph(handle!),
                  style: t.heading(size + 2, weight: FontWeight.w900),
                ),
              ),
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.body(size, weight: FontWeight.w700, color: color),
              ),
            ),
          ],
        );
      },
    );
  }
}
