import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_mode_data.dart';
import 'references/agent_handle_tag.dart';

/// The first layer: what needs the person now ("现在需要你"). The same screen
/// on a phone, a desktop and a TV: a count line, the items in sections (等你
/// 决定 / 卡住了 / 点名你) as numbered rows, a pager for the rest.
///
/// One row is the current item (a tap, a key, or the voice says so). A window
/// 1280 wide or more (and a TV) shows the current item's detail with its last
/// progress and actions beside the list, in place; a narrower one has its
/// owner show it in a sheet. A TV only shows: its actions are voice hints.
class AgentAttentionView extends StatefulWidget {
  const AgentAttentionView({
    super.key,
    required this.attention,
    required this.focusPrefix,
    required this.onApprove,
    required this.onOpen,
    required this.onLater,
    this.batchStart = 0,
    this.onBatch,
    this.error,
    this.current,
    this.onCurrent,
    this.onPage,
  });

  /// Null until the first result of this account was accepted.
  final AgentAttention? attention;
  final Object? error;
  final String focusPrefix;
  final void Function(AgentAttentionItem item) onApprove, onOpen, onLater;

  /// The first row on screen, counted over all the items. A page holds as
  /// many rows as fit (at most [HfData.attentionRows]) and [onBatch] asks for
  /// the next ones (the pager; voice says "下一批").
  final int batchStart;
  final void Function(int start)? onBatch;

  /// The current row (from 1), set from outside: the voice and the TV follow
  /// what the agent talks about. Null is none (a wide window then shows the
  /// first row of the page).
  final int? current;

  /// A row was tapped, or an arrow key moved on: it is the current one.
  final ValueChanged<int>? onCurrent;

  /// The page on show changed: its first and one past its last row. The
  /// owner needs it for "下一批".
  final void Function(int start, int end)? onPage;

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

  /// Where a page that starts at [start] ends: as many whole rows as fit in
  /// [budget] px, at most [cap], with the section labels they come under.
  int _pageEnd(
    HfData hf,
    TextScaler scaler,
    List<AgentAttentionItem> items,
    int start, {
    required double rowWidth,
    required double budget,
    required int cap,
    required int titleLines,
  }) {
    var used = 0.0;
    var end = start;
    for (var n = start; n < items.length && end - start < cap; n++) {
      final i = items[n];
      final label = n == start || i.priority != items[n - 1].priority;
      final cost =
          (n == start ? 0 : (label ? hf.sp(10) : hf.rowGap)) +
          (label ? HfFit.section(hf) : 0) +
          HfFit.row(
            hf,
            scaler,
            width: rowWidth,
            title: i.headline,
            meta: _meta(i),
            detail: i.askText,
            badge: n == 0,
            stat: true,
            titleLines: titleLines,
          );
      // A page holds at least one row, whatever its size.
      if (end > start && used + cost > budget) break;
      used += cost;
      end = n + 1;
    }
    return end;
  }

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

