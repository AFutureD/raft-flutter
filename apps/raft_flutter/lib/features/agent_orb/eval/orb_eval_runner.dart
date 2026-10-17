import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentMicState;

import '../../../data/workspace_controller.dart';
import '../../agent_mode/agent_audio.dart';
import '../../agent_mode/agent_voice.dart';
import '../../agent_mode/agent_voice_settings.dart';
import '../../agent_mode/voice_provider.dart';
import '../nav/orb_nav_tools.dart' show orbNavigationTools;
import '../orb_controller.dart';
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
    this.turnTimeout = const Duration(seconds: 45),
    this.settle = const Duration(milliseconds: 1200),
    this.sessionFactory,
    this.voiceKey,
    this.onProgress,
  });

  final OrbEvalStage stage;

  /// How many times each scenario runs.
  final int runs;

  /// The longest a model turn may take.
  final Duration turnTimeout;

  /// How long after a turn the late words (transcripts arrive after the turn
  /// ends) and the screen are given to settle before they are read.
  final Duration settle;

  /// The session builder; the real providers unless a test gives a fake.
  final VoiceSessionFactory? sessionFactory;

  /// The key; the one stored in the app unless a test gives one.
  final AgentVoiceKey? voiceKey;

  final void Function(OrbEvalProgress progress)? onProgress;

  bool _stop = false;
  String? _abortReason;
  _Recorder? _recorder;

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
    final report = OrbEvalReport(
      startedAt: started,
      runsPerScenario: runs,
      results: results,
      provider: settings.provider.name,
      reasoning: settings.reasoning.name,
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

  /// Progress lines only: scenario ids and pass or fail. Never a prompt, a
  /// reply or a key.
  void _log(String line) => debugPrint('orb-eval: $line');

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
      final recorder = _recorder = _Recorder(run);
      orb = OrbController(
        workspace: world.workspace,
        navigatorContext: () => shown.navigatorContext(),
        sessionFactory: recorder.wrap(sessionFactory ?? createVoiceSession),
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
    for (final check in s.checks) {
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
    final outcome = recorder.waitForTurn(orb.voice, turnTimeout);
    await orb.sendText(line);
    final error = await outcome;
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
  _Recorder(this.run);
  final OrbEvalRun run;
  OrbEvalTurn? _turn;
  Completer<String?>? _done;
  Timer? _timeout;
  VoidCallback? _unlisten;

  OrbEvalTurn begin(String line, {required bool scored}) {
    final turn = OrbEvalTurn(line, scored: scored);
    run.turns.add(turn);
    _turn = turn;
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
      finish('超过 ${limit.inSeconds} 秒没有结束');
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
    turn.completed = true;
    final done = _done;
    if (done != null && !done.isCompleted) done.complete(null);
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
      }) => inner(
        provider: provider,
        apiKey: apiKey,
        systemPrompt: systemPrompt,
        tools: tools,
        voice: voice,
        reasoning: reasoning,
        onAudio: onAudio,
        onInputText: onInputText,
        onInterrupted: onInterrupted,
        playbackPending: playbackPending,
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
      );
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
