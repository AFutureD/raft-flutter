import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_mode_data.dart';
import 'references/agent_handle_tag.dart';

/// The first layer: what needs the person now ("现在需要你"). The same screen
/// on a phone, a desktop and a TV: a count line, the items in sections (等你
/// 决定 / 卡住了 / 点名你) as numbered rows, a pager for the rest. A window
/// 1280 wide or more (and a TV) puts the selected item's detail with its
/// last progress and actions beside the list; a narrower one opens the
/// detail as a layer of its own. A TV only shows: its actions are voice
/// hints.
class AgentAttentionView extends StatefulWidget {
  const AgentAttentionView({
    super.key,
    required this.attention,
    required this.focusPrefix,
    required this.onApprove,
    required this.onOpen,
    required this.onLater,
    required this.onExpand,
    this.batchStart = 0,
    this.onBatch,
    this.error,
    this.selectedNumber,
    this.onPage,
  });

  /// Null until the first result of this account was accepted.
  final AgentAttention? attention;
  final Object? error;
  final String focusPrefix;
  final void Function(AgentAttentionItem item) onApprove, onOpen, onLater;

  /// A row was tapped (narrow screen): opens the detail layer (the same call
  /// the voice tool `expand_item` makes).
  final void Function(AgentAttentionItem item) onExpand;

  /// The first row on screen, counted over all the items. A page holds as
  /// many rows as fit (at most [HfData.attentionRows]) and [onBatch] asks for
  /// the next ones (the pager; voice says "下一批").
  final int batchStart;
  final void Function(int start)? onBatch;

  /// The row (from 1) the detail is of, and the page it is on, set from
  /// outside: the TV follows what the agent talks about.
  final int? selectedNumber;

  /// The page on show changed: its first and one past its last row. The
  /// owner needs it for "下一批".
  final void Function(int start, int end)? onPage;

  @override
  State<AgentAttentionView> createState() => _AgentAttentionViewState();
}

class _AgentAttentionViewState extends State<AgentAttentionView> {
  String? _selected;
  int _index = 0;
  bool _teamOpen = false;

  static const _title = '现在需要你';

  List<AgentAttentionItem> get _items => widget.attention?.items ?? const [];

  AgentAttentionItem? get _current {
    final items = _items;
    if (items.isEmpty) return null;
    final at = items.indexWhere((i) => i.id == _selected);
    final index = at >= 0 ? at : _index.clamp(0, items.length - 1);
    _index = index;
    _selected = items[index].id;
    return items[index];
  }

  /// Where the page that holds a row starts, by the layout of the last build.
  int Function(int index)? _startOf;

  /// The page on show, by the layout of the last build.
  (int, int) _shown = (0, 0);

  void _select(int index) {
    final items = _items;
    if (items.isEmpty) return;
    final next = index.clamp(0, items.length - 1);
    setState(() {
      _index = next;
      _selected = items[next].id;
    });
    // The page follows the selection.
    final start = _startOf?.call(next);
    if (start != null && start != widget.batchStart) {
      widget.onBatch?.call(start);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final item = _current;
    if (item == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _select(_index + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _select(_index - 1);
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
    meta: _meta(i),
    title: i.headline,
    detail: i.askText,
    stat: HfStatBlock(
      label: i.idle ? '没动' : '已等',
      value: '${i.waitValue}',
      unit: i.waitUnit,
    ),
    selected: selected,
    onTap: hf.interactive
        ? () => split ? _select(n - 1) : widget.onExpand(i)
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
    final current = _current;
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
        children.add(SizedBox(height: hf.sp(8)));
      } else {
        children.add(SizedBox(height: hf.rowGap));
      }
      final id = '${widget.focusPrefix}#${n + 1}';
      children.add(
        AgentFocusable(
          id: id,
          child: AgentHandleTag(
            focusId: id,
            child: _row(
              hf,
              i,
              n + 1,
              split: split,
              selected: split && i.id == current?.id,
            ),
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

  Widget _detail(HfData hf, AgentAttentionItem item, int n) {
    final lines = item.progress.length > 2
        ? item.progress.sublist(item.progress.length - 2)
        : item.progress;
    final who = item.doer ?? (item.waiters.isEmpty ? null : item.waiters.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HfDetail(
          key: const ValueKey('attention-detail'),
          titleMode: HfDetailTitle.heading,
          index: n,
          title: item.headline,
          status: [
            if (item.channelName != null) '#${item.channelName}',
            item.reason,
          ].join(' · '),
          tone: _tone(item.priority),
          facts: [
            HfFact('要你做', item.askText),
            if (who != null) HfFact('谁', who),
            HfFact('多久', item.waitLabel),
          ],
          progress: [
            for (final p in lines) HfProgressLine(p.time, p.who, p.text),
          ],
          actions: [
            if (item.canApprove)
              HfAction(
                '通过',
                key: ValueKey('attention-approve-${item.id}'),
                kind: HfActionKind.primary,
                icon: Icons.check_rounded,
                onPressed: () => widget.onApprove(item),
              ),
            HfAction(
              item.action == AgentAction.reply
                  ? '回复${who == null ? '' : ' $who'}'
                  : '打开讨论',
              key: ValueKey('attention-open-${item.id}'),
              kind: item.canApprove
                  ? HfActionKind.secondary
                  : HfActionKind.primary,
              onPressed: () => widget.onOpen(item),
            ),
            HfAction(
              '稍后',
              key: ValueKey('attention-later-${item.id}'),
              kind: HfActionKind.text,
              onPressed: () => widget.onLater(item),
            ),
          ],
        ),
        if (hf.interactive)
          Padding(
            padding: EdgeInsets.only(top: hf.sp(4)),
            child: Text(
              '↑↓ 切换 · ↵ ${item.canApprove ? '通过' : '打开'} · S 稍后',
              style: hf.type(HfType.meta, color: HfColors.inkMuted),
            ),
          ),
      ],
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
    return LayoutBuilder(builder: (context, box) => _paged(context, hf, a, box));
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
    final pagerRoom = gap + hf.sp(36);
    int endOf(int start, {required bool pager}) => _pageEnd(
      hf,
      scaler,
      items,
      start,
      rowWidth: listWidth,
      budget: pager ? room - pagerRoom : room,
      cap: cap,
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

    final sel = widget.selectedNumber;
    var start = widget.batchStart >= items.length ? 0 : widget.batchStart;
    if (sel != null && sel >= 1 && sel <= items.length) {
      start = pageStartOf(sel - 1);
    }
    final end = pageEnd(start);
    _startOf = pageStartOf;
    _shown = (start, end);
    widget.onPage?.call(start, end);
    if (sel != null && sel >= 1 && sel <= items.length) {
      _index = sel - 1;
      _selected = items[sel - 1].id;
    } else if (!hf.interactive) {
      // A TV shows the detail of the first row on the page.
      _index = start;
      _selected = items[start].id;
    }
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
    final current = _current;
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 53,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    list,
                    if (pager != null) ...[SizedBox(height: hf.sp(12)), pager],
                  ],
                ),
              ),
              SizedBox(width: hf.sp(28)),
              Expanded(
                flex: 47,
                child: current == null
                    ? const SizedBox.shrink()
                    : _detail(hf, current, _index + 1),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
