import 'package:flutter/material.dart';

import '../display_spec.dart';
import '../entity_model.dart';
import 'hf_detail.dart';
import 'hf_row.dart';
import 'hf_scope.dart';
import 'hf_tokens.dart';

/// The place a component has on the numbered screen: the number its row wears
/// on the bar (what the person says to point at it) and its focus id. The
/// surface view puts one around every numbered component; a card without one
/// (the thing a confirm card is about, a table cell) is not numbered.
class HfItemScope extends InheritedWidget {
  const HfItemScope({
    super.key,
    required this.index,
    this.focusId,
    required super.child,
  });
  final int index;
  final String? focusId;

  static HfItemScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HfItemScope>();

  @override
  bool updateShouldNotify(HfItemScope old) =>
      old.index != index || old.focusId != focusId;
}

/// The colour of a task status: waiting for the person is red, moving is
/// green, anything else is plain information.
HfTone hfTaskTone(String status) => switch (status) {
  'in_review' => HfTone.decision,
  'in_progress' || 'done' => HfTone.progress,
  _ => HfTone.info,
};

/// The colour of what an agent is doing: busy green, blocked orange, the rest
/// information (so the busy ones stand out).
HfTone hfWorkTone(AgentWorkState s) => switch (s) {
  AgentWorkState.busy => HfTone.progress,
  AgentWorkState.blocked => HfTone.blocked,
  AgentWorkState.idle || AgentWorkState.offline => HfTone.info,
};

/// A tone the model asked for (`good`, `warn`) over the colour the thing has.
HfTone hfToneOver(AgentTone tone, HfTone base) => switch (tone) {
  AgentTone.good => HfTone.progress,
  AgentTone.warn => HfTone.blocked,
  AgentTone.neutral => base,
};

/// A square avatar: the app's own when given, else the first letter.
class HfAvatar extends StatelessWidget {
  const HfAvatar({super.key, required this.name, this.builder, this.size = 44});
  final String name;
  final AgentAvatarBuilder? builder;

  /// In s-units.
  final double size;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final px = hf.sp(size);
    final radius = BorderRadius.circular(hf.sp(10));
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: HfColors.ink, width: hf.sp(2.5)),
        color: HfColors.cream,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox.square(
          dimension: px,
          child: builder != null
              ? builder!(context, px)
              : Center(
                  child: Text(
                    initial,
                    style: hf.type(HfType.headline, base: size * .5),
                  ),
                ),
        ),
      ),
    );
  }
}

/// A file's picture or its icon, small, at the right of its row.
class HfThumb extends StatelessWidget {
  const HfThumb({super.key, required this.data});
  final AgentFileData data;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final px = hf.sp(56);
    final radius = BorderRadius.circular(hf.sp(10));
    final picture = data.isImage && data.thumbnail != null;
    return DecoratedBox(
      key: ValueKey(picture ? 'entity-thumb' : 'entity-file-icon'),
      decoration: BoxDecoration(
        color: HfColors.cream,
        borderRadius: radius,
        border: Border.all(color: HfColors.ink, width: hf.sp(2.5)),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox.square(
          dimension: px,
          child: picture
              ? data.thumbnail!(context, Size.square(px))
              : Center(
                  child: Icon(
                    data.isImage
                        ? Icons.image_outlined
                        : Icons.insert_drive_file_outlined,
                    size: hf.sp(30),
                    color: HfColors.inkSoft,
                  ),
                ),
        ),
      ),
    );
  }
}

/// What a card prints, before it is drawn: filled in per kind from the
/// elements that are shown.
class _Parts {
  String? title;
  int titleLines = 2;
  final meta = <String>[];
  final detail = <String>[];
  int detailLines = 1;
  HfTone tone = HfTone.info;

  /// The detail card: label and value rows, and the last thing said.
  final facts = <HfFact>[];
  String? quote;
  Widget? trailing;
  String semantics = '';

  bool get hasContent =>
      title != null || meta.isNotEmpty || detail.isNotEmpty || facts.isNotEmpty;
}

String? _some(String? s) => s == null || s.isEmpty ? null : s;

