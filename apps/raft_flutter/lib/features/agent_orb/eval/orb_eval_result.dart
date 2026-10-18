import 'orb_eval_run.dart';
import 'orb_eval_scenario.dart';

/// A check that did not hold in a run.
class OrbEvalFailure {
  const OrbEvalFailure(this.check, this.reason);
  final String check;
  final String reason;

  Map<String, Object?> toJson() => {'check': check, 'reason': reason};
}

/// One run of one scenario, scored.
class OrbEvalRunResult {
  const OrbEvalRunResult({
    required this.index,
    required this.run,
    required this.failures,
    this.error,
  });

  /// From 1.
  final int index;
  final OrbEvalRun run;
  final List<OrbEvalFailure> failures;

  /// The run could not be carried out (no key, a connection that failed).
  final String? error;

  bool get passed => failures.isEmpty && error == null;
}

/// How a scenario came out over its runs.
enum OrbEvalOutcome {
  /// Every run passed.
  passed,

  /// Some runs passed, some failed.
  flaky,

  /// No run passed.
  failed,

  /// Not run: needs the action tools.
  skipped,

  /// Not built yet and failed, as expected.
  expectedFail,

  /// Not built yet but passed: the scenario or the feature needs a look.
  unexpectedPass,
}

class OrbEvalScenarioResult {
  const OrbEvalScenarioResult(this.scenario, this.runs);

  final OrbEvalScenario scenario;
  final List<OrbEvalRunResult> runs;

  int get passes => runs.where((r) => r.passed).length;
  double get passRate => runs.isEmpty ? 0 : passes / runs.length;

  OrbEvalOutcome get outcome {
    switch (scenario.status) {
      case OrbEvalStatus.skipped:
        return OrbEvalOutcome.skipped;
      case OrbEvalStatus.expectedFail:
        return passes == runs.length && runs.isNotEmpty
            ? OrbEvalOutcome.unexpectedPass
            : OrbEvalOutcome.expectedFail;
      case OrbEvalStatus.run:
        if (runs.isEmpty || passes == 0) return OrbEvalOutcome.failed;
        return passes == runs.length
            ? OrbEvalOutcome.passed
            : OrbEvalOutcome.flaky;
    }
  }

  /// Counts against the run: a scenario that was run and did not pass every
  /// time. Skipped and not-yet-built scenarios never do.
  bool get failsTheRun =>
      outcome == OrbEvalOutcome.failed || outcome == OrbEvalOutcome.flaky;

  /// The checks that failed, with the runs they failed in.
  Map<String, List<int>> get failedChecks {
    final out = <String, List<int>>{};
    for (final r in runs) {
      for (final f in r.failures) {
        out.putIfAbsent('${f.check} — ${f.reason}', () => []).add(r.index);
      }
      final error = r.error;
      if (error != null) {
        out.putIfAbsent('运行出错 — $error', () => []).add(r.index);
      }
    }
    return out;
  }
}

/// What drives the orb in an evaluation.
enum OrbEvalHarness {
  /// The realtime voice model of the settings, in text mode (the default).
  realtime,

  /// A Gemini text model in a function-calling loop: the same prompt and
  /// tools, answered by plain `generateContent` calls.
  agent,

  /// The same text agent with its model calls made by Genkit
  /// (`GenkitAgentSession`): the model is a `provider/model` string.
  genkit,

  /// The whole voice layer in text: a Gemini Live session whose only tool is
  /// `ask_agent`, with the Genkit (or direct) agent behind it. Live is typed to
  /// and its spoken words are read from its transcript.
  layered;

  /// Whether a text agent (and the app's rules around it) drives the orb.
  bool get isTextAgent => this != realtime;
}

/// All scenarios of one evaluation.
class OrbEvalReport {
  OrbEvalReport({
    required this.startedAt,
    required this.runsPerScenario,
    required this.results,
    this.provider,
    this.reasoning,
    this.harness,
    this.model,
    this.thinking,
    this.engine,
    this.agentModel,
    this.voiceMode,
    this.language,
    this.combination,
    this.cancelled = false,
    this.abortReason,
  });

  final DateTime startedAt;
  final int runsPerScenario;
  final List<OrbEvalScenarioResult> results;

  /// The voice service and reasoning level the runs used (never the key).
  final String? provider;
  final String? reasoning;

  /// Which [OrbEvalHarness] drove the orb, and the model it ended up on.
  final String? harness;
  final String? model;

  /// The text agent's thinking level (`AgentThinking.name`), for the agent
  /// harness.
  final String? thinking;

  /// The layered harness: what made the agent's model calls (`genkit`,
  /// `direct`), and the model it ran (`model` is then the Live model).
  final String? engine, agentModel;

  /// The layered harness: how the voice speaks (`appSpeaks`: the app reads
  /// the agent's words with a voice of its own; `liveRelays`).
  final String? voiceMode;

  /// The language the agent was pinned to for the run (`zh`, `en`).
  final String? language;

  /// What was run, in a line: the brain (the realtime voice model alone, or a
  /// voice model with the text Agent) and each side of it.
  final String? combination;

  /// The run was stopped before every scenario was through.
  final bool cancelled;

  /// Why the evaluation was ended from outside (`page gone`).
  final String? abortReason;

