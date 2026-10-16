import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentSpeaker;

import '../../../data/workspace_controller.dart';
import '../agent_mode_data.dart';
import '../agent_surface_stream.dart';
import '../agent_surface_tools.dart';
import '../agent_voice.dart';
import '../capabilities/agent_action_board.dart';
import '../capabilities/agent_capability.dart';
import '../capabilities/agent_capability_tools.dart';
import '../capabilities/agent_consent.dart';
import '../capabilities/agent_read_tools.dart';
import '../references/agent_reference_table.dart';
import 'agent_stop_words.dart';
import 'agent_turn.dart';

/// What the voice session needs that only the screen knows.
class AgentVoiceSetup {
  const AgentVoiceSetup({
    required this.tools,
    required this.systemPrompt,
    this.beforeConnect,
    this.onSessionEnd,
  });

  /// The function declarations (the runtime adds `additive` to the ones that
  /// start a request, see [agentTurnToolDeclarations]).
  final List<Map<String, Object?>> tools;
  final String Function() systemPrompt;
  final Future<void> Function()? beforeConnect;
  final void Function(List<(AgentSpeaker, String)> transcript)? onSessionEnd;
}

/// The tools that never say what a request is about: a mood, a spotlight,
/// asking what "this one" is. A call to one of them neither starts a request
/// nor decides what becomes of the previous one.
const _neutralTools = {
  'set_mood',
  'spotlight',
  'release_spotlight',
  'mark',
  'resolve',
};

/// Answered at once, never waited for: a screen operation or a decision of
/// the person's already taken. Everything else is a read (or a preview), and
/// is dropped when it arrives for a turn that no longer counts.
const _instantTools = {
  ...AgentGroundedTools.uiNames,
  'show_surface',
  'confirm',
  'undo',
  'resolve',
  'set_mood',
  'spotlight',
  'release_spotlight',
  'mark',
};

/// The streaming screen tools, which name the screen they work on.
const _streamingTools = {'add_component', 'update_component', 'end_surface'};

/// The tools that start a request and may say it adds to the previous one.
Set<String> get _additiveTools => {
  ...agentReadToolNames,
  ...agentOnlyActionTools,
  'find',
  'query',
  'act',
  'begin_surface',
  'show_surface',
  'list_agents',
  'get_task',
  'search_tasks',
  'read_channel',
  'read_tasks',
};

/// The direct action tools (kept in one place so the runtime does not import
/// every capability file).
const agentOnlyActionTools = {
  'send_message',
  'reply_in_thread',
  'react',
  'mark_read',
  'mark_done',
  'create_task',
  'set_task_status',
  'assign_task',
  'unassign_task',
  'join_channel',
};

/// [tools] with the two turn parameters added to the ones that start a
/// request: `additive` (this adds to the previous request: do not cancel it)
/// and `turn` (the id of the turn it goes on from).
List<Map<String, Object?>> agentTurnToolDeclarations(
  List<Map<String, Object?>> tools,
) {
  final names = _additiveTools;
  return [
    for (final t in tools)
      if (names.contains(t['name']))
        {
          ...t,
          'parameters': () {
            final p =
                ((t['parameters'] as Map?) ??
                        const {'type': 'object', 'properties': {}})
                    .cast<String, Object?>();
            return {
              ...p,
              'properties': {
                ...((p['properties'] as Map?) ?? const {})
                    .cast<String, Object?>(),
                'additive': {
                  'type': 'boolean',
                  'description':
                      '这句话是接着上一轮说的（再加、继续、还有）就写 true，上一轮没做完的会保留；否则不要写',
                },
              },
            };
          }(),
        }
      else
        t,
  ];
}

/// The model-facing answer for work that no longer counts.
Map<String, Object?> _droppedAnswer(AgentTurn turn) => {
  'cancelled': true,
  'message':
      '用户${turn.cancellation.reason == AgentCancelReason.stopped ? '叫停了' : '已经换了话题'}，'
      '这次的结果作废了，没有显示。不要再提它；如果用户的新话是接着它说的，带 additive:true 再来一次。',
};

