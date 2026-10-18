import '../../agent_mode/key_info.dart' show keyCompact;
import '../orb_key_info.dart';
import 'orb_eval_data.dart';
import 'orb_eval_run.dart';
import 'orb_eval_world.dart' show OrbEvalWrite;

/// The names of the fixture's people (but the person themself): another one
/// in what was spoken is a person the answer did not have.
final orbEvalPeople = [
  for (final p in evalPeople)
    if (p != evalMe && !p.system) p.name,
];

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

  /// What is expected, in a line ("get_briefing(show: true)").
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
        (run) => orbEvalMatches(pattern, run.text) ? null : '没有说到：$label',
      );

  /// The text (of every turn) must not match [pattern].
  factory OrbEvalCheck.avoids(RegExp pattern, String label) =>
      OrbEvalCheck('不能出现 $label', (run) {
        final m = orbEvalFirstMatch(pattern, run.allText);
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

  /// The layered harness: what was spoken carries the key information of what
  /// the agent said, in whatever words: every number, every Latin name and,
  /// for a confirmation card, what it does, to whom, the exact words and that
  /// it asks for a yes (taken from the card's preview, not from the text). A
  /// paraphrase, another order, filler words are fine; a missing fact or a
  /// number or a person the answer does not have is not. What was spoken is
  /// the voice's transcript and the sentences the app's own voice was asked
  /// for. Applied to every scenario of that harness.
  factory OrbEvalCheck.keyInfoSpoken() =>
      OrbEvalCheck('说出了 Agent 那句话的关键信息（数字、人名、确认卡的动作、对象、内容、要不要确认），措辞不限', (run) {
        final problems = <String>[];
        for (final t in run.turns) {
          if (t.line == '（事件）') continue;
          if (t.asks.isEmpty) {
            problems.add('「${t.line}」没有交给 Agent');
            continue;
          }
          final say = t.asks.map((a) => a.say).join(' ');
          if (say.trim().isEmpty) continue;
          var info = orbSayKeyInfo(say);
          for (final c in t.tools) {
            final card = orbCardKeyInfoOfResult(c.name, c.args, c.result);
            if (card != null) info += card;
          }
          final spoken = '${t.text} ${t.spoken.join(' ')}';
          final missing = info.missingIn(spoken);
          // A person the agent named is its own, in whatever script.
          final sayCompact = keyCompact(say);
          final wrong = info.contradictionsIn(
            spoken,
            knownNames: [
              for (final p in orbEvalPeople)
                if (!sayCompact.contains(keyCompact(p))) p,
            ],
          );
          if (missing.isEmpty && wrong.isEmpty) continue;
          problems.add(
            '「${t.line}」'
            '${missing.isEmpty ? '' : '漏了：${missing.join('、')}'}'
            '${missing.isNotEmpty && wrong.isNotEmpty ? '；' : ''}'
            '${wrong.isEmpty ? '' : '不对：${wrong.join('、')}'}'
            '（say「$say」；说出「${spoken.trim()}」）',
          );
        }
        return problems.isEmpty ? null : problems.join('；');
      });

  /// "说到的东西，屏幕上都有对应" (driving): every person and every number that
  /// is spoken in a driving turn is on the screen at the end of that turn, in
  /// the cards, the rows, the open detail or the heading ([OrbEvalSnapshot]),
  /// unless the person said it themselves. What a voice speaks and what a
  /// person glances at must be the same things.
  factory OrbEvalCheck.spokenIsShown() => OrbEvalCheck('说到的人和数字，屏幕上都有（驾驶中）', (
    run,
  ) {
    final problems = <String>[];
    for (final t in run.scoredTurns) {
      final snap = t.after;
      if (snap == null || !snap.driving) continue;
      final spoken = '${t.text} ${t.spoken.join(' ')}'.trim();
      if (spoken.isEmpty) continue;
      final screen = _screenWords(snap);
      final said = keyCompact(t.line);
      final missing = <String>[];
      for (final p in orbEvalPeople) {
        if (spoken.toLowerCase().contains(p.toLowerCase()) &&
            !keyCompact(screen).contains(keyCompact(p)) &&
            !said.contains(keyCompact(p))) {
          missing.add(p);
        }
      }
      final onScreen = RegExp(r'\d+').allMatches(screen).map((m) => m[0]!);
      final shownNumbers = onScreen.toSet();
      for (final m in RegExp(r'\d+').allMatches(spoken)) {
        final n = m[0]!;
        if (!shownNumbers.contains(n) && !t.line.contains(n)) {
          missing.add(n);
        }
      }
      if (missing.isNotEmpty) {
        problems.add(
          '「${t.line}」说到了屏幕上没有的：${missing.toSet().join('、')}'
          '（屏幕：${snap.surface} ${snap.listTitle}${snap.listTotal > 0 ? ' ${snap.listTotal}' : ''}）',
        );
      }
    }
    return problems.isEmpty ? null : problems.join('；');
  });

  /// A turn whose ask to the agent took long was not met with silence: the
  /// voice (a lead-in of its own, or the app's acknowledgment) was heard
  /// before the answer was back, and within [within] of the person's words.
  /// Applied to every scenario of the layered harness.
  factory OrbEvalCheck.feedbackWhenSlow({
    Duration slow = const Duration(milliseconds: 1500),
    Duration within = const Duration(milliseconds: 1500),
  }) => OrbEvalCheck('Agent 慢的时候不是一片沉默（先出声：接话或确认）', (run) {
    final problems = <String>[];
    for (final t in run.scoredTurns) {
      if (t.asks.isEmpty || t.askMs < slow.inMilliseconds) continue;
      final first = t.firstVoiceMs;
      if (first <= 0) {
        problems.add('「${t.line}」Agent 用了 ${t.askMs}ms，这期间没有出过声');
      } else if (first > t.askMs) {
        problems.add('「${t.line}」第一声在 ${first}ms，Agent 在 ${t.askMs}ms 就答了');
      } else if (first > within.inMilliseconds) {
        problems.add(
          '「${t.line}」第一声在 ${first}ms，晚于 ${within.inMilliseconds}ms',
        );
      }
    }
    return problems.isEmpty ? null : problems.join('；');
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

/// [s] for comparing words: no spaces at all (a transcript puts them between
/// words: "要发 吗？"), full-width letters, digits and punctuation as
/// half-width, lower case.
String _squash(String s) => orbEvalCompact(s, punctuation: true).toLowerCase();

/// [s] without any space (also the ideographic and no-break ones), and the
/// full-width letters and digits as ordinary ones; with [punctuation] the
/// full-width punctuation too ("？" as "?", "，" as ",").
String orbEvalCompact(String s, {bool punctuation = false}) {
  final out = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x20 || r == 0x3000 || r == 0xA0 || (r >= 0x09 && r <= 0x0D)) {
      continue;
    }
    final wide = r >= 0xFF01 && r <= 0xFF5E;
    final letterOrDigit =
        (r >= 0xFF10 && r <= 0xFF19) ||
        (r >= 0xFF21 && r <= 0xFF3A) ||
        (r >= 0xFF41 && r <= 0xFF5A);
    out.writeCharCode(wide && (punctuation || letterOrDigit) ? r - 0xFEE0 : r);
  }
  return out.toString();
}

/// The first match of [pattern] in [text] as it was said, without spaces, or
/// with the punctuation made half-width or full-width: a pattern written with
/// "?" or "？" finds either.
RegExpMatch? orbEvalFirstMatch(RegExp pattern, String text) {
  final compact = orbEvalCompact(text);
  return pattern.firstMatch(compact) ??
      pattern.firstMatch(orbEvalCompact(text, punctuation: true)) ??
      // A pattern written with the full-width mark finds the half-width one.
      pattern.firstMatch(
        compact.replaceAllMapped(
          RegExp(r'[,!?:;()]'),
          (m) => String.fromCharCode(m[0]!.codeUnitAt(0) + 0xFEE0),
        ),
      );
}

bool orbEvalMatches(RegExp pattern, String text) =>
    orbEvalFirstMatch(pattern, text) != null;

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

/// Everything of the screen a person can read in [s]: the heading and count of
/// the list, its rows, the open detail, the cards of the deck and how many
/// there are, the page of the new arrival.
String _screenWords(OrbEvalSnapshot s) {
  final b = StringBuffer()
    ..write('${s.listTitle} ${s.listTotal} ${s.page + 1} ')
    ..write('${s.cards.length} ${s.cards.isEmpty ? '' : s.drivingIndex + 1} ');
  for (final c in s.cards) {
    b.write('${c.values.join(' ')} ');
  }
  for (final r in s.rows) {
    b.write('${r.values.join(' ')} ');
  }
  if (s.detail != null) b.write('${s.detail!.values.join(' ')} ');
  if (s.arrival != null) b.write(s.arrival);
  return '$b';
}

/// What the voice says to fill a wait.
final _filler = RegExp(
  r"let me (?:check|see|look)|checking|one moment|hold on|稍等|等一下|等我一下|我看一下|我查一下|让我(?:看|查|找)|马上",
  caseSensitive: false,
);

/// The voice said a filler and nothing like what the agent gave it to say:
/// its words are less than half like any `say` of the turn, and are a known
/// way to say "wait".
bool orbEvalLiveFiller(OrbEvalTurn turn) {
  if (turn.asks.isEmpty || turn.text.trim().isEmpty) return false;
  final spoken = orbEvalWords(turn.text);
  for (final a in turn.asks) {
    final say = orbEvalWords(a.say);
    if (say.isNotEmpty && orbEvalSimilarity(say, spoken) >= .5) return false;
  }
  return _filler.hasMatch(turn.text);
}

/// [text] for comparing what was said: lower case, without spaces and
/// punctuation (a spoken transcript and a written line differ in those).
String orbEvalWords(String text) => text.toLowerCase().replaceAll(
  RegExp(r'[\s,，.。!！?？、;；:：“”"\x27‘’「」『』（）()\[\]【】~～…—-]+'),
  '',
);

/// How like [needle] the most alike stretch of [haystack] is, 0 to 1: one
/// minus the fewest edits that turn [needle] into some part of [haystack],
/// over the length of [needle] (so words around it do not count against it).
double orbEvalSimilarity(String needle, String haystack) {
  final n = needle.runes.toList();
  final h = haystack.runes.toList();
  if (n.isEmpty) return 1;
  // Row 0 is free along the haystack: the match may start anywhere.
  var prev = List<int>.filled(h.length + 1, 0);
  for (var i = 1; i <= n.length; i++) {
    final cur = List<int>.filled(h.length + 1, 0)..[0] = i;
    for (var j = 1; j <= h.length; j++) {
      final cost = n[i - 1] == h[j - 1] ? 0 : 1;
      cur[j] = [
        prev[j - 1] + cost,
        prev[j] + 1,
        cur[j - 1] + 1,
      ].reduce((a, b) => a < b ? a : b);
    }
    prev = cur;
  }
  final best = prev.reduce((a, b) => a < b ? a : b);
  return 1 - best / n.length;
}

/// The numbers and the Latin names in [words] (already normalized): what a
/// transcript must not lose.
List<String> orbEvalFacts(String words) => [
  for (final m in RegExp(r'\d+|[a-z][a-z\-]{1,}').allMatches(words))
    m.group(0)!,
];
