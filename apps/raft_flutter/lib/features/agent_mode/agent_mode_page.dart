import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart' show RaftTokens;

import '../../data/workspace_controller.dart';
import 'agent_audio.dart';
import 'agent_mode_data.dart';
import 'agent_tv.dart';
import 'agent_voice.dart';

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
  late final _voice = AgentVoiceController(
    tools: _toolDeclarations,
    onToolCall: _runTool,
    systemPrompt: _systemPrompt,
  );

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
    _voice.dispose();
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
        _voice.say(AgentSpeaker.agent, _attentionSummary(items));
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

  Future<AgentChannelBrief?> _openChannel(
    RaftChannel c, {
    bool announce = true,
  }) async {
    final layer = _Channel(c);
    _push(layer);
    try {
      final brief = await data.channel(c);
      if (!mounted) return null;
      setState(() {
        _briefs[c.id] = brief;
        _briefErrors.remove(c.id);
      });
      if (announce) _voice.say(AgentSpeaker.agent, _channelSummary(brief));
      return brief;
    } catch (e) {
      if (mounted) setState(() => _briefErrors[c.id] = e);
      rethrow;
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

  Future<List<Map<String, dynamic>>?> _showTasks({bool announce = true}) async {
    _push(const _Tasks());
    try {
      final tasks = await data.openTasks();
      if (!mounted) return null;
      setState(() {
        _tasks = tasks;
        _tasksError = null;
      });
      final review = tasks.where((t) => t['status'] == 'in_review').length;
      if (announce) {
        _voice.say(
          AgentSpeaker.agent,
          '进行中的任务有 ${tasks.length - review} 个，等验收的 $review 个。',
        );
      }
      return tasks;
    } catch (e) {
      if (mounted) setState(() => _tasksError = e);
      rethrow;
    }
  }

  Future<void> _submit(String text) async {
    if (await _voice.sendText(text)) return;
    if (!mounted) return;
    _voice.say(AgentSpeaker.you, text);
    switch (parseAgentIntent(text, widget.controller.channels)) {
      case AgentBack():
        _pop();
      case AgentHome():
        setState(() => _stack.removeRange(1, _stack.length));
      case AgentTasks():
        _showTasks().ignore();
      case AgentOpenChannel(:final channel):
        _openChannel(channel).ignore();
      case AgentUnknown():
        _voice.say(AgentSpeaker.agent, '这句我还不会。可以说一个频道名、“任务”或者“返回”。');
    }
  }

  static const _toolDeclarations = <Map<String, Object?>>[
    {
      'name': 'show_attention',
      'description':
          '回到首页并列出现在需要用户处理的事（等决定、卡住、提到他、进展），按权重排序。问“现在怎么样”“有什么要我处理”时用。',
    },
    {
      'name': 'open_channel',
      'description': '在屏幕上打开一个频道，返回它最近的消息和进行中的任务。',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '频道名，不带 #'},
        },
        'required': ['name'],
      },
    },
    {'name': 'show_tasks', 'description': '在屏幕上列出所有进行中和等验收的任务。'},
    {'name': 'go_back', 'description': '返回上一层。'},
  ];

  String _systemPrompt() {
    final channels = widget.controller.channels
        .where((c) => c.name.isNotEmpty)
        .take(80)
        .map((c) => c.name)
        .join('、');
    final attention = _attention == null
        ? ''
        : '\n当前首页：${_attentionSummary(_attention!)}';
    return '你是用户在 Raft 里的个人语音助理。Raft 是一个人和 AI agent 一起协作的消息平台。\n'
        '用简短、口语化的中文回答，一般一两句话；不要用列表、编号或 Markdown。\n'
        '屏幕会显示细节，你只说重点和结论，不要逐条朗读。\n'
        '需要信息时先调用工具再回答：整体情况用 show_attention，某个频道用 open_channel，'
        '任务用 show_tasks，用户说“返回”用 go_back。\n'
        '你现在只能查看，不能发消息、改任务或做其他操作；被要求做这些时，说明 demo 还不支持。\n'
        '可以打开的频道：$channels$attention';
  }

  static String _clip(Object? v, [int max = 240]) {
    final text = '${v ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= max ? text : '${text.substring(0, max)}…';
  }

  RaftChannel? _channelNamed(String raw) {
    String norm(String v) =>
        v.toLowerCase().replaceAll(RegExp(r'[#\s_\-]'), '');
    final want = norm(raw);
    if (want.isEmpty) return null;
    final channels = widget.controller.channels;
    return channels.where((c) => norm(c.name) == want).firstOrNull ??
        channels.where((c) => norm(c.name).contains(want)).firstOrNull ??
        channels
            .where((c) => c.name.isNotEmpty && want.contains(norm(c.name)))
            .firstOrNull;
  }

  Map<String, Object?> _taskFacts(Map<String, dynamic> t) => {
    'number': t['taskNumber'],
    'title': _clip(t['title'], 120),
    'status': t['status'],
    'owner': t['claimedByName'],
    'channel': t['channelName'],
  };

  /// Voice tools: each one changes the screen and returns what is on it.
  Future<Map<String, Object?>> _runTool(
    String name,
    Map<String, Object?> args,
  ) async {
    if (!mounted) return {'error': 'closed'};
    switch (name) {
      case 'show_attention':
        setState(() => _stack.removeRange(1, _stack.length));
        final items = _attention ?? await data.attention();
        return {
          'items': [
            for (final i in items.take(10))
              {
                'kind': agentPriorityLabels[i.priority],
                'weight': i.weight,
                'title': _clip(i.title, 120),
                'detail': _clip(i.detail, 120),
              },
          ],
        };
      case 'open_channel':
        final c = _channelNamed('${args['name'] ?? ''}');
        if (c == null) return {'error': '没有叫 ${args['name']} 的频道'};
        final b = await _openChannel(c, announce: false);
        if (b == null) return {'error': 'closed'};
        return {
          'channel': c.name,
          'hours': b.windowHours,
          'tasks': [for (final t in b.tasks.take(8)) _taskFacts(t)],
          'messages': [
            for (final m in b.messages.reversed.take(15))
              {
                'from': m['senderName'],
                'time': _hhmm(m['createdAt']),
                'text': _clip(m['content']),
              },
          ],
        };
      case 'show_tasks':
        final tasks = await _showTasks(announce: false) ?? const [];
        return {
          'tasks': [for (final t in tasks.take(20)) _taskFacts(t)],
        };
      case 'go_back':
        _pop();
        return {'ok': true, 'layers': _stack.length};
    }
    return {'error': 'unknown tool $name'};
  }

  Future<void> _scanKey() async {
    try {
      final key = AgentVoiceKey.parse(await AgentAudio.instance.scanCode());
      if (key == null) return;
      await AgentVoiceKey.instance.save(key);
      _voice.say(AgentSpeaker.agent, 'Key 已保存。按住下面的按钮说话吧。');
    } on PlatformException catch (e) {
      _voice.say(AgentSpeaker.agent, '扫码失败：${e.message ?? e.code}');
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
                          if (AgentAudio.instance.supported)
                            IconButton(
                              key: const ValueKey('agent-voice-key-scan'),
                              tooltip: '扫码填入 Gemini Key',
                              icon: Icon(
                                Icons.qr_code_scanner,
                                size: 20,
                                color: t.muted,
                              ),
                              onPressed: _scanKey,
                            ),
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
                                  if (c != null) _openChannel(c).ignore();
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      child: ListenableBuilder(
                        listenable: _voice,
                        builder: (context, _) => AgentVoiceDock(
                          lines: _voice.lines,
                          state: _voice.state,
                          notice: _voice.notice,
                          onSubmit: _submit,
                          onMicDown: () => unawaited(_voice.micDown()),
                          onMicUp: _voice.micUp,
                        ),
                      ),
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