/// The runtime of agent mode: one explicit turn state machine and the owner of
/// everything a turn touches.
///
/// A turn is one thing the person asked ([AgentTurn]). Whatever starts a new
/// one (words, typed text, speaking over the model) makes the previous one
/// *superseded* at once: what it had in flight is dropped when it arrives, its
/// streaming screen stops (what is already shown stays, marked 已停止). Whether
/// its confirmations and the rest carry on is decided by the model, which
/// knows both requests: a call that says `additive` or names the old turn (or
/// confirms one of its tokens, or adds to its screen) merges the old turn into
/// the new one; the first call that does not cancels it, and its confirmation
/// cards turn into 已取消. "停 / 算了 / 等一下" cancels everything with no
/// round trip to the model.
///
/// The runtime owns the pieces that used to be state of the page: the consent
/// ledger (what the person agreed to), the action board, the grounded tools
/// (screens the model composes), the capability tools, the direct read tools
/// and the voice session. The page is a view of it.
class AgentRuntime extends ChangeNotifier {
  AgentRuntime({
    required this.workspace,
    required this.data,
    required this.surfaces,
    required this.references,
    AgentCapabilityRegistry? registry,
    this.pointed,
    this.screenTool,
    this.screenSummary,
    this.decorate,
    this.around,
    this.onRejected,
    AgentVoiceSetup? voice,
    this.modelLink,
    this.onNotice,
    DateTime Function()? now,
    AgentConsentLedger? consent,
    AgentActionBoard? actions,
  }) : _now = now ?? DateTime.now,
       consent = consent ?? AgentConsentLedger(now: now),
       actions = actions ?? AgentActionBoard(now: now) {
    _gate = _TurnConsent(this);
    grounded = AgentGroundedTools(
      data: data,
      host: _host,
      catalog: null,
      onRejected: onRejected,
      capabilities: registry,
      references: references,
    );
    final env = AgentCapabilityEnv(data: data, facts: grounded.facts);
    capabilities = AgentCapabilityTools(
      workspace: workspace,
      registry: registry,
      env: env,
      references: references,
      pointed: pointed,
      userConsent: _gate,
      board: this.actions,
      now: now,
    );
    reads = AgentReadTools(
      workspace: workspace,
      env: env,
      host: _host,
      registry: registry,
      references: references,
    );
    this.consent.addListener(_consentChanged);
    if (voice != null) {
      this.voice = AgentVoiceController(
        tools: agentTurnToolDeclarations(voice.tools),
        onToolCall: runTool,
        systemPrompt: voice.systemPrompt,
        beforeConnect: voice.beforeConnect,
        onSessionEnd: voice.onSessionEnd,
        onUserSaid: (text, {required fresh}) =>
            userTranscript(text, fresh: fresh),
        onListening: beginListening,
        onListeningEnded: userDone,
        onModelInterrupted: modelInterrupted,
        onModelSpoke: modelSpoke,
        onModelTurnComplete: modelTurnComplete,
        muted: () => muted,
      );
    }
  }

  final WorkspaceController workspace;
  final AgentModeData data;

  /// What the screen does for the runtime: show a layer, say whether one is
  /// still open.
  final AgentSurfaceHost surfaces;

  /// What is on the front screen, by handle (① ② ③ …).
  final AgentReferenceTable Function() references;

  /// The card the person tapped, for "这个".
  final AgentEntityRef? Function()? pointed;

  /// The tools only the page can run (open a channel, spotlight, expand an
  /// item, go back …).
  final Future<Map<String, Object?>> Function(
    String name,
    Map<String, Object?> args,
  )?
  screenTool;

  /// One line on what the screen shows ("第 2 层「任务」"), for the context.
  final String Function()? screenSummary;

  /// Last touch on the result of a tool the runtime ran (e.g. adding the
  /// handles of what is on screen now).
  final Map<String, Object?> Function(String name, Map<String, Object?> result)?
  decorate;

