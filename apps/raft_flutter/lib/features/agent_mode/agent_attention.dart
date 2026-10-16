import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_mode_data.dart';
import 'references/agent_handle_tag.dart';

/// The first layer: the App's Activity ("动态"), in real time. The same screen
/// on a phone, a desktop and a TV: a count line, then the Activity rows
/// newest first as numbered rows (who, where, the real words, how long ago,
/// why it is here, unread), with the tasks that wait for a decision among
/// them by recency, and at the end a collapsed group of tasks nobody touched
/// for days ("可能需要收尾"). All of them, in one page that scrolls as a whole
/// (nothing inside scrolls on its own).
///
/// One row is the current item (a tap, a key, or the voice says so). Its
/// detail, with the message in full and the feedback actions (回复, 点赞,
/// 标记已处理, 稍后, 交给 Agent), is part of the same page: it stands beside
/// the list at the height of the row on a window 1280 wide or more (and a
/// TV) and opens under the row on a narrower one; the page scrolls to show
/// both. A TV only shows: its actions are voice hints.
///
/// One thing the home layer lists, in order: a section label, a card, the
/// stale group's row (and its cards when it is open), the "团队在推进" row and
/// (when it is open) the team's own rows. The screen draws them and the
/// description of the layer reads them, so the two lists are the same list.
sealed class AgentAttentionPart {
  const AgentAttentionPart();
}

class AgentAttentionSection extends AgentAttentionPart {
  const AgentAttentionSection(this.label);
  final HfSectionLabel label;
}

class AgentAttentionCard extends AgentAttentionPart {
  const AgentAttentionCard(this.n, this.item, this.row);

  /// The number on the card, from 1.
  final int n;
  final AgentAttentionItem item;
  final HfRow row;
}

/// The row that opens and closes the stale group.
class AgentAttentionStaleRow extends AgentAttentionPart {
  const AgentAttentionStaleRow(this.row);
  final HfRow row;
}

class AgentAttentionTeamRow extends AgentAttentionPart {
  const AgentAttentionTeamRow(this.row);
  final HfRow row;
}

class AgentAttentionTeamItem extends AgentAttentionPart {
  const AgentAttentionTeamItem(this.row);
  final HfRow row;
}

class AgentAttentionView extends StatefulWidget {
  const AgentAttentionView({
    super.key,
    required this.attention,
    required this.focusPrefix,
    required this.onApprove,
    required this.onOpen,
    required this.onLater,
    this.error,
    this.current,
    this.onCurrent,
    this.teamOpen = false,
    this.onTeam,
    this.staleOpen = false,
    this.onStale,
  });

  /// Null until the first result of this account was accepted.
  final AgentAttention? attention;
  final Object? error;
  final String focusPrefix;
  final void Function(AgentAttentionItem item) onApprove, onOpen, onLater;

  /// The current row (from 1), set from outside: the voice and the TV follow
  /// what the agent talks about. Null is none (a wide window then marks the
  /// first row).
  final int? current;

  /// A row was tapped, or an arrow key moved on: it is the current one.
  final ValueChanged<int>? onCurrent;

  /// The team's rows are open under the "团队在推进" row, which [onTeam]
  /// opens and closes: the owner keeps it, so it can say what is shown.
  final bool teamOpen;
  final VoidCallback? onTeam;

  /// The stale tasks are open under the "可能需要收尾" row, which [onStale]
  /// opens and closes.
  final bool staleOpen;
  final VoidCallback? onStale;

  static const layerTitle = '动态';
  static const layerMeta = '最新在前';
  static const emptyHeadline = '动态里现在没有新的消息';
  static const staleTitle = '可能需要收尾';
  static const staleNote = '很久没动的任务：可能已经做完，只是没改状态';
  static const feedLabel = '最新动态';

  /// Why a row sits where it does, for a person who asks.
  static String _meta(AgentAttentionItem i) {
    if (i.isActivity) {
      return [i.reason, i.place ?? ''].where((e) => e.isNotEmpty).join(' · ');
    }
    return [
      if (i.channelName != null) '#${i.channelName}',
      i.reason,
    ].where((e) => e.isNotEmpty).join(' · ');
  }

  /// The task a row belongs to, when it has one: "任务 #12 待验收".
  static String? taskChip(AgentAttentionItem i) {
    if (i.taskNumber == null) return null;
    final status = switch (i.taskStatus) {
      'todo' => '待办',
      'in_progress' => '进行中',
      'in_review' => '待验收',
      'done' => '已完成',
      'closed' => '已关闭',
      _ => null,
    };
    return '任务 #${i.taskNumber}${status == null ? '' : ' $status'}';
  }

