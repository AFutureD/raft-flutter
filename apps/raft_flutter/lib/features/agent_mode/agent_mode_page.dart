import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart' show RaftTokens;

import '../../data/workspace_controller.dart';
import 'agent_audio.dart';
import 'agent_memory.dart';
import 'agent_mode_data.dart';
import 'agent_tools.dart';
import 'agent_tv.dart';
import 'agent_voice.dart';
import 'agent_voice_settings.dart';

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
    tools: agentToolDeclarations,
    onToolCall: _runTool,
    systemPrompt: _systemPrompt,
    beforeConnect: () => _brainLoading ?? Future<void>.value(),
    onSessionEnd: _sessionEnded,
  );

  /// Memory shared with a Raft agent (real workspace only).
  late final _brain = AgentBrain(widget.controller);
  String? _brainContext;
  String? _brainContextFor;
  Future<void>? _brainLoading;

  /// The item the agent is talking about, lifted above the page.
  final _spotlight = AgentSpotlightController();
  final _marks = AgentMarkController();
  AgentMicState _lastMic = AgentMicState.idle;

  /// Bumped on every layer change so a visual timed to speech that belongs
  /// to an old screen never fires.
  int _screenEpoch = 0;

  /// Visuals waiting for the agent to say their words, in call order.
  final _cues = <({Set<String> words, VoidCallback effect, int epoch})>[];
  int _heardFrom = 0;
  Timer? _cueFallback;
  Object? _fallbackFor;

  /// Runs [effect] once the agent says [words] (fuzzy, from the live
  /// transcript) and the speaker has reached them. Models often send every
  /// tool call before speaking; this keeps each visual on its own phrase.
  void _cue(String words, VoidCallback effect) {
    _cues.add((words: _grams(words), effect: effect, epoch: _screenEpoch));
    _checkCues();
  }

  void _sayingChanged() {
    if (_voice.saying.value.isEmpty) {
      // A new reply: leftovers from the last one no longer apply.
      _cues.clear();
      _heardFrom = 0;
      _cueFallback?.cancel();
      _fallbackFor = null;
      return;
    }
    _checkCues();
  }

  void _checkCues() {
    while (_cues.isNotEmpty) {
      final cue = _cues.first;
      if (cue.epoch != _screenEpoch) {
        _cues.removeAt(0);
        continue;
      }
      final said = _voice.saying.value;
      final fresh = said.length >= _heardFrom ? said.substring(_heardFrom) : '';
      if (!_heard(fresh, cue.words)) break;
      _cues.removeAt(0);
      _heardFrom = said.length;
      unawaited(_atSpeech(cue.effect));
    }
    if (_cues.isEmpty) {
      _cueFallback?.cancel();
      _fallbackFor = null;
      return;
    }
    // Words that never come (paraphrase, another language) still show, in
    // order, a little after the cue reaches the front of the queue; more
    // transcript arriving does not postpone it.
    if (identical(_fallbackFor, _cues.first)) return;
    _fallbackFor = _cues.first;
    _cueFallback?.cancel();
    _cueFallback = Timer(const Duration(milliseconds: 3500), () {
      if (!mounted || _cues.isEmpty) return;
      final cue = _cues.removeAt(0);
      _fallbackFor = null;
      _heardFrom = _voice.saying.value.length;
      if (cue.epoch == _screenEpoch) cue.effect();
      _checkCues();
    });
  }

  static Set<String> _grams(String text) {
    final t = text.toLowerCase().replaceAll(
      RegExp(r'[\s\p{P}\p{S}]', unicode: true),
      '',
    );
    final words = RegExp(r'[a-z0-9]+');
    return {
      for (final m in words.allMatches(t))
        if (m[0]!.length >= 2) m[0]!,
      for (final part in t.split(words))
        for (var i = 0; i + 1 < part.length; i++) part.substring(i, i + 2),
    };
  }

  static bool _heard(String said, Set<String> words) {
    if (words.isEmpty) return true;
    final heard = _grams(said);
    final hits = words.where(heard.contains).length;
    return hits >= math.max(1, math.min(3, (words.length * .25).ceil()));
  }

  /// Runs [effect] when the speaker reaches the words received so far, so
  /// a spotlight or a mark lands with the phrase it belongs to.
  Future<void> _atSpeech(VoidCallback effect) async {
    final epoch = _screenEpoch;
    final wait = await AgentAudio.instance.pending();
    if (wait > const Duration(milliseconds: 60)) {
      await Future<void>.delayed(wait - const Duration(milliseconds: 40));
    }
    if (mounted && epoch == _screenEpoch) effect();
  }

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
    _voice.addListener(_voiceChanged);
    AgentVoiceSettings.instance.addListener(_loadBrain);
    _loadBrain();
    _voice.saying.addListener(_sayingChanged);
    _spotlight.addListener(() {
      // Annotations belong to what is being explained; a new focus or
      // putting the item back wipes them.
      _marks.clear();
      setState(() {});
    });
    _marks.addListener(() => setState(() {}));
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
    _voice.removeListener(_voiceChanged);
    AgentVoiceSettings.instance.removeListener(_loadBrain);
    _voice.saying.removeListener(_sayingChanged);
    _cueFallback?.cancel();
    _voice.dispose();
    _spotlight.dispose();
    _marks.dispose();
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
      'spotlight': _spotlight.focused,
      'marks': [for (final m in _marks.marks) m.toJson()],
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
    _spotlight.release();
    _marks.clear();
    _screenEpoch++;
    setState(() {
      _stack.removeWhere((l) => l.id == layer.id);
      _stack.add(layer);
    });
  }

  void _pop() {
    _spotlight.release();
    _marks.clear();
    _screenEpoch++;
    if (_stack.length > 1) setState(_stack.removeLast);
  }

  void _revealTo(int index) {
    _spotlight.release();
    _marks.clear();
    _screenEpoch++;
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

  String _systemPrompt() => agentSystemPrompt(
    style: AgentVoiceSettings.instance.styleNote,
    memory: _brainContext,
    channels: widget.controller.channels
        .where((c) => c.name.isNotEmpty)
        .take(80)
        .map((c) => c.name)
        .join('、'),
    home: _attention == null ? null : _attentionSummary(_attention!),
  );

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

  /// The items of the front layer, numbered as the person sees them.
  List<Map<String, Object?>> _screenItems() {
    final items = (_frame(_stack.last)['items'] as List?) ?? const [];
    var n = 0;
    return [
      for (final i in items.cast<Map<String, Object?>>())
        if (i['kind'] != 'section')
          {
            'n': ++n,
            if (i['kind'] == 'message') ...{
              'from': i['sender'],
              'time': i['time'],
              'text': _clip(i['text'], 160),
            } else ...{
              'label':
                  i['label'] ??
                  agentPriorityLabels[AgentPriority.values
                      .where((p) => p.name == i['priority'])
                      .firstOrNull],
              'title': _clip(i['title'], 120),
              'detail': _clip(i['detail'], 80),
            },
          },
    ];
  }

  /// What the screen shows now; every screen tool returns this.
  Map<String, Object?> _screen() {
    final frame = _frame(_stack.last);
    return {
      'layer': _stack.length,
      'title': _peek(_stack.last),
      if (frame['loading'] == true) 'loading': true,
      'items': _screenItems().take(12).toList(),
    };
  }

  Future<Map<String, Object?>> _channelFacts(RaftChannel c) async {
    final b = _briefs[c.id] ?? await data.channel(c);
    if (mounted && !_briefs.containsKey(c.id)) {
      setState(() => _briefs[c.id] = b);
    }
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
  }

  /// Voice tools. Screen tools act before returning and never wait for data;
  /// read tools fetch what the model needs to answer.
  Future<Map<String, Object?>> _runTool(
    String name,
    Map<String, Object?> args,
  ) async {
    if (!mounted) return {'error': 'closed'};
    switch (name) {
      case 'show_attention' || 'go_home':
        setState(() => _stack.removeRange(1, _stack.length));
        return _screen();
      case 'open_channel':
        final c = _channelNamed('${args['name'] ?? ''}');
        if (c == null) return {'error': '没有叫 ${args['name']} 的频道'};
        final top = _stack.last;
        if (top is! _Channel || top.channel.id != c.id) {
          _openChannel(c, announce: false).ignore();
        }
        return _screen();
      case 'open_item':
        final n = (args['number'] as num?)?.toInt() ?? 0;
        final items = (_frame(_stack.last)['items'] as List? ?? const [])
            .cast<Map<String, Object?>>()
            .where((i) => i['kind'] != 'section')
            .toList();
        if (n < 1 || n > items.length) {
          return {'error': '屏幕上没有第 $n 条', ..._screen()};
        }
        final c = _channelById(items[n - 1]['channelId'] as String?);
        if (c == null) return {'error': '第 $n 条没有可以打开的详情', ..._screen()};
        _openChannel(c, announce: false).ignore();
        return _screen();
      case 'spotlight':
        final n = (args['number'] as num?)?.toInt() ?? 0;
        final items = _screenItems();
        if (n < 1 || n > items.length) {
          return {'error': '屏幕上没有第 $n 条', ..._screen()};
        }
        final id = '${_stack.last.id}#$n';
        final item = items[n - 1];
        _cue(
          [
            for (final k in const ['label', 'title', 'detail', 'from', 'text'])
              '${item[k] ?? ''}',
          ].join(' '),
          () => _spotlight.focus(id),
        );
        return {'ok': true, 'item': items[n - 1]};
      case 'mark':
        final n = (args['number'] as num?)?.toInt() ?? 0;
        final phrase = '${args['phrase'] ?? ''}'.trim();
        final items = _screenItems();
        if (n < 1 || n > items.length) {
          return {'error': '屏幕上没有第 $n 条', ..._screen()};
        }
        final item = items[n - 1];
        final words = [
          for (final k in const ['title', 'detail', 'text']) '${item[k] ?? ''}',
        ];
        if (phrase.isEmpty || !words.any((w) => w.contains(phrase))) {
          return {'error': '第 $n 条里没有“$phrase”这几个字，请从原文里挑', 'item': item};
        }
        final style =
            AgentMarkStyle.values
                .where((v) => v.name == args['style'])
                .firstOrNull ??
            AgentMarkStyle.circle;
        final mark = AgentMark(
          itemId: '${_stack.last.id}#$n',
          phrase: phrase,
          style: style,
          note: args['note'] as String?,
        );
        // Marking an item that is not lifted lifts it first.
        _cue(phrase, () {
          if (_spotlight.focused != mark.itemId) {
            _spotlight.focus(mark.itemId);
          }
          _marks.add(mark);
        });
        return {'ok': true};
      case 'release_spotlight':
        _spotlight.release();
        return {'ok': true};
      case 'show_tasks':
        if (_stack.last is! _Tasks) _showTasks(announce: false).ignore();
        return _screen();
      case 'go_back':
        _pop();
        return _screen();
      case 'read_channel':
        final named = '${args['name'] ?? ''}';
        final top = _stack.last;
        final c = named.isEmpty
            ? (top is _Channel ? top.channel : null)
            : _channelNamed(named);
        if (c == null) {
          return {'error': named.isEmpty ? '屏幕上没有打开频道' : '没有叫 $named 的频道'};
        }
        return _channelFacts(c);
      case 'read_tasks':
        final tasks = _tasks ?? await data.openTasks();
        if (mounted && _tasks == null) setState(() => _tasks = tasks);
        return {
          'tasks': [for (final t in tasks.take(20)) _taskFacts(t)],
        };
    }
    return {'error': 'unknown tool $name'};
  }

  /// The lifted item goes back once the agent has finished speaking.
  void _voiceChanged() {
    final now = _voice.state;
    final finished =
        _lastMic == AgentMicState.speaking && now == AgentMicState.idle;
    _lastMic = now;
    if (!finished || _spotlight.focused == null) return;
    final shown = _spotlight.focused;
    final said = _voice.saying.value.length;
    // A pause between sentences also goes idle; only put the item back once
    // the reply has really stopped (no new words, nothing waiting to show).
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted &&
          _spotlight.focused == shown &&
          _voice.state == AgentMicState.idle &&
          _voice.saying.value.length == said &&
          _cues.isEmpty) {
        _spotlight.release();
      }
    });
  }

  /// Reads the chosen agent's memory for the next voice session.
  Future<void> _loadBrain() async {
    final brain = widget.data == null
        ? AgentVoiceSettings.instance.brain
        : null;
    if (brain?.id == _brainContextFor) return;
    _brainContextFor = brain?.id;
    if (brain == null) {
      _brainContext = null;
      return;
    }
    final loading = _brain.context(brain);
    _brainLoading = loading.then((_) {}, onError: (Object _) {});
    final context = await loading;
    if (!mounted || _brainContextFor != brain.id) return;
    _brainContext = context;
    // Says what the voice will remember, so a missing memory is visible.
    final note = _brain.note;
    if (note != null) _voice.say(AgentSpeaker.agent, '记忆：$note');
  }

  /// Hands the session to the shared agent so it remembers what matters.
  void _sessionEnded(List<(AgentSpeaker, String)> transcript) {
    final settings = AgentVoiceSettings.instance;
    final brain = settings.brain;
    if (widget.data != null || brain == null || !settings.writeBack) return;
    unawaited(
      _brain.sendSummary(brain, transcript).catchError((Object _) => false),
    );
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
        body: AgentMarks(
          controller: _marks,
          child: AgentCanvas(
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
                            IconButton(
                              key: const ValueKey('agent-voice-settings'),
                              tooltip: '声音设置',
                              icon: Icon(Icons.tune, size: 20, color: t.muted),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => AgentVoiceSettingsPage(
                                    agents: widget.data == null
                                        ? _brain.agents
                                        : null,
                                    onPreview: (v) =>
                                        unawaited(_voice.preview(v)),
                                  ),
                                ),
                              ),
                            ),
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
                        child: AgentSpotlight(
                          controller: _spotlight,
                          child: ZLayerStack(
                            padding: const EdgeInsets.fromLTRB(14, 76, 14, 12),
                            onReveal: _revealTo,
                            layers: [
                              for (final l in _stack)
                                ZLayer(
                                  key: ValueKey(l.id),
                                  peek: _peek(l),
                                  child: AgentFrameView(
                                    focusPrefix: l.id,
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
      ),
    );
  }
}
