import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart' show RaftTokens;

import '../../data/source_activity_unread_store.dart';
import '../../data/workspace_controller.dart';
import 'agent_attention.dart';
import 'agent_audio.dart';
import 'agent_catalog.dart';
import 'agent_choreography.dart';
import 'agent_consent_tray.dart';
import 'agent_conversation.dart';
import 'agent_conversation_view.dart';
import 'agent_detail.dart';
import 'agent_entity_binding.dart';
import 'agent_frame_view.dart';
import 'agent_headlines.dart';
import 'agent_memory.dart';
import 'agent_mode_data.dart';
import 'agent_mood.dart';
import 'agent_screen_snapshot.dart';
import 'agent_scripted_model.dart';
import 'agent_surface.dart';
import 'agent_surface_stream.dart';
import 'agent_summary.dart' show AgentToolOutcome;
import 'agent_surface_tools.dart';
import 'agent_tools.dart';
import 'agent_tv.dart';
import 'agent_voice.dart';
import 'agent_voice_settings.dart';
import 'capabilities/agent_capability.dart' show AgentCapabilityRegistry;
import 'capabilities/agent_snooze.dart' show AgentSnoozeStore;
import 'capabilities/agent_action_board.dart';
import 'capabilities/agent_capability_tools.dart';
import 'capabilities/agent_consent.dart';
import 'capabilities/agent_read_tools.dart' show agentReadToolNames;
import 'gemini_live.dart' show agentToolTimeout;
import 'voice_provider.dart';
import 'references/agent_entities.dart';
import 'references/agent_handle_tag.dart';
import 'references/agent_reference_table.dart';
import 'runtime/agent_runtime.dart';
import 'runtime/agent_stop_words.dart' show isStopUtterance;
import 'runtime/agent_turn.dart' show AgentTurn;
import 'runtime/agent_tool_set.dart';

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
    this.registry,
  });
  final WorkspaceController controller;

  /// Test seam; defaults to the app's capabilities.
  final AgentCapabilityRegistry? registry;

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

/// A conversation: a channel, a private conversation or a thread, drawn as
/// the chat it is. [highlight] is the message the person opened it from.
class _Channel extends _Layer {
  _Channel(this.channel, {this.thread, this.threadTitle, this.highlight})
    : super(thread != null ? 'thread:$thread' : 'channel:${channel.id}');

  /// The channel; for a thread, the channel it is in.
  final RaftChannel channel;
  final String? thread, threadTitle, highlight;

  /// The channel the messages are read from.
  String get readId => thread ?? channel.id;
}

/// The open tasks of the workspace, or (with [channel]) of one channel.
class _Tasks extends _Layer {
  _Tasks({this.channel}) : super(channel == null ? 'tasks' : 'tasks:${channel.id}');
  final RaftChannel? channel;
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

  /// What the person did on the choices, switches and confirm cards of the
  /// screen (see `agentWithInteraction`).
  final interacted = <String, Object?>{};
}

class _AgentModePageState extends State<AgentModePage> {
  /// One summarizer for the app session, so its answers outlive a visit.
  static final _summarizer = ModelHeadlineSummarizer.gemini();

  late final data =
      widget.data ?? AgentModeData(widget.controller, summarizer: _summarizer);
  final _stack = <_Layer>[const _Attention()];
  int _surfaces = 0;

  /// How many times "下一批" scrolled a page by a screen: the TV does the same
  /// when this changes (it cannot be scrolled by hand).
  int _screens = 0;

  /// The scroll of each layer's page, by layer id: the voice moves it.
  final _pages = <String, HfPageController>{};

  HfPageController _pageOf(_Layer l) =>
      _pages.putIfAbsent(l.id, HfPageController.new);

  /// The phone layout (set by build): surfaces fold their groups to one row.
  bool _compact = true;

  /// A window wide enough for a list with its detail beside it (set by
  /// build). Narrower ones show the current item under its row.
  bool _split = false;

  /// The current item of each layer (layer id to its number), kept while
  /// another layer is in front, so going back finds it still current.
  final _currentOf = <String, int>{};

  // ignore: raft_lints/avoid_imperative_notice_state -- Cleared by the next layer change (push, pop, reveal) or when a surface is accepted.
  String? _surfaceError;

  /// The turn state machine, and the owner of everything a turn touches: what
  /// the person agreed to, the screens the model composes, the tools, the
  /// voice session. This page draws what the runtime holds.
  late final _runtime = AgentRuntime(
    workspace: widget.controller,
    data: data,
    registry: widget.registry,
    surfaces: AgentSurfaceHost(
      begin: _beginSurface,
      changed: _surfaceChanged,
      isOpen: (draft) =>
          _stack.any((l) => l is _Surface && identical(l.draft, draft)),
      ended: (_) {
        _choreo.end();
        _setComposing(false);
      },
    ),
    references: _references,
    compact: () => _compact,
    pointed: _pointed,
    screenTool: _dispatchScreenTool,
    screenSummary: () => _snapshot().text(),
    decorate: (name, result) =>
        _withSnapshot(name == 'end_surface' ? _withRefs(result) : result),
    around: _aroundTool,
    onLeave: () {
      if (mounted) Navigator.of(context).maybePop();
    },
    // 切到另一个工作区: what the layers hold belongs to the old one.
    onServerSwitched: () {
      if (!mounted) return;
      setState(() {
        _attention = AgentModeData.cached(widget.controller);
        _attentionError = null;
        _announced = false;
        _stack.removeRange(1, _stack.length);
      });
      unawaited(_loadAttention());
    },
    onRejected: (problems) {
      if (mounted) setState(() => _surfaceError = problems.first);
    },
    voice: AgentVoiceSetup(
      tools: agentModeToolDeclarations(widget.registry),
      systemPrompt: _systemPrompt,
      beforeConnect: () => _brainLoading ?? Future<void>.value(),
      onSessionEnd: _sessionEnded,
    ),
  )..addListener(_runtimeChanged);

  AgentGroundedTools get _grounded => _runtime.grounded;
  AgentCapabilityTools get _capabilities => _runtime.capabilities;

  /// The card the person tapped, for "这个".
  final _pointer = AgentPointer();

  /// The confirmed operations: their confirm cards turn into the result.
  AgentActionBoard get _actions => _runtime.actions;

  /// The person pressed 撤销 / 重试 on a result card: that press is their
  /// say-so (the undo is within its 30 s, the retry is the same operation
  /// they already agreed to).
  Future<void> _actionPressed(String id, {required bool undo}) async {
    final r = undo
        ? await _capabilities.undoAction(id)
        : await _capabilities.retryAction(id);
    if (!mounted) return;
    final ok = r['error'] == null && r['status'] != 'failed';
    await _voice.tell(
      '（屏幕提示，不是用户说的）用户点了卡片上的“${undo ? '撤销' : '重试'}”，'
      '${ok ? '已经${undo ? '撤销' : '重新执行'}了' : '没有成功：${r['error'] ?? r['message']}'}。用一句话告诉他。',
    );
  }

  /// What the person has agreed to. Fed only by them: a tap on a confirm
  /// card, their typed words and the transcript of their speech.
  AgentConsentLedger get _consent => _runtime.consent;

  /// Reads the things entity cards point at; the frame takes their titles
  /// from it, so "Cody 那个任务" finds a card too.
  late final _entities = WorkspaceEntityResolver(widget.controller)
    ..addListener(_entitiesChanged);

  void _entitiesChanged() {
    final front = _stack.last;
    if (mounted &&
        front is _Surface &&
        front.spec.root.walk().any(
          (n) => n.component == AgentEntityComponents.entity,
        )) {
      setState(() {});
    }
  }

  /// Cards that could not be drawn from real data, for the model to hear.
  final _entityProblems = <String>[];
  Timer? _problemsTold;

  void _entityProblem(String kind, String id, String reason) {
    final line = '$kind $id：$reason';
    if (_entityProblems.contains(line) || _entityProblems.length >= 6) return;
    _entityProblems.add(line);
    // Normally the next tool result carries it; a model that is done with
    // tools is told after a moment.
    _problemsTold?.cancel();
    _problemsTold = Timer(const Duration(seconds: 2), () {
      if (!mounted || _entityProblems.isEmpty) return;
      final lines = List.of(_entityProblems);
      _entityProblems.clear();
      unawaited(
        _voice.tell(
          '（屏幕提示，不是用户说的）有卡片画不出来：${lines.join('；')}。用读取工具核对 id 后改正，或如实告诉用户。',
        ),
      );
    });
  }