  /// Conversations with something unread, mentions, and the tasks that wait
  /// for a decision or are stuck.
  static HfCountLine countOf(AgentAttention a) => HfCountLine(
    counts: [
      HfCount(
        HfTone.info,
        a.unreadCount,
        '个会话有未读',
        key: const ValueKey('attention-count-unread'),
      ),
      HfCount(
        HfTone.mention,
        a.mentionCount,
        '处点名你',
        key: const ValueKey('attention-count-mention'),
      ),
      HfCount(
        HfTone.decision,
        a.decisionCount,
        '件等你决定',
        key: const ValueKey('attention-count-decision'),
      ),
      HfCount(
        HfTone.blocked,
        a.blockedCount,
        '件卡住了',
        key: const ValueKey('attention-count-blocked'),
      ),
    ],
  );

  /// The row of card [n]. [onTap] makes it the current one (never on a TV).
  static HfRow rowOf(
    AgentAttentionItem i,
    int n, {
    required bool split,
    required bool selected,
    VoidCallback? onTap,
  }) {
    final chip = taskChip(i);
    return HfRow(
      key: ValueKey(split ? 'attention-row-${i.id}' : 'attention-card-${i.id}'),
      index: n,
      tone: i.tone,
      badge: i.arrived ? '刚到' : null,
      // Beside the detail, which has the whole sentence, a row keeps to one line.
      titleLines: split ? 1 : 2,
      meta: _meta(i),
      title: i.headline,
      detail: i.isActivity ? chip : i.askText,
      stat: HfStatBlock(
        label: i.isActivity
            ? (i.unread > 0 ? '${i.unread} 条未读' : '已读')
            : (i.idle ? '没动' : '已等'),
        value: '${i.waitValue}',
        unit: i.isActivity ? '${i.waitUnit}前' : i.waitUnit,
      ),
      selected: selected,
      onTap: onTap,
    );
  }

  /// The frame of the layer: [a] not read yet is the spinner (or why it
  /// failed), an empty [a] says so, else [children] are the list.
  static HfLayerFrame frameOf(
    AgentAttention? a,
    Object? error, {
    required bool phone,
    List<Widget> children = const [],
  }) {
    if (a == null) {
      return HfLayerFrame(
        title: layerTitle,
        meta: layerMeta,
        loading: error == null,
        summary: error == null ? null : TextSpan(text: '读取失败：$error'),
      );
    }
    return HfLayerFrame(
      title: layerTitle,
      meta: phone && !a.isEmpty ? null : layerMeta,
      count: countOf(a),
      children: children,
    );
  }

  /// What the layer says when there is nothing in the feed.
  static List<Widget> emptyBody(HfData hf) => [
    Padding(
      padding: EdgeInsets.fromLTRB(0, hf.sp(8), 0, hf.sp(6)),
      child: Text(emptyHeadline, style: hf.type(HfType.headline)),
    ),
    if (!hf.phone)
      Text(
        AgentAttention.scopeNote,
        style: hf.type(HfType.meta, color: HfColors.inkMuted),
      ),
  ];

  /// The same, as words.
  static HfDescription describeLayer(
    AgentAttention? a,
    Object? error, {
    required HfDescribeEnv env,
  }) {
    final frame = frameOf(a, error, phone: env.phone).describe(env);
    if (a == null || !a.isEmpty) return frame;
    return HfDescription([
      ...frame.lines,
      emptyHeadline,
      if (!env.phone) AgentAttention.scopeNote,
    ], block: true);
  }

  /// The list of the layer: the feed with its label, the stale group (its
  /// cards when [staleOpen]), then the team row (and its rows when
  /// [teamOpen]). [selected] is the current card, from 1.
  static List<AgentAttentionPart> partsOf(
    AgentAttention a, {
    required bool split,
    required bool interactive,
    bool teamOpen = false,
    bool staleOpen = false,
    int? selected,
    void Function(int n)? onTap,
    VoidCallback? onTeam,
    VoidCallback? onStale,
    Widget? teamIcon,
    Widget? staleIcon,
  }) {
    final parts = <AgentAttentionPart>[];
    var n = 0;
    void card(AgentAttentionItem i) {
      n++;
      final number = n;
      parts.add(
        AgentAttentionCard(
          number,
          i,
          rowOf(
            i,
            number,
            split: split,
            selected: number == selected,
            onTap: interactive && onTap != null ? () => onTap(number) : null,
          ),
        ),
      );
    }

    if (a.items.isNotEmpty) {
      parts.add(
        AgentAttentionSection(
          HfSectionLabel(
            feedLabel,
            tone: HfTone.progress,
            count: a.items.length,
          ),
        ),
      );
      a.items.forEach(card);
    }
    if (a.stale.isNotEmpty) {
      parts.add(
        AgentAttentionStaleRow(
          HfRow(
            key: const ValueKey('attention-stale'),
            index: null,
            tone: HfTone.blocked,
            title: '$staleTitle ${a.staleCount} 件',
            titleLines: 1,
            detail: staleNote,
            trailing: staleIcon,
            onTap: interactive ? onStale : null,
          ),
        ),
      );
      if (staleOpen) a.stale.forEach(card);
    }
    if (a.teamCount > 0 && interactive) {
      parts.add(
        AgentAttentionTeamRow(
          HfRow(
            key: const ValueKey('attention-team'),
            index: null,
            tone: HfTone.progress,
            title: '团队在推进 ${a.teamLabel} 件',
            titleLines: 1,
            trailing: teamIcon,
            onTap: onTeam,
          ),
        ),
      );
      if (teamOpen) {
        for (final t in a.team) {
          parts.add(
            AgentAttentionTeamItem(
              HfRow(
                index: null,
                tone: HfTone.progress,
                meta: '#${t.channelName}',
                title: t.headline,
                titleLines: 1,
              ),
            ),
          );
        }
      }
    }
    return parts;
  }