  Widget _list(
    HfData hf,
    AgentAttention a, {
    required bool split,
    required int start,
    required int end,
  }) {
    final items = a.items;
    final children = <Widget>[];
    for (var n = start; n < end; n++) {
      final i = items[n];
      if (n == start || i.priority != items[n - 1].priority) {
        if (n > start) children.add(SizedBox(height: hf.sp(10)));
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
    if (a.teamCount > 0 && hf.interactive && end == items.length) {
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

  Widget _detail(AgentAttentionItem item, int n) => AgentItemScope(
    // The marks the agent draws on this item show here too.
    id: '${widget.focusPrefix}#$n',
    child: AgentAttentionDetail(
      item: item,
      number: n,
      onApprove: widget.onApprove,
      onOpen: widget.onOpen,
      onLater: widget.onLater,
    ),
  );

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
    return LayoutBuilder(
      builder: (context, box) => _paged(context, hf, a, box),
    );
  }

  /// The layer once the room is known: a page of as many whole rows as fit.
  Widget _paged(
    BuildContext context,
    HfData hf,
    AgentAttention a,
    BoxConstraints box,
  ) {
    final items = a.items;
    final split = hf.split;
    final scaler = MediaQuery.textScalerOf(context);
    final cap = hf.attentionRows;
    // The room for rows: what is left under the header, and above the pager
    // when there is one. The list is the left part of a split view.
    final listWidth = split
        ? (box.maxWidth - hf.sp(8 + 28)) * 53 / 100
        : box.maxWidth - hf.sp(8);
    final gap = hfScreenGap(hf);
    final room = box.hasBoundedHeight
        ? box.maxHeight - HfFit.header(hf, count: true) - gap
        : double.infinity;
    final pagerRoom = gap + hf.sp(32);
    int endOf(int start, {required bool pager}) => _pageEnd(
      hf,
      scaler,
      items,
      start,
      rowWidth: listWidth,
      budget: pager ? room - pagerRoom : room,
      cap: cap,
      titleLines: split ? 1 : 2,
    );
    // Everything fits on one page: no pager. Else the pager takes its room.
    final alone = endOf(0, pager: false) >= items.length;
    int pageEnd(int start) => alone ? items.length : endOf(start, pager: true);
    int pageStartOf(int index) {
      var start = 0;
      while (true) {
        final end = pageEnd(start);
        if (index < end || end >= items.length) return start;
        start = end;
      }
    }

    final sel = widget.current;
    var start = widget.batchStart >= items.length ? 0 : widget.batchStart;
    final hasSel = sel != null && sel >= 1 && sel <= items.length;
    if (hasSel) start = pageStartOf(sel - 1);
    final end = pageEnd(start);
    widget.onPage?.call(start, end);
    // A wide window always shows a detail: the first row of the page when
    // nothing was chosen.
    _shown = hasSel ? sel - 1 : (split ? start : -1);
    final pager = alone
        ? null
        : HfPager(
            from: start + 1,
            to: end,
            total: items.length,
            noun: '件',
            nextKey: const ValueKey('attention-more'),
            onNext: widget.onBatch == null
                ? null
                : () => widget.onBatch!(end < items.length ? end : 0),
          );
    final list = _list(hf, a, split: split, start: start, end: end);
    final current = _currentItem;
    if (!split) {
      return HfLayerFrame(
        title: _title,
        meta: hf.phone ? null : '按紧急程度',
        count: _count(a),
        pager: pager,
        children: [list],
      );
    }
    // Beside the detail the pager is the list's: it sits under the list.
    return Focus(
      autofocus: true,
      onKeyEvent: _key,
      child: HfLayerFrame(
        title: _title,
        meta: '按紧急程度',
        count: _count(a),
        children: [
          // A room of its own height: the detail scrolls inside it and keeps
          // its actions in view.
          SizedBox(
            height: room.isFinite ? room - hf.sp(10) : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 53,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      list,
                      if (pager != null) ...[
                        SizedBox(height: hf.sp(12)),
                        pager,
                      ],
                    ],
                  ),
                ),
                SizedBox(width: hf.sp(28)),
                Expanded(
                  flex: 47,
                  child: current == null
                      ? const SizedBox.shrink()
                      : _detail(current, _shown + 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One attention item in its detail rendering: what is asked, who, how long,
/// the last progress and the three actions. The detail slot beside the list
/// (a wide window, a TV) and a phone's sheet both show it; [trailing] is the
/// small tools of a sheet.
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
    final hf = HandsFree.of(context);
    final n = number;
    final lines = item.progress.isEmpty
        ? const <AgentProgressLine>[]
        : [item.progress.last];
    final who = item.doer ?? (item.waiters.isEmpty ? null : item.waiters.first);
    return HfDetail(
      key: const ValueKey('attention-detail'),
      trailing: trailing,
      // The tools are a sheet's: it has no height for stacked buttons.
      oneRowActions: trailing != null,
      titleMode: HfDetailTitle.heading,
      index: n,
      // A desktop can scroll the pane to read the whole line; a TV is only
      // looked at, so it keeps to one.
      progressLines: hf.interactive ? 4 : 1,
      title: item.headline,
      status: [
        if (item.channelName != null) '#${item.channelName}',
        item.reason,
      ].join(' · '),
      tone: HfColors.toneOf(item.priority),
      facts: [
        HfFact('要你做', item.askText, lines: 1),
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
