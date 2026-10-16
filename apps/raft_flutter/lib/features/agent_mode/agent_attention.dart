import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_mode_data.dart';
import 'references/agent_handle_tag.dart';

/// The first layer: what needs the person now ("现在需要你"). The same screen
/// on a phone, a desktop and a TV: a count line, the items in sections (等你
/// 决定 / 卡住了 / 点名你) as numbered rows. All of them, in one page that
/// scrolls as a whole (nothing inside scrolls on its own).
///
/// One row is the current item (a tap, a key, or the voice says so). Its
/// detail, with its last progress and actions, is part of the same page: it
/// stands beside the list at the height of the row on a window 1280 wide or
/// more (and a TV) and opens under the row on a narrower one; the page scrolls
/// to show both. A TV only shows: its actions are voice hints.
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

  @override
  State<AgentAttentionView> createState() => _AgentAttentionViewState();
}

class _AgentAttentionViewState extends State<AgentAttentionView> {
  bool _teamOpen = false;

  /// The row index (from 0) that is current, set by the last build; -1 is
  /// none.
  int _shown = -1;

  static const _title = '现在需要你';

  List<AgentAttentionItem> get _items => widget.attention?.items ?? const [];

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

  static HfTone _tone(AgentPriority p) => HfColors.toneOf(p);

  static String _meta(AgentAttentionItem i) => [
    if (i.channelName != null) '#${i.channelName}',
    i.reason,
  ].where((e) => e.isNotEmpty).join(' · ');

  static String _sectionOf(AgentPriority p) => switch (p) {
    AgentPriority.decision => '等你决定',
    AgentPriority.blocked => '卡住了',
    AgentPriority.mention => '点名你',
    AgentPriority.progress => '进行中',
  };

