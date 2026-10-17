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

/// All scenarios of one evaluation.
class OrbEvalReport {
  OrbEvalReport({
    required this.startedAt,
    required this.runsPerScenario,
    required this.results,
    this.provider,
    this.reasoning,
    this.cancelled = false,
    this.abortReason,
  });

  final DateTime startedAt;
  final int runsPerScenario;
  final List<OrbEvalScenarioResult> results;

  /// The voice service and reasoning level the runs used (never the key).
  final String? provider;
  final String? reasoning;

  /// The run was stopped before every scenario was through.
  final bool cancelled;

  /// Why the evaluation was ended from outside (`page gone`).
  final String? abortReason;

  int count(OrbEvalOutcome o) => results.where((r) => r.outcome == o).length;

  /// Nothing that was run failed.
  bool get ok => !cancelled && results.every((r) => !r.failsTheRun);

  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toUtc().toIso8601String(),
    'runsPerScenario': runsPerScenario,
    if (provider != null) 'provider': provider,
    if (reasoning != null) 'reasoning': reasoning,
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
