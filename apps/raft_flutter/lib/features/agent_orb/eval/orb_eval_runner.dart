import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentMicState;

import '../../../data/workspace_controller.dart';
import '../../agent_mode/agent_audio.dart';
import '../../agent_mode/agent_engine.dart';
import '../../agent_mode/agent_thinking.dart';
import '../../agent_mode/agent_voice.dart';
import '../../agent_mode/agent_voice_settings.dart';
import '../../agent_mode/gemini_agent.dart';
import '../../agent_mode/genkit_agent.dart';
import '../../agent_mode/layered_voice.dart';
import '../../agent_mode/layered_voice_mode.dart';
import '../../agent_mode/app_speech.dart' show RecordingSpeech;
import '../../agent_mode/voice_provider.dart';
import '../nav/orb_nav_tools.dart' show orbNavigationTools;
import '../orb_controller.dart';
import '../orb_preference.dart';
import '../orb_tool.dart';
import 'orb_eval_result.dart';
import 'orb_eval_run.dart';
import 'orb_eval_scenario.dart';
import 'orb_eval_world.dart';

/// Where a scenario's workspace is shown: the app's own pages need a widget
/// tree and a Navigator to move in. The evaluation page is one; a test gives
/// another.
abstract interface class OrbEvalStage {
  /// Shows [workspace] (the app's phone shell over it).
  Future<OrbEvalSite> mount(WorkspaceController workspace);
}

abstract interface class OrbEvalSite {
  /// A context under the Navigator of the shown app (null once it is gone).
  BuildContext? navigatorContext();

  /// Takes the workspace off the screen.
  Future<void> unmount();
}

/// What a run says when the device has no voice key; the evaluation stops
/// there rather than failing every scenario the same way.
const orbEvalNoKey = '没有语音 Key：先在 设置 > Labs 里填入';

/// Why a run ended when the evaluation page was closed under it.
const orbEvalPageGone = 'page gone';

/// One step of progress, for the page and the log.
class OrbEvalProgress {
  const OrbEvalProgress(
    this.scenario,
    this.run,
    this.runs, {
    this.passed,
    this.index = 0,
    this.total = 0,
  });
  final OrbEvalScenario scenario;

  /// The run now under way (from 1), or just finished when [passed] is set.
  final int run;
  final int runs;

  /// Null while the run is under way.
  final bool? passed;

  /// The scenario's place in the batch.
  final int index;
  final int total;
}

/// Runs scenarios against the real model: each in a fresh fixture workspace,
/// through the orb's own controller (real tools, real settings, the stored
/// key), by typed text. Every tool call and every word of the reply is
/// recorded and scored. Nothing here reads or prints the key.
class OrbEvalRunner {
  OrbEvalRunner({
    required this.stage,
    this.runs = 2,
    this.turnTimeout,
    this.harness = OrbEvalHarness.realtime,
    this.thinking,
    this.model,
    this.engine,
    this.voiceMode,
    this.layeredGrace = const Duration(seconds: 4),
    this.settle = const Duration(milliseconds: 1200),
    this.sessionFactory,
    this.voiceKey,
    this.onProgress,
  });

  final OrbEvalStage stage;

  /// How many times each scenario runs.
  final int runs;

  /// The longest a model turn may take; 45 seconds for the realtime model,
  /// 120 for the agent (a turn there is several model calls in a row).
  final Duration? turnTimeout;

  /// What drives the orb: the realtime model, or the text agent.
  final OrbEvalHarness harness;

  /// The text agent's thinking level; the Labs setting when null.
  final AgentThinking? thinking;

  /// The text agent's model; the app picks a Flash Lite when null.
  final String? model;

  /// The layered harness: what makes the agent's model calls; the Labs setting
  /// when null.
  final AgentEngine? engine;