  /// Wraps every call (the screen keeps the mood badge honest and adds what
  /// the screen noticed to the answer): [run] does the call.
  final Future<Map<String, Object?>> Function(
    String name,
    Map<String, Object?> args,
    Future<Map<String, Object?>> Function() run,
  )?
  around;
  final void Function(List<String> problems)? onRejected;

  /// A line for the person (a caption): "已停止".
  final void Function(String line)? onNotice;
  final DateTime Function() _now;

  /// What stands in for the voice session when there is none (tests).
  final AgentModelLink? modelLink;

  /// What the person has agreed to. Fed only by them (see
  /// [AgentConsentLedger]).
  final AgentConsentLedger consent;

  /// The confirmed operations, as the cards that turn into their result.
  final AgentActionBoard actions;
  late final _TurnConsent _gate;
  late final AgentGroundedTools grounded;
  late final AgentCapabilityTools capabilities;
  late final AgentReadTools reads;

  /// The voice session; null when the runtime was made without one (tests,
  /// the offline demo).
  AgentVoiceController? voice;

  AgentModelLink? get link => modelLink ?? voice;

  /// A call that comes within this long after the person began to speak, with
  /// nothing heard yet, was started before they spoke.
  static const staleWindow = Duration(milliseconds: 700);

  /// After "停", the model's own reply (it still hears the word) is not played.
  bool get muted => current?.stopRequest ?? false;

  // ---- state -----------------------------------------------------------

  AgentPhase _phase = AgentPhase.idle;
  AgentPhase get phase => _phase;

  /// The turns of this session, oldest first (the last few).
  final turns = <AgentTurn>[];
  int _turnSeq = 0, _callSeq = 0;

  /// The turn being worked on, or the last one.
  AgentTurn? get current => turns.isEmpty ? null : turns.last;

  /// Moves the state machine made that its table does not allow (a bug if any).
  final illegalTransitions = <String>[];

  /// What was said to the person (captions like "已停止"), for tests.
  final notices = <String>[];

  final _owners = <String, AgentTurn>{};
  final _drafts = <String, AgentSurfaceDraft>{};
  final _stopped = <String>{};

  /// The surfaces whose streaming was stopped by a new request: the screen
  /// marks them 已停止.
  Set<String> get stoppedSurfaces => Set.unmodifiable(_stopped);
  bool surfaceStopped(String id) => _stopped.contains(id);

  late final AgentSurfaceHost _host = AgentSurfaceHost(
    begin: (draft) {
      final turn = _callTurn() ?? current;
      _owners[draft.id] = turn ?? _implicit();
      _drafts[draft.id] = draft;
      // A screen the app drew (a direct read) can be changed in place too.
      grounded.drafts.putIfAbsent(draft.id, () => draft);
      (_owners[draft.id]!).surfaces.add(draft.id);
      _owners[draft.id]!.rendered = true;
      return surfaces.begin(draft);
    },
    changed: surfaces.changed,
    isOpen: surfaces.isOpen,
    ended: surfaces.ended,
  );