  Map<String, Object?> _withProblems(Map<String, Object?> result) {
    if (_entityProblems.isEmpty || result.containsKey('entityProblems')) {
      return result;
    }
    final lines = List.of(_entityProblems);
    _entityProblems.clear();
    return {
      ...result,
      'entityProblems': lines,
      'entityHint': '这些卡片没能画出来：id 只能取自读取工具的结果；核对后用 update_component 改正',
    };
  }

  /// A press on a component the model composed. A confirm card the app drew
  /// for an `act` preview is decided by the ledger itself (see
  /// [AgentConsentTray]); anything else is only news for the model.
  void _interaction(AgentInteraction i) {
    // What the person did stays on the screen, and in what the model reads
    // of it.
    final front = _stack.last;
    final slot = i.slot;
    if (front is _Surface && slot != null) {
      front.interacted[slot] = switch (i) {
        AgentConfirmed(:final yes) => yes ? 'confirmed' : 'cancelled',
        AgentChose(:final index) => index,
        AgentToggled(:final on) => on,
      };
    }
    final note = switch (i) {
      AgentConfirmed(:final title, :final yes) =>
        '（屏幕提示，不是用户说的）用户点了你放的确认卡“$title”的“${yes ? '确认' : '取消'}”。'
            '这张卡不会执行任何操作；要改动数据请用 act 预览，由用户确认预览。',
      AgentChose(:final index, :final label, :final prompt) =>
        '（屏幕提示，不是用户说的）用户在“${prompt ?? '选项'}”里选了第 ${index + 1} 个：$label。',
      AgentToggled(:final label, :final on) =>
        '（屏幕提示，不是用户说的）用户把“$label”${on ? '打开' : '关掉'}了。',
    };
    unawaited(_voice.tell(note));
  }

  /// What is on the front screen, by handle (① ② ③ …).
  AgentReferenceTable _references() =>
      AgentReferenceTable.fromFrame(_stack.last.id, _frame(_stack.last));

  /// The tapped card, while it is still on the front screen.
  AgentEntityRef? _pointed() =>
      _pointer.layerId == _stack.last.id ? _pointer.entity : null;

  /// The voice session; the runtime owns it and hears what happens in it.
  AgentVoiceController get _voice => _runtime.voice!;

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
    // Only a screen with a stage for the current item follows the stream.
    followStream: () => _split,
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
    'find',
    'query',
    ...agentReadToolNames,
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
              AgentMicState.holding ||
              AgentMicState.live => AgentMoodPhase.listening,
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

  /// The team's rows are open under the "团队在推进" row.
  bool _teamOpen = false;
  Object? _attentionError;
  final _briefs = <String, AgentChannelBrief>{};
  final _briefErrors = <String, Object>{};

  /// What each conversation layer was drawn from (by layer id), and its
  /// messages as the chat draws them.
  final _convos = <String, AgentConversationRead>{};
  final _convoMessages = <String, List<HfMessageData>>{};
  final _convoErrors = <String, Object>{};
  List<Map<String, dynamic>>? _tasks;
  Object? _tasksError;

  /// The App's Activity: the inbox window its badge and its page read. The
  /// home follows it live.
  late final SourceActivityUnreadStore _activity =
      widget.controller.activityUnreadIfBound ??
      widget.controller.activityUnread;

  @override
  void initState() {
    super.initState();
    _loadAttention();
    _activity.addListener(_activityChanged);
    final tv = AgentPresentation.instance;
    tv.onDisplaysChanged = () => unawaited(_attachTv());
    _voice.addListener(_voiceChanged);
    // The person pressed 确认 / 取消 on a preview: tell the model, which is
    // waiting for them (their words reach it as audio or text on their own).
    _consent.onTapped = (request, yes) {
      // A preview the person's own tap started (点赞, 标记已处理 ...) has no
      // model waiting for the answer: the app runs it.
      if (_tapTokens.remove(request.token)) {
        if (yes) {
          unawaited(_runtime.runTool('confirm', {'token': request.token}));
        }
        return;
      }
      unawaited(
        _voice.tell(
          yes
              ? '（屏幕提示，不是用户说的）用户点了确认卡的“确认”（confirmToken ${request.token}）。现在可以调用 confirm 执行。'
              : '（屏幕提示，不是用户说的）用户点了确认卡的“取消”（confirmToken ${request.token}）。不要执行，告诉他已经取消。',
        ),
      );
    };
    _mood.addListener(() {
      if (mounted) setState(() {});
    });
    AgentVoiceSettings.instance.addListener(_loadBrain);
    _loadBrain();
    _spotlight.addListener(_currentChanged);
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
    _activity.removeListener(_activityChanged);
    unawaited(AgentPresentation.instance.detach());
    _voice.removeListener(_voiceChanged);
    AgentVoiceSettings.instance.removeListener(_loadBrain);
    _choreo.dispose();
    _reveal.dispose();
    _composingEnds?.cancel();
    _mood.dispose();
    _runtime.removeListener(_runtimeChanged);
    _runtime.dispose();
    _spotlight.removeListener(_currentChanged);
    _spotlight.dispose();
    _marks.dispose();
    for (final p in _pages.values) {
      p.dispose();
    }
    _pointer.dispose();
    _problemsTold?.cancel();
    _entities.dispose();
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
      'caption': _caption(),
      'mood': _mood.emoji,
      'spotlight': _spotlight.focused,
      'spotlightEnter': _spotlight.entering,
      'marks': [for (final m in _marks.marks) m.toJson()],
      'confirms': _confirmsFrame(),
      'screens': _screens,
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

  /// The confirm cards the person has to answer, and the results of the ones
  /// they did, as the TV draws them (without the buttons).
  List<Map<String, Object?>> _confirmsFrame() {
    final now = DateTime.now();
    final records = _actions.records;
    return [
      for (final r in records)
        {
          'title': r.preview.summary,
          'changes': r.preview.changes,
          'outcome': {
            'kind': switch (r.phase) {
              AgentActionPhase.running => 'running',
              AgentActionPhase.done => 'done',
              AgentActionPhase.failed => 'failed',
            },
            'text': r.text ?? '执行中',
            'undoLabel': r.undoLabel,
            'undo': r.undoOpen(now),
            'retry': r.phase == AgentActionPhase.failed && r.canRetry,
          },
        },
      for (final p in _consent.active)
        if (!records.any((r) => r.id == p.request.token))
          {
            'title': p.request.total > 1
                ? '${p.request.preview.summary}（第 ${p.request.step}/${p.request.total} 次确认）'
                : p.request.preview.summary,
            'changes': p.request.preview.changes,
            'sensitive': p.request.sensitive,
            if (p.approved) 'result': 'confirmed',
          },
    ];
  }

  /// What the person has not set aside or approved in this app session.
  AgentAttention? get _visible =>
      _attention?.without(AgentModeData.hidden(widget.controller));

  /// The stale tasks are open under the "可能需要收尾" row.
  bool _staleOpen = false;

  /// The items the home lists and numbers now: the feed, and the stale tasks
  /// while their group is open.
  List<AgentAttentionItem> get _listed =>
      _visible?.listed(open: _staleOpen) ?? const [];

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

  /// The App's Activity changed (a message arrived, a conversation was read
  /// or set to done, the window was read again): the feed follows, through
  /// the same window the Activity page reads. New unread rows wear "刚到".
  void _activityChanged() {
    final before = _attention;
    if (!mounted || before == null) return;
    final rows = data.storeRows();
    if (rows == null) return;
    final next = before.withActivity(data.activityItems(rows));
    final known = {for (final i in before.items) i.id};
    final arrived = [
      for (final i in next.items)
        if (i.arrived && !known.contains(i.id)) i,
    ];
    AgentModeData.remember(widget.controller, next);
    setState(() => _attention = next);
    if (arrived.isNotEmpty) {
      _voice.say(AgentSpeaker.agent, '新动态：${arrived.first.urgent}');
    }
  }

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
    _itemGone();
    setState(() => AgentModeData.hidden(widget.controller).add(item.id));
    _voice.say(AgentSpeaker.agent, '已通过：${item.headline}');
    unawaited(_loadAttention());
    return true;
  }

