import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';

import '../../data/workspace_controller.dart';
import 'agent_mode_data.dart';

/// Opens agent mode above the workspace. A [PageRouteBuilder] (not a
/// MaterialPageRoute) so a layout change adapts the page instead of closing it.
Future<void> openAgentMode(BuildContext context, WorkspaceController w) =>
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: '/agent-mode'),
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => AgentModePage(controller: w),
        transitionsBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween(begin: .94, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );

class AgentModePage extends StatefulWidget {
  const AgentModePage({super.key, required this.controller, this.data});
  final WorkspaceController controller;

  /// Test seam; defaults to reading the workspace.
  final AgentModeData? data;

  @override
  State<AgentModePage> createState() => _AgentModePageState();
}

sealed class _Layer {
  const _Layer(this.id);
  final String id;
}

class _Attention extends _Layer {
  const _Attention() : super('attention');
}

class _Channel extends _Layer {
  _Channel(this.channel) : super('channel:${channel.id}');
  final RaftChannel channel;
}

class _Tasks extends _Layer {
  const _Tasks() : super('tasks');
}

class _AgentModePageState extends State<AgentModePage> {
  late final data = widget.data ?? AgentModeData(widget.controller);
  final _stack = <_Layer>[const _Attention()];
  final _lines = <(AgentSpeaker, String)>[];

  List<AgentAttentionItem>? _attention;
  Object? _attentionError;
  final _briefs = <String, AgentChannelBrief>{};
  final _briefErrors = <String, Object>{};
  List<Map<String, dynamic>>? _tasks;
  Object? _tasksError;

  @override
  void initState() {
    super.initState();
    _loadAttention();
  }

  Future<void> _loadAttention() async {
    try {
      final items = await data.attention();
      if (!mounted) return;
      setState(() {
        _attention = items;
        _attentionError = null;
        _lines.add((AgentSpeaker.agent, _attentionSummary(items)));
      });
    } catch (e) {
      if (mounted) setState(() => _attentionError = e);
    }
  }

  String _attentionSummary(List<AgentAttentionItem> items) {
    int count(AgentPriority p) => items.where((i) => i.priority == p).length;
    final decision = count(AgentPriority.decision);
    final blocked = count(AgentPriority.blocked);
    final mention = count(AgentPriority.mention);
    if (decision + blocked + mention == 0) return '现在没有需要你处理的事。';
    final parts = [
      if (decision > 0) '$decision 件等你决定',
      if (blocked > 0) '$blocked 件卡住了',
      if (mention > 0) '$mention 处提到了你',
    ];
    return '${parts.join('，')}。';
  }

  void _push(_Layer layer) {
    setState(() {
      _stack.removeWhere((l) => l.id == layer.id);
      _stack.add(layer);
    });
  }

  void _pop() {
    if (_stack.length > 1) setState(_stack.removeLast);
  }

  void _revealTo(int index) {
    setState(() => _stack.removeRange(index + 1, _stack.length));
  }

  Future<void> _openChannel(RaftChannel c) async {
    final layer = _Channel(c);
    _push(layer);
    try {
      final brief = await data.channel(c);
      if (!mounted) return;
      setState(() {
        _briefs[c.id] = brief;
        _briefErrors.remove(c.id);
        _lines.add((AgentSpeaker.agent, _channelSummary(brief)));
      });
    } catch (e) {
      if (mounted) setState(() => _briefErrors[c.id] = e);
    }
  }

  String _channelSummary(AgentChannelBrief b) {
    final parts = [
      '#${b.channel.name} 最近有 ${b.recentCount} 条消息',
      if (b.inReview > 0) '${b.inReview} 个任务等验收',
      if (b.inProgress > 0) '${b.inProgress} 个在进行',
    ];
    return '${parts.join('，')}。细节在屏幕上。';
  }

