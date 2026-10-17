import 'orb_eval_data.dart';
import 'orb_eval_run.dart';
import 'orb_eval_world.dart' show OrbEvalWrite;

/// Where a scenario starts: the page the person is on when they speak.
class OrbEvalStart {
  const OrbEvalStart._(this.label, this._args);

  /// The home screen: no navigation.
  static const home = OrbEvalStart._('首页', null);

  /// The Activity page.
  static const activity = OrbEvalStart._('动态', _activityArgs);

  /// A channel by key.
  factory OrbEvalStart.channel(String key) =>
      OrbEvalStart._('#$key', (d) => {'channel_id': d.idOf(key)});

  /// A private conversation by key (`dm:cody`).
  factory OrbEvalStart.dm(String key) =>
      OrbEvalStart._(key, (d) => {'dm_id': d.idOf(key)});

  /// A discussion by the id of the message it hangs under.
  factory OrbEvalStart.thread(String Function(OrbEvalData d) parent) =>
      OrbEvalStart._('讨论', (d) => {'thread_id': parent(d)});

  /// A task by its number.
  factory OrbEvalStart.task(int number) =>
      OrbEvalStart._('任务 #$number', (d) => {'task_number': number});

  final String label;
  final Map<String, Object?> Function(OrbEvalData d)? _args;

  static Map<String, Object?> _activityArgs(OrbEvalData d) => {
    'page': 'activity',
  };

  /// The `navigate` arguments that go there; null for the home screen.
  Map<String, Object?>? navigateArgs(OrbEvalData d) => _args?.call(d);
}

/// How a scenario counts in the run.
enum OrbEvalStatus {
  /// Run and scored.
  run,

  /// Not run: it needs the action tools (reply, set a task's status).
  skipped,

  /// Run and reported, but a failure does not fail the run: the feature is
  /// not built yet. A pass is flagged as unexpected.
  expectedFail,
}

/// A realtime event pushed into the fixture after the setup lines (a new
/// message arriving while the person drives).
class OrbEvalEvent {
  const OrbEvalEvent(this.name, this.payload);
  final String name;
  final Object? Function(OrbEvalData d) payload;
}

/// One thing a run is checked for.
class OrbEvalCheck {
  const OrbEvalCheck(this.label, this.test, {this.why});

  /// What is expected, in a line ("navigate(page: activity, show: true)").
  final String label;

  /// Null passes; otherwise the reason.
  final String? Function(OrbEvalRun run) test;
  final String? why;

  /// A tool was called in the scored turns with these arguments. A value is
  /// compared by equality, or by a predicate; a missing argument fails.
  factory OrbEvalCheck.tool(
    String name, {
    Map<String, Object?> args = const {},
    String? label,
  }) {
    final shown = args.isEmpty
        ? ''
        : args.entries
              .map((e) => '${e.key}: ${e.value is Function ? '…' : e.value}')
              .join(', ');
    return OrbEvalCheck(label ?? '调用 $name($shown)', (run) {
      final calls = run.tools.where((c) => c.name == name).toList();
      if (calls.isEmpty) {
        final called = run.tools.map((c) => c.name).toSet();
        return '没有调用 $name（调用了：${called.isEmpty ? '无' : called.join('、')}）';
      }
      for (final call in calls) {
        if (_argsMatch(call.args, args)) return null;
      }
      return '$name 的参数不对：${calls.map((c) => orbEvalTrim(c.args)).join(' | ')}';
    });
  }

  /// One of several tools was called (the scenario allows either way).
  factory OrbEvalCheck.anyTool(
    List<String> names, {
    Map<String, Object?> args = const {},
    String? label,
  }) => OrbEvalCheck(label ?? '调用 ${names.join(' 或 ')}', (run) {
    final calls = run.tools.where((c) => names.contains(c.name)).toList();
    if (calls.isEmpty) return '没有调用 ${names.join(' 或 ')}';
    if (args.isEmpty || calls.any((c) => _argsMatch(c.args, args))) return null;
    return '参数不对：${calls.map((c) => orbEvalTrim(c.args)).join(' | ')}';
  });

