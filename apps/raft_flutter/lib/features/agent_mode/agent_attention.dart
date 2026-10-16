import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_mode_data.dart';

/// Screen width from which the attention layer becomes master-detail.
const agentWideBreakpoint = 900.0;

AgentCardData agentCardFor(AgentAttentionItem i, int rank) => AgentCardData(
  id: i.id,
  rank: rank,
  priority: i.priority,
  reason: i.reason,
  wait: i.waitLabel,
  headline: i.headline,
  askLine: i.askText,
  primaryLabel: i.action == AgentAction.reply
      ? '回复${i.doer == null ? '' : ' ${i.doer}'}'
      : '打开讨论',
  approve: i.canApprove,
  channel: i.channelName,
  thread: i.threadTitle,
  threadKind: i.taskNumber != null || i.threadTitle != null ? i.threadKind : null,
  waiting: i.waitingText.isEmpty ? null : i.waitingText,
  progress: [
    for (final p in i.progress)
      AgentQuoteData(who: p.who, time: p.time, text: p.text),
  ],
);

/// The first layer: what needs the person now, as final cards. Phone: one
/// scrolling list of cards. Wide: list on the left, the selected item with
/// its last progress lines and actions on the right.
class AgentAttentionView extends StatefulWidget {
  const AgentAttentionView({
    super.key,
    required this.attention,
    required this.wide,
    required this.focusPrefix,
    required this.onApprove,
    required this.onOpen,
    required this.onLater,
    this.error,
  });

  /// Null until the first result of this account was accepted.
  final AgentAttention? attention;
  final Object? error;
  final bool wide;
  final String focusPrefix;
  final void Function(AgentAttentionItem item) onApprove, onOpen, onLater;

  @override
  State<AgentAttentionView> createState() => _AgentAttentionViewState();
}

class _AgentAttentionViewState extends State<AgentAttentionView> {
  String? _selected;
  int _index = 0;
  bool _teamOpen = false;
  final _rowKeys = <String, GlobalKey>{};

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

  void _select(int index) {
    final items = _items;
    if (items.isEmpty) return;
    final next = index.clamp(0, items.length - 1);
    setState(() {
      _index = next;
      _selected = items[next].id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _rowKeys[items[next].id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, alignment: .5, duration: Duration.zero);
      }
    });
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

  Widget _summary(AgentAttention a) {
    if (a.isEmpty) {
      final t = RaftAgentTheme.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('现在没有需要你处理的事', style: t.body(16.5, weight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(AgentAttention.scopeNote, style: t.body(11.5, color: t.muted)),
          ],
        ),
      );
    }
    String? n(int v) => v == 0 ? null : '$v${a.capped ? '+' : ''}';
    return AgentAttentionSummary(
      decision: n(a.decisionCount),
      blocked: n(a.blockedCount),
      mention: a.mentionCount == 0 ? null : '${a.mentionCount}',
      urgent: a.urgent,
      scope: AgentAttention.scopeNote,
    );
  }

  List<Widget> _sections(AgentAttention a, {required bool wide}) {
    final current = wide ? _current : null;
    var rank = 0;
    Widget card(AgentAttentionItem i) {
      final n = ++rank;
      final data = agentCardFor(i, n);
      final focus = '${widget.focusPrefix}#$n';
      if (wide) {
        return AgentFocusable(
          id: focus,
          child: KeyedSubtree(
            key: _rowKeys.putIfAbsent(i.id, GlobalKey.new),
            child: AgentAttentionRow(
              key: ValueKey('attention-row-${i.id}'),
              data: data,
              selected: identical(i, current) || i.id == current?.id,
              onTap: () => _select(n - 1),
            ),
          ),
        );
      }
      return AgentFocusable(
        id: focus,
        child: AgentAttentionCard(
          data: data,
          onApprove: () => widget.onApprove(i),
          onOpen: () => widget.onOpen(i),
          onLater: () => widget.onLater(i),
        ),
      );
    }

    return [
      for (final (title, hint, p, list) in [
        ('等你决定', '你的事', AgentPriority.decision, a.decisions),
        ('卡住了', '超过 4 小时没动', AgentPriority.blocked, a.blocked),
        ('点名你', null, AgentPriority.mention, a.mentions),
      ])
        if (list.isNotEmpty) ...[
          AgentSectionHeader(
            title: title,
            count: '${list.length}',
            priority: p,
            hint: hint,
          ),
          for (final i in list) card(i),
        ],
      if (a.teamCount > 0)
        AgentTeamRow(
          count: a.teamLabel,
          expanded: _teamOpen,
          onTap: () => setState(() => _teamOpen = !_teamOpen),
          children: [
            for (final t in a.team)
              AgentTeamLine(text: t.headline, channel: t.channelName),
            const SizedBox(height: 4),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attention;
    if (a == null) {
      return AgentLayerFrame(
        title: _title,
        meta: '按紧急程度',
        loading: widget.error == null,
        summary: widget.error == null
            ? null
            : TextSpan(text: '读取失败：${widget.error}'),
      );
    }
    if (!widget.wide) {
      return AgentLayerFrame(
        title: _title,
        meta: '按紧急程度',
        children: [_summary(a), ..._sections(a, wide: false)],
      );
    }
    final t = RaftAgentTheme.of(context);
    final current = _current;
    return Focus(
      autofocus: true,
      onKeyEvent: _key,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 18, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              flex: 54,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 18, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: Text(
                              _title,
                              style: t
                                  .heading(t.titleSize, weight: t.titleWeight)
                                  .copyWith(height: 1.1),
                            ),
                          ),
                          Text('按紧急程度', style: t.body(12, color: t.hint)),
                        ],
                      ),
                    ),
                    _summary(a),
                    ..._sections(a, wide: true),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Flexible(
              flex: 56,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: current == null
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.only(right: 6, bottom: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AgentAttentionDetail(
                              data: agentCardFor(current, _index + 1),
                              onApprove: () => widget.onApprove(current),
                              onOpen: () => widget.onOpen(current),
                              onLater: () => widget.onLater(current),
                            ),
                            const AgentKeyHints(
                              hints: [('↑↓', '切换'), ('↵', '通过'), ('S', '稍后')],
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