  /// The layered harness: how the voice speaks (the Labs setting when null).
  /// With the app speaking, the person's words are typed straight into the
  /// path a transcript takes, Live is not connected, and the app's voice is a
  /// recorder.
  final LayeredVoiceMode? voiceMode;

  LayeredVoiceMode get _voiceMode =>
      voiceMode ?? AgentOrbPreference.instance.layeredVoiceMode;

  /// The layered harness: how long after a Live turn that asked nothing the
  /// turn is called over (an ask may still follow a filler).
  final Duration layeredGrace;

  Duration get _turnLimit =>
      turnTimeout ??
      (harness.isTextAgent
          ? const Duration(seconds: 120)
          : const Duration(seconds: 45));

  /// How long after a turn the late words (transcripts arrive after the turn
  /// ends) and the screen are given to settle before they are read.
  final Duration settle;

  /// The session builder; the real providers (or the text agent, for its
  /// harness) unless a test gives a fake.
  final VoiceSessionFactory? sessionFactory;

  /// The key; the one stored in the app unless a test gives one.
  final AgentVoiceKey? voiceKey;

  final void Function(OrbEvalProgress progress)? onProgress;

  bool _stop = false;
  String? _abortReason;
  _Recorder? _recorder;
  String? _model;
  String? _agentModel;
  String? _liveThinking;

  /// Stops after the run under way.
  void stop() => _stop = true;

  /// Ends the run under way at once, and the evaluation with it, because
  /// [reason] (the page was closed) leaves nothing to run on.
  void abort(String reason) {
    if (_abortReason != null) return;
    _abortReason = reason;
    _stop = true;
    _log(reason);
    _recorder?.interrupt(reason);
  }

  Future<OrbEvalReport> runAll(List<OrbEvalScenario> scenarios) async {
    _stop = false;
    _abortReason = null;
    _model = null;
    _agentModel = null;
    _liveThinking = null;
    final started = DateTime.now();
    final results = <OrbEvalScenarioResult>[];
    for (final (i, s) in scenarios.indexed) {
      if (_stop) break;
      if (s.status == OrbEvalStatus.skipped) {
        results.add(OrbEvalScenarioResult(s, const []));
        _log('${s.id} skipped');
        continue;
      }
      // A scenario that cannot pass yet is run once.
      final times = s.status == OrbEvalStatus.expectedFail ? 1 : runs;
      final done = <OrbEvalRunResult>[];
      for (var n = 1; n <= times && !_stop; n++) {
        onProgress?.call(
          OrbEvalProgress(s, n, times, index: i + 1, total: scenarios.length),
        );
        final result = await _runOnce(s, n);
        done.add(result);
        if (result.error == orbEvalNoKey) _stop = true;
        _log('${s.id} run $n/$times ${result.passed ? 'pass' : 'fail'}');
        onProgress?.call(
          OrbEvalProgress(
            s,
            n,
            times,
            passed: result.passed,
            index: i + 1,
            total: scenarios.length,
          ),
        );
      }
      if (done.isEmpty) break;
      results.add(OrbEvalScenarioResult(s, done));
    }
    final settings = AgentVoiceSettings.instance;
    // The agent harness ignores the voice settings: they would only mislead.
    final agent = harness.isTextAgent && harness != OrbEvalHarness.layered;
    final layered = harness == OrbEvalHarness.layered;
    final report = OrbEvalReport(
      startedAt: started,
      runsPerScenario: runs,
      results: results,
      // The voice layer is Gemini whatever the voice settings name.
      provider: agent ? null : (layered ? 'gemini' : settings.provider.name),
      // The voice layer runs Live with the least thinking it takes, whatever
      // the voice settings say.
      reasoning: agent
          ? null
          : (layered ? _liveThinking : settings.reasoning.name),
      harness: harness.name,
      model: _model,
      thinking: agent || layered
          ? (thinking ?? AgentOrbPreference.instance.agentThinking).name
          : null,
      engine: layered
          ? (engine ?? AgentOrbPreference.instance.agentEngine).name
          : null,
      agentModel: layered ? _agentModel : null,
      voiceMode: layered ? _voiceMode.name : null,
      combination: _combination(settings, agent: agent, layered: layered),
      cancelled: _stop,
      abortReason: _abortReason,
    );
    _log(
      'done ok=${report.ok} passed=${report.count(OrbEvalOutcome.passed)} '
      'flaky=${report.count(OrbEvalOutcome.flaky)} '
      'failed=${report.count(OrbEvalOutcome.failed)}',
    );
    return report;
  }