  /// A tool was not called in the scored turns.
  factory OrbEvalCheck.noTool(String name) => OrbEvalCheck(
    '不调用 $name',
    (run) => run.tools.any((c) => c.name == name) ? '调用了 $name' : null,
  );

  /// The text has every group; a group is met by any of its alternatives.
  factory OrbEvalCheck.says(List<List<String>> groups, {String? label}) =>
      OrbEvalCheck(label ?? '说到 ${groups.map((g) => g.join('/')).join('、')}', (
        run,
      ) {
        final text = _squash(run.text);
        final missing = [
          for (final g in groups)
            if (!g.any((alt) => text.contains(_squash(alt)))) g.join('/'),
        ];
        return missing.isEmpty ? null : '没有说到：${missing.join('、')}';
      });

  /// The text matches [pattern] (an alternative way to say it).
  factory OrbEvalCheck.saysMatching(RegExp pattern, String label) =>
      OrbEvalCheck(
        label,
        (run) => pattern.hasMatch(run.text) ? null : '没有说到：$label',
      );

  /// The text (of every turn) must not match [pattern].
  factory OrbEvalCheck.avoids(RegExp pattern, String label) =>
      OrbEvalCheck('不能出现 $label', (run) {
        final m = pattern.firstMatch(run.allText);
        return m == null ? null : '出现了 $label：「${m.group(0)}」';
      });

  /// The words come in this order (the first of each group that appears).
  factory OrbEvalCheck.inOrder(
    List<List<String>> groups, {
    required String label,
  }) => OrbEvalCheck(label, (run) {
    final text = _squash(run.text);
    var from = 0;
    for (final g in groups) {
      final at = [for (final alt in g) text.indexOf(_squash(alt), from)]
          .where((i) => i >= 0)
          .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
      if (at == null) return '没有按顺序说到：${g.join('/')}';
      from = at + 1;
    }
    return null;
  });

  /// At most [n] sentences in the scored turns' text.
  factory OrbEvalCheck.shortReply(int n) => OrbEvalCheck('至多 $n 句', (run) {
    final count = orbEvalSentences(run.text);
    return count <= n ? null : '说了 $count 句';
  });