  @override
  State<AgentAttentionView> createState() => _AgentAttentionViewState();
}

class _AgentAttentionViewState extends State<AgentAttentionView> {
  /// The row index (from 0) that is current, set by the last build; -1 is
  /// none.
  int _shown = -1;

  List<AgentAttentionItem> get _items =>
      widget.attention?.listed(open: widget.staleOpen) ?? const [];

  AgentAttentionItem? get _currentItem {
    final items = _items;
    if (items.isEmpty || _shown < 0) return null;
    return items[_shown.clamp(0, items.length - 1)];
  }

  void _select(int index) {
    final items = _items;
    if (items.isEmpty) return;
    final next = index.clamp(0, items.length - 1);
    // Keys can arrive faster than frames: the next one starts from here.
    _shown = next;
    widget.onCurrent?.call(next + 1);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final item = _currentItem;
    if (item == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _select(_shown + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _select(_shown - 1);
    } else if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      item.canApprove ? widget.onApprove(item) : widget.onOpen(item);
    } else if (event is KeyDownEvent && key == LogicalKeyboardKey.keyS) {
      widget.onLater(item);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _list(HfData hf, AgentAttention a, {required bool split}) {
    final children = <Widget>[];
    var afterLabel = false;
    for (final part in AgentAttentionView.partsOf(
      a,
      split: split,
      interactive: hf.interactive,
      teamOpen: widget.teamOpen,
      staleOpen: widget.staleOpen,
      selected: _shown + 1,
      onTap: widget.onCurrent,
      onTeam: widget.onTeam,
      onStale: widget.onStale,
      teamIcon: Icon(
        widget.teamOpen ? Icons.expand_less : Icons.expand_more,
        size: hf.sp(26),
        color: HfColors.inkSoft,
      ),
      staleIcon: Icon(
        widget.staleOpen ? Icons.expand_less : Icons.expand_more,
        size: hf.sp(26),
        color: HfColors.inkSoft,
      ),
    )) {
      switch (part) {
        case AgentAttentionSection(:final label):
          if (children.isNotEmpty) children.add(SizedBox(height: hf.sp(10)));
          children.add(label);
          children.add(SizedBox(height: hf.sp(4)));
          afterLabel = true;
        case AgentAttentionCard(:final n, :final row):
          if (!afterLabel) children.add(SizedBox(height: hf.rowGap));
          afterLabel = false;
          final id = '${widget.focusPrefix}#$n';
          children.add(
            AgentFocusable(
              id: id,
              child: AgentHandleTag(focusId: id, child: row),
            ),
          );
        case AgentAttentionStaleRow(:final row) ||
            AgentAttentionTeamRow(:final row) ||
            AgentAttentionTeamItem(:final row):
          afterLabel = false;
          children.add(SizedBox(height: hf.rowGap));
          children.add(row);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final a = widget.attention;
    if (a == null || (a.isEmpty && a.stale.isEmpty)) {
      return AgentAttentionView.frameOf(
        a,
        widget.error,
        phone: hf.phone,
        children: a == null ? const [] : AgentAttentionView.emptyBody(hf),
      );
    }
    final items = a.listed(open: widget.staleOpen);
    final split = hf.split;
    final sel = widget.current;
    final hasSel = sel != null && sel >= 1 && sel <= items.length;
    // A wide window always marks one: the first row when nothing was chosen.
    _shown = hasSel ? sel - 1 : (split && items.isNotEmpty ? 0 : -1);
    final frame = AgentAttentionView.frameOf(
      a,
      widget.error,
      phone: hf.phone,
      children: [
        if (a.isEmpty) ...AgentAttentionView.emptyBody(hf),
        _list(hf, a, split: split),
      ],
    );
    if (!split) return frame;
    return Focus(autofocus: true, onKeyEvent: _key, child: frame);
  }
}

/// One item in its detail rendering: the message in full, who, where, how
/// long ago, and what the person can do with it. For an Activity row those
/// are the feedback actions: 回复, 点赞, 标记已处理, 稍后, 交给 Agent. The
/// detail slot beside the list (a wide window, a TV) and under the row on a
/// phone both show it; [trailing] is the small tools of a phone's stage.
///
/// An action whose callback is null is not offered (the TV has none).
class AgentAttentionDetail extends StatelessWidget {
  const AgentAttentionDetail({
    super.key,
    required this.item,
    required this.number,
    required this.onApprove,
    required this.onOpen,
    required this.onLater,
    this.onReply,
    this.onLike,
    this.onDone,
    this.onAssign,
    this.trailing,
  });
  final AgentAttentionItem item;

  /// The number the item has on the screen.
  final int number;
  final void Function(AgentAttentionItem item) onApprove, onOpen, onLater;
  final void Function(AgentAttentionItem item)? onReply, onLike, onDone, onAssign;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => view();

  /// What 回复 says on the button.
  static const replyLabel = '回复';
  static const likeLabel = '点赞';
  static const doneLabel = '标记已处理';
  static const assignLabel = '交给 Agent';
  static const openActivityLabel = '看完整对话';

  /// The detail as the screen draws it; the description of the current item
  /// is read from this same widget.
  HfDetail view() {
    final n = number;
    final lines = item.progress.isEmpty
        ? const <AgentProgressLine>[]
        : [item.progress.last];
    final who = item.doer ?? (item.waiters.isEmpty ? null : item.waiters.first);
    final activity = item.isActivity;
    final chip = AgentAttentionView.taskChip(item);
    VoidCallback? call(void Function(AgentAttentionItem)? f) =>
        f == null ? null : () => f(item);
    final HfAction? open = HfAction(
      activity
          ? openActivityLabel
          : item.action == AgentAction.reply
          ? '回复${who == null ? '' : ' $who'}'
          : '打开讨论',
      key: ValueKey('attention-open-${item.id}'),
      kind: item.canApprove ? HfActionKind.secondary : HfActionKind.primary,
      onPressed: () => onOpen(item),
    );
    return HfDetail(
      key: const ValueKey('attention-detail'),
      trailing: trailing,
      // The tools are a phone's: its page has little height for stacked
      // buttons.
      oneRowActions: trailing != null && !activity,
      gridActions: activity,
      titleMode: HfDetailTitle.heading,
      index: n,
      title: activity ? (item.place ?? item.headline) : item.headline,
      status: activity
          ? [item.reason, if (item.arrived) '刚到'].join(' · ')
          : [
              if (item.channelName != null) '#${item.channelName}',
              item.reason,
            ].join(' · '),
      tone: item.tone,
      facts: activity
          ? [
              if (who != null) HfFact('谁', who),
              HfFact(
                '多久',
                '${item.agoLabel} · ${item.unread > 0 ? '${item.unread} 条未读' : '已读'}',
              ),
              if (chip != null) HfFact('任务', chip),
            ]
          : [
              HfFact('要你做', item.askText),
              if (who != null) HfFact('谁', who),
              HfFact('多久', item.waitLabel),
            ],
      progress: [for (final p in lines) HfProgressLine(p.time, p.who, p.text)],
      actions: [
        if (item.canApprove)
          HfAction(
            '通过',
            key: ValueKey('attention-approve-${item.id}'),
            kind: HfActionKind.primary,
            icon: Icons.check_rounded,
            onPressed: () => onApprove(item),
          ),
        ?open,
        if (activity && onReply != null)
          HfAction(
            replyLabel,
            key: ValueKey('attention-reply-${item.id}'),
            onPressed: call(onReply),
          ),
        if (activity && onLike != null && item.messageId != null)
          HfAction(
            likeLabel,
            key: ValueKey('attention-like-${item.id}'),
            onPressed: call(onLike),
          ),
        if (activity &&
            onDone != null &&
            item.rowKind != 'mention_action')
          HfAction(
            doneLabel,
            key: ValueKey('attention-done-${item.id}'),
            onPressed: call(onDone),
          ),
        HfAction(
          '稍后',
          key: ValueKey('attention-later-${item.id}'),
          kind: HfActionKind.text,
          onPressed: () => onLater(item),
        ),
        if (onAssign != null && (activity || item.taskId != null))
          HfAction(
            assignLabel,
            key: ValueKey('attention-assign-${item.id}'),
            onPressed: call(onAssign),
          ),
      ],
    );
  }
}
