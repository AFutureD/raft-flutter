import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart' show RaftTokens;

import '../../data/workspace_controller.dart';
import 'agent_mode_data.dart';
import 'agent_tv.dart';

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
    final tv = AgentPresentation.instance;
    tv.onDisplaysChanged = () => unawaited(_attachTv());
    unawaited(_attachTv());
  }

  bool _tvAttached = false;
  String? _sentFrame;

  Future<void> _attachTv() async {
    final attached = await AgentPresentation.instance.attach();
    if (!mounted) return;
    _tvAttached = attached;
    _sentFrame = null;
    setState(() {});
  }

  @override
  void dispose() {
    unawaited(AgentPresentation.instance.detach());
    super.dispose();
  }

  /// Sends the visible layers to the TV after a build that changed them.
  void _syncTv(BuildContext context) {
    if (!_tvAttached) return;
    final t = RaftTokens.of(context);
    final frame = {
      'theme': t.brutal
          ? 'brutal'
          : t.dark
          ? 'elegant-dark'
          : 'elegant-light',
      'layers': [
        for (final l in _stack.skip(_stack.length > 3 ? _stack.length - 3 : 0))
          {..._frame(l), 'id': l.id, 'peek': _peek(l)},
      ],
    };
    final encoded = jsonEncode(frame);
    if (encoded == _sentFrame) return;
    _sentFrame = encoded;
    unawaited(AgentPresentation.instance.send(frame));
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

  String _hhmm(Object? iso) {
    final t = iso is String ? DateTime.tryParse(iso)?.toLocal() : null;
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  Map<String, Object?> _taskItem(Map<String, dynamic> t, {bool where = false}) {
    final review = t['status'] == 'in_review';
    return {
      'kind': 'priority',
      'priority':
          (review ? AgentPriority.decision : AgentPriority.progress).name,
      'label': review ? '等验收' : '进行中',
      'weight': review ? 4 : 2,
      'title': '${t['title'] ?? ''}',
      'detail': [
        '#${t['taskNumber']}',
        '${t['claimedByName'] ?? '未认领'}',
        if (where) '#${t['channelName'] ?? ''}',
      ].join(' · '),
      'channelId': where ? t['channelId'] : null,
    };
  }

  /// One layer as data: drawn on the phone and sent unchanged to the TV.
  Map<String, Object?> _frame(_Layer l) => switch (l) {
    _Attention() => {
      'title': '现在需要你',
      'meta': '按权重排序',
      'loading': _attention == null && _attentionError == null,
      'summary': _attentionError != null
          ? '读取失败：$_attentionError'
          : _attention == null
          ? null
          : _attentionSummary(_attention!),
      'items': [
        for (final i in _attention?.take(8) ?? const <AgentAttentionItem>[])
          {
            'kind': 'priority',
            'priority': i.priority.name,
            'weight': i.weight,
            'title': i.title,
            'detail': i.detail,
            'chips': i.chips,
            'channelId': i.channelId,
          },
      ],
    },
    _Channel(:final channel) => () {
      final b = _briefs[channel.id];
      final error = _briefErrors[channel.id];
      return <String, Object?>{
        'title': '# ${channel.name}',
        'meta': b == null ? null : '最近 ${b.windowHours} 小时',
        'loading': b == null && error == null,
        'summary': error != null
            ? '读取失败：$error'
            : b == null
            ? null
            : '要点：${_channelSummary(b)}',
        'items': [
          if (b != null && b.tasks.isNotEmpty) ...[
            {'kind': 'section', 'text': '进行中的任务'},
            for (final t in b.tasks.take(4)) _taskItem(t),
          ],
          if (b != null && b.messages.isNotEmpty) ...[
            {'kind': 'section', 'text': '最近的消息'},
            for (final m in b.messages.reversed.take(8))
              {
                'kind': 'message',
                'sender': '${m['senderName'] ?? ''}',
                'time': _hhmm(m['createdAt']),
                'text': '${m['content'] ?? ''}',
              },
          ],
        ],
      };
    }(),
    _Tasks() => {
      'title': '进行中的任务',
      'loading': _tasks == null && _tasksError == null,
      'summary': _tasksError == null ? null : '读取失败：$_tasksError',
      'items': [
        for (final t in _tasks ?? const <Map<String, dynamic>>[])
          _taskItem(t, where: true),
      ],
    },
  };

  String _peek(_Layer l) => switch (l) {
    _Attention() => '现在需要你',
    _Channel(:final channel) => '# ${channel.name}',
    _Tasks() => '进行中的任务',
  };

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTv(context);
    });
    return PopScope(
      canPop: _stack.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _pop();
      },
      child: Scaffold(
        backgroundColor: t.canvas,
        body: AgentCanvas(
          child: SafeArea(
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
                          if (_tvAttached)
                            Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: Icon(Icons.tv, size: 16, color: t.hint),
                            ),
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
                              child: AgentFrameView(
                                frame: _frame(l),
                                onOpen: (id) {
                                  final c = _channelById(id);
                                  if (c != null) _openChannel(c);
                                },
                              ),
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
      ),
    );
  }
}