  /// The combination that was run, in one line: the brain, and what each
  /// side was.
  String _combination(
    AgentVoiceSettings settings, {
    required bool agent,
    required bool layered,
  }) {
    final thinkingLabel =
        (thinking ?? AgentOrbPreference.instance.agentThinking).label;
    if (layered) {
      final engineLabel =
          (engine ?? AgentOrbPreference.instance.agentEngine).label;
      return '${AgentBrainMode.layered.label}：'
          '语音模型 Gemini Live${_model == null ? '' : '（$_model）'}'
          '${_liveThinking == null ? '' : ' 推理 $_liveThinking'}'
          ' · ${_voiceMode.label}'
          ' · Agent 引擎 $engineLabel'
          '${_agentModel == null ? '' : ' 模型 $_agentModel'}'
          ' 推理 $thinkingLabel';
    }
    if (agent) {
      return '文字 Agent（不带语音模型）：${_model ?? '自动选'} 推理 $thinkingLabel';
    }
    return '${AgentBrainMode.voiceOnly.label}：'
        '${agentVoiceProviderLabels[settings.provider]}'
        '${_model == null ? '' : '（$_model）'}'
        ' 推理 ${settings.reasoning.name}';
  }

  /// Progress lines only: scenario ids and pass or fail. Never a prompt, a
  /// reply or a key.
  void _log(String line) => debugPrint('orb-eval: $line');

  /// What builds the session when a test gave none.
  VoiceSessionFactory _defaultFactory(_Recorder recorder) => switch (harness) {
    OrbEvalHarness.realtime => createVoiceSession,
    // Live is typed to; the agent behind its one tool is the app's own.
    OrbEvalHarness.layered =>
      ({
        required provider,
        required apiKey,
        required systemPrompt,
        required tools,
        required onToolCall,
        required voice,
        reasoning = AgentReasoning.low,
        onAudio,
        onInputText,
        onOutputText,
        onTurnComplete,
        onInterrupted,
        onClosed,
        playbackPending,
        steering,
      }) => LayeredVoiceSession(
        apiKey: apiKey,
        systemPrompt: systemPrompt,
        tools: tools,
        onToolCall: onToolCall,
        steering: steering!,
        thinking: thinking ?? AgentOrbPreference.instance.agentThinking,
        engine: engine ?? AgentOrbPreference.instance.agentEngine,
        agentModelId: model ?? AgentOrbPreference.instance.agentModel,
        voice: voice,
        reasoning: reasoning,
        liveModel: AgentVoiceSettings.instance.liveModel,
        mode: _voiceMode,
        // Also with Live relaying: the app says a confirmation line itself
        // when Live's words for it miss something.
        speech: recorder.speech,
        listen: _voiceMode != LayeredVoiceMode.appSpeaks,
        onAudio: onAudio,
        onInputText: onInputText,
        onOutputText: onOutputText,
        onTurnComplete: onTurnComplete,
        onInterrupted: onInterrupted,
        onClosed: onClosed,
      ),
    // The text agent has its own key reading (the stored Gemini key, or the
    // one a test gave): provider, voice and reasoning do not apply to it.
    OrbEvalHarness.agent =>
      ({
        required provider,
        required apiKey,
        required systemPrompt,
        required tools,
        required onToolCall,
        required voice,
        reasoning = AgentReasoning.low,
        onAudio,
        onInputText,
        onOutputText,
        onTurnComplete,
        onInterrupted,
        onClosed,
        playbackPending,
        steering,
      }) => GeminiAgentSession(
        key: voiceKey,
        thinking: thinking ?? AgentOrbPreference.instance.agentThinking,
        modelName: model,
        steering: steering,
        systemPrompt: systemPrompt,
        tools: tools,
        onToolCall: onToolCall,
        onOutputText: onOutputText,
        onTurnComplete: onTurnComplete,
        onClosed: onClosed,
      ),
    OrbEvalHarness.genkit =>
      ({
        required provider,
        required apiKey,
        required systemPrompt,
        required tools,
        required onToolCall,
        required voice,
        reasoning = AgentReasoning.low,
        onAudio,
        onInputText,
        onOutputText,
        onTurnComplete,
        onInterrupted,
        onClosed,
        playbackPending,
        steering,
      }) => GenkitAgentSession(
        key: voiceKey,
        thinking: thinking ?? AgentOrbPreference.instance.agentThinking,
        modelId: model,
        steering: steering,
        systemPrompt: systemPrompt,
        tools: tools,
        onToolCall: onToolCall,
        onOutputText: onOutputText,
        onTurnComplete: onTurnComplete,
        onClosed: onClosed,
      ),
  };