  Future<void> _showTasks() async {
    _push(const _Tasks());
    try {
      final tasks = await data.openTasks();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _tasksError = null;
        final review = tasks.where((t) => t['status'] == 'in_review').length;
        _lines.add((
          AgentSpeaker.agent,
          '进行中的任务有 ${tasks.length - review} 个，等验收的 $review 个。',
        ));
      });
    } catch (e) {
      if (mounted) setState(() => _tasksError = e);
    }
  }

  void _submit(String text) {
    setState(() => _lines.add((AgentSpeaker.you, text)));
    switch (parseAgentIntent(text, widget.controller.channels)) {
      case AgentBack():
        _pop();
      case AgentHome():
        setState(() => _stack.removeRange(1, _stack.length));
      case AgentTasks():
        _showTasks();
      case AgentOpenChannel(:final channel):
        _openChannel(channel);
      case AgentUnknown():
        setState(
          () => _lines.add((AgentSpeaker.agent, '这句我还不会。可以说一个频道名、“任务”或者“返回”。')),
        );
    }
  }

  RaftChannel? _channelById(String? id) => id == null
      ? null
      : widget.controller.channels.where((c) => c.id == id).firstOrNull;

  Widget _attentionLayer() {
    final items = _attention;
    final top = items?.take(8).toList() ?? const <AgentAttentionItem>[];
    return AgentLayerFrame(
      title: '现在需要你',
      meta: '按权重排序',
      loading: items == null && _attentionError == null,
      error: _attentionError == null ? null : '读取失败：$_attentionError',
      summary: items == null ? null : TextSpan(text: _attentionSummary(items)),
      children: [
        for (final i in top)
          AgentPriorityCard(
            priority: i.priority,
            weight: i.weight,
            title: i.title,
            detail: i.detail,
            chips: [
              for (final (n, c) in i.chips.indexed)
                AgentChip(c, hot: i.hot && n == 0),
            ],
            onTap: _channelById(i.channelId) == null
                ? null
                : () => _openChannel(_channelById(i.channelId)!),
          ),
      ],
    );
  }

  String _hhmm(Object? iso) {
    final t = iso is String ? DateTime.tryParse(iso)?.toLocal() : null;
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  Widget _channelLayer(_Channel layer) {
    final b = _briefs[layer.channel.id];
    final error = _briefErrors[layer.channel.id];
    return AgentLayerFrame(
      title: '# ${layer.channel.name}',
      meta: b == null ? null : '最近 ${b.windowHours} 小时',
      loading: b == null && error == null,
      error: error == null ? null : '读取失败：$error',
      summary: b == null
          ? null
          : TextSpan(
              children: [
                const TextSpan(
                  text: '要点：',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: _channelSummary(b)),
              ],
            ),
      children: [
        if (b != null && b.tasks.isNotEmpty) ...[
          const AgentSectionLabel('进行中的任务'),
          for (final t in b.tasks.take(4))
            AgentPriorityCard(
              priority: t['status'] == 'in_review'
                  ? AgentPriority.decision
                  : AgentPriority.progress,
              label: t['status'] == 'in_review' ? '等验收' : '进行中',
              weight: t['status'] == 'in_review' ? 4 : 2,
              title: '${t['title'] ?? ''}',
              detail: '#${t['taskNumber']} · ${t['claimedByName'] ?? '未认领'}',
            ),
        ],
        if (b != null && b.messages.isNotEmpty) ...[
          const AgentSectionLabel('最近的消息'),
          for (final m in b.messages.reversed.take(8))
            AgentMessageTile(
              sender: '${m['senderName'] ?? ''}',
              time: _hhmm(m['createdAt']),
              text: '${m['content'] ?? ''}',
            ),
        ],
      ],
    );
  }

  Widget _tasksLayer() {
    final tasks = _tasks;
    return AgentLayerFrame(
      title: '进行中的任务',
      loading: tasks == null && _tasksError == null,
      error: _tasksError == null ? null : '读取失败：$_tasksError',
      children: [
        for (final t in tasks ?? const <Map<String, dynamic>>[])
          AgentPriorityCard(
            priority: t['status'] == 'in_review'
                ? AgentPriority.decision
                : AgentPriority.progress,
            label: t['status'] == 'in_review' ? '等验收' : '进行中',
            weight: t['status'] == 'in_review' ? 4 : 2,
            title: '${t['title'] ?? ''}',
            detail:
                '#${t['taskNumber']} · ${t['claimedByName'] ?? '未认领'} · #${t['channelName'] ?? ''}',
            onTap: _channelById(t['channelId'] as String?) == null
                ? null
                : () => _openChannel(_channelById(t['channelId'] as String?)!),
          ),
      ],
    );
  }

  Widget _layerBody(_Layer l) => switch (l) {
    _Attention() => _attentionLayer(),
    _Channel() => _channelLayer(l),
    _Tasks() => _tasksLayer(),
  };

  String _peek(_Layer l) => switch (l) {
    _Attention() => '现在需要你',
    _Channel(:final channel) => '# ${channel.name}',
    _Tasks() => '进行中的任务',
  };

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return PopScope(
      canPop: _stack.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _pop();
      },
      child: Scaffold(
        backgroundColor: t.canvas,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                    child: Row(
                      children: [
                        IconButton(
                          key: const ValueKey('agent-mode-close'),
                          tooltip: '关闭',
                          icon: Icon(Icons.close, color: t.muted),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        Text('Agent 模式', style: t.heading(15)),
                        const Spacer(),
                        Text(
                          '第 ${_stack.length} 层',
                          style: t.body(12, color: t.hint),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ZLayerStack(
                      padding: const EdgeInsets.fromLTRB(14, 76, 14, 12),
                      onReveal: _revealTo,
                      layers: [
                        for (final l in _stack)
                          ZLayer(
                            key: ValueKey(l.id),
                            peek: _peek(l),
                            child: _layerBody(l),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: AgentVoiceDock(lines: _lines, onSubmit: _submit),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