_Parts _partsOf(AgentEntityData d, AgentDisplay x) {
  final has = x.has;
  final p = _Parts();
  switch (d) {
    case AgentMessageData():
      p.semantics = '消息，${d.author} 说：${d.text}';
      p.tone = HfTone.info;
      if (has('avatar')) {
        p.trailing = HfAvatar(name: d.author, builder: d.avatar);
      }
      final time = has('time') ? _some(d.time) : null;
      final channel = has('channel') ? _some(d.channel) : null;
      p.meta.addAll([
        if (has('author')) d.author,
        ?time,
        if (channel != null) '#$channel',
        if (has('attachments') && d.attachmentCount > 0)
          '附件 ${d.attachmentCount}',
      ]);
      if (has('text')) p.title = d.text;
      p.titleLines = x.lines;
      if (has('reactions')) {
        for (final r in d.reactions) {
          if (r.count > 0) p.detail.add('${r.emoji} ${r.count}');
        }
      }
      if (has('thread_count') && d.threadCount > 0) {
        p.detail.add('回复 ${d.threadCount}');
      }
      p.facts.addAll([
        if (has('author')) HfFact('发送者', d.author),
        ?(time == null ? null : HfFact('时间', time)),
        ?(channel == null ? null : HfFact('频道', '#$channel')),
        if (has('reactions') && p.detail.any((e) => !e.startsWith('回复')))
          HfFact('回应', p.detail.where((e) => !e.startsWith('回复')).join(' ')),
        if (has('thread_count') && d.threadCount > 0)
          HfFact('回复', '回复 ${d.threadCount}'),
      ]);
    case AgentTaskData():
      final status = agentTaskStatusLabels[d.status] ?? d.status;
      p.semantics =
          '任务${d.number == null ? '' : ' ${d.number}'}，$status，${d.title}';
      p.tone = hfTaskTone(d.status);
      final number = has('number') && d.number != null ? '#${d.number}' : null;
      final assignee = has('assignee') ? _some(d.assignee) : null;
      final channel = has('channel') ? _some(d.channel) : null;
      final updated = has('updated') ? _some(d.updated) : null;
      p.meta.addAll([
        if (has('status')) status,
        ?number,
        ?updated,
        ?(assignee == null ? null : '负责人 $assignee'),
        ?(channel == null ? null : '#$channel'),
      ]);
      if (has('title')) p.title = d.title;
      p.titleLines = x.lines;
      final description = has('description') ? _some(d.description) : null;
      final quote = has('latest_progress') ? _some(d.latestProgress) : null;
      p.detail.addAll([?description, ?quote]);
      p.detailLines = x.lines > 1 ? 2 : 1;
      p.quote = quote;
      p.facts.addAll([
        ?(assignee == null ? null : HfFact('负责人', assignee)),
        ?(channel == null ? null : HfFact('频道', '#$channel')),
        ?(updated == null ? null : HfFact('更新', updated)),
        ?(description == null ? null : HfFact('描述', description)),
      ]);
    case AgentAgentData():
      p.semantics = '${d.name}，${agentWorkStateLabels[d.state]}';
      p.tone = hfWorkTone(d.state);
      if (has('avatar')) {
        p.trailing = HfAvatar(name: d.name, builder: d.avatar);
      }
      final activity = has('activity') ? _some(d.activity) : null;
      final computer = has('computer') ? _some(d.computer) : null;
      final since = has('since') ? _some(d.since) : null;
      final channel = has('channel') ? _some(d.channel) : null;
      final model = has('model') ? _some(d.model) : null;
      p.meta.addAll([
        if (has('state')) agentWorkStateLabels[d.state] ?? '',
        ?since,
      ]);
      if (has('name')) p.title = d.name;
      p.detail.addAll([
        ?activity,
        ?(computer == null ? null : '在 $computer'),
        ?(channel == null ? null : '#$channel'),
        ?model,
      ]);
      p.detailLines = x.lines > 1 ? 2 : 1;
      p.facts.addAll([
        ?(activity == null ? null : HfFact('在做', activity)),
        ?(computer == null ? null : HfFact('电脑', computer)),
        ?(since == null ? null : HfFact('持续', since)),
        ?(channel == null ? null : HfFact('频道', '#$channel')),
        ?(model == null ? null : HfFact('模型', model)),
      ]);
    case AgentChannelData():
      p.semantics = '${d.direct ? '私聊' : '频道'} ${d.label}，未读 ${d.unread}';
      p.tone = d.mentioned
          ? HfTone.mention
          : d.unread > 0
          ? HfTone.progress
          : HfTone.info;
      final last = has('last_activity') ? _some(d.lastActivity) : null;
      final members = has('members') ? d.memberCount : null;
      p.meta.addAll([
        if (has('unread') && d.unread > 0) '未读 ${d.unread}',
        if (has('mentions') && d.mentioned) '@我',
        ?(last == null ? null : '最近 $last'),
        ?(members == null ? null : '成员 $members'),
      ]);
      if (has('name')) p.title = d.label;
      if (has('description')) p.detail.addAll([?_some(d.description)]);
      p.detailLines = x.lines > 1 ? 2 : 1;
      p.facts.addAll([
        if (has('description') && _some(d.description) != null)
          HfFact('简介', d.description!),
        if (has('unread')) HfFact('未读', '${d.unread}'),
        if (has('mentions')) HfFact('@我', d.mentioned ? '有' : '无'),
        ?(last == null ? null : HfFact('最近活动', last)),
        ?(members == null ? null : HfFact('成员', '$members')),
      ]);
    case AgentMemberData():
      final presence = d.presence;
      p.semantics =
          '成员 ${d.name}${presence == null ? '' : '，${agentPresenceLabels[presence]}'}';
      p.tone = switch (presence) {
        AgentPresence.online => HfTone.progress,
        AgentPresence.away => HfTone.blocked,
        _ => HfTone.info,
      };
      if (has('avatar')) {
        p.trailing = HfAvatar(name: d.name, builder: d.avatar);
      }
      p.meta.addAll([
        if (has('role')) ?_some(d.role),
        if (has('presence') && presence != null) agentPresenceLabels[presence]!,
      ]);
      if (has('name')) p.title = d.name;
      p.titleLines = x.lines;
      p.facts.addAll([
        if (has('role') && _some(d.role) != null) HfFact('角色', d.role!),
        if (has('presence') && presence != null)
          HfFact('状态', agentPresenceLabels[presence]!),
      ]);
    case AgentComputerData():
      final runtimes = d.runtimes.join('、');
      p.semantics = '电脑 ${d.name}，${d.online ? '在线' : '离线'}';
      p.tone = d.online ? HfTone.progress : HfTone.info;
      final version = has('version') ? _some(d.version) : null;
      final showRuntimes = has('runtimes') && runtimes.isNotEmpty;
      p.meta.addAll([
        if (has('online')) d.online ? '在线' : '离线',
        ?(version == null ? null : 'v$version'),
      ]);
      if (has('name')) p.title = d.name;
      p.titleLines = x.lines;
      p.detail.addAll([
        if (showRuntimes) runtimes,
        if (has('agents')) '${d.agentCount} 个 Agent',
      ]);
      p.facts.addAll([
        if (showRuntimes) HfFact('运行环境', runtimes),
        if (has('agents')) HfFact('Agent', '${d.agentCount} 个'),
        ?(version == null ? null : HfFact('版本', version)),
      ]);
    case AgentFileData():
      p.semantics = '${d.isImage ? '图片' : '文件'} ${d.name}';
      p.tone = HfTone.info;
      final type = has('type') ? _some(d.type) : null;
      final size = has('size') ? _some(d.size) : null;
      final author = has('author') ? _some(d.author) : null;
      p.meta.addAll([?type, ?size]);
      if (has('name')) p.title = d.name;
      p.titleLines = x.lines;
      if (author != null) p.detail.add(author);
      p.facts.addAll([
        ?(type == null ? null : HfFact('类型', type)),
        ?(size == null ? null : HfFact('大小', size)),
        ?(author == null ? null : HfFact('上传者', author)),
      ]);
      if (has('thumbnail')) p.trailing = HfThumb(data: d);
  }
  // Every element off still leaves a card that says what it is.
  if (!p.hasContent) p.title = d.label;
  return p;
}