  /// 稍后: set aside until this afternoon or the next morning (kept on the
  /// device, see AgentSnoozeStore), then it is asked about again.
  void _later(AgentAttentionItem item) {
    _itemGone();
    setState(
      () => _runtime.snooze.snooze(
        item,
        AgentSnoozeStore.untilFor('later', DateTime.now()),
      ),
    );
  }

  // ---- feedback on an Activity item -------------------------------------

  /// The previews the person's own taps started: their confirm card decides
  /// them, and the app (not the model) then runs `confirm`.
  final _tapTokens = <String>{};

  /// 回复 was pressed: what the person says or types next is the reply.
  AgentAttentionItem? _replying;

  /// 交给 Agent was pressed: the Agents to choose from (null while they are
  /// being read).
  AgentAttentionItem? _assigning;
  List<String>? _assignees;

  /// One feedback action, through the tool the model would use for it: the
  /// preview and its confirm card are the ones every operation has.
  Future<void> _feedback(String tool, Map<String, Object?> args) async {
    final r = await _runtime.runTool(tool, args);
    if (!mounted) return;
    final token = r['confirmToken'];
    if (token is String) _tapTokens.add(token);
    if (r['error'] != null) {
      _voice.say(AgentSpeaker.agent, '${r['message'] ?? r['error']}');
      return;
    }
    final summary = (r['preview'] as Map?)?['summary'];
    if (summary != null) _voice.say(AgentSpeaker.agent, '$summary，确认吗？');
    _showTray();
  }

