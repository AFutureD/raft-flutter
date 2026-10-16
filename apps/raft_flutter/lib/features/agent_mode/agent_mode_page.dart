import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart' show RaftTokens;

import '../../data/workspace_controller.dart';
import 'agent_attention.dart';
import 'agent_audio.dart';
import 'agent_catalog.dart';
import 'agent_choreography.dart';
import 'agent_detail.dart';
import 'agent_headlines.dart';
import 'agent_memory.dart';
import 'agent_mode_data.dart';
import 'agent_mood.dart';
import 'agent_scripted_model.dart';
import 'agent_surface.dart';
import 'agent_surface_stream.dart';
import 'agent_surface_tools.dart';
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
  const AgentModePage({
    super.key,
    required this.controller,
    this.data,
    this.model,
  });
  final WorkspaceController controller;

  /// Stands in for the voice model (offline demo, tests): answers the
  /// scripted questions through the same tools, with no network.
  final AgentScriptedModel? model;

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

/// A screen composed from the catalog: by the model (`show_surface`), or the
/// detail of one attention item ([item], `expand_item` and a tap on a card).
class _Surface extends _Layer {
  _Surface.draft(AgentSurfaceDraft this.draft, int n)
    : spec = draft.spec,
      item = null,
      super('surface:$n');
  _Surface.detail(this.spec, AgentAttentionItem this.item)
    : draft = null,
      super('detail:${item.id}');

  /// What is on screen; follows [draft] while the model composes it.
  AgentSurfaceSpec spec;

  /// Set for a screen the model composes (and streams).
  final AgentSurfaceDraft? draft;
  final AgentAttentionItem? item;

  /// Folded containers the person opened (paths, see `foldedPaths`).
  final expanded = <String>{};
}

class _AgentModePageState extends State<AgentModePage> {
  /// One summarizer for the app session, so its answers outlive a visit.
  static final _summarizer = ModelHeadlineSummarizer.gemini();

  late final data =
      widget.data ?? AgentModeData(widget.controller, summarizer: _summarizer);
  final _stack = <_Layer>[const _Attention()];
  int _surfaces = 0;

  /// Phone: the first attention card on screen (see [agentPhoneBatch]).
  int _batchStart = 0;