  /// The median time, in milliseconds, from the person's text to the end of
  /// the model's turn, over every scored turn that was timed.
  int? get latencyP50 => _percentile(_turnTimes((t) => t.millis), .5);
  int? get latencyP90 => _percentile(_turnTimes((t) => t.millis), .9);

  /// The time from the person's text to the voice's first sound after the
  /// last answer of the agent.
  int? get firstAudioP50 => _percentile(_turnTimes((t) => t.firstAudioMs), .5);
  int? get firstAudioP90 => _percentile(_turnTimes((t) => t.firstAudioMs), .9);

  /// The time from the person's words to the first sound of the voice, and to
  /// the first sentence of the answer (the layered harness).
  int? get firstVoiceP50 => _percentile(_turnTimes((t) => t.firstVoiceMs), .5);
  int? get firstVoiceP90 => _percentile(_turnTimes((t) => t.firstVoiceMs), .9);
  int? get firstAnswerP50 =>
      _percentile(_turnTimes((t) => t.firstAnswerMs), .5);
  int? get firstAnswerP90 =>
      _percentile(_turnTimes((t) => t.firstAnswerMs), .9);

  /// The median of each piece of the time to the first sound (see
  /// `OrbEvalTurn.segments`), over the turns that have it.
  Map<String, int> get segmentP50 {
    final by = <String, List<int>>{};
    for (final r in results) {
      for (final run in r.runs) {
        for (final t in run.run.scoredTurns) {
          t.segments.forEach((k, v) => by.putIfAbsent(k, () => []).add(v));
        }
      }
    }
    return {
      for (final e in by.entries)
        e.key: (e.value..sort())[(e.value.length - 1) ~/ 2],
    };
  }

  /// The time the asks to the agent took in a turn.
  int? get askP50 => _percentile(_turnTimes((t) => t.askMs), .5);
  int? get askP90 => _percentile(_turnTimes((t) => t.askMs), .9);

  List<int> _turnTimes(int Function(OrbEvalTurn t) of) => [
    for (final r in results)
      for (final run in r.runs)
        for (final t in run.run.scoredTurns)
          if (of(t) > 0) of(t),
  ]..sort();

  static int? _percentile(List<int> sorted, double p) => sorted.isEmpty
      ? null
      : sorted[((sorted.length - 1) * p).round().clamp(0, sorted.length - 1)];

  int count(OrbEvalOutcome o) => results.where((r) => r.outcome == o).length;

  /// Nothing that was run failed.
  bool get ok => !cancelled && results.every((r) => !r.failsTheRun);

  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toUtc().toIso8601String(),
    'runsPerScenario': runsPerScenario,
    if (provider != null) 'provider': provider,
    if (reasoning != null) 'reasoning': reasoning,
    if (harness != null) 'harness': harness,
    if (model != null) 'model': model,
    if (thinking != null) 'thinking': thinking,
    if (engine != null) 'engine': engine,
    if (agentModel != null) 'agentModel': agentModel,
    if (voiceMode != null) 'voiceMode': voiceMode,
    if (language != null) 'language': language,
    if (combination != null) 'combination': combination,
    if (latencyP50 != null) 'latencyP50Ms': latencyP50,
    if (latencyP90 != null) 'latencyP90Ms': latencyP90,
    if (firstAudioP50 != null) 'firstAudioP50Ms': firstAudioP50,
    if (firstAudioP90 != null) 'firstAudioP90Ms': firstAudioP90,
    if (firstVoiceP50 != null) 'firstVoiceP50Ms': firstVoiceP50,
    if (firstVoiceP90 != null) 'firstVoiceP90Ms': firstVoiceP90,
    if (firstAnswerP50 != null) 'firstAnswerP50Ms': firstAnswerP50,
    if (firstAnswerP90 != null) 'firstAnswerP90Ms': firstAnswerP90,
    if (segmentP50.isNotEmpty) 'segmentP50Ms': segmentP50,
    if (askP50 != null) 'askP50Ms': askP50,
    if (askP90 != null) 'askP90Ms': askP90,
    if (cancelled) 'cancelled': true,
    if (abortReason != null) 'abortReason': abortReason,
    'ok': ok,
    'summary': {for (final o in OrbEvalOutcome.values) o.name: count(o)},
    'scenarios': [
      for (final r in results)
        {
          'id': r.scenario.id,
          'title': r.scenario.title,
          'start': r.scenario.start.label,
          'say': [...r.scenario.setup, ...r.scenario.say],
          'status': r.scenario.status.name,
          if (r.scenario.note != null) 'note': r.scenario.note,
          'outcome': r.outcome.name,
          'runs': r.runs.length,
          'passes': r.passes,
          'passRate': r.passRate,
          'failedChecks': [
            for (final e in r.failedChecks.entries)
              {'check': e.key, 'runs': e.value},
          ],
          'results': [
            for (final run in r.runs)
              {
                'run': run.index,
                'passed': run.passed,
                if (run.error != null) 'error': run.error,
                'failures': [for (final f in run.failures) f.toJson()],
                'turns': [for (final t in run.run.turns) t.toJson()],
                'writes': [for (final w in run.run.writes) w.toJson()],
              },
          ],
        },
    ],
  };
}