  /// The confirm cards end the page: scroll there to show the one that
  /// just came.
  void _showTray() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final page = _pageOf(_stack.last);
      if (!page.hasClients) return;
      unawaited(
        page.position.animateTo(
          page.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  /// The tool and arguments that reply to [item] with [text]: a private
  /// message is answered in its conversation, a discussion in its thread, a
  /// message in a channel in the thread of that message.
  static (String, Map<String, Object?>) replyCall(
    AgentAttentionItem item,
    String text,
  ) {
    final channel = item.channelId;
    if (item.dm && channel != null) {
      return ('send_message', {'channel': channel, 'text': text});
    }
    return (
      'reply_in_thread',
      {
        'message': item.parentMessageId ?? item.messageId ?? '',
        'text': text,
        'channel': ?channel,
      },
    );
  }

  void _reply(AgentAttentionItem item) {
    if (item.messageId == null && item.parentMessageId == null && !item.dm) {
      _voice.say(AgentSpeaker.agent, '这条没有可以回复的消息。');
      return;
    }
    setState(() {
      _replying = item;
      _assigning = null;
    });
    final to = item.doer == null ? '' : ' ${item.doer}';
    _voice.say(AgentSpeaker.agent, '回复$to：说出或输入要回的话，我先给你看预览。');
    final (tool, args) = replyCall(item, '<他说的话>');
    unawaited(
      _voice.tell(
        '（屏幕提示，不是用户说的）用户点了“回复”：${item.headline}（${item.place ?? ''}）。'
        '请他说出要回复的内容，他说完后调用 $tool 出预览，参数 ${jsonEncode(args)}（text 换成他说的话）。',
      ),
    );
  }

  /// Typed words while 回复 is pending are the reply itself.
  bool _typedReply(String text) {
    final item = _replying;
    if (item == null || text.trim().isEmpty || isStopUtterance(text.trim())) {
      return false;
    }
    setState(() => _replying = null);
    _voice.say(AgentSpeaker.you, text);
    final (tool, args) = replyCall(item, text.trim());
    unawaited(_feedback(tool, args));
    return true;
  }

  /// The conversation a message of [item] is in: its thread, else its channel.
  static String? conversationOf(AgentAttentionItem item) =>
      item.threadChannelId ?? item.channelId;

  void _like(AgentAttentionItem item) {
    final id = item.messageId;
    if (id == null) {
      _voice.say(AgentSpeaker.agent, '这条没有可以点赞的消息。');
      return;
    }
    unawaited(
      _feedback('react', {
        'message': id,
        'emoji': '👍',
        'channel': ?conversationOf(item),
      }),
    );
  }

  void _done(AgentAttentionItem item) {
    final channel = item.channelId ?? item.threadChannelId;
    if (channel == null) {
      _voice.say(AgentSpeaker.agent, '这条动态没法标为已处理。');
      return;
    }
    unawaited(
      _feedback('mark_done', {
        'channel': channel,
        if (item.rowKind == 'thread' && item.threadChannelId != null)
          'thread': item.threadChannelId,
      }),
    );
  }

  /// 交给 Agent: choose which one, then a task is assigned to it (the item's
  /// own task) or created for it from the message.
  void _assign(AgentAttentionItem item) {
    setState(() {
      _assigning = item;
      _assignees = null;
      _replying = null;
    });
    _voice.say(AgentSpeaker.agent, '交给哪个 Agent？点一个，或者说名字。');
    unawaited(() async {
      List<AgentRuntimeInfo> agents;
      try {
        agents = await data.agents();
      } on Object {
        agents = const [];
      }
      if (!mounted || !identical(_assigning, item)) return;
      setState(() {
        _assignees = [
          for (final a in agents)
            if (a.state != AgentWorkState.offline) a.name,
        ].take(6).toList();
      });
    }());
  }

  /// [item] goes to the Agent [name]: the preview of `assign_task` for a
  /// task, of `create_task` (with the message as its description) for the
  /// rest.
  void _assignTo(AgentAttentionItem item, String name) {
    setState(() {
      _assigning = null;
      _assignees = null;
    });
    final task = item.taskId;
    if (task != null) {
      unawaited(_feedback('assign_task', {'task': task, 'assignee': name}));
      return;
    }
    final channel = item.channelId;
    if (channel == null) {
      _voice.say(AgentSpeaker.agent, '这条所在的频道不明确，交不出去。');
      return;
    }
    final said = item.excerpt ?? item.headline;
    unawaited(
      _feedback('create_task', {
        'channel': channel,
        'title': said.length <= 60 ? said : '${said.substring(0, 60)}…',
        'description': '来自动态（${item.place ?? ''}）：$said',
        'assignee': name,
      }),
    );
  }

  /// 看完整对话: the whole conversation the item is in (the channel, the
  /// private conversation or the thread), with the item's message
  /// highlighted.
  void _openItem(AgentAttentionItem item) {
    final c = _channelById(item.channelId);
    if (c == null) {
      _voice.say(AgentSpeaker.agent, '这条所在的频道不在你的列表里，打不开。');
      return;
    }
    final thread = item.rowKind == 'thread' ? item.threadChannelId : null;
    _openChannel(
      c,
      thread: thread,
      threadTitle: thread == null ? null : item.threadTitle,
      highlight: item.focusMessageId ?? item.messageId,
      parentMessageId: item.parentMessageId,
      announce: false,
    ).ignore();
  }

  // ---- the current item ---------------------------------------------------

  void _currentChanged() {
    final id = _spotlight.focused;
    if (id != null) {
      final at = id.lastIndexOf('#');
      final n = at < 0 ? null : int.tryParse(id.substring(at + 1));
      final layer = at < 0 ? null : id.substring(0, at);
      if (n != null && _stack.any((l) => l.id == layer)) {
        _currentOf[layer!] = n;
        // The current item is the one "这个" means.
        if (layer == _stack.last.id) {
          final ref = _references().byIndex(n);
          if (ref != null) _pointer.point(layer, ref);
        }
      }
    }
    if (mounted) setState(() {});
  }

  /// The current item of the front layer (from 1), or null.
  int? get _current {
    final id = _spotlight.focused;
    final prefix = '${_stack.last.id}#';
    return id != null && id.startsWith(prefix)
        ? int.tryParse(id.substring(prefix.length))
        : null;
  }

  /// The current item as the screen is about to show it: a layer that was just
  /// put back finds its item again after the next frame, and a wide window
  /// marks its first row; the words about the screen say so at once.
  int? get _currentNow {
    final c = _current ?? _currentOf[_stack.last.id];
    if (c != null) return c;
    return _split &&
            _stack.last is _Attention &&
            _listed.isNotEmpty
        ? 1
        : null;
  }

  /// A tap, a key and the voice all make an item current the same way.
  void _setCurrent(int n) => _spotlight.focus('${_stack.last.id}#$n');

  /// Nothing is current on the front layer (a phone's stage closes).
  void _clearCurrent() {
    _currentOf.remove(_stack.last.id);
    _spotlight.release();
  }

  /// The current attention item left the list (通过, 稍后). A phone's stage
  /// closes; a wide window keeps the same place, which the next item now
  /// takes.
  void _itemGone() {
    if (_split) return;
    _currentOf.remove(_stack.first.id);
    if (_stack.last is _Attention) _spotlight.release();
  }

  /// A tap on a row. On a phone, the tap on the current row again puts its
  /// stage away.
  void _tapCurrent(int n) {
    if (_current == n && !_split) {
      _clearCurrent();
    } else {
      _setCurrent(n);
    }
  }

  /// After the layer in front changed (the spotlight was let go with the old
  /// one): the new front layer's own current item, if it had one.
  void _restoreCurrent() {
    _currentOf.removeWhere((id, _) => !_stack.any((l) => l.id == id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final n = _currentOf[_stack.last.id];
      if (n != null && _current != n) _setCurrent(n);
    });
  }

  /// Whether the front layer shows its current item on a stage: the full
  /// detail of an item is a stage of its own.
  bool get _stageAllowed {
    final top = _stack.last;
    // A conversation is read, not picked from: it has no detail pane.
    return !(top is _Surface && top.item != null) && top is! _Channel;
  }

  /// A phone's stage is open: the current item has its detail under it.
  bool get _stageOpen => !_split && _stageAllowed && _current != null;

  /// The detail of one attention item as a new layer (the full page). The
  /// voice tool `expand_item` on a narrow screen and the stage's 展开 both
  /// come here, so they show the same thing. An open detail is replaced, not
  /// stacked. The item stays current, so going back finds it.
  void _expandItem(AgentAttentionItem item) {
    final top = _stack.last;
    if (top is _Surface && top.item != null) _stack.removeLast();
    _currentOf[_stack.first.id] = _rankOf(item);
    _push(_Surface.detail(attentionDetailSpec(item, _rankOf(item)), item));
    // The card that was tapped (or spoken about) is the one "这个" means on
    // the detail it opened.
    final ref = _references().entries.firstOrNull;
    if (ref != null) _pointer.point(_stack.last.id, ref);
  }

  int _rankOf(AgentAttentionItem item) {
    final at = _listed.indexWhere(
      (i) => i.id == item.id,
    );
    return at < 0 ? 1 : at + 1;
  }

  /// `expand_item` and "讲讲第一条": [number] counts the home cards from 1;
  /// null means the current one, else the most urgent. The item becomes the
  /// current one. A window with a detail beside its list shows it there and
  /// pushes no layer; a narrower one goes to the full detail page.
  Map<String, Object?> _expandNumber(int? number) {
    final items = _listed;
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
    final inPlace = _split && _stack.last is _Attention;
    if (inPlace) {
      _setCurrent(n);
    } else {
      _currentOf[_stack.first.id] = n;
      _expandItem(item);
    }
    return {
      'ok': true,
      'layer': _stack.length,
      'shown': inPlace ? '在右边的详情栏里' : '整页详情',
      'item': facts,
    };
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
    _restoreCurrent();
  }

  /// `next_batch`: the front layer's page scrolls on by a screen to the next
  /// items, or back to the top after the last. (A TV scrolls the same way:
  /// see [_screens].)
  Map<String, Object?> _nextBatch() {
    final cards = _listed.length;
    final step = _pageOf(_stack.last).nextScreen();
    if (step == HfPageStep.none) {
      return {'error': '这一层已经全部显示在一屏里了，没有更多要翻的'};
    }
    setState(() => _screens++);
    return {
      'ok': true,
      'showing': step == HfPageStep.wrapped ? '已经是最后了，回到最前面' : '往后翻了一屏',
      'layer': _stack.length,
      if (_stack.last is _Attention) 'total': cards,
    };
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
    _restoreCurrent();
  }

  /// Back: a stage that is open goes first, then the layer.
  void _pop() {
    if (_stageOpen) {
      _clearCurrent();
      return;
    }
    _choreo.newScreen();
    if (_stack.length > 1) {
      setState(() {
        _surfaceError = null;
        _stack.removeLast();
      });
    }
    _restoreCurrent();
  }

  void _revealTo(int index) {
    _choreo.newScreen();
    setState(() {
      _surfaceError = null;
      _stack.removeRange(index + 1, _stack.length);
    });
    _restoreCurrent();
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
    String? thread,
    String? threadTitle,
    String? highlight,
    String? parentMessageId,
  }) async {
    final layer = _Channel(
      c,
      thread: thread,
      threadTitle: threadTitle,
      highlight: highlight,
    );
    _push(layer);
    try {
      final read = await data.conversation(
        layer.readId,
        withTasks: thread == null,
        parentChannelId: thread == null ? null : c.id,
        parentMessageId: parentMessageId,
      );
      if (!mounted) return null;
      final brief = data.briefOf(c, read);
      setState(() {
        _convos[layer.id] = read;
        _convoMessages[layer.id] = hfMessagesFrom(
          read.rows,
          myUserId: widget.controller.client.user?.id,
          now: data.now(),
        );
        _convoErrors.remove(layer.id);
        if (thread == null) {
          _briefs[c.id] = brief;
          _briefErrors.remove(c.id);
        }
      });
      // What the screen shows may be quoted by the model.
      for (final m in read.rows) {
        _grounded.facts.learnMessage(
          '${m['senderName'] ?? m['senderDisplayName'] ?? ''}',
          '${m['content'] ?? ''}',
          id: m['id'] is String ? m['id'] as String : null,
        );
      }
      _grounded.facts.learnTaskRows(read.tasks);
      if (announce) _voice.say(AgentSpeaker.agent, _channelSummary(brief));
      return brief;
    } catch (e) {
      if (mounted) setState(() => _convoErrors[layer.id] = e);
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

  Future<List<Map<String, dynamic>>?> _showTasks({
    bool announce = true,
    RaftChannel? channel,
  }) async {
    _push(_Tasks(channel: channel));
    if (channel != null) {
      // The channel's tasks were read with its conversation.
      final tasks = _convos['channel:${channel.id}']?.tasks ?? const [];
      if (announce) {
        _voice.say(AgentSpeaker.agent, '#${channel.name} 有 ${tasks.length} 个任务。');
      }
      return tasks;
    }
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

  /// The runtime heard a change (a new request, a screen stopped, a card
  /// cancelled): redraw what it holds.
  void _runtimeChanged() {
    if (mounted) setState(() {});
  }

  /// What the model is told in front of typed words: the turn, what the
  /// last one was, what waits, and what "第二个" means on this screen.
  String _typedContext(AgentTurn turn) => [
    ?_runtime.takeContext(turn),
    _references().contextText(pointed: _pointed()),
  ].where((line) => line.isNotEmpty).join('\n');

  Future<void> _submit(String text) async {
    // 回复 was pressed: the next words are the reply.
    if (_typedReply(text)) return;
    // Typed words are the person's: they may answer a pending preview, or
    // only stop everything ("算了"), which needs no model.
    final turn = _runtime.submitText(text);
    if (turn == null) {
      _voice.say(AgentSpeaker.you, text);
      return;
    }
    final stub = widget.model;
    if (stub == null &&
        await _voice.sendText(text, context: _typedContext(turn))) {
      return;
    }
    if (!mounted) return;
    _voice.say(AgentSpeaker.you, text);
    _mood.newTurn();
    _localBusy = stub != null;
    _syncMood();
    final handled =
        stub != null &&
        await stub.handle(text, _runtime.runTool, (line) {
          if (mounted) _voice.say(AgentSpeaker.agent, line);
        });
    _localBusy = false;
    if (mounted) _syncMood();
    // Nobody else answers a typed request that is handled here.
    _runtime.finishTurn();
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
          r['error'] != null ? '${r['error']}' : '${r['showing']}。',
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
            ..._handleOf(i['entity'], n),
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

  /// The handle and identity of a screen item, as the model reads them.
  static Map<String, Object?> _handleOf(Object? entity, int n) {
    final ref = AgentEntityRef.fromJson(entity);
    if (ref == null) return const {};
    return {
      'handle': agentHandle(n),
      'entity': {'type': ref.type, 'id': ?ref.id},
    };
  }

  /// The words of a screen item, to time its visual to the speech.
  static String _itemWords(Map<String, Object?> item) => [
    for (final k in const ['label', 'title', 'detail', 'from', 'text'])
      '${item[k] ?? ''}',
  ].join(' ');

  /// A read that drew its answer on the screen says so (`screen`, a few
  /// words); the whole screen as it is now rides on that answer too.
  Map<String, Object?> _withSnapshot(Map<String, Object?> result) =>
      result['screen'] is String && !result.containsKey('snapshot')
      ? {...result, 'snapshot': _snapshot().text()}
      : result;

  /// [result] of a tool that changed the screen, with the handles of what is
  /// on it now: a spoken "这个" or "③" has no 【屏幕引用】 line in front of
  /// it, so the tool results carry it.
  Map<String, Object?> _withRefs(Map<String, Object?> result) {
    if (result.containsKey('refs')) return result;
    final refs = _references();
    return refs.isEmpty
        ? result
        : {...result, 'refs': refs.contextText(pointed: _pointed())};
  }

  /// What the screen shows now; every screen tool returns this. `screen` is
  /// the whole layer in words (see [_snapshot]); `items` are the numbers and
  /// what they point at.
  Map<String, Object?> _screen() {
    final snap = _snapshot();
    final refs = AgentReferenceTable.fromFrame(
      _stack.last.id,
      _frame(_stack.last),
    );
    return {
      'layer': _stack.length,
      'title': _peek(_stack.last),
      if (snap.loading) 'loading': true,
      if (snap.current != null) 'current': snap.current,
      'snapshot': snap.text(),
      'items': snap.itemsJson(),
      if (!refs.isEmpty) 'refs': refs.contextText(pointed: _pointed()),
    };
  }

  /// What the words of a component need that the widget gets from its place:
  /// where the entities it points at are read, the window.
  HfDescribeEnv get _describeEnv =>
      HfDescribeEnv(resolver: _entities, phone: _compact);

  /// The front layer in words: every component describes itself, from the
  /// values it draws (see [HfDescribed]); this only adds what is not drawn
  /// (ids, which items are in view, the buttons an item has) and puts it
  /// together.
  AgentScreenSnapshot _snapshot() {
    final layer = _stack.last;
    final env = _describeEnv;
    final current = _stageAllowed ? _currentNow : _current;
    final views = agentItemViews(layer.id);
    final tray = [
      for (final e in AgentConsentTray.entriesOf(
        ledger: _consent,
        board: _actions,
        now: DateTime.now(),
      ))
        e.card.describe(env),
    ];
    final notes = [
      if (widget.controller.servers.length > 1)
        '工作区：${widget.controller.server?.name ?? ''}',
      if (_replying != null)
        '屏幕下方提示：正在回复${_replying!.doer == null ? '' : ' ${_replying!.doer}'}，等他说出或输入要回的话',
      if (_assigning != null)
        '屏幕下方提示：交给哪个 Agent？${_assignees == null ? '正在读取' : _assignees!.isEmpty ? '没有在线的 Agent' : _assignees!.join('、')}',
    ];
    AgentScreenSnapshot make(
      String kind,
      HfDescription head,
      List<AgentScreenPart> parts, {
      bool loading = false,
      AgentScreenPart? detail,
      List<String> more = const [],
    }) => AgentScreenSnapshot(
      layer: _stack.length,
      kind: kind,
      title: _peek(layer),
      head: head,
      parts: parts,
      loading: loading,
      current: current,
      detail: detail,
      tray: tray,
      views: views,
      notes: [...notes, ...more],
    );
    switch (layer) {
      case _Attention():
        final a = _visible;
        final table = _references();
        final parts = <AgentScreenPart>[];
        if (a != null && !a.isEmpty) {
          for (final part in AgentAttentionView.partsOf(
            a,
            split: _split,
            interactive: true,
            teamOpen: _teamOpen,
            staleOpen: _staleOpen,
            selected: current,
          )) {
            switch (part) {
              case AgentAttentionSection(:final label):
                parts.add(AgentScreenPart(label.describe(env), heading: true));
              case AgentAttentionCard(:final n, :final item, :final row):
                parts.add(
                  AgentScreenPart(
                    row.describe(env),
                    n: n,
                    facts: _attentionFacts(item),
                    actions: _attentionDetail(item, n).describe(env).actions,
                    view: views?[n],
                    entity: table.byIndex(n),
                  ),
                );
              case AgentAttentionStaleRow(:final row):
                parts.add(
                  AgentScreenPart(
                    row.describe(env),
                    actions: [_staleOpen ? '收起' : '展开'],
                  ),
                );
              case AgentAttentionTeamRow(:final row):
                parts.add(
                  AgentScreenPart(
                    row.describe(env),
                    actions: [_teamOpen ? '收起' : '展开'],
                  ),
                );
              case AgentAttentionTeamItem(:final row):
                parts.add(AgentScreenPart(row.describe(env)));
            }
          }
        }
        return make(
          '首页',
          AgentAttentionView.describeLayer(a, _attentionError, env: env),
          parts,
          loading: a == null && _attentionError == null,
          detail: _detailPart(current, env),
        );
      case _Surface():
        final frame = _frame(layer);
        final table = AgentReferenceTable.fromFrame(layer.id, frame);
        final entries = AgentFrameView.entriesOf(frame);
        return make(
          layer.item == null ? '屏幕' : '详情页',
          AgentSurfaceView.frameOf(layer.spec).describe(env),
          [
            for (final p in describeSurface(
              layer.spec,
              compact: _compact,
              expanded: layer.expanded,
              interacted: layer.interacted,
              env: env,
            ))
              AgentScreenPart(
                p.description,
                n: p.number,
                heading: p.heading,
                entity: p.number == null ? null : table.byIndex(p.number!),
                facts: p.number == null
                    ? const []
                    : _channelOfItem(entries, p.number!),
                actions: p.number == null
                    ? const []
                    : _stageActions(entries, p.number!),
                view: p.number == null ? null : views?[p.number],
              ),
          ],
          detail: _detailPart(current, env),
        );
      case _Channel():
        final convo = _conversationOf(layer);
        final frame = _frame(layer);
        final table = AgentReferenceTable.fromFrame(layer.id, frame);
        final parts = HfConversation.partsOf(
          convo.messages,
          highlightId: convo.highlightId,
          hasMoreAbove: convo.hasMoreAbove,
          now: data.now(),
        );
        return make(
          '频道',
          AgentConversationView.frameOf(convo).describe(env),
          [
            for (final p in parts)
              AgentScreenPart(
                p.describe(env),
                n: p is HfMessagePart ? p.n : null,
                heading: p is HfSeparatorPart,
                entity: p is HfMessagePart ? table.byIndex(p.n) : null,
                facts: [
                  if (p is HfMessagePart)
                    '消息 id ${p.message.id}（频道 #${layer.channel.name}，id ${layer.readId}）',
                ],
                view: p is HfMessagePart ? views?[p.n] : null,
              ),
          ],
          loading: convo.loading && convo.messages.isEmpty,
          more: [
            '这一层是${layer.thread == null ? '' : '讨论串，在'}频道 #${layer.channel.name}（id ${layer.channel.id}）'
                '${layer.thread == null ? '' : '，讨论串 id ${layer.thread}'}',
            if (convo.taskCount > 0)
              '标题旁的“任务 ${convo.taskCount}”点开是这个频道的任务（show_tasks 也可以）',
          ],
        );
      case _Tasks():
        final frame = _frame(layer);
        final table = AgentReferenceTable.fromFrame(layer.id, frame);
        final entries = AgentFrameView.entriesOf(frame);
        return make(
          '任务',
          AgentFrameView.frameOf(frame).describe(env),
          [
            for (final e in entries)
              AgentScreenPart(
                AgentFrameView.rowOf(e).describe(env),
                n: e.n,
                entity: table.byIndex(e.n),
                facts: _channelOfItem(entries, e.n),
                actions: _stageActions(entries, e.n),
                view: views?[e.n],
              ),
          ],
          loading: frame['loading'] == true && entries.isEmpty,
          detail: _detailPart(current, env),
        );
    }
  }

  /// The detail of item [n] of the front layer, as its stage draws it (the
  /// pane beside the list, or under the row on a phone); null when the item
  /// has none or the layer shows no stage.
  AgentScreenPart? _detailPart(int? n, HfDescribeEnv env) {
    final layer = _stack.last;
    if (n == null || n < 1 || !_stageAllowed) return null;
    if (layer is _Attention) {
      final items = _listed;
      if (n > items.length) return null;
      return AgentScreenPart(
        _attentionDetail(items[n - 1], n).describe(env),
        n: n,
      );
    }
    final entries = AgentFrameView.entriesOf(_frame(layer));
    if (n > entries.length) return null;
    return AgentScreenPart(_frameStage(entries[n - 1], n).describe(env), n: n);
  }

  /// The detail of the attention card [n], as its stage draws it.
  HfDetail _attentionDetail(AgentAttentionItem item, int n) =>
      AgentAttentionDetail(
        item: item,
        number: n,
        onApprove: (_) {},
        onOpen: (_) {},
        onLater: (_) {},
        onReply: (_) {},
        onLike: (_) {},
        onDone: (_) {},
        onAssign: (_) {},
      ).view();

  /// The stage of item [e] of a frame, as the screen draws it.
  HfDetail _frameStage(AgentFrameEntry e, int n) => AgentFrameStage(
    item: e.item,
    number: n,
    onOpen: _channelById(e.item['channelId'] as String?) == null ? null : () {},
  ).view();

  List<String> _stageActions(List<AgentFrameEntry> entries, int n) => [
    for (final a in _frameStage(entries[n - 1], n).actions) a.label,
  ];

  /// The channel an item of a frame belongs to, by name and id.
  List<String> _channelOfItem(List<AgentFrameEntry> entries, int n) {
    final c = _channelById(entries[n - 1].item['channelId'] as String?);
    return [if (c != null) '频道 #${c.name}（id ${c.id}）'];
  }

  /// What the card says without printing: the ids behind the names, who is
  /// involved, the thread.
  static List<String> _attentionFacts(AgentAttentionItem i) => [
    if (i.channelName != null)
      '频道 #${i.channelName}${i.channelId == null ? '' : '（id ${i.channelId}）'}',
    if (i.taskNumber != null)
      '任务 #${i.taskNumber}${i.taskId == null ? '' : '（id ${i.taskId}）'}'
    else
      '来源 id ${i.id}',
    if (i.messageId != null) '消息 id ${i.messageId}',
    if (i.threadChannelId != null)
      '讨论串 id ${i.threadChannelId}（父消息 ${i.parentMessageId}）',
    if (i.isActivity) '动态来源：${i.place ?? ''}，${i.unread > 0 ? '${i.unread} 条未读' : '已读'}',
    if (i.doer != null) '负责人/发言人 ${i.doer}',
    if (i.waiters.isNotEmpty) '在等的人 ${i.waiters.join('、')}',
    if (i.threadTitle != null) '讨论「${i.threadTitle}」',
  ];

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
        id: m['id'] is String ? m['id'] as String : null,
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

  /// Around every tool call: a read keeps the mood badge on "reading" until it
  /// is answered, and what the screen noticed (cards that could not be drawn)
  /// rides on the answer.
  Future<Map<String, Object?>> _aroundTool(
    String name,
    Map<String, Object?> args,
    Future<Map<String, Object?>> Function() run,
  ) async {
    if (!mounted) return {'error': 'closed'};
    final reading = _readTools.contains(name);
    // The model is answered with an error after agentToolTimeout; the read
    // must stop counting then too, or the mood badge stays on "reading".
    var settled = !reading;
    void settle() {
      if (settled) return;
      settled = true;
      _reads--;
      if (mounted) _syncMood();
    }

    Timer? guard;
    if (reading) {
      _reads++;
      _syncMood();
      guard = Timer(agentToolTimeout, settle);
    }
    try {
      return _withProblems(await run());
    } finally {
      guard?.cancel();
      settle();
    }
  }

  /// The tools only this screen can run: change the layer, open, expand,
  /// spotlight, mark. Everything else (reads, screens the model composes,
  /// operations) is the runtime's.
  Future<Map<String, Object?>> _dispatchScreenTool(
    String name,
    Map<String, Object?> args,
  ) async {
    switch (name) {
      case 'set_mood':
        return _mood.setMood(args['emoji'], args['reason']);
      case 'show_attention' || 'go_home':
        _choreo.newScreen();
        setState(() => _stack.removeRange(1, _stack.length));
        _restoreCurrent();
        return _screen();
      case 'open_channel':
        final c = _channelNamed('${args['name'] ?? ''}');
        if (c == null) return {'error': '没有叫 ${args['name']} 的频道'};
        final top = _stack.last;
        if (top is! _Channel || top.thread != null || top.channel.id != c.id) {
          _openChannel(c, announce: false).ignore();
        }
        return _screen();
      case 'read_screen':
        return _screen();
      case 'next_batch':
        final moved = _nextBatch();
        // The page scrolls for a moment; what is in view is told after it.
        if (moved['ok'] == true) {
          await Future<void>.delayed(const Duration(milliseconds: 450));
          if (mounted) moved['snapshot'] = _snapshot().text();
        }
        return _withRefs(moved);
      case 'expand_item':
        final expanded = _expandNumber(
          ((args['index'] ?? args['number']) as num?)?.toInt(),
        );
        return _withRefs({
          ...expanded,
          if (expanded['error'] == null) 'snapshot': _snapshot().text(),
        });
      case 'open_item':
        final n = (args['number'] as num?)?.toInt() ?? 0;
        // On the home, the item's whole conversation.
        if (_stack.last is _Attention) {
          final listed = _listed;
          if (n < 1 || n > listed.length) {
            return {'error': '屏幕上没有第 $n 条', ..._screen()};
          }
          _currentOf[_stack.first.id] = n;
          _openItem(listed[n - 1]);
          return _screen();
        }
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
        // What it says in full, and the detail that opens for it.
        final snap = _snapshot();
        final part = snap.items.where((p) => p.n == n).firstOrNull;
        final detail = _detailPart(n, _describeEnv);
        return {
          'ok': true,
          'item': {
            'n': n,
            ..._handleOf(item['entity'], n),
            if (part != null) 'text': part.text(),
            if (detail != null)
              'detail': [
                ...detail.description.lines,
                if (detail.description.actions.isNotEmpty)
                  '可做：${detail.description.actions.join(' / ')}',
              ],
          },
        };
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
        _clearCurrent();
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
    if (!finished) return;
    final said = _voice.saying.value.length;
    // A pause between sentences also goes idle; only settle the screen once
    // the reply has really stopped (no new words, nothing waiting to show).
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted &&
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
  void _sessionEnded(
    List<(AgentSpeaker, String)> transcript,
    List<AgentToolOutcome> outcomes,
  ) {
    final settings = AgentVoiceSettings.instance;
    final brain = settings.brain;
    if (widget.data != null || brain == null || !settings.writeBack) return;
    unawaited(
      _brain
          .sendSummary(brain, transcript, outcomes)
          .catchError((Object _) => false),
    );
  }

  Future<void> _scanKey() async {
    try {
      final saved = await saveScannedKey(
        await AgentAudio.instance.scanCode(),
        preferred: AgentVoiceSettings.instance.provider,
      );
      if (saved == null) return;
      _voice.say(AgentSpeaker.agent, 'Key 已保存。按住下面的按钮说话吧。');
    } on PlatformException catch (e) {
      // ignore: raft_lints/avoid_caught_exception_text -- Demo screen: the scanner plugin's own message is the most useful thing to read aloud.
      _voice.say(AgentSpeaker.agent, '扫码失败：${e.message ?? e.code}');
    }
  }

  RaftChannel? _channelById(String? id) => id == null
      ? null
      : [
          ...widget.controller.channels,
          ...widget.controller.dms,
        ].where((c) => c.id == id).firstOrNull;

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
      'entity': taskRowEntity(t),
    };
  }

  /// One layer as data: drawn on the phone and sent unchanged to the TV.
  Map<String, Object?> _frame(_Layer l) => switch (l) {
    _Attention() => {
      'title': AgentAttentionView.layerTitle,
      'meta': AgentAttentionView.layerMeta,
      'loading': _attention == null && _attentionError == null,
      'summary': _attention == null
          ? (_attentionError == null ? null : '读取失败：$_attentionError')
          : _attentionSummary(_visible!),
      // What the voice agent sees and numbers: the cards, in rank order.
      'items': [
        for (final (n, i)
            in _listed.indexed)
          {
            'kind': 'priority',
            'priority': i.priority.name,
            'label': i.reason,
            'weight': n + 1,
            'title': i.headline,
            'detail': i.isActivity
                ? [
                    ?i.place,
                    i.waitLabel,
                    i.unread > 0 ? '${i.unread} 条未读' : '已读',
                  ].join(' · ')
                : '要你做：${i.askText} · ${i.waitLabel}',
            'chips': [
              if (i.isActivity)
                ?i.place
              else if (i.channelName != null)
                '#${i.channelName}',
              i.waitLabel,
            ],
            'channelId': i.channelId,
            'entity': attentionEntity(i),
          },
      ],
      // The TV draws the same screen from the result itself.
      if (_visible != null)
        'attention': {..._visible!.toJson(), 'staleOpen': _staleOpen},
    },
    _Channel() => () {
      final convo = _conversationOf(l);
      // What the voice agent sees and numbers: the messages, as the chat
      // numbers its bubbles.
      return <String, Object?>{
        ...convo.toFrame(),
        'items': [
          for (final p in HfConversation.partsOf(
            convo.messages,
            highlightId: convo.highlightId,
            hasMoreAbove: convo.hasMoreAbove,
            now: data.now(),
          ))
            if (p is HfMessagePart)
              {
                'kind': 'message',
                'sender': p.message.senderName,
                'time': HfConversation.clock(p.message.time),
                'text': p.message.text,
                'channelId': l.channel.id,
                'entity': agentEntity(
                  AgentEntityTypes.message,
                  p.message.id,
                  p.message.text,
                  [p.message.senderName],
                ),
              },
        ],
      };
    }(),
    _Surface() => agentSurfaceFrame(
      l.spec,
      compact: _compact,
      expanded: l.expanded,
      entityLabel: (kind, id) => agentEntityLabel(_entities, kind, id),
      entityData: (kind, id) => agentEntityData(_entities, kind, id),
      entityOf: (n) => l.item != null && n.component == AgentComponents.taskCard
          ? attentionEntity(l.item!)
          : surfaceEntity(
              n,
              _grounded.facts,
              labelOf: (kind, id) => agentEntityLabel(_entities, kind, id),
            ),
    ),
    _Tasks(:final channel) => () {
      final rows = channel == null
          ? _tasks
          : _convos['channel:${channel.id}']?.tasks;
      return <String, Object?>{
        'title': channel == null ? '进行中的任务' : '# ${channel.name} 的任务',
        'loading': rows == null && _tasksError == null,
        'summary': _tasksError == null ? null : '读取失败：$_tasksError',
        'items': [
          for (final t in rows ?? const <Map<String, dynamic>>[])
            _taskItem(t, where: channel == null),
        ],
      };
    }(),
  };

  /// The title of a conversation: the channel, the private conversation
  /// ("@Alice") or the thread.
  String _conversationTitle(_Channel l) {
    if (l.thread != null) {
      final t = l.threadTitle;
      return '讨论 · ${t == null || t.isEmpty ? l.channel.name : t}';
    }
    return l.channel.type == 'dm'
        ? '@${l.channel.peerLabel}'
        : '# ${l.channel.name}';
  }

  /// What the conversation layer [l] draws.
  AgentConversationData _conversationOf(_Channel l) {
    final read = _convos[l.id];
    final error = _convoErrors[l.id];
    final messages = _convoMessages[l.id] ?? const <HfMessageData>[];
    return AgentConversationData(
      title: _conversationTitle(l),
      meta: l.thread == null
          ? null
          : '在 ${l.channel.type == 'dm' ? '@${l.channel.peerLabel}' : '#${l.channel.name}'}',
      messages: messages,
      highlightId: messages.any((m) => m.id == l.highlight)
          ? l.highlight
          : null,
      hasMoreAbove: read?.hasMore ?? false,
      taskCount: l.thread == null ? (read?.tasks.length ?? 0) : 0,
      loading: read == null && error == null,
      error: error == null ? null : '读取失败：$error',
    );
  }

  /// What the agent says, for the caption strip on the TV.
  String _caption() {
    final said = _voice.lines.where((l) => l.$1 == AgentSpeaker.agent);
    return said.isEmpty ? (_visible?.urgent ?? '') : said.last.$2;
  }

  String _peek(_Layer l) => switch (l) {
    _Attention() => AgentAttentionView.layerTitle,
    _Channel() => _conversationTitle(l),
    _Tasks(:final channel) =>
      channel == null ? '进行中的任务' : '# ${channel.name} 的任务',
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
      interacted: l.interacted,
    );
    // Only a detail layer carries actions.
    final body = l.item == null
        ? view
        : AgentActionScope(
            onAction: (action) => _detailAction(l, action),
            child: view,
          );
    final draft = l.draft;
    if (draft == null || !_runtime.surfaceStopped(draft.id)) return body;
    // A new request stopped this screen while it was being composed: what is
    // here stays, and it says it will not grow.
    final hf = HandsFree.of(context);
    return Stack(
      children: [
        body,
        Positioned(
          right: hf.sp(12),
          top: hf.sp(4),
          child: Container(
            key: const ValueKey('agent-surface-stopped'),
            padding: EdgeInsets.symmetric(
              horizontal: hf.sp(10),
              vertical: hf.sp(3),
            ),
            decoration: BoxDecoration(
              color: HfColors.cream,
              borderRadius: BorderRadius.circular(hf.sp(10)),
              border: Border.all(color: HfColors.ink, width: hf.sp(2.5)),
            ),
            child: Text(
              '已停止',
              style: hf.type(HfType.meta, color: HfColors.inkSoft),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AgentReferenceScope(
    table: _references(),
    pointer: _pointer,
    child: AgentEntityBindingScope(
      controller: widget.controller,
      resolver: _entities,
      onProblem: (ref, reason) => _entityProblem(ref.kind.name, ref.id, reason),
      child: AgentInteractionScope(
        onInteraction: _interaction,
        child: _page(context),
      ),
    ),
  );

  Widget _page(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTv(context);
    });
    return PopScope(
      canPop: _stack.length == 1 && !_stageOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _pop();
      },
      child: Scaffold(
        backgroundColor: t.canvas,
        body: AgentMarks(
          controller: _marks,
          child: SafeArea(
            child: HandsFree(
              child: Builder(
                builder: (context) {
                  final hf = HandsFree.of(context);
                  _compact = hf.phone;
                  _split = hf.split;
                  return _frameScreen(context, hf);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The close button, the settings and which layer this is: small. On a
  /// phone a bar of its own; on a desktop window the right end of the header
  /// of the front layer ([HfChrome]), so the page keeps its room.
  Widget _chrome(HfData hf, {required bool bar}) {
    final ink = HfColors.inkSoft;
    return SizedBox(
      height: hf.sp(bar ? 40 : 36),
      child: Row(
        mainAxisSize: bar ? MainAxisSize.max : MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('agent-mode-close'),
            tooltip: '关闭',
            icon: Icon(Icons.close, color: ink, size: hf.sp(24)),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Text('Agent 模式', style: hf.type(HfType.body)),
          if (bar) const Spacer() else SizedBox(width: hf.sp(12)),
          IconButton(
            key: const ValueKey('agent-voice-settings'),
            tooltip: '声音设置',
            icon: Icon(Icons.tune, size: hf.sp(22), color: ink),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AgentVoiceSettingsPage(
                  agents: widget.data == null ? _brain.agents : null,
                  onPreview: (v) => unawaited(_voice.preview(v)),
                ),
              ),
            ),
          ),
          if (AgentAudio.instance.supported)
            IconButton(
              key: const ValueKey('agent-voice-key-scan'),
              tooltip: '扫码填入语音 Key',
              icon: Icon(Icons.qr_code_scanner, size: hf.sp(22), color: ink),
              onPressed: _scanKey,
            ),
          if (_tvAttached)
            Padding(
              padding: EdgeInsets.only(right: hf.sp(10)),
              child: Icon(Icons.tv, size: hf.sp(18), color: HfColors.inkMuted),
            ),
          Text(
            '第 ${_stack.length} 层',
            style: hf.type(HfType.meta, color: HfColors.inkMuted),
          ),
        ],
      ),
    );
  }

  Widget _layerView(_Layer l, HfData hf) {
    Widget view = _layerContent(l, hf);
    if (!identical(l, _stack.last)) {
      return HfPageControllerScope(controller: _pageOf(l), child: view);
    }
    // The current item's detail is part of the layer's page: beside its row
    // on a wide window, under it on a phone. The confirm cards that wait for
    // an answer end the page.
    final n = _current;
    final stage = _stage(l, n, hf, tools: hf.split ? null : _stageTools(l, n));
    // The scope is always there, so the page keeps its place (and its scroll)
    // when a stage comes and goes.
    view = HfPageTail(
      tail: _tray(),
      child: HfStageScope(
        id: stage == null || n == null ? '' : '${l.id}#$n',
        stage: stage,
        child: view,
      ),
    );
    return HfPageControllerScope(controller: _pageOf(l), child: view);
  }

  Widget _layerContent(_Layer l, HfData hf) {
    if (l is _Surface) return _surfaceLayer(l, compact: hf.phone);
    if (l is _Attention) {
      // A wide window always has a current item: the first row until another
      // is chosen.
      if (_split &&
          identical(l, _stack.last) &&
          _current == null &&
          _listed.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _split &&
              _current == null &&
              _stack.last is _Attention) {
            _setCurrent(1);
          }
        });
      }
      return AgentAttentionView(
        attention: _visible,
        error: _attentionError,
        focusPrefix: l.id,
        onApprove: (i) => unawaited(_approve(i)),
        onOpen: _openItem,
        onLater: _later,
        current: identical(l, _stack.last) ? _current : _currentOf[l.id],
        onCurrent: _tapCurrent,
        teamOpen: _teamOpen,
        onTeam: () => setState(() => _teamOpen = !_teamOpen),
        staleOpen: _staleOpen,
        onStale: () => setState(() => _staleOpen = !_staleOpen),
      );
    }
    if (l is _Channel) {
      return AgentConversationView(
        data: _conversationOf(l),
        focusPrefix: l.id,
        onTasks: () => unawaited(_showTasks(channel: l.channel)),
        onTapMessage: (n, _) => _tapCurrent(n),
      );
    }
    return AgentFrameView(
      focusPrefix: l.id,
      frame: _frame(l),
      focused: _spotlight.focused,
      onCurrent: _tapCurrent,
    );
  }

  /// The current item [n] of [layer] in its detail rendering, for the stage:
  /// the pane beside a list, or under a row on a phone. Null when nothing is
  /// current, or the layer has no such item. [tools] are the phone stage's
  /// 展开 and close.
  Widget? _stage(_Layer layer, int? n, HfData hf, {Widget? tools}) {
    if (n == null || !_stageAllowed) return null;
    if (layer is _Attention) {
      final items = _listed;
      if (n < 1 || n > items.length) return null;
      return AgentItemScope(
        id: '${layer.id}#$n',
        child: AgentAttentionDetail(
          item: items[n - 1],
          number: n,
          onApprove: (i) => unawaited(_approve(i)),
          onOpen: _openItem,
          onLater: _later,
          onReply: _reply,
          onLike: _like,
          onDone: _done,
          onAssign: _assign,
          trailing: tools,
        ),
      );
    }
    final items = [
      for (final i in (_frame(layer)['items'] as List? ?? const []))
        if (i is Map && i['kind'] != 'section') i.cast<String, Object?>(),
    ];
    if (n < 1 || n > items.length) return null;
    final channel = _channelById(items[n - 1]['channelId'] as String?);
    return AgentItemScope(
      id: '${layer.id}#$n',
      child: AgentFrameStage(
        item: items[n - 1],
        number: n,
        trailing: tools,
        onOpen: channel == null ? null : () => _openChannel(channel).ignore(),
      ),
    );
  }

  /// A phone's stage has two small tools: a way to the full page (attention
  /// items only) and a way to put it away.
  Widget _stageTools(_Layer layer, int? n) => HfStageTools(
    onExpand: layer is _Attention && n != null
        ? () {
            final items = _listed;
            if (n >= 1 && n <= items.length) _expandItem(items[n - 1]);
          }
        : null,
    onClose: _clearCurrent,
  );

  /// The confirm cards, as the end of the front layer's page.
  Widget _tray() => AgentEntityScope(
    resolver: _entities,
    child: AgentConsentTray(
      ledger: _consent,
      board: _actions,
      onUndo: (id) => unawaited(_actionPressed(id, undo: true)),
      onRetry: (id) => unawaited(_actionPressed(id, undo: false)),
    ),
  );

  /// A small panel above the dock: what 回复 waits for, or who 交给 Agent
  /// can go to.
  List<Widget> _feedbackPanels(HfData hf) {
    Widget box(Key key, List<Widget> children) => Padding(
      padding: EdgeInsets.only(top: hf.sp(6)),
      child: Container(
        key: key,
        padding: EdgeInsets.fromLTRB(hf.sp(12), hf.sp(8), hf.sp(8), hf.sp(8)),
        decoration: BoxDecoration(
          color: HfColors.cream,
          borderRadius: BorderRadius.circular(hf.sp(14)),
          border: Border.all(color: HfColors.ink, width: hf.sp(3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
    Widget head(String text, VoidCallback cancel, Key cancelKey) => Row(
      children: [
        Expanded(child: Text(text, style: hf.type(HfType.headline))),
        GestureDetector(
          key: cancelKey,
          behavior: HitTestBehavior.opaque,
          onTap: cancel,
          child: Padding(
            padding: EdgeInsets.all(hf.sp(6)),
            child: Icon(Icons.close, size: hf.sp(22), color: HfColors.inkSoft),
          ),
        ),
      ],
    );
    final replying = _replying, assigning = _assigning;
    return [
      if (replying != null)
        box(const ValueKey('agent-reply-note'), [
          head(
            '回复${replying.doer == null ? '' : ' ${replying.doer}'}：说出或输入要回的话',
            () => setState(() => _replying = null),
            const ValueKey('agent-reply-cancel'),
          ),
        ]),
      if (assigning != null)
        box(const ValueKey('agent-assign-panel'), [
          head(
            _assignees == null
                ? '交给哪个 Agent？正在读取'
                : _assignees!.isEmpty
                ? '现在没有在线的 Agent 可以交给'
                : '交给哪个 Agent？',
            () => setState(() {
              _assigning = null;
              _assignees = null;
            }),
            const ValueKey('agent-assign-cancel'),
          ),
          if (_assignees != null && _assignees!.isNotEmpty) ...[
            SizedBox(height: hf.sp(4)),
            HfActions(
              grid: true,
              actions: [
                for (final name in _assignees!)
                  HfAction(
                    name,
                    key: ValueKey('agent-assign-$name'),
                    onPressed: () => _assignTo(assigning, name),
                  ),
              ],
            ),
          ],
        ]),
    ];
  }

  Widget _frameScreen(BuildContext context, HfData hf) {
    // Room above the front layer only for the layers that peek out behind
    // it: one layer, no gap.
    final peeks = (_stack.length - 1).clamp(0, 2);
    return HfScreenFrame(
      top: hf.phone ? _chrome(hf, bar: true) : null,
      content: AgentRevealSyncScope(
        sync: _reveal,
        child: AgentSpotlight(
          controller: _spotlight,
          child: ZLayerStack(
            padding: EdgeInsets.only(top: hf.sp(40) * peeks),
            onReveal: _revealTo,
            layers: [
              for (final l in _stack)
                ZLayer(
                  key: ValueKey(l.id),
                  peek: _peek(l),
                  child: !hf.phone && identical(l, _stack.last)
                      ? HfChrome(
                          trailing: _chrome(hf, bar: false),
                          child: _layerView(l, hf),
                        )
                      : _layerView(l, hf),
                ),
            ],
          ),
        ),
      ),
      above: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ..._feedbackPanels(hf),
          if (_surfaceError != null)
            Padding(
              padding: EdgeInsets.only(top: hf.sp(6)),
              child: Text(
                key: const ValueKey('agent-surface-error'),
                '这块界面没能显示：$_surfaceError',
                style: hf.type(HfType.meta, color: HfColors.decision),
              ),
            ),
        ],
      ),
      foot: ListenableBuilder(
        listenable: _voice,
        builder: (context, _) => AgentVoiceDock(
          mood: AgentMoodBadge(emoji: _mood.emoji, label: _mood.label),
          lines: _voice.lines,
          state: _voice.state,
          notice: _voice.notice,
          onSubmit: _submit,
          onMicDown: () => unawaited(_voice.micDown()),
          onMicUp: _voice.micUp,
        ),
      ),
    );
  }
}