  /// The phone layout (set by build): surfaces fold their groups to one row.
  bool _compact = true;
  // ignore: raft_lints/avoid_imperative_notice_state -- Cleared by the next layer change (push, pop, reveal) or when a surface is accepted.
  String? _surfaceError;
  late final _grounded = AgentGroundedTools(
    data: data,
    host: AgentSurfaceHost(
      begin: _beginSurface,
      changed: _surfaceChanged,
      isOpen: (draft) =>
          _stack.any((l) => l is _Surface && identical(l.draft, draft)),
      ended: (_) {
        _choreo.end();
        _setComposing(false);
      },
    ),
    onRejected: (problems) {
      if (mounted) setState(() => _surfaceError = problems.first);
    },
  );
  late final _voice = AgentVoiceController(
    tools: [
      ...agentToolDeclarations,
      ...groundedToolDeclarations(agentStandardCatalog),
    ],
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

  /// The only owner of what moves for the voice: spotlight, marks and the
  /// typing of what is being said, timed to the speech.
  late final _choreo = AgentChoreographer(
    spotlight: _spotlight,
    marks: _marks,
    reveal: _reveal,
    saying: _voice.saying,
    playbackLag: AgentAudio.instance.pending,
    isSpeaking: () => _voice.state == AgentMicState.speaking,
  );
  final _reveal = AgentRevealSync();

  /// The mood badge: the phase comes from the voice session and the tools
  /// that run; the model may set a mood with `set_mood`.
  final _mood = AgentMoodController();
  int _reads = 0;
  bool _composing = false;
  bool _localBusy = false;
  Timer? _composingEnds;
  AgentMicState _moodMic = AgentMicState.idle;

  static const _readTools = {
    'list_agents',
    'get_task',
    'search_tasks',
    'read_channel',
    'read_tasks',
  };

  void _syncMood() {
    final mic = _voice.state;
    // A new turn starts when the person starts talking or typing.
    if (mic != _moodMic) {
      final start =
          mic == AgentMicState.holding ||
          mic == AgentMicState.live ||
          (mic == AgentMicState.thinking &&
              (_moodMic == AgentMicState.idle ||
                  _moodMic == AgentMicState.speaking));
      if (start) _mood.newTurn();
      _moodMic = mic;
    }
    _mood.setPhase(
      _reads > 0
          ? AgentMoodPhase.reading
          : _composing
          ? AgentMoodPhase.composing
          : _localBusy
          ? AgentMoodPhase.thinking
          : switch (mic) {
              AgentMicState.holding || AgentMicState.live =>
                AgentMoodPhase.listening,
              AgentMicState.connecting ||
              AgentMicState.thinking => AgentMoodPhase.thinking,
              AgentMicState.speaking => AgentMoodPhase.speaking,
              AgentMicState.idle => AgentMoodPhase.idle,
            },
    );
  }

  /// A screen is being composed (or has just been); a model that never ends
  /// it does not leave the badge writing for good.
  void _setComposing(bool on) {
    _composingEnds?.cancel();
    _composing = on;
    if (on) {
      _composingEnds = Timer(const Duration(seconds: 8), () {
        _composing = false;
        if (mounted) _syncMood();
      });
    }
    _syncMood();
  }

  /// The last accepted attention result. It starts from the previous visit
  /// so the first frame is already final; a refresh replaces it in place.
  late AgentAttention? _attention = AgentModeData.cached(widget.controller);
  bool _announced = false;
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
    _mood.addListener(() {
      if (mounted) setState(() {});
    });
    AgentVoiceSettings.instance.addListener(_loadBrain);
    _loadBrain();
    _spotlight.addListener(() => setState(() {}));
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
    _choreo.dispose();
    _reveal.dispose();
    _composingEnds?.cancel();
    _mood.dispose();
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
      'spotlightEnter': _spotlight.entering,
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

  /// What the person has not set aside or approved in this app session.
  AgentAttention? get _visible =>
      _attention?.without(AgentModeData.hidden(widget.controller));

  Future<void> _loadAttention() async {
    try {
      final result = await data.attention();
      if (!mounted) return;
      AgentModeData.remember(widget.controller, result);
      setState(() {
        _attention = result;
        _attentionError = null;
      });
      if (!_announced) {
        _announced = true;
        final visible = _visible!;
        final urgent = visible.urgent;
        _voice.say(
          AgentSpeaker.agent,
          urgent == null
              ? _attentionSummary(visible)
              : '${_attentionSummary(visible)}最急的：$urgent。',
        );
      }
    } catch (e) {
      // A result already on screen stays; only a first visit shows the error.
      if (mounted && _attention == null) setState(() => _attentionError = e);
    }
  }

  String _attentionSummary(AgentAttention a) => a.summary;

  /// True when the task was set to done.
  Future<bool> _approve(AgentAttentionItem item) async {
    final id = item.taskId;
    if (!item.canApprove || id == null) return false;
    final t = RaftAgentTheme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: t.layer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.cardRadius == 0 ? 14 : 18),
          side: BorderSide(color: t.line, width: t.cardBorderWidth),
        ),
        title: Text('通过这件事？', style: t.heading(18, weight: FontWeight.w900)),
        content: Text('${item.headline}\n\n会把任务设为已完成。', style: t.body(14)),
        actions: [
          TextButton(
            key: const ValueKey('attention-approve-cancel'),
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text('取消', style: t.body(14, color: t.muted)),
          ),
          FilledButton(
            key: const ValueKey('attention-approve-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: t.markHighlight,
              foregroundColor: t.foreground,
            ),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('通过'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return false;
    try {
      await data.approve(id);
    } catch (_) {
      if (mounted) {
        _voice.say(AgentSpeaker.agent, '没能通过这件事，任务还在原处。稍后再试，或打开讨论处理。');
      }
      return false;
    }
    if (!mounted) return false;
    setState(() => AgentModeData.hidden(widget.controller).add(item.id));
    _voice.say(AgentSpeaker.agent, '已通过：${item.headline}');
    unawaited(_loadAttention());
    return true;
  }

  void _later(AgentAttentionItem item) =>
      setState(() => AgentModeData.hidden(widget.controller).add(item.id));

  void _openItem(AgentAttentionItem item) {
    final c = _channelById(item.channelId);
    if (c == null) {
      _voice.say(AgentSpeaker.agent, '这条所在的频道不在你的列表里，打不开。');
      return;
    }
    _openChannel(c).ignore();
  }

  /// The detail of one attention item as a new layer. A tap on a card and
  /// the voice tool `expand_item` both come here, so they show the same
  /// thing. An open detail is replaced, not stacked.
  void _expandItem(AgentAttentionItem item) {
    final top = _stack.last;
    if (top is _Surface && top.item != null) _stack.removeLast();
    _push(_Surface.detail(attentionDetailSpec(item, _rankOf(item)), item));
  }

  int _rankOf(AgentAttentionItem item) {
    final at = (_visible?.items ?? const <AgentAttentionItem>[]).indexWhere(
      (i) => i.id == item.id,
    );
    return at < 0 ? 1 : at + 1;
  }

  /// `expand_item` and "讲讲第一条": [number] counts the home cards from 1;
  /// null means the focused one, else the most urgent.
  Map<String, Object?> _expandNumber(int? number) {
    final items = _visible?.items ?? const <AgentAttentionItem>[];
    if (items.isEmpty) return {'error': '现在没有需要你处理的事，没有可展开的'};
    final focused = RegExp(r'^attention#(\d+)$')
        .firstMatch(_spotlight.focused ?? '')?[1];
    final n = number ?? int.tryParse(focused ?? '') ?? 1;
    if (n < 1 || n > items.length) {
      return {'error': '首页没有第 $n 条，一共 ${items.length} 条'};
    }
    final item = items[n - 1];
    final facts = attentionFacts(item, n);
    // What the screen now shows may be quoted by the model.
    for (final p in item.progress) {
      _grounded.facts.learnMessage(p.who, p.text);
    }
    _expandItem(item);
    return {'ok': true, 'layer': _stack.length, 'item': facts};
  }

  /// 通过 / 打开讨论 / 稍后 on a detail layer: the only place they live.
  void _detailAction(_Surface layer, String action) {
    final item = layer.item;
    if (item == null) return;
    switch (action) {
      case 'approve':
        _approve(item).then((done) {
          if (done) _dismiss(layer);
        });
      case 'open':
        _openItem(item);
      case 'later':
        _later(item);
        _dismiss(layer);
    }
  }

  void _dismiss(_Layer layer) {
    if (!mounted || !_stack.contains(layer)) return;
    _choreo.newScreen();
    setState(() {
      _surfaceError = null;
      _stack.remove(layer);
    });
  }

  /// Shows the cards from [start] on the phone's first layer; what was
  /// lifted or marked belonged to the old ones.
  void _showBatch(int start) {
    _choreo.newScreen();
    setState(() => _batchStart = start);
  }

  /// `next_batch`: the next [agentPhoneBatch] cards, or the first ones again
  /// after the last. Takes the person back to the first layer.
  Map<String, Object?> _nextBatch() {
    final a = _visible;
    final cards = a == null ? 0 : a.decisionCount + a.blockedCount;
    if (cards <= agentPhoneBatch) {
      return {'error': '只有 $cards 件，已经全部显示了'};
    }
    final next = _batchStart + agentPhoneBatch;
    if (_stack.length > 1) setState(() => _stack.removeRange(1, _stack.length));
    _showBatch(next >= cards ? 0 : next);
    final from = _batchStart + 1;
    final to = (_batchStart + agentPhoneBatch).clamp(0, cards);
    return {'ok': true, 'showing': '第 $from 到 $to 条', 'total': cards};
  }

  /// A summary row was tapped: show that group in full.
  void _expandNode(_Surface layer, String path) {
    _choreo.newScreen();
    setState(() => layer.expanded.add(path));
  }

  void _push(_Layer layer) {
    _choreo.newScreen();
    setState(() {
      _surfaceError = null;
      _stack.removeWhere((l) => l.id == layer.id);
      _stack.add(layer);
    });
  }

  void _pop() {
    _choreo.newScreen();
    if (_stack.length > 1) {
      setState(() {
        _surfaceError = null;
        _stack.removeLast();
      });
    }
  }

  void _revealTo(int index) {
    _choreo.newScreen();
    setState(() {
      _surfaceError = null;
      _stack.removeRange(index + 1, _stack.length);
    });
  }

  /// `begin_surface` / `show_surface`: the screen becomes the front layer.
  Map<String, Object?> _beginSurface(AgentSurfaceDraft draft) {
    // The same screen asked again (say, a group in full) replaces itself.
    final top = _stack.last;
    if (top is _Surface &&
        top.item == null &&
        (top.draft?.id == draft.id || top.spec.title == draft.title)) {
      _stack.removeLast();
    }
    _push(_Surface.draft(draft, ++_surfaces));
    // A whole tree (show_surface) is composed already.
    _setComposing(!draft.ended);
    return _screen();
  }

  /// A component was added to, or changed on, a streamed screen. The
  /// layer follows the draft in place: what is above stays where it is.
  /// Returns the screen number of the component just added (when it is an
  /// item of its own) so the model can point at it.
  Map<String, Object?> _surfaceChanged(
    AgentSurfaceDraft draft, {
    String? added,
  }) {
    final layer = _stack
        .whereType<_Surface>()
        .where((l) => identical(l.draft, draft))
        .firstOrNull;
    if (layer == null) return const {};
    setState(() => layer.spec = draft.spec);
    if (!draft.ended) _setComposing(true);
    final id = added;
    final path = id == null ? null : draft.pathOf(id);
    if (path == null) return const {};
    final catalog = agentStandardCatalog;
    final folded = foldedPaths(
      catalog,
      layer.spec.root,
      compact: _compact,
      expanded: layer.expanded,
    );
    final number = focusNumbers(catalog, layer.spec.root, folded)[path];
    if (number == null) return const {};
    // While the agent talks about it, it enters the spotlight.
    if (identical(_stack.last, layer)) {
      final node = draft.find(id!)!;
      _choreo.added('${layer.id}#$number', _nodeWords(node));
    }
    return {'item': number};
  }

  static String _nodeWords(SurfaceNode node) => [
    for (final v in node.props.values)
      if (v is String) v else if (v is Map) ...v.values.whereType<String>(),
  ].join(' ');

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
    final stub = widget.model;
    if (stub == null && await _voice.sendText(text)) return;
    if (!mounted) return;
    _voice.say(AgentSpeaker.you, text);
    _mood.newTurn();
    _localBusy = stub != null;
    _syncMood();
    final handled =
        stub != null &&
        await stub.handle(text, _runTool, (line) {
          if (mounted) _voice.say(AgentSpeaker.agent, line);
        });
    _localBusy = false;
    if (mounted) _syncMood();
    if (handled) return;
    if (!mounted) return;
    switch (parseAgentIntent(text, widget.controller.channels)) {
      case AgentBack():
        _pop();
      case AgentHome():
        setState(() => _stack.removeRange(1, _stack.length));
      case AgentExpand(:final index):
        final r = _expandNumber(index);
        _voice.say(
          AgentSpeaker.agent,
          r['error'] != null
              ? '${r['error']}'
              : explainAttention((r['item'] as Map).cast<String, Object?>()),
        );
      case AgentNextBatch():
        final r = _nextBatch();
        _voice.say(
          AgentSpeaker.agent,
          r['error'] != null ? '${r['error']}' : '现在是${r['showing']}。',
        );
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

  /// The words of a screen item, to time its visual to the speech.
  static String _itemWords(Map<String, Object?> item) => [
    for (final k in const ['label', 'title', 'detail', 'from', 'text'])
      '${item[k] ?? ''}',
  ].join(' ');

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
    _grounded.facts.learnTaskRows(b.tasks);
    for (final m in b.messages) {
      _grounded.facts.learnMessage(
        '${m['senderName'] ?? ''}',
        '${m['content'] ?? ''}',
      );
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
    final reading = _readTools.contains(name);
    if (reading) {
      _reads++;
      _syncMood();
    }
    try {
      return await _dispatchTool(name, args);
    } finally {
      if (reading) {
        _reads--;
        if (mounted) _syncMood();
      }
    }
  }

  Future<Map<String, Object?>> _dispatchTool(
    String name,
    Map<String, Object?> args,
  ) async {
    switch (name) {
      case 'set_mood':
        return _mood.setMood(args['emoji'], args['reason']);
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
      case 'next_batch':
        return _nextBatch();
      case 'expand_item':
        return _expandNumber(
          ((args['index'] ?? args['number']) as num?)?.toInt(),
        );
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
        _choreo.spotlightItem(id, _itemWords(item));
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
        _choreo.mark(mark);
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
        _grounded.facts.learnTaskRows(tasks);
        return {
          'tasks': [for (final t in tasks.take(20)) _taskFacts(t)],
        };
    }
    final grounded = await _grounded.run(name, args);
    if (grounded != null) return grounded;
    return {'error': 'unknown tool $name'};
  }

  /// The lifted item goes back once the agent has finished speaking.
  void _voiceChanged() {
    // The TV caption follows what the agent says.
    if (mounted && _tvAttached) _syncTv(context);
    if (mounted) _syncMood();
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
          !_choreo.hasCues) {
        _choreo.speechEnded();
      }
    });
  }