  static AgentTurn? _callTurn() {
    final t = Zone.current[#agentTurn];
    return t is AgentTurn ? t : null;
  }

  // ---- the state machine ----------------------------------------------

  void _go(AgentPhase next) {
    if (_phase == next) return;
    if (!(agentPhaseTransitions[_phase]?.contains(next) ?? false)) {
      illegalTransitions.add('${_phase.name}→${next.name}');
      return;
    }
    _phase = next;
    notifyListeners();
  }

  /// A new turn restarts the machine from wherever it was.
  void _restart(AgentPhase next) {
    _phase = next;
    notifyListeners();
  }

  AgentTurn _newTurn(
    AgentTurnSource source,
    String text, {
    bool supersede = true,
  }) {
    final prev = current;
    final turn = AgentTurn(
      id: 't${++_turnSeq}',
      userText: text,
      startedAt: _now(),
      source: source,
    );
    if (prev != null && supersede) {
      // A request still undecided two turns back cannot go on any more.
      final older = prev.previous;
      if (older != null) _cancelTurn(older, AgentCancelReason.replaced);
      if (prev.status == AgentTurnStatus.open ||
          prev.status == AgentTurnStatus.merged) {
        _supersede(prev, turn);
      }
    }
    turns.add(turn);
    while (turns.length > 12) {
      turns.removeAt(0);
    }
    return turn;
  }

  /// The new request replaced [old]: what it had in flight is dropped, its
  /// screen stops streaming. Its confirmations wait for the model's word.
  void _supersede(AgentTurn old, AgentTurn next) {
    old.status = AgentTurnStatus.superseded;
    old.cancellation.cancel(AgentCancelReason.replaced);
    old.inFlight.clear();
    _stopStreaming(old);
    next.previous = old;
  }

  void _stopStreaming(AgentTurn turn) {
    var any = false;
    for (final id in turn.surfaces) {
      final draft = _drafts[id];
      if (draft == null || draft.ended || _stopped.contains(id)) continue;
      if (!surfaces.isOpen(draft)) continue;
      _stopped.add(id);
      any = true;
      surfaces.ended?.call(draft);
    }
    if (any) notifyListeners();
  }

  void _resumeStreaming(AgentTurn turn) {
    var any = false;
    for (final id in turn.surfaces) {
      if (_stopped.remove(id)) any = true;
    }
    if (any) notifyListeners();
  }

  void _cancelTurn(AgentTurn turn, AgentCancelReason reason) {
    final force = reason == AgentCancelReason.stopped;
    if (turn.status == AgentTurnStatus.cancelled ||
        turn.status == AgentTurnStatus.finished) {
      return;
    }
    turn.status = AgentTurnStatus.cancelled;
    turn.cancellation.cancel(reason);
    turn.inFlight.clear();
    _stopStreaming(turn);
    for (final token in turn.pendingConfirmations.toList()) {
      consent.cancel(token, force: force);
    }
    turn.pendingConfirmations.clear();
    final next = turn.previous;
    turn.previous = null;
    if (next != null) _cancelTurn(next, reason);
  }

  /// The model has said what [turn] is about: [additive] keeps the request it
  /// replaced and goes on with it, anything else drops it.
  void _decide(AgentTurn turn, {required bool additive}) {
    final old = turn.previous;
    turn.previous = null;
    if (old == null) return;
    if (additive && old.status == AgentTurnStatus.superseded) {
      old.status = AgentTurnStatus.merged;
      old.mergedInto = turn;
      turn.pendingConfirmations.addAll(old.pendingConfirmations);
      old.pendingConfirmations.clear();
      _resumeStreaming(old);
      for (final id in old.surfaces) {
        _owners[id] = turn;
      }
      turn.surfaces.addAll(old.surfaces);
      turn.summary ??= old.summary;
    } else {
      _cancelTurn(old, AgentCancelReason.replaced);
    }
    notifyListeners();
  }

  AgentTurn _implicit() {
    final turn = _newTurn(AgentTurnSource.model, '');
    _restart(AgentPhase.understanding);
    return turn;
  }

  // ---- what the person does -------------------------------------------

  /// The person starts to speak (the mic opened), or speaks over the model.
  AgentTurn beginListening({bool bargeIn = false}) {
    final t = current;
    if (t != null &&
        _phase == AgentPhase.listening &&
        t.userText.isEmpty &&
        t.status == AgentTurnStatus.open) {
      return t;
    }
    final turn = _newTurn(
      bargeIn ? AgentTurnSource.bargeIn : AgentTurnSource.voice,
      '',
    );
    _restart(AgentPhase.listening);
    return turn;
  }

  /// A chunk of the transcript of what the person says. [fresh] starts a new
  /// utterance. The words also go to the consent ledger: they are the one
  /// stream a confirmation or an undo may be read from.
  void userTranscript(String text, {bool fresh = true}) {
    if (text.trim().isEmpty) return;
    var turn = current;
    final usable =
        turn != null &&
        turn.source != AgentTurnSource.text &&
        turn.source != AgentTurnSource.model &&
        (turn.status == AgentTurnStatus.open || turn.stopRequest) &&
        (!fresh || turn.userText.isEmpty);
    if (!usable) {
      turn = _newTurn(AgentTurnSource.voice, '');
      _restart(AgentPhase.listening);
    } else if (turn.stopRequest) {
      // "等一下……" went on into a request: the stop became a turn.
      turn.stopRequest = false;
      turn.status = AgentTurnStatus.open;
      _restart(AgentPhase.listening);
    }
    turn.userText += text;
    if (isStopUtterance(turn.userText)) _stop(turn);
    consent.userSaid(text, fresh: fresh);
  }

  /// The person is done speaking (let go of the button, or ended live mode).
  void userDone() {
    if (_phase == AgentPhase.listening) _go(AgentPhase.understanding);
  }

  /// Typed text. Returns the new turn, or null when it was only a stop
  /// ("算了") and nothing is to be sent to the model.
  AgentTurn? submitText(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return null;
    if (isStopUtterance(clean)) {
      // Cancel first: the cards the stop cancels say so (the ledger would
      // only make them disappear).
      _stop(_newTurn(AgentTurnSource.text, clean, supersede: false));
      consent.userSaid(clean);
      return null;
    }
    consent.userSaid(clean);
    final turn = _newTurn(AgentTurnSource.text, clean);
    _restart(AgentPhase.understanding);
    return turn;
  }

  /// 停 / 算了 / 等一下 / the stop button: everything in flight is dropped,
  /// every screen being streamed stops, every confirmation is cancelled, the
  /// model is silenced. No round trip.
  void cancelAll() {
    _stop(_newTurn(AgentTurnSource.text, '', supersede: false));
  }

  void _stop(AgentTurn stopTurn) {
    var anything = false;
    for (final t in turns.toList()) {
      if (identical(t, stopTurn)) continue;
      if (t.status == AgentTurnStatus.open ||
          t.status == AgentTurnStatus.superseded ||
          t.status == AgentTurnStatus.merged) {
        anything =
            anything ||
            t.inFlight.isNotEmpty ||
            t.pendingConfirmations.isNotEmpty ||
            t.surfaces.any((id) => !(_drafts[id]?.ended ?? true));
        _cancelTurn(t, AgentCancelReason.stopped);
      }
    }
    stopTurn.previous = null;
    stopTurn.stopRequest = true;
    stopTurn.status = AgentTurnStatus.finished;
    link?.stopSpeaking();
    _notice(anything ? '已停止' : '好，没有在做的事');
    _restart(AgentPhase.idle);
  }

  void _notice(String line) {
    notices.add(line);
    onNotice?.call(line);
    voice?.say(AgentSpeaker.agent, line);
  }

  // ---- what the model does --------------------------------------------

  /// The server cut the model off: the person is speaking over it.
  void modelInterrupted() {
    if (_phase == AgentPhase.listening) return;
    beginListening(bargeIn: true);
  }

  /// The model began to answer (words or audio).
  void modelSpoke() {
    final t = current;
    if (t == null || t.status == AgentTurnStatus.finished) return;
    t.modelDone = false;
    if (_phase == AgentPhase.listening) {
      // Only an answer to words that were said is an answer.
      if (t.userText.isEmpty) return;
      _go(AgentPhase.understanding);
    }
    if (_phase == AgentPhase.understanding) _go(AgentPhase.presenting);
  }

  /// The model finished its turn.
  void modelTurnComplete() {
    final t = current;
    if (t == null || _phase == AgentPhase.listening) return;
    t.modelDone = true;
    // A turn that made no call did not go on from the old one.
    if (!t.classified) _decide(t, additive: false);
    _settle();
  }

  /// A turn that is only text (the offline demo, a scripted model) is over.
  void finishTurn() {
    final t = current;
    if (t == null) return;
    t.modelDone = true;
    if (!t.classified) _decide(t, additive: false);
    _settle();
  }

  // ---- the context the model is given ---------------------------------

  /// What the model is told when a turn starts, in a few words: the turn id,
  /// what the previous turn was and how it ended, the confirmations waiting,
  /// the screen. Nothing when there is no history yet.
  String contextLine([AgentTurn? turn]) {
    final t = turn ?? current;
    if (t == null) return '';
    final prev = t.previous ?? _before(t);
    final parts = <String>['【回合】这是 ${t.id}'];
    if (prev != null) {
      final said = prev.userText.trim();
      final status = switch (prev.status) {
        AgentTurnStatus.open || AgentTurnStatus.superseded => '还没做完',
        AgentTurnStatus.merged => '已并入后来的请求',
        AgentTurnStatus.finished => prev.stopRequest ? '用户叫停了' : '已完成',
        AgentTurnStatus.cancelled =>
          prev.cancellation.reason == AgentCancelReason.stopped
              ? '被用户叫停'
              : '被新请求取消了',
      };
      parts.add(
        '上一轮 ${prev.id}'
        '${said.isEmpty ? '' : '「${_clip(said, 16)}」'}：$status'
        '${prev.summary == null ? '' : '（${prev.summary}）'}',
      );
    }
    final waiting = _waiting();
    if (waiting.isNotEmpty) {
      parts.add(
        '待用户确认：${[for (final w in waiting) '${w.summary}（${w.turn}，token ${w.token}）'].join('；')}',
      );
    }
    final screen = screenSummary?.call();
    if (screen != null && screen.isNotEmpty) parts.add('屏幕：$screen');
    if (parts.length == 1) return '';
    if (prev != null && (waiting.isNotEmpty || t.previous != null)) {
      parts.add(
        '用户这句如果是接着上一轮说的（再加、继续、还有），调用工具时带 additive:true，上一轮的会保留；否则上一轮没做完的会被取消',
      );
    }
    return '${parts.join('。')}。';
  }

  /// The context for the first call of a turn is told once.
  String? takeContext([AgentTurn? turn]) {
    final t = turn ?? current;
    if (t == null || t.contextTold) return null;
    t.contextTold = true;
    final line = contextLine(t);
    return line.isEmpty ? null : line;
  }

  AgentTurn? _before(AgentTurn t) {
    final at = turns.indexOf(t);
    for (var i = at - 1; i >= 0; i--) {
      if (turns[i].userText.trim().isNotEmpty || turns[i].summary != null) {
        return turns[i];
      }
    }
    return null;
  }

  List<({String token, String summary, String turn})> _waiting() => [
    for (final p in consent.active)
      if (!p.approved)
        (
          token: p.request.token,
          summary: p.request.preview.summary,
          turn:
              turns
                  .where(
                    (t) => t.pendingConfirmations.contains(p.request.token),
                  )
                  .map((t) => t.id)
                  .firstOrNull ??
              '',
        ),
  ];

  static String _clip(String s, int max) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= max ? one : '${one.substring(0, max)}…';
  }

