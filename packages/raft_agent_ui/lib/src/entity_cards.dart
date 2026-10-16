import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'display_spec.dart';
import 'entity_common.dart';
import 'entity_model.dart';
import 'marks.dart';
import 'surface_cards.dart';

/// One thing the app holds, drawn from its own data by id.
///
/// The model gives only [entity] (kind and id), an optional [handle] ("①",
/// the number the person says to point at it), [emphasis], [tone] and a
/// [display]: a preset level, and which of the elements of the card are
/// shown. What the card says comes from the [AgentEntityScope] resolver,
/// so it follows the data when it changes, and an id that cannot be read is
/// drawn as a small "找不到" stub and reported (never invented).
///
/// [density] is the screen's default: the level and type scale a card has
/// when [display] says neither.
class AgentEntityCard extends StatelessWidget {
  const AgentEntityCard({
    super.key,
    required this.entity,
    this.handle,
    this.emphasis = AgentEmphasis.normal,
    this.tone = AgentTone.neutral,
    this.density = AgentCardDensity.compact,
    this.display,
    this.onTap,
  });
  final AgentEntityRef entity;
  final String? handle;
  final AgentEmphasis emphasis;
  final AgentTone tone;
  final AgentCardDensity density;

  /// What to show; unset parts come from [density].
  final DisplaySpec? display;
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
            density: density,
            spec: display ?? DisplaySpec.none,
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

/// One coloured word in the top row of a card.
class _Pill {
  const _Pill(this.text, this.fill);
  final String text;
  final Color fill;
}

/// What a card prints, before sizes: filled in per kind from the elements
/// that are shown.
class _Parts {
  String? headline;
  int headlineLines = 1;

  /// Small text left of the pills ("#98").
  String? lead;
  final pills = <_Pill>[];

  /// The one meta line of the compact card.
  final meta = <String>[];
  int metaLines = 2;
  Color? statusDot;
  String? statusText;

  /// Text under the headline (a message on the detail card, a description).
  String? body;
  int bodyLines = 3;

  /// The latest thing said about a task.
  String? quote;

  /// "👍 3", "回复 2".
  final chips = <String>[];

  /// Label / value rows of the detail card.
  final facts = <(String, String)>[];
  AgentAvatarBuilder? avatar;
  String? avatarName;
  Widget Function(bool compact)? thumb;
  String semantics = '';