  /// Reads the chosen agent's memory for the next voice session. A stored
  /// agent that is archived or gone is cleared first (独立记忆) instead of
  /// being read.
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
    final loading = _brain.liveBrain(AgentVoiceSettings.instance).then((
      live,
    ) async {
      if (live == null) return (cleared: true, context: null as String?);
      return (cleared: false, context: await _brain.context(live));
    });
    _brainLoading = loading.then((_) {}, onError: (Object _) {});
    final result = await loading;
    if (!mounted) return;
    if (result.cleared) {
      // The setting listener already moved on to 独立记忆.
      _voice.say(AgentSpeaker.agent, '记忆：之前选的 Agent 已经归档，改用独立记忆');
      return;
    }
    if (_brainContextFor != brain.id) return;
    _brainContext = result.context;
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
      'meta': '按紧急程度',
      'loading': _attention == null && _attentionError == null,
      'summary': _attention == null
          ? (_attentionError == null ? null : '读取失败：$_attentionError')
          : _attentionSummary(_visible!),
      // What the voice agent sees and numbers: the cards, in rank order.
      'items': [
        for (final (n, i)
            in (_visible?.items ?? const <AgentAttentionItem>[]).indexed)
          {
            'kind': 'priority',
            'priority': i.priority.name,
            'label': i.reason,
            'weight': n + 1,
            'title': i.headline,
            'detail': '要你做：${i.askText} · ${i.waitLabel}',
            'chips': [
              if (i.channelName != null) '#${i.channelName}',
              i.waitLabel,
            ],
            'channelId': i.channelId,
          },
      ],
      if (_visible != null)
        'tv': {
          ..._visible!.tvFrame(caption: _caption()),
          'mood': _mood.emoji,
        },
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
    _Surface() => agentSurfaceFrame(
      l.spec,
      compact: _compact,
      expanded: l.expanded,
    ),
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

