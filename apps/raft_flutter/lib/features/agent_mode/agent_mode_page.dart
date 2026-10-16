import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart' show RaftTokens;

import '../../data/workspace_controller.dart';
import 'agent_attention.dart';
import 'agent_audio.dart';
import 'agent_catalog.dart';
import 'agent_choreography.dart';
import 'agent_consent_tray.dart';
import 'agent_detail.dart';
import 'agent_entity_binding.dart';
import 'agent_frame_view.dart';
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

  /// The first attention row on screen (see [_pageRows]).
  int _batchStart = 0;

  /// The phone layout (set by build): surfaces fold their groups to one row.
  bool _compact = true;

  /// A window wide enough for a list with its detail beside it (set by
  /// build). Narrower ones show the current item in a sheet under the layer.
  bool _split = false;

  /// The current item of each layer (layer id to its number), kept while
  /// another layer is in front, so going back finds it still current.
  final _currentOf = <String, int>{};

  /// One past the last attention row on screen (reported by the view).
  int _batchEnd = 0;
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
    screenSummary: () => '第 ${_stack.length} 层「${_peek(_stack.last)}」',
    decorate: (name, result) =>
        name == 'end_surface' ? _withRefs(result) : result,
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
        _batchStart = 0;
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
    // The person pressed 确认 / 取消 on a preview: tell the model, which is
    // waiting for them (their words reach it as audio or text on their own).
    _consent.onTapped = (request, yes) => unawaited(
      _voice.tell(
        yes
            ? '（屏幕提示，不是用户说的）用户点了确认卡的“确认”（confirmToken ${request.token}）。现在可以调用 confirm 执行。'
            : '（屏幕提示，不是用户说的）用户点了确认卡的“取消”（confirmToken ${request.token}）。不要执行，告诉他已经取消。',
      ),
    );
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

  void _openItem(AgentAttentionItem item) {
    final c = _channelById(item.channelId);
    if (c == null) {
      _voice.say(AgentSpeaker.agent, '这条所在的频道不在你的列表里，打不开。');
      return;
    }
    _openChannel(c).ignore();
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

  /// A tap, a key and the voice all make an item current the same way.
  void _setCurrent(int n) => _spotlight.focus('${_stack.last.id}#$n');

  /// Nothing is current on the front layer (the sheet closes).
  void _clearCurrent() {
    _currentOf.remove(_stack.last.id);
    _spotlight.release();
  }

  /// The current attention item left the list (通过, 稍后). A sheet closes; a
  /// wide window keeps the same place, which the next item now takes.
  void _itemGone() {
    if (_split) return;
    _currentOf.remove(_stack.first.id);
    if (_stack.last is _Attention) _spotlight.release();
  }

  /// A tap on a row. On a screen with a sheet, the tap on the current row
  /// again puts the sheet away.
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
    return !(top is _Surface && top.item != null);
  }

  /// A phone's stage is open: the current item has its sheet.
  bool get _sheetOpen => !_split && _stageAllowed && _current != null;

  /// The detail of one attention item as a new layer (the full page). The
  /// voice tool `expand_item` on a narrow screen and the sheet's 展开 both
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
    final at = (_visible?.items ?? const <AgentAttentionItem>[]).indexWhere(
      (i) => i.id == item.id,
    );
    return at < 0 ? 1 : at + 1;
  }

  /// `expand_item` and "讲讲第一条": [number] counts the home cards from 1;
  /// null means the current one, else the most urgent. The item becomes the
  /// current one. A window with a detail beside its list shows it there and
  /// pushes no layer; a narrower one goes to the full detail page.
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

  /// Shows the rows from [start] on the first layer; what was lifted or
  /// marked belonged to the old ones.
  void _showBatch(int start) {
    _choreo.newScreen();
    // Another page: its rows are new, and the old current one is not on it.
    _currentOf.remove(_stack.first.id);
    setState(() => _batchStart = start);
  }

  /// `next_batch`: the next page of rows, or the first ones again after the
  /// last. Takes the person back to the first layer.
  Map<String, Object?> _nextBatch() {
    final cards = _visible?.items.length ?? 0;
    // The view says where its page ends; before it said anything, one page.
    final shownTo = _batchEnd == 0 ? cards : _batchEnd;
    if (_batchStart == 0 && shownTo >= cards) {
      return {'error': '只有 $cards 件，已经全部显示了'};
    }
    final next = shownTo >= cards ? 0 : shownTo;
    if (_stack.length > 1) setState(() => _stack.removeRange(1, _stack.length));
    _showBatch(next);
    return {'ok': true, 'showing': '从第 ${next + 1} 条起', 'total': cards};
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

  /// Back: a sheet that is open goes first, then the layer.
  void _pop() {
    if (_sheetOpen) {
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

  /// What the screen shows now; every screen tool returns this.
  Map<String, Object?> _screen() {
    final frame = _frame(_stack.last);
    final refs = AgentReferenceTable.fromFrame(_stack.last.id, frame);
    return {
      'layer': _stack.length,
      'title': _peek(_stack.last),
      if (frame['loading'] == true) 'loading': true,
      if (_current != null) 'current': _current,
      'items': _screenItems().take(12).toList(),
      if (!refs.isEmpty) 'refs': refs.contextText(pointed: _pointed()),
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
        if (top is! _Channel || top.channel.id != c.id) {
          _openChannel(c, announce: false).ignore();
        }
        return _screen();
      case 'next_batch':
        return _withRefs(_nextBatch());
      case 'expand_item':
        return _withRefs(
          _expandNumber(((args['index'] ?? args['number']) as num?)?.toInt()),
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
      'entity': taskRowEntity(t),
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
            'entity': attentionEntity(i),
          },
      ],
      // The TV draws the same screen from the result itself.
      if (_visible != null) 'attention': _visible!.toJson(),
      'batch': _batchStart,
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
                'entity': messageRowEntity(m),
              },
          ],
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
      canPop: _stack.length == 1 && !_sheetOpen,
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
    final view = _layerContent(l, hf);
    // A wide window shows the current item of a list in the slot beside it
    // (the attention layer draws its own, in place).
    if (!hf.split || l is _Attention || !identical(l, _stack.last)) return view;
    final stage = _stage(l, _current, hf);
    return stage == null ? view : HfStageScope(stage: stage, child: view);
  }

  Widget _layerContent(_Layer l, HfData hf) {
    if (l is _Surface) return _surfaceLayer(l, compact: hf.phone);
    if (l is _Attention) {
      return AgentAttentionView(
        attention: _visible,
        error: _attentionError,
        focusPrefix: l.id,
        onApprove: (i) => unawaited(_approve(i)),
        onOpen: _openItem,
        onLater: _later,
        current: identical(l, _stack.last) ? _current : _currentOf[l.id],
        onCurrent: _tapCurrent,
        batchStart: _batchStart,
        onBatch: _showBatch,
        onPage: (start, end) {
          _batchStart = start;
          _batchEnd = end;
          // A wide window always shows a detail: the first row of the page is
          // the current one until another is chosen.
          if (_split && identical(l, _stack.last) && _current == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  _split &&
                  _current == null &&
                  _stack.last is _Attention) {
                _setCurrent(start + 1);
              }
            });
          }
        },
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
  /// the pane beside a list, or a phone's sheet. Null when nothing is
  /// current, or the layer has no such item. [tools] are the sheet's 展开 and
  /// close.
  Widget? _stage(_Layer layer, int? n, HfData hf, {Widget? tools}) {
    if (n == null || !_stageAllowed) return null;
    if (layer is _Attention) {
      final items = _visible?.items ?? const <AgentAttentionItem>[];
      if (n < 1 || n > items.length) return null;
      return AgentItemScope(
        id: '${layer.id}#$n',
        child: AgentAttentionDetail(
          item: items[n - 1],
          number: n,
          onApprove: (i) => unawaited(_approve(i)),
          onOpen: _openItem,
          onLater: _later,
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

  /// A phone's stage: the current item of the front layer in a sheet that
  /// takes the lower half of the layer's area, with a way to the full page
  /// (attention items only) and a way to put it away.
  Widget? _sheet(HfData hf, double room) {
    if (hf.split) return null;
    final layer = _stack.last;
    final n = _current;
    final tools = HfStageTools(
      onExpand: layer is _Attention && n != null
          ? () {
              final items = _visible?.items ?? const <AgentAttentionItem>[];
              if (n >= 1 && n <= items.length) _expandItem(items[n - 1]);
            }
          : null,
      onClose: _clearCurrent,
    );
    final stage = _stage(layer, n, hf, tools: tools);
    return stage == null ? null : HfStageSheet(height: room * .5, child: stage);
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
          child: LayoutBuilder(
            builder: (context, box) {
              final sheet = _sheet(hf, box.maxHeight);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
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
                  if (sheet != null) ...[SizedBox(height: hf.sp(12)), sheet],
                ],
              );
            },
          ),
        ),
      ),
      above: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_surfaceError != null)
            Padding(
              padding: EdgeInsets.only(top: hf.sp(6)),
              child: Text(
                key: const ValueKey('agent-surface-error'),
                '这块界面没能显示：$_surfaceError',
                style: hf.type(HfType.meta, color: HfColors.decision),
              ),
            ),
          AgentEntityScope(
            resolver: _entities,
            child: AgentConsentTray(
              ledger: _consent,
              board: _actions,
              onUndo: (id) => unawaited(_actionPressed(id, undo: true)),
              onRetry: (id) => unawaited(_actionPressed(id, undo: false)),
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