  bool get hasContent =>
      headline != null ||
      lead != null ||
      pills.isNotEmpty ||
      meta.isNotEmpty ||
      statusText != null ||
      body != null ||
      quote != null ||
      chips.isNotEmpty ||
      facts.isNotEmpty ||
      avatarName != null ||
      thumb != null;
}

String? _some(String? s) => s == null || s.isEmpty ? null : s;

_Parts _partsOf(
  RaftAgentTheme t,
  AgentEntityData d,
  AgentDisplay x, {
  required bool detail,
}) {
  final has = x.has;
  final progress = agentPriorityFill(t, AgentPriority.progress);
  final p = _Parts();
  switch (d) {
    case AgentMessageData():
      p.semantics = '消息，${d.author} 说：${d.text}';
      if (has('avatar')) {
        p.avatar = d.avatar;
        p.avatarName = d.author;
      }
      final time = has('time') ? _some(d.time) : null;
      final channel = has('channel') ? _some(d.channel) : null;
      final meta = [
        if (!detail && has('author')) d.author,
        ?time,
        if (channel != null) '#$channel',
        if (has('attachments') && d.attachmentCount > 0)
          '附件 ${d.attachmentCount}',
      ];
      p.meta.addAll(meta);
      if (detail) {
        p.headline = has('author') ? d.author : null;
        p.body = has('text') ? d.text : null;
        p.bodyLines = x.lines;
      } else {
        p.headline = has('text') ? d.text : null;
        p.headlineLines = x.lines;
      }
      if (has('reactions')) {
        for (final r in d.reactions) {
          if (r.count > 0) p.chips.add('${r.emoji} ${r.count}');
        }
      }
      if (has('thread_count') && d.threadCount > 0) {
        p.chips.add('回复 ${d.threadCount}');
      }
    case AgentTaskData():
      final status = agentTaskStatusLabels[d.status] ?? d.status;
      p.semantics =
          '任务${d.number == null ? '' : ' ${d.number}'}，$status，${d.title}';
      if (has('number') && d.number != null) p.lead = '#${d.number}';
      if (has('status')) p.pills.add(_Pill(status, _taskFill(t, d.status)));
      if (has('title')) p.headline = d.title;
      p.headlineLines = x.lines;
      final assignee = has('assignee') ? _some(d.assignee) : null;
      final channel = has('channel') ? _some(d.channel) : null;
      final updated = has('updated') ? _some(d.updated) : null;
      if (detail) {
        p.facts.addAll([
          ?(assignee == null ? null : ('负责人', assignee)),
          ?(channel == null ? null : ('频道', '#$channel')),
          ?(updated == null ? null : ('更新', updated)),
        ]);
      } else {
        p.meta.addAll([
          ?(assignee == null ? null : '负责人 $assignee'),
          ?(channel == null ? null : '#$channel'),
          ?updated,
        ]);
      }
      if (has('description')) p.body = _some(d.description);
      if (has('latest_progress')) p.quote = _some(d.latestProgress);
    case AgentAgentData():
      p.semantics = '${d.name}，${agentWorkStateLabels[d.state]}';
      if (has('avatar')) {
        p.avatar = d.avatar;
        p.avatarName = d.name;
      }
      if (has('name')) p.headline = d.name;
      if (has('state')) {
        p.pills.add(
          _Pill(
            agentWorkStateLabels[d.state] ?? '',
            agentWorkStateColor(t, d.state),
          ),
        );
        p.statusDot = agentWorkStateColor(t, d.state);
      }
      final activity = has('activity') ? _some(d.activity) : null;
      final computer = has('computer') ? _some(d.computer) : null;
      final since = has('since') ? _some(d.since) : null;
      final channel = has('channel') ? _some(d.channel) : null;
      final model = has('model') ? _some(d.model) : null;
      p.metaLines = x.lines;
      if (detail) {
        p.facts.addAll([
          ?(activity == null ? null : ('在做', activity)),
          ?(computer == null ? null : ('电脑', computer)),
          ?(since == null ? null : ('持续', since)),
          ?(channel == null ? null : ('频道', '#$channel')),
          ?(model == null ? null : ('模型', model)),
        ]);
      } else {
        p.meta.addAll([
          ?activity,
          ?(computer == null ? null : '在 $computer'),
          ?since,
          ?(channel == null ? null : '#$channel'),
          ?model,
        ]);
      }
    case AgentChannelData():
      p.semantics = '${d.direct ? '私聊' : '频道'} ${d.label}，未读 ${d.unread}';
      if (has('name')) p.headline = d.label;
      if (has('unread') && d.unread > 0) {
        p.pills.add(_Pill('未读 ${d.unread}', progress));
      }
      if (has('mentions') && d.mentioned) {
        p.pills.add(_Pill('@我', agentPriorityFill(t, AgentPriority.mention)));
      }
      final last = has('last_activity') ? _some(d.lastActivity) : null;
      final members = has('members') ? d.memberCount : null;
      if (has('description')) p.body = _some(d.description);
      p.bodyLines = x.lines;
      if (detail) {
        p.facts.addAll([
          if (has('unread')) ('未读', '${d.unread}'),
          if (has('mentions')) ('@我', d.mentioned ? '有' : '无'),
          ?(last == null ? null : ('最近活动', last)),
          ?(members == null ? null : ('成员', '$members')),
        ]);
      } else {
        p.meta.addAll([
          ?(last == null ? null : '最近 $last'),
          ?(members == null ? null : '成员 $members'),
        ]);
      }
    case AgentMemberData():
      final presence = d.presence;
      p.semantics =
          '成员 ${d.name}${presence == null ? '' : '，${agentPresenceLabels[presence]}'}';
      if (has('avatar')) {
        p.avatar = d.avatar;
        p.avatarName = d.name;
      }
      if (has('name')) p.headline = d.name;
      p.headlineLines = x.lines;
      if (has('role') && _some(d.role) != null) {
        p.pills.add(_Pill(d.role!, t.chip));
      }
      if (has('presence') && presence != null) {
        p.statusDot = switch (presence) {
          AgentPresence.online => progress,
          AgentPresence.away => agentPriorityFill(t, AgentPriority.blocked),
          AgentPresence.offline => t.hint.withValues(alpha: .35),
        };
        p.statusText = agentPresenceLabels[presence];
      }
    case AgentComputerData():
      final runtimes = d.runtimes.join('、');
      p.semantics = '电脑 ${d.name}，${d.online ? '在线' : '离线'}';
      if (has('name')) p.headline = d.name;
      p.headlineLines = x.lines;
      if (has('online')) {
        p.statusDot = d.online ? progress : t.hint.withValues(alpha: .35);
        p.statusText = d.online ? '在线' : '离线';
      }
      final version = has('version') ? _some(d.version) : null;
      final showRuntimes = has('runtimes') && runtimes.isNotEmpty;
      if (detail) {
        p.facts.addAll([
          if (showRuntimes) ('运行环境', runtimes),
          if (has('agents')) ('Agent', '${d.agentCount} 个'),
          ?(version == null ? null : ('版本', version)),
        ]);
      } else {
        p.meta.addAll([
          if (showRuntimes) runtimes,
          if (has('agents')) '${d.agentCount} 个 Agent',
          ?(version == null ? null : 'v$version'),
        ]);
      }
    case AgentFileData():
      p.semantics = '${d.isImage ? '图片' : '文件'} ${d.name}';
      if (has('name')) p.headline = d.name;
      p.headlineLines = x.lines;
      final type = has('type') ? _some(d.type) : null;
      final size = has('size') ? _some(d.size) : null;
      final author = has('author') ? _some(d.author) : null;
      if (detail) {
        p.facts.addAll([
          ?(type == null ? null : ('类型', type)),
          ?(size == null ? null : ('大小', size)),
          ?(author == null ? null : ('上传者', author)),
        ]);
      } else {
        p.meta.addAll([?type, ?size, ?author]);
      }
      if (has('thumbnail')) {
        p.thumb = (compactSize) => _FileThumb(data: d, compact: compactSize);
      }
  }
  // Every element off still leaves a card that says what it is.
  if (!p.hasContent) p.headline = d.label;
  return p;
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
    required this.density,
    required this.spec,
  });
  final AgentEntityData data;
  final String? handle;
  final AgentEmphasis emphasis;
  final AgentTone tone;
  final AgentCardDensity density;
  final DisplaySpec spec;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final x = spec.resolve(
      data.kind.name,
      fallbackLevel: density == AgentCardDensity.compact
          ? AgentLevel.medium
          : AgentLevel.detail,
    );
    // The level picks how much; the facts of the detail card are labelled
    // rows, the others a single meta line.
    final detail = x.level == AgentLevel.detail;
    final scale = x.scale(
      density == AgentCardDensity.compact
          ? AgentTypeScale.compact
          : AgentTypeScale.wide,
    );
    final p = _partsOf(t, data, x, detail: detail);
    final high = emphasis == AgentEmphasis.high;
    final headlineSize = scale.headline;
    final metaSize = scale.meta;
    final showHandle = handle != null && x.has('handle');
    final hasTop = p.lead != null || p.pills.isNotEmpty;
    final avatarSize = detail ? 44.0 : (scale.headline * 2.15).roundToDouble();
    final thumbBeside = p.thumb != null && !detail;
    final thumbAbove = p.thumb != null && detail;
    // With nothing else in the top row the handle sits in front of the
    // headline, and a minimum card stays one line.
    final handleInline = showHandle && !hasTop && p.headline != null;
    final handleTop = showHandle && !handleInline;
    final topRow = handleTop || hasTop;

    final showStatusRow = p.meta.isNotEmpty || p.statusText != null;
    final headline = p.headline == null
        ? null
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (handleInline) ...[
                AgentHandleBadge(handle!),
                const SizedBox(width: 10),
              ],
              if (p.statusDot != null && p.avatarName == null) ...[
                Padding(
                  padding: EdgeInsets.only(top: headlineSize * .4),
                  child: AgentStatusDot(p.statusDot!, size: detail ? 14 : 18),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: AgentMarkText(
                  p.headline!,
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
          );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (topRow)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                if (handleTop) ...[
                  AgentHandleBadge(handle!),
                  const SizedBox(width: 10),
                ],
                if (p.lead != null)
                  Text(
                    p.lead!,
                    style: t.heading(scale.meta, weight: FontWeight.w900),
                  ),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final (i, e) in p.pills.indexed)
                        AgentEntityPill(
                          e.text,
                          fill: e.fill,
                          order: i,
                          size: scale.small,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ?headline,
        if (showStatusRow)
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
                    padding: EdgeInsets.only(right: p.meta.isEmpty ? 0 : 8),
                    child: Text(
                      p.statusText!,
                      style: t.body(metaSize, weight: FontWeight.w800),
                    ),
                  ),
                if (p.meta.isNotEmpty)
                  Expanded(
                    child: Text(
                      p.meta.join(' · '),
                      maxLines: p.metaLines,
                      overflow: TextOverflow.ellipsis,
                      style: t.body(metaSize, color: t.muted),
                    ),
                  ),
              ],
            ),
          ),
        if (p.body != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: AgentMarkText(
              p.body!,
              maxLines: p.bodyLines,
              style: t.body(scale.body, color: t.foreground),
            ),
          ),
        if (p.quote != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: t.line.withValues(alpha: .25),
                    width: 4,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: AgentMarkText(
                  p.quote!,
                  maxLines: 3,
                  style: t.body(metaSize, color: t.muted),
                ),
              ),
            ),
          ),
        if (p.chips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final c in p.chips)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: t.chip,
                      borderRadius: BorderRadius.circular(
                        t.cardRadius == 0 ? 0 : 999,
                      ),
                      border: Border.all(color: t.line, width: 1.5),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 2,
                      ),
                      child: Text(
                        c,
                        style: t.body(scale.small, weight: FontWeight.w800),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (p.facts.isNotEmpty)
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
                          width: (scale.small * 5.25).roundToDouble(),
                          child: Text(
                            label,
                            style: t.body(
                              scale.small,
                              weight: FontWeight.w800,
                              color: t.muted,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            value,
                            maxLines: data is AgentAgentData ? p.metaLines : 3,
                            overflow: TextOverflow.ellipsis,
                            style: t.body(scale.body),
                          ),
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