  /// What the agent says, for the caption strip on the TV.
  String _caption() {
    final said = _voice.lines.where((l) => l.$1 == AgentSpeaker.agent);
    return said.isEmpty ? (_visible?.urgent ?? '') : said.last.$2;
  }

  String _peek(_Layer l) => switch (l) {
    _Attention() => '现在需要你',
    _Channel(:final channel) => '# ${channel.name}',
    _Tasks() => '进行中的任务',
    _Surface(:final spec) => spec.title,
  };

  Widget _surfaceLayer(_Surface l, {required bool compact}) {
    final view = AgentSurfaceView(
      spec: l.spec,
      animate: l.draft != null,
      focusPrefix: l.id,
      compact: compact,
      expanded: l.expanded,
      onExpand: (path) => _expandNode(l, path),
    );
    // Only a detail layer carries actions.
    return l.item == null
        ? view
        : AgentActionScope(
            onAction: (action) => _detailAction(l, action),
            child: view,
          );
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= agentWideBreakpoint;
    _compact = !wide;
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
                  constraints: BoxConstraints(maxWidth: wide ? 1240 : 760),
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
                        child: AgentRevealSyncScope(
                          sync: _reveal,
                          child: AgentSpotlight(
                            controller: _spotlight,
                            // Room above the front layer only for the layers
                            // that peek out behind it: one layer, no gap.
                            child: ZLayerStack(
                              padding: EdgeInsets.fromLTRB(
                                14,
                                6 + 34.0 * (_stack.length - 1).clamp(0, 2),
                                14,
                                8,
                              ),
                              onReveal: _revealTo,
                              layers: [
                                for (final l in _stack)
                                  ZLayer(
                                    key: ValueKey(l.id),
                                    peek: _peek(l),
                                    child: l is _Surface
                                        ? _surfaceLayer(l, compact: !wide)
                                        : l is _Attention
                                        ? AgentAttentionView(
                                            attention: _visible,
                                            error: _attentionError,
                                            wide: wide,
                                            focusPrefix: l.id,
                                            onApprove: (i) =>
                                                unawaited(_approve(i)),
                                            onOpen: _openItem,
                                            onLater: _later,
                                            onExpand: _expandItem,
                                            batchStart: _batchStart,
                                            onBatch: _showBatch,
                                          )
                                        : AgentFrameView(
                                            focusPrefix: l.id,
                                            frame: _frame(l),
                                            onOpen: (id) {
                                              final c = _channelById(id);
                                              if (c != null) {
                                                _openChannel(c).ignore();
                                              }
                                            },
                                          ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (_surfaceError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                          child: Text(
                            key: const ValueKey('agent-surface-error'),
                            '这块界面没能显示：$_surfaceError',
                            style: t.body(
                              11.5,
                              color: t.priority(AgentPriority.decision),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        child: ListenableBuilder(
                          listenable: _voice,
                          builder: (context, _) => AgentVoiceDock(
                            mood: AgentMoodBadge(
                              emoji: _mood.emoji,
                              label: _mood.label,
                            ),
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