  // ---- one run -------------------------------------------------------------

  Future<OrbEvalRunResult> _runOnce(OrbEvalScenario s, int index) async {
    final data = s.data();
    final run = OrbEvalRun(ids: data.allIds);
    OrbEvalWorld? world;
    OrbEvalSite? site;
    OrbController? orb;
    String? problem;
    try {
      world = await OrbEvalWorld.create(data);
      final shown = site = await stage.mount(world.workspace);
      problem = await _awaitFixture(shown);
      if (problem != null) throw StateError(problem);
      await _warm(world);
      await _start(s, world, shown);
      final recorder = _recorder = _Recorder(
        run,
        grace: harness == OrbEvalHarness.layered ? layeredGrace : null,
      );
      orb = OrbController(
        workspace: world.workspace,
        navigatorContext: () => shown.navigatorContext(),
        sessionFactory: recorder.wrap(
          sessionFactory ?? _defaultFactory(recorder),
        ),
        agentLayer: harness.isTextAgent,
        layeredVoice: harness == OrbEvalHarness.layered,
        audio: _SilentAudio(),
        voiceKey: voiceKey,
        // The summary of a session would be a write to the shared agent.
        summarySender: (brain, transcript, outcomes, header) async => false,
      );
      if (!await orb.voice.hasKey) {
        problem = orbEvalNoKey;
      } else {
        for (final line in s.setup) {
          problem = await _say(orb, recorder, world, line, scored: false);
          if (problem != null) break;
        }
        if (problem == null && s.events.isNotEmpty) {
          problem = await _push(orb, recorder, world, s);
        }
        for (final line in s.say) {
          if (problem != null) break;
          problem = await _say(orb, recorder, world, line, scored: true);
        }
      }
    } catch (e) {
      // ignore: raft_lints/avoid_caught_exception_text -- Only our own StateError texts (the start page); they go into the report of a developer tool.
      problem = '运行出错：${e is StateError ? e.message : e.runtimeType}';
    } finally {
      _model ??= _recorder?.session?.model;
      final made = _recorder?.session;
      if (made is LayeredVoiceSession) {
        _agentModel ??= made.agentModel;
        _liveThinking ??= made.liveThinking;
      }
      run.writes = world?.writes.toList() ?? const [];
      try {
        // The layer opens on the app's root Navigator and outlives the
        // scenario's workspace unless it is closed.
        if (orb != null && orb.layerOpen) {
          orb.closeLayer();
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        await orb?.hangUp();
      } catch (_) {}
      orb?.dispose();
      try {
        await site?.unmount();
      } catch (_) {}
      try {
        await world?.dispose();
      } catch (_) {}
    }
    final failures = <OrbEvalFailure>[];
    // The voice layer is held to one thing in every scenario.
    final checks = [
      ...s.checks,
      if (harness == OrbEvalHarness.layered) OrbEvalCheck.keyInfoSpoken(),
    ];
    for (final check in checks) {
      String? reason;
      try {
        reason = check.test(run);
      } catch (e) {
        reason = '检查本身出错：${e.runtimeType}';
      }
      if (reason != null) failures.add(OrbEvalFailure(check.label, reason));
    }
    return OrbEvalRunResult(
      index: index,
      run: run,
      failures: failures,
      error: problem,
    );
  }

  /// The fixture's Navigator exists a moment after it is mounted; a run
  /// cannot start before it does (the orb's tools answer "not ready"
  /// without it). Null when it is there.
  Future<String?> _awaitFixture(OrbEvalSite site) async {
    for (var i = 0; i < 50; i++) {
      if (_abortReason != null) return _abortReason;
      if (site.navigatorContext() != null) return null;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _abortReason ?? '评测的界面没有准备好（5 秒内没有出现）';
  }

  /// Reads the Activity first, as the app has done long before the person
  /// speaks (the discussions the orb can open are named by its rows). A
  /// scenario whose Activity never answers just waits a moment.
  Future<void> _warm(OrbEvalWorld world) async {
    try {
      await world.workspace.activityUnread.refresh().timeout(
        const Duration(seconds: 3),
      );
    } catch (_) {}
  }

  /// Takes the app to the scenario's start page, as the model's own
  /// `navigate` would (by id).
  Future<void> _start(
    OrbEvalScenario s,
    OrbEvalWorld world,
    OrbEvalSite site,
  ) async {
    final args = s.start.navigateArgs(world.data);
    if (args == null) return;
    final context = site.navigatorContext();
    if (context == null) throw StateError('no navigator');
    final operating = ValueNotifier<bool>(false);
    try {
      final navigate = orbNavigationTools().firstWhere(
        (t) => t.name == 'navigate',
      );
      final answer = await navigate
          .handler(
            args,
            OrbToolContext(
              workspace: world.workspace,
              navigatorContext: context,
              operating: operating,
            ),
          )
          .timeout(const Duration(seconds: 20));
      // A scenario that did not start where it says would be scored on the
      // wrong page.
      if (answer['error'] != null || answer['candidates'] != null) {
        throw StateError('start page: ${answer['error'] ?? 'ambiguous'}');
      }
    } finally {
      operating.dispose();
    }
  }

  /// One typed turn. Returns an error text, or null when the model finished.
  Future<String?> _say(
    OrbController orb,
    _Recorder recorder,
    OrbEvalWorld world,
    String line, {
    required bool scored,
  }) async {
    final turn = recorder.begin(line, scored: scored);
    final watch = Stopwatch()..start();
    final outcome = recorder.waitForTurn(orb.voice, _turnLimit);
    await orb.sendText(line);
    final error = await outcome;
    // Text sent to the end of the model's turn (the settling is not in it).
    turn.millis = math.max(1, watch.elapsedMilliseconds);
    turn.fastPath = orb.fastPath;
    orb.fastPath = null;
    return _finish(orb, world, turn, error);
  }

  /// Pushes the scenario's events into the connected session's workspace and
  /// watches for what the orb does about them.
  Future<String?> _push(
    OrbController orb,
    _Recorder recorder,
    OrbEvalWorld world,
    OrbEvalScenario s,
  ) async {
    final turn = recorder.begin('（事件）', scored: true);
    for (final e in s.events) {
      world.client.emit(e.name, e.payload(world.data));
    }
    await Future<void>.delayed(s.observe);
    turn.completed = true;
    return _finish(orb, world, turn, null);
  }

  Future<String?> _finish(
    OrbController orb,
    OrbEvalWorld world,
    OrbEvalTurn turn,
    String? error,
  ) async {
    if (error != null) turn.failure = error;
    // Late transcript words and the screen's last frames.
    await Future<void>.delayed(settle);
    turn.liveFiller = orbEvalLiveFiller(turn);
    turn.writesAfter = world.writes
        .where((w) => !orbEvalIsBenignWrite(w))
        .length;
    turn.after = OrbEvalSnapshot(
      location: world.workspace.location.toString(),
      layerOpen: orb.layerOpen,
      driving: orb.driving,
      drivingIndex: orb.drivingIndex,
      cards: [
        for (final item in orb.drivingItems)
          {
            'id': item.id,
            'who': item.who,
            'where': item.where,
            'title': item.title,
            'reason': item.reason.name,
          },
      ],
    );
    return error;
  }
}

/// Watches the session the orb builds: the tool calls and their answers, the
/// reply's words and the end of the turn.
class _Recorder {
  _Recorder(this.run, {this.grace});
  final OrbEvalRun run;

  /// The layered harness: how long Live may have said its turn complete
  /// without having asked the agent before that is taken for its answer (it
  /// is often a filler; the ask can follow).
  final Duration? grace;
  int _asking = 0;
  int _turnAsks = 0;
  final _clock = Stopwatch();
  bool _askBack = false;
  Timer? _graceTimer;
  OrbEvalTurn? _turn;
  Completer<String?>? _done;
  Timer? _timeout;
  VoidCallback? _unlisten;

  /// The session the orb last built (its model is told in the report).
  VoiceSession? session;

  /// The app's voice in the layered harness: it says nothing aloud and notes
  /// each sentence it is asked to speak in the turn under way.
  final speech = RecordingSpeech();

  OrbEvalTurn begin(String line, {required bool scored}) {
    final turn = OrbEvalTurn(line, scored: scored);
    run.turns.add(turn);
    _turn = turn;
    _turnAsks = 0;
    _askBack = false;
    _clock
      ..reset()
      ..start();
    _graceTimer?.cancel();
    return turn;
  }

  /// Completes with null when the model finishes the turn, or with the reason
  /// it could not (the connection failed, the time ran out).
  Future<String?> waitForTurn(AgentVoiceController voice, Duration limit) {
    final done = _done = Completer<String?>();
    void finish(String? error) {
      if (!done.isCompleted) done.complete(error);
    }

    _timeout?.cancel();
    _timeout = Timer(limit, () {
      _turn?.timedOut = true;
      finish(
        '超过 ${limit.inSeconds} 秒没有结束'
        '${grace == null ? '' : '（ask_agent 发起了 $_turnAsks 次，还有 $_asking 个没回来）'}',
      );
    });
    // A session that never opens or closes under the turn leaves a note.
    void changed() {
      final note = voice.notice;
      if (note != null &&
          voice.state == AgentMicState.idle &&
          !(_turn?.completed ?? false)) {
        finish(note);
      }
    }

    voice.addListener(changed);
    _unlisten = () => voice.removeListener(changed);
    return done.future.whenComplete(() {
      _timeout?.cancel();
      _unlisten?.call();
      _unlisten = null;
    });
  }

  /// Ends the turn under way with [reason].
  void interrupt(String reason) {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete(reason);
  }

  void _turnComplete() {
    final turn = _turn;
    if (turn == null) return;
    if (grace != null) {
      // Live's turn ends when it has the agent's answer and has spoken it:
      // not while an ask is out, and not at a filler said before the ask.
      if (_asking > 0) return;
      if (_turnAsks == 0) {
        _graceTimer?.cancel();
        _graceTimer = Timer(grace!, _finish);
        return;
      }
    }
    _finish();
  }

  void _finish() {
    _graceTimer?.cancel();
    final turn = _turn;
    if (turn == null) return;
    turn.completed = true;
    final done = _done;
    if (done != null && !done.isCompleted) done.complete(null);
  }

  void _askingChanged(int inFlight) {
    if (inFlight > _asking) {
      _turnAsks++;
      _askBack = false;
      _graceTimer?.cancel();
      // The voice that came before this ask is not what the person waited for.
      _turn?.firstAudioMs = 0;
    } else if (inFlight == 0) {
      _askBack = true;
    }
    _asking = inFlight;
  }

  /// A sound or a word of the voice: the first one after the last answer of
  /// the agent (or the first at all, when it asked nothing) is when the
  /// person starts to hear.
  void _heard() {
    final turn = _turn;
    if (turn == null || turn.firstAudioMs > 0 || _asking > 0) return;
    if (_turnAsks > 0 && !_askBack) return;
    turn.firstAudioMs = math.max(1, _clock.elapsedMilliseconds);
  }

  /// Wraps a session builder so the session reports to this recorder.
  VoiceSessionFactory wrap(VoiceSessionFactory inner) =>
      ({
        required provider,
        required apiKey,
        required systemPrompt,
        required tools,
        required onToolCall,
        required voice,
        reasoning = AgentReasoning.low,
        onAudio,
        onInputText,
        onOutputText,
        onTurnComplete,
        onInterrupted,
        onClosed,
        playbackPending,
        steering,
      }) => _track(
        session = inner(
          provider: provider,
          apiKey: apiKey,
          systemPrompt: systemPrompt,
          tools: tools,
          voice: voice,
          reasoning: reasoning,
          onAudio: (pcm) {
            _heard();
            onAudio?.call(pcm);
          },
          onInputText: onInputText,
          onInterrupted: onInterrupted,
          playbackPending: playbackPending,
          steering: steering,
          onToolCall: (name, args) async {
            final watch = Stopwatch()..start();
            Map<String, Object?> result;
            try {
              result = await onToolCall(name, args);
            } catch (e) {
              _turn?.tools.add(
                OrbEvalToolCall(
                  name: name,
                  args: args,
                  result: {'error': 'threw ${e.runtimeType}'},
                  millis: watch.elapsedMilliseconds,
                ),
              );
              rethrow;
            }
            _turn?.tools.add(
              OrbEvalToolCall(
                name: name,
                args: args,
                result: result,
                millis: watch.elapsedMilliseconds,
              ),
            );
            return result;
          },
          onOutputText: (text) {
            _heard();
            _turn?.addText(text);
            onOutputText?.call(text);
          },
          onTurnComplete: () {
            onTurnComplete?.call();
            _turnComplete();
          },
          onClosed: (reason) {
            onClosed?.call(reason);
            final done = _done;
            if (done != null && !done.isCompleted) {
              done.complete('连接断开：$reason');
            }
          },
        ),
      );

  /// A layered session reports each ask of the voice model to the agent.
  VoiceSession _track(VoiceSession made) {
    if (made is LayeredVoiceSession) {
      made
        ..onAsk = _ask
        ..onSpoken = ((sentence) => _turn?.spoken.add(sentence))
        ..onCorrection = ((say, missing) => _turn?.corrections.add(missing))
        ..addAskingListener(_askingChanged);
    }
    return made;
  }

  void _ask(String request, String say, int millis) =>
      _turn?.asks.add(OrbEvalAsk(request: request, say: say, millis: millis));
}

/// No sound: the model's speech is dropped (its words arrive as text).
class _SilentAudio extends AgentAudio {
  // ignore: invalid_use_of_visible_for_testing_member
  _SilentAudio() : super.forTesting();

  @override
  bool get supported => false;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Stream<Uint8List> microphone() => const Stream.empty();
  @override
  Future<void> play(Uint8List pcm) async {}
  @override
  Future<Duration> pending() async => Duration.zero;
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<void> release() async {}
}