/// One thing the app holds, drawn from its own data by id, as a numbered
/// [HfRow] (or an [HfDetail] when the level says `detail`).
///
/// The model gives only [entity] (kind and id), [emphasis], [tone] and a
/// [display]: a preset level, and which of the elements are shown. What the
/// card says comes from the [AgentEntityScope] resolver, so it follows the
/// data when it changes, and an id that cannot be read is drawn as a plain
/// "找不到" row and reported (never invented).
///
/// `minimum` is the title alone, `medium` meta, title and one line, `detail`
/// a card with a row per fact. A card with no level of its own is `medium`.
class HfEntityCard extends StatelessWidget {
  const HfEntityCard({
    super.key,
    required this.entity,
    this.emphasis = AgentEmphasis.normal,
    this.tone = AgentTone.neutral,
    this.display,
    this.onTap,
  });
  final AgentEntityRef entity;
  final AgentEmphasis emphasis;
  final AgentTone tone;

  /// What to show; unset parts take the `medium` preset.
  final DisplaySpec? display;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scope = HfItemScope.maybeOf(context);
    return AgentEntityBuilder(
      entity: entity,
      builder: (context, resolution) {
        switch (resolution) {
          case AgentEntityFound(:final data):
            return _found(context, data, scope);
          case AgentEntityLoading():
            return _stub(scope, '读取中…', missing: false);
          case AgentEntityMissing():
            return _stub(
              scope,
              '找不到${agentEntityKindLabels[entity.kind]}',
              missing: true,
            );
        }
      },
    );
  }

  Widget _stub(HfItemScope? scope, String text, {required bool missing}) =>
      HfRow(
        key: ValueKey('entity-stub-${entity.kind.name}-${entity.id}'),
        index: scope?.index,
        tone: missing ? HfTone.blocked : HfTone.info,
        title: text,
        detail: entity.id,
        onTap: onTap,
      );

  Widget _found(BuildContext context, AgentEntityData data, HfItemScope? scope) {
    final x = (display ?? DisplaySpec.none).resolve(
      data.kind.name,
      fallbackLevel: AgentLevel.medium,
    );
    final p = _partsOf(data, x);
    final base = hfToneOver(tone, p.tone);
    final high = emphasis == AgentEmphasis.high;
    // The number is the handle: a card whose `handle` element is off still
    // can be pointed at, it just does not wear it.
    final index = x.has('handle') ? scope?.index : null;
    Widget card;
    if (x.level == AgentLevel.detail) {
      card = HfDetail(
        titleMode: HfDetailTitle.heading,
        index: index,
        title: p.title ?? '',
        titleLines: x.lines,
        status: p.meta.isEmpty ? null : p.meta.join(' · '),
        tone: base,
        facts: p.facts,
        progress: [
          if (p.quote != null) HfProgressLine('', '', p.quote!),
        ],
        trailing: p.trailing,
      );
    } else {
      card = HfRow(
        index: index,
        tone: base,
        title: p.title ?? '',
        titleLines: p.titleLines,
        meta: p.meta.isEmpty ? null : p.meta.join(' · '),
        detail: p.detail.isEmpty ? null : p.detail.join(' · '),
        detailLines: p.detailLines,
        badge: high ? '重点' : null,
        trailing: p.trailing,
        onTap: onTap,
      );
    }
    final number = scope?.index;
    // An element shown or hidden grows or shrinks the card smoothly.
    return AnimatedSize(
      key: ValueKey('entity-card-${data.kind.name}'),
      duration: agentResizeDuration,
      curve: agentResizeCurve,
      alignment: Alignment.topCenter,
      child: Semantics(
        container: true,
        label: number == null
            ? p.semantics
            : '${agentHandleGlyph('$number')} ${p.semantics}',
        child: card,
      ),
    );
  }
}

/// One entity as a single line: its name. For a table cell or a timeline row;
/// an unreadable one says "找不到" and is reported like a card.
class HfEntityInline extends StatelessWidget {
  const HfEntityInline({
    super.key,
    required this.entity,
    this.handle,
    this.size = 15,
  });
  final AgentEntityRef entity;
  final String? handle;

  /// In s-units.
  final double size;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return AgentEntityBuilder(
      entity: entity,
      builder: (context, resolution) {
        final (text, color) = switch (resolution) {
          AgentEntityFound(:final data) => (data.label, HfColors.ink),
          AgentEntityLoading() => ('读取中…', HfColors.inkMuted),
          AgentEntityMissing() => (
            '找不到${agentEntityKindLabels[entity.kind]} ${entity.id}',
            HfColors.inkMuted,
          ),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (handle != null)
              Padding(
                padding: EdgeInsets.only(right: hf.sp(6)),
                child: Text(
                  agentHandleGlyph(handle!),
                  style: hf.type(HfType.headline, base: size + 2),
                ),
              ),
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: hf.type(HfType.body, color: color, base: size),
              ),
            ),
          ],
        );
      },
    );
  }
}