  /// No raw id in anything the model said: not a UUID, not an id of the
  /// fixture.
  factory OrbEvalCheck.noIds() => OrbEvalCheck('不念 id', (run) {
    final text = run.allText;
    final uuid = RegExp(
      r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4,12}',
      caseSensitive: false,
    ).firstMatch(text);
    if (uuid != null) return '说出了一个 id：${uuid.group(0)}';
    for (final id in run.ids) {
      if (id.length >= 8 && text.contains(id)) return '说出了一个 id：$id';
    }
    return null;
  });

  /// The app sent no write (reads the app posts by itself do not count).
  factory OrbEvalCheck.noWrites() => OrbEvalCheck('不发出任何写操作', (run) {
    final writes = run.realWrites;
    return writes.isEmpty ? null : '发出了：${writes.join('、')}';
  });

  /// An action the app asks the person about first: one of [actionTools]
  /// answered `needs_confirmation` (the card is up) and no write had been sent
  /// by then; after that `confirm` was done, and the fixture recorded
  /// exactly [count] writes, all of them matching [write].
  factory OrbEvalCheck.confirmedWrite({
    required String label,
    required List<String> actionTools,
    required bool Function(OrbEvalWrite write) write,
    int count = 1,
  }) => OrbEvalCheck(label, (run) {
    final turns = run.scoredTurns.toList();
    final asked = turns.indexWhere(
      (t) => t.tools.any(
        (c) =>
            (actionTools.contains(c.name) || c.name == 'act') &&
            c.result['status'] == 'needs_confirmation',
      ),
    );
    if (asked < 0) {
      return '没有出确认卡（${actionTools.join('、')} 没有返回 needs_confirmation）';
    }
    if (turns[asked].writesAfter != 0) {
      return '确认之前就有写操作：${run.realWrites.join('、')}';
    }
    final confirmed = turns
        .skip(asked)
        .expand((t) => t.tools)
        .any((c) => c.name == 'confirm' && c.result['status'] == 'done');
    if (!confirmed) return '用户确认后没有成功调用 confirm';
    // Opening the thread a reply goes into is part of the reply.
    final sent = [
      for (final w in run.realWrites)
        if (!(w.method == 'POST' && w.path.endsWith('/threads'))) w,
    ];
    final hits = sent.where(write).toList();
    if (hits.length != count) {
      return '期望 $count 次写入，实际 ${hits.length}：${sent.join('、')}';
    }
    if (sent.length != hits.length) {
      return '还有别的写入：${sent.join('、')}';
    }
    return null;
  });

  /// The card is up and the person never confirmed: nothing was written.
  factory OrbEvalCheck.cardWithoutWrite(
    List<String> actionTools, {
    String? label,
  }) => OrbEvalCheck(label ?? '出确认卡，没确认前不写', (run) {
    final asked = run.tools.any(
      (c) =>
          (actionTools.contains(c.name) || c.name == 'act') &&
          c.result['status'] == 'needs_confirmation',
    );
    if (!asked) return '没有出确认卡';
    return run.realWrites.isEmpty ? null : '发出了：${run.realWrites.join('、')}';
  });

  /// A tool answered "停车后再做": the action was refused and nothing went out.
  factory OrbEvalCheck.refused(
    String tool,
  ) => OrbEvalCheck('$tool 驾驶中被拒绝（停车后再做）', (run) {
    final calls = run.tools.where((c) => c.name == tool).toList();
    if (calls.isEmpty) return '没有调用 $tool';
    if (!calls.every((c) => c.result['refused'] == true)) {
      return '$tool 没有被拒绝：${calls.map((c) => orbEvalTrim(c.result)).join(' | ')}';
    }
    return null;
  });

  /// A check on what the screen and the orb looked like at the end.
  factory OrbEvalCheck.screen(
    String label,
    bool Function(OrbEvalSnapshot s, OrbEvalRun run) test,
  ) => OrbEvalCheck(label, (run) {
    final s = run.last;
    if (s == null) return '没有记录到界面状态';
    return test(s, run) ? null : '界面不符：$label';
  });

  /// Free-form: returns the reason when it fails.
  factory OrbEvalCheck.custom(
    String label,
    String? Function(OrbEvalRun run) test,
  ) => OrbEvalCheck(label, test);
}

bool _argsMatch(Map<String, Object?> actual, Map<String, Object?> wanted) {
  for (final e in wanted.entries) {
    final value = actual[e.key];
    final want = e.value;
    if (want is bool Function(Object?)) {
      if (!want(value)) return false;
    } else if (value != want) {
      return false;
    }
  }
  return true;
}

String _squash(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// How many sentences [text] has (ends: 。！？!? and line breaks, and a
/// period that ends a word, not the one inside `v1.4`).
int orbEvalSentences(String text) => text
    .split(RegExp(r'[。！？!?\n]+|\.(?=\s|$)'))
    .where((part) => part.trim().isNotEmpty)
    .length;

/// One scenario of scenarios-v1.md: where the person is, what the workspace
/// holds, what they say, and what must come of it.
class OrbEvalScenario {
  const OrbEvalScenario({
    required this.id,
    required this.title,
    required this.start,
    this.data = OrbEvalData.cast,
    this.setup = const [],
    this.say = const [],
    this.events = const [],
    this.checks = const [],
    this.status = OrbEvalStatus.run,
    this.note,
    this.observe = const Duration(seconds: 8),
  });

  /// `A1` ... `E5`.
  final String id;
  final String title;
  final OrbEvalStart start;

  /// The workspace this scenario runs in; a fresh one for every run.
  final OrbEvalData Function() data;

  /// Said first, not scored (entering driving mode before the scored line).
  final List<String> setup;

  /// The scored lines. Empty when an event is the trigger.
  final List<String> say;

  /// Pushed after the setup lines; the run then watches for [observe].
  final List<OrbEvalEvent> events;
  final List<OrbEvalCheck> checks;
  final OrbEvalStatus status;

  /// Why it is skipped or expected to fail ("needs actions", "not built").
  final String? note;
  final Duration observe;

  String get group => id.substring(0, 1);
}