  /// The two things that need a decision; the mentions are counted by their
  /// own section.
  Widget _count(AgentAttention a) => HfCountLine(
    counts: [
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

  HfRow _row(
    HfData hf,
    AgentAttentionItem i,
    int n, {
    required bool split,
    required bool selected,
  }) => HfRow(
    key: ValueKey(split ? 'attention-row-${i.id}' : 'attention-card-${i.id}'),
    index: n,
    tone: _tone(i.priority),
    badge: n == 1 ? '最急' : null,
    // Beside the detail, which has the whole sentence, a row keeps to one line.
    titleLines: split ? 1 : 2,
    meta: _meta(i),
    title: i.headline,
    detail: i.askText,
    stat: HfStatBlock(
      label: i.idle ? '没动' : '已等',
      value: '${i.waitValue}',
      unit: i.waitUnit,
    ),
    selected: selected,
    onTap: hf.interactive && widget.onCurrent != null
        ? () => widget.onCurrent!(n)
        : null,
  );

  Widget _list(HfData hf, AgentAttention a, {required bool split}) {
    final items = a.items;
    final children = <Widget>[];
    for (var n = 0; n < items.length; n++) {
      final i = items[n];
      if (n == 0 || i.priority != items[n - 1].priority) {
        if (n > 0) children.add(SizedBox(height: hf.sp(10)));
        children.add(
          HfSectionLabel(
            _sectionOf(i.priority),
            tone: _tone(i.priority),
            count: items.where((x) => x.priority == i.priority).length,
          ),
        );
        children.add(SizedBox(height: hf.sp(4)));
      } else {
        children.add(SizedBox(height: hf.rowGap));
      }
      final id = '${widget.focusPrefix}#${n + 1}';
      children.add(
        AgentFocusable(
          id: id,
          child: AgentHandleTag(
            focusId: id,
            child: _row(hf, i, n + 1, split: split, selected: n == _shown),
          ),
        ),
      );
    }
    if (a.teamCount > 0 && hf.interactive) {
      children.add(SizedBox(height: hf.rowGap));
      children.add(
        HfRow(
          key: const ValueKey('attention-team'),
          index: null,
          tone: HfTone.progress,
          title: '团队在推进 ${a.teamLabel} 件',
          titleLines: 1,
          trailing: Icon(
            _teamOpen ? Icons.expand_less : Icons.expand_more,
            size: hf.sp(26),
            color: HfColors.inkSoft,
          ),
          onTap: () => setState(() => _teamOpen = !_teamOpen),
        ),
      );
      if (_teamOpen) {
        for (final t in a.team) {
          children.add(SizedBox(height: hf.rowGap));
          children.add(
            HfRow(
              index: null,
              tone: HfTone.progress,
              meta: '#${t.channelName}',
              title: t.headline,
              titleLines: 1,
            ),
          );
        }
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
    if (a == null) {
      return HfLayerFrame(
        title: _title,
        meta: '按紧急程度',
        loading: widget.error == null,
        summary: widget.error == null
            ? null
            : TextSpan(text: '读取失败：${widget.error}'),
      );
    }
    if (a.isEmpty) {
      return HfLayerFrame(
        title: _title,
        meta: '按紧急程度',
        count: _count(a),
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(0, hf.sp(8), 0, hf.sp(6)),
            child: Text('现在没有需要你处理的事', style: hf.type(HfType.headline)),
          ),
          if (!hf.phone)
            Text(
              AgentAttention.scopeNote,
              style: hf.type(HfType.meta, color: HfColors.inkMuted),
            ),
        ],
      );
    }
    final items = a.items;
    final split = hf.split;
    final sel = widget.current;
    final hasSel = sel != null && sel >= 1 && sel <= items.length;
    // A wide window always marks one: the first row when nothing was chosen.
    _shown = hasSel ? sel - 1 : (split ? 0 : -1);
    final frame = HfLayerFrame(
      title: _title,
      meta: hf.phone ? null : '按紧急程度',
      count: _count(a),
      children: [_list(hf, a, split: split)],
    );
    if (!split) return frame;
    return Focus(autofocus: true, onKeyEvent: _key, child: frame);
  }
}

/// One attention item in its detail rendering: what is asked, who, how long,
/// the last progress and the three actions. The detail slot beside the list
/// (a wide window, a TV) and under the row on a phone both show it;
/// [trailing] is the small tools of a phone's stage.
class AgentAttentionDetail extends StatelessWidget {
  const AgentAttentionDetail({
    super.key,
    required this.item,
    required this.number,
    required this.onApprove,
    required this.onOpen,
    required this.onLater,
    this.trailing,
  });
  final AgentAttentionItem item;

  /// The number the item has on the screen.
  final int number;
  final void Function(AgentAttentionItem item) onApprove, onOpen, onLater;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final n = number;
    final lines = item.progress.isEmpty
        ? const <AgentProgressLine>[]
        : [item.progress.last];
    final who = item.doer ?? (item.waiters.isEmpty ? null : item.waiters.first);
    return HfDetail(
      key: const ValueKey('attention-detail'),
      trailing: trailing,
      // The tools are a phone's: its page has little height for stacked
      // buttons.
      oneRowActions: trailing != null,
      titleMode: HfDetailTitle.heading,
      index: n,
      title: item.headline,
      status: [
        if (item.channelName != null) '#${item.channelName}',
        item.reason,
      ].join(' · '),
      tone: HfColors.toneOf(item.priority),
      facts: [
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
        HfAction(
          item.action == AgentAction.reply
              ? '回复${who == null ? '' : ' $who'}'
              : '打开讨论',
          key: ValueKey('attention-open-${item.id}'),
          kind: item.canApprove ? HfActionKind.secondary : HfActionKind.primary,
          onPressed: () => onOpen(item),
        ),
        HfAction(
          '稍后',
          key: ValueKey('attention-later-${item.id}'),
          kind: HfActionKind.text,
          onPressed: () => onLater(item),
        ),
      ],
    );
  }
}