  // ---- tools -----------------------------------------------------------

  bool _owns(String name) =>
      agentReadToolNames.contains(name) ||
      AgentGroundedTools.names.contains(name) ||
      AgentCapabilityTools.allNames.contains(name);

  /// Every function call of the model comes through here. A tool answers
  /// with a map and never throws.
  ///
  /// Reads and previews of a turn that was replaced or stopped are not
  /// delivered: the model is told at once and the late result is ignored.
  Future<Map<String, Object?>> runTool(
    String name,
    Map<String, Object?> rawArgs,
  ) {
    final around = this.around;
    return around == null
        ? _runTool(name, rawArgs)
        : around(name, rawArgs, () => _runTool(name, rawArgs));
  }

  Future<Map<String, Object?>> _runTool(
    String name,
    Map<String, Object?> rawArgs,
  ) async {
    final args = Map<String, Object?>.of(rawArgs);
    final additive = args.remove('additive') == true;
    final named = args.remove('turn');
    if (_neutralTools.contains(name)) return _dispatch(name, args, null);

    final refusal = _staleCall();
    if (refusal != null) return refusal;
    var turn = current;
    if (turn == null ||
        turn.status == AgentTurnStatus.finished ||
        turn.status == AgentTurnStatus.cancelled) {
      turn = _implicit();
    }
    _classify(turn, name, args, additive: additive, named: '${named ?? ''}');

    // A screen that was stopped takes no more components.
    if (_streamingTools.contains(name)) {
      final owner = _streamOwner(args);
      if (owner != null && owner.dropped) {
        return {'error': '这一屏已经停止（用户换了话题或叫停了），不要再往里加。', 'stopped': true};
      }
    }

    final call = AgentToolCall(++_callSeq, name, _now());
    turn.inFlight.add(call);
    turn.modelDone = false;
    _enterActing(turn);
    final droppable = _owns(name) && !_instantTools.contains(name);
    Map<String, Object?> result;
    try {
      final work = Zone.current
          .fork(zoneValues: {#agentTurn: turn})
          .run(() => _dispatch(name, args, turn));
      if (droppable) {
        final early = await Future.any<Map<String, Object?>?>([
          work,
          turn.cancellation.whenCancelled.then((_) => null),
        ]);
        if (early == null) {
          // The late answer is not wanted; make sure it fails quietly.
          unawaited(work.then<void>((_) {}, onError: (Object _) {}));
          result = _droppedAnswer(turn);
        } else {
          result = turn.dropped ? _droppedAnswer(turn) : early;
        }
      } else {
        result = await work;
      }
    } finally {
      turn.inFlight.remove(call);
    }
    if (!result.containsKey('cancelled')) {
      _note(turn, name, result);
      final ctx = takeContext(turn);
      if (ctx != null) result = {...result, 'ctx': ctx};
    }
    _settle();
    return result;
  }

  Future<Map<String, Object?>> _dispatch(
    String name,
    Map<String, Object?> args,
    AgentTurn? turn,
  ) async {
    final read = await reads.run(
      name,
      args,
      cancelled: () => turn?.dropped ?? false,
    );
    if (read != null) return read;
    final grounded = await this.grounded.run(name, args);
    if (grounded != null) return decorate?.call(name, grounded) ?? grounded;
    final capability = await capabilities.run(name, args);
    if (capability != null) return capability;
    final screen = screenTool;
    if (screen != null) return screen(name, args);
    return {'error': 'unknown tool $name'};
  }

  /// A call that came after the person stopped everything, or while they are
  /// still speaking and the model has nothing to answer yet, is not wanted.
  Map<String, Object?>? _staleCall() {
    final t = current;
    if (t == null) return null;
    if (t.stopRequest) {
      return {'cancelled': true, 'message': '用户叫停了，什么都不要做，也不要再调用工具。等他的下一句话。'};
    }
    if (_phase == AgentPhase.listening &&
        t.userText.isEmpty &&
        t.status == AgentTurnStatus.open &&
        _now().difference(t.startedAt) < staleWindow) {
      return {
        'cancelled': true,
        'stale': true,
        'message': '用户正在说话，这次调用是在他开口之前发起的，作废了。听他说完再做。',
      };
    }
    return null;
  }

  /// The first call that says what the request is decides what becomes of the
  /// one it replaced.
  void _classify(
    AgentTurn turn,
    String name,
    Map<String, Object?> args, {
    required bool additive,
    required String named,
  }) {
    final old = turn.previous;
    turn.classified = true;
    if (old == null) return;
    final surface = _streamingTools.contains(name) ? _streamOwner(args) : null;
    final token = '${args['token'] ?? ''}';
    final refers =
        additive && _additiveTools.contains(name) ||
        named == old.id ||
        (surface != null && identical(surface, old)) ||
        (name == 'confirm' && old.pendingConfirmations.contains(token));
    _decide(turn, additive: refers);
  }

  AgentTurn? _streamOwner(Map<String, Object?> args) {
    final id = args['surface_id'] ?? args['id'];
    if (id is String && _owners.containsKey(id)) return _owners[id];
    // No id: the latest screen still open.
    final open = grounded.drafts.values
        .where(surfaces.isOpen)
        .map((d) => d.id)
        .lastOrNull;
    return open == null ? null : _owners[open];
  }

  void _enterActing(AgentTurn turn) {
    if (!identical(turn, current)) return;
    if (_phase == AgentPhase.listening) _go(AgentPhase.understanding);
    _go(AgentPhase.acting);
  }

  void _note(AgentTurn turn, String name, Map<String, Object?> result) {
    if (result['error'] != null) return;
    if (result['shown'] is int) {
      turn.rendered = true;
      turn.summary =
          '展示了 ${result['shown']} 项${result['kind'] == null ? '' : '：${result['kind']}'}';
    } else if (result['status'] == 'needs_confirmation') {
      final p = result['preview'];
      turn.summary = '等用户确认：${p is Map ? p['summary'] : name}';
    } else if (result['status'] == 'done') {
      turn.summary = '已执行：${(result['result'] as Map?)?['done'] ?? name}';
    } else if (name == 'begin_surface' || name == 'show_surface') {
      turn.rendered = true;
      turn.summary = '组了一屏';
    } else if (agentReadToolNames.contains(name)) {
      turn.rendered = true;
    }
  }

  // ---- settling ---------------------------------------------------------

  void _consentChanged() {
    final live = {for (final p in consent.active) p.request.token};
    for (final t in turns) {
      t.pendingConfirmations.removeWhere((token) => !live.contains(token));
    }
    _settle();
  }

  bool _hasPending(AgentTurn t) => t.pendingConfirmations.isNotEmpty;

  /// Where the machine is once the dust settles: acting while a call runs,
  /// waiting while a preview is on screen, presenting while the result is
  /// said, idle when the model is done and nothing waits.
  void _settle() {
    final t = current;
    if (t == null || t.stopRequest) return;
    if (t.status == AgentTurnStatus.finished ||
        t.status == AgentTurnStatus.cancelled) {
      return;
    }
    if (_phase == AgentPhase.listening) return;
    if (t.inFlight.isNotEmpty) {
      _go(AgentPhase.acting);
    } else if (_hasPending(t)) {
      _go(AgentPhase.awaitingConfirmation);
    } else if (t.modelDone) {
      t.status = AgentTurnStatus.finished;
      _go(AgentPhase.idle);
    } else if (t.rendered) {
      _go(AgentPhase.presenting);
    } else if (_phase == AgentPhase.acting ||
        _phase == AgentPhase.awaitingConfirmation) {
      _go(AgentPhase.understanding);
    }
  }

  // ---- the model link ---------------------------------------------------

  /// Tells the model something the app saw (outside the captions).
  Future<bool> tell(String note) async => await link?.tell(note) ?? false;

  @override
  void dispose() {
    for (final t in turns) {
      if (t.status == AgentTurnStatus.open ||
          t.status == AgentTurnStatus.superseded) {
        t.cancellation.cancel(AgentCancelReason.closed);
      }
    }
    consent.removeListener(_consentChanged);
    voice?.dispose();
    consent.dispose();
    actions.dispose();
    super.dispose();
  }
}

/// The consent ledger as the capability tools see it: a preview shown for a
/// turn that no longer counts is not shown, and each preview is remembered
/// under the turn that asked for it.
class _TurnConsent implements AgentUserConsent {
  _TurnConsent(this.runtime);
  final AgentRuntime runtime;

  @override
  void previewShown(AgentConsentRequest request) {
    final turn = AgentRuntime._callTurn() ?? runtime.current;
    if (turn != null && turn.dropped) return;
    runtime.consent.previewShown(request);
    turn?.pendingConfirmations.add(request.token);
  }

  @override
  AgentConsentVerdict take(String token) => runtime.consent.take(token);

  @override
  bool takeUndo() => runtime.consent.takeUndo();
}
