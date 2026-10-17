import '../agent_mode/agent_steering.dart';
import '../agent_mode/app_speech.dart' show orbSentences;
import 'orb_agent_review.dart' show orbAsksNeeds, orbBriefingOf;

/// What a fact is about: it decides how the app says it when the answer left
/// it out.
enum OrbFactKind {
  who,
  topic,
  action,
  time,
  task,
  status,
  owner,
  speaker,
  outcome,
}

/// One thing the answer has to convey, in the words it may be conveyed in.
class OrbFact {
  OrbFact(
    this.any, {
    String? say,
    this.kind,
    this.value,
    this.subject = '',
    this.group = 0,
  }) : say = say ?? any.first;

  /// What it is about, and the bare value (the name, the step, the verb ...).
  final OrbFactKind? kind;
  final String? value;

  /// Whom the thing it belongs to is about (the one who asks), and which of
  /// the things read it is (0 for the first).
  final String subject;
  final int group;

  /// Any of these (spaces and punctuation aside) says it; the first is the
  /// plainest.
  final List<String> any;

  /// How the app says it when the answer left it out.
  final String say;

  /// What it is, shortly.
  String get shown => any.first;

  bool isIn(String reply) {
    final text = _norm(reply);
    return any.any((a) => text.contains(_norm(a)));
  }
}

String _norm(String s) => s.toLowerCase().replaceAll(
  RegExp(r'[\s,，.。!！?？、;；:：“”"\x27‘’「」『』（）()\[\]【】~～…—-]+'),
  '',
);

/// What is read here is looked at for facts: the tools that bring something
/// the person asked about.
const _reads = {
  'navigate',
  'describe_page',
  'read_conversation',
  'task_detail',
  'get_briefing',
};

/// How a task's state is said: the words an answer may use for it.
const _statusWords = <String, List<String>>{
  'in_review': ['验收', '评审', 'review', '审阅', '等你审', '等审'],
  'in_progress': ['进行中', '在做', '正在做', '处理中', '做着'],
  'todo': ['待办', '没开始', '等开始', 'todo'],
  'done': ['完成', '做完', '已完成', 'done'],
  'closed': ['关闭', '关掉', '已关', 'closed'],
};

const _statusByText = <String, String>{
  '等验收': 'in_review',
  '进行中': 'in_progress',
  '待办': 'todo',
  '已完成': 'done',
  '已关闭': 'closed',
};

/// The state, as the person hears it: 等验收, 进行中 ...
const _statusSay = <String, String>{
  'in_review': '等验收',
  'in_progress': '进行中',
  'todo': '待办',
  'done': '已完成',
  'closed': '已关闭',
};

/// What an item asks, said in a few ways each.
const _actions = <String, List<String>>{
  '合入': ['合入', '合并', 'merge', '并入', '合进'],
  '合并': ['合入', '合并', 'merge', '并入', '合进'],
  '批准': ['批准', '通过', '同意', 'approve'],
  '评审': ['评审', '验收', 'review', '审阅', '审'],
  '验收': ['验收', '评审', 'review', '审阅', '审'],
  '发布': ['发布', '上线', 'release'],
};

/// The step, task, version or weekday a line is about.
final _topics = RegExp(
  r'第\s*\d+\s*步|#\d+|v\d+(?:\.\d+)+|方案\s*[A-Za-z]|周[一二三四五六日天]|星期[一二三四五六日天]',
  caseSensitive: false,
);

/// "第 10 步" is also said "第10步" and "10 步".
List<String> _topicForms(String t) {
  final step = RegExp(r'第\s*(\d+)\s*步').firstMatch(t);
  if (step != null) {
    final n = step.group(1)!;
    return [t, '第$n步', '$n步'];
  }
  final plan = RegExp(r'方案\s*([A-Za-z])').firstMatch(t);
  if (plan != null) return [t, '方案${plan.group(1)}'];
  return [t];
}

/// "已等 20 分钟" → "20 分钟" (and "20分钟"); null when it has no number.
OrbFact? _timeFact(Object? since) {
  if (since is! String) return null;
  final m = RegExp(r'(\d+)\s*(分钟|小时|天)').firstMatch(since);
  if (m == null) return null;
  final t = '${m.group(1)}${m.group(2)}';
  return OrbFact(
    [t, if (t == '1分钟') '刚刚'],
    say: '等了 ${m.group(1)} ${m.group(2)}',
    kind: OrbFactKind.time,
    value: '${m.group(1)} ${m.group(2)}',
  );
}

/// The facts of one thing that needs the person: who, what, how long.
/// (public: the context given to the agent before each ask carries them)
List<OrbFact> orbItemFacts(Map item, {int group = 0}) {
  final who = '${item['who'] ?? ''}'.trim();
  final text = '${item['title'] ?? ''} ${item['ask'] ?? ''}';
  final facts = <OrbFact>[
    if (who.isNotEmpty)
      OrbFact([who], kind: OrbFactKind.who, value: who, subject: who),
  ];
  final seen = <String>{};
  for (final m in _topics.allMatches(text)) {
    final t = m.group(0)!;
    if (seen.add(_norm(t))) {
      facts.add(
        OrbFact(
          _topicForms(t),
          kind: OrbFactKind.topic,
          value: t.replaceAll(RegExp(r'\s+'), ' '),
        ),
      );
    }
  }
  final verbs = <String>{};
  for (final e in _actions.entries) {
    if (text.contains(e.key) && verbs.add(e.value.first)) {
      facts.add(
        OrbFact(e.value, say: e.key, kind: OrbFactKind.action, value: e.key),
      );
    }
  }
  final time = _timeFact(item['since']);
  if (time != null) facts.add(time);
  return [
    for (final f in facts)
      OrbFact(
        f.any,
        say: f.say,
        kind: f.kind,
        value: f.value,
        subject: who,
        group: group,
      ),
  ];
}

/// The facts of a task: which, how it stands, who has it.
List<OrbFact> _taskFacts(Map task) {
  final title = '${task['title'] ?? ''}'.trim();
  final number = task['number'];
  final raw = '${task['status'] ?? ''}';
  final text = '${task['statusText'] ?? ''}';
  final status = _statusWords.containsKey(raw) ? raw : _statusByText[text];
  final owner = '${task['assignee'] ?? ''}'.trim();
  return [
    if (title.isNotEmpty || number != null)
      OrbFact(
        [
          if (title.isNotEmpty) title,
          if (number != null) ...['#$number', '$number'],
        ],
        say:
            '任务${number == null ? '' : ' #$number'}${title.isEmpty ? '' : '「$title」'}',
        kind: OrbFactKind.task,
      ),
    if (status != null)
      OrbFact(
        _statusWords[status]!,
        say: '${_statusSay[status]}',
        kind: OrbFactKind.status,
        value: status,
      ),
    if (owner.isNotEmpty)
      OrbFact([owner], say: '$owner 负责', kind: OrbFactKind.owner, value: owner),
  ];
}

/// "定了什么", "结论": what was settled in a conversation.
final _asksOutcome = RegExp(r'定了什么|结论|决定|怎么定');

/// The facts of the last thing somebody else said: who, and the step, plan or
/// version in it.
List<OrbFact> _outcomeFacts(List<Map> messages) {
  Map? last;
  for (final m in messages.reversed) {
    if (m['fromMe'] != true && m['system'] != true && m['from'] is String) {
      last = m;
      break;
    }
  }
  if (last == null) return const [];
  final facts = <OrbFact>[
    OrbFact(
      ['${last['from']}'],
      kind: OrbFactKind.speaker,
      value: '${last['from']}',
    ),
  ];
  final seen = <String>{};
  for (final m in _topics.allMatches('${last['text']}')) {
    final t = m.group(0)!;
    if (seen.add(_norm(t))) {
      facts.add(
        OrbFact(
          _topicForms(t),
          kind: OrbFactKind.outcome,
          value: t.replaceAll(RegExp(r'\s+'), ' '),
        ),
      );
    }
  }
  return facts;
}

/// The messages and task a read result holds, wherever the tool put them.
Map? _taskOf(AgentToolRun r) {
  final direct = r.result['task'];
  if (r.name == 'task_detail' && direct is Map) return direct;
  final page = r.name == 'navigate' ? r.result['page'] : r.result;
  if (page is Map && page['page'] == 'task' && page['task'] is Map) {
    return page['task'] as Map;
  }
  return null;
}

List<Map> _messagesOf(AgentToolRun r) {
  final page = r.name == 'navigate' ? r.result['page'] : r.result;
  return [
    if (page is Map)
      for (final m in (page['messages'] as List? ?? const []))
        if (m is Map) m,
  ];
}

/// What the answer to [said] has to convey, from what the turn read: the
/// facts of the things that need the person when that was asked; else of the
/// primary object of the last read (a task); else of what was settled in a
/// conversation when that was asked. Empty for small talk, for a turn that read
/// nothing, and for a read that found nothing.
List<OrbFact> orbKeyFacts(List<AgentToolRun> runs, {required String said}) {
  if (runs.any((r) => r.result['loading'] == true)) return const [];
  // 1. What needs the person.
  if (orbAsksNeeds.hasMatch(said)) {
    final b = orbBriefingOf(runs);
    final items = [
      for (final i in (b?['needsYou'] as List? ?? const []))
        if (i is Map) i,
    ];
    if (items.isNotEmpty) {
      return [
        for (final (n, i) in items.take(3).indexed)
          ...orbItemFacts(i, group: n),
      ];
    }
  }
  AgentToolRun? last;
  for (final r in runs.reversed) {
    if (_reads.contains(r.name) && r.result['error'] == null) {
      last = r;
      break;
    }
  }
  if (last == null) return const [];
  // 2. The task the last read opened.
  final task = _taskOf(last);
  if (task != null) return _taskFacts(task);
  // 3. What a conversation settled.
  if (_asksOutcome.hasMatch(said) &&
      (last.name == 'read_conversation' || last.name == 'describe_page')) {
    return _outcomeFacts(_messagesOf(last));
  }
  return const [];
}

/// The short strings a result carries for the model.
List<String> orbKeyFactStrings(List<OrbFact> facts) => [
  for (final f in facts) f.say,
];

/// The facts [reply] leaves out.
List<OrbFact> orbMissingFacts(List<OrbFact> facts, String reply) => [
  for (final f in facts)
    if (!f.isIn(reply)) f,
];

/// How a task stands, as a clause that reads aloud.
const _statusClause = <String, String>{
  'in_review': '在等你验收',
  'in_progress': '还在进行中',
  'todo': '还没开始',
  'done': '已经完成了',
  'closed': '已经关闭了',
};

/// What an item asks, as a clause that reads aloud ("在问第 10 步能不能合入",
/// "在等你批准").
String _askClause(String verb, String topic) => switch (verb) {
  '合入' || '合并' || '发布' => '在问$topic能不能$verb',
  _ => '在等你$verb$topic',
};

/// The clauses of the facts [g] of one thing leaves out, as they are said:
/// "Cody 找你，在问第 10 步能不能合入，已经等了 20 分钟". [named]: more than
/// one thing is being added to, so "he" would not say which.
List<String> _clauses(List<OrbFact> g, {required bool named}) {
  Iterable<OrbFact> of(OrbFactKind k) => g.where((f) => f.kind == k);
  OrbFact? one(OrbFactKind k) => of(k).firstOrNull;
  final out = <String>[];
  final who = one(OrbFactKind.who);
  final speaker = one(OrbFactKind.speaker);
  if (who != null) out.add('${who.value} 找你');
  if (speaker != null) out.add('是 ${speaker.value} 定的');
  final outcome = [for (final f in of(OrbFactKind.outcome)) f.value];
  if (outcome.isNotEmpty) out.add('定的是${outcome.join('、')}');
  final topics = [for (final f in of(OrbFactKind.topic)) f.value].join('、');
  final action = one(OrbFactKind.action);
  if (action != null) {
    final subject = who != null
        ? ''
        : (named && g.first.subject.isNotEmpty ? g.first.subject : '他');
    out.add('$subject${_askClause(action.value!, topics)}');
  } else if (topics.isNotEmpty) {
    out.add('这是$topics的事');
  }
  final time = one(OrbFactKind.time);
  if (time != null) out.add('已经等了 ${time.value}');
  final task = one(OrbFactKind.task);
  final status = one(OrbFactKind.status);
  final clause = status == null ? null : _statusClause[status.value];
  if (task != null && clause != null) {
    out.add('${task.say}$clause');
  } else if (task != null) {
    out.add('这是${task.say}');
  } else if (clause != null) {
    out.add('这件$clause');
  }
  final owner = one(OrbFactKind.owner);
  if (owner != null) out.add('由 ${owner.value} 负责');
  return out;
}

/// The one short sentence that adds what [missing] says, worded for the ear
/// ("他在等你批准。", "这件在等你验收。", "已经等了 20 分钟。"): a clause per
/// kind of fact, which of the things read they belong to kept apart. Never
/// more than two things; a fact of no known kind is said as it is.
String orbFactsSentence(List<OrbFact> missing) {
  final groups = <int, List<OrbFact>>{};
  final plain = <String>[];
  for (final f in missing) {
    if (f.kind == null) {
      plain.add(f.say);
    } else {
      groups.putIfAbsent(f.group, () => []).add(f);
    }
  }
  final named = groups.length > 1;
  final parts = [
    for (final g in groups.values.take(2)) _clauses(g, named: named).join('，'),
    if (plain.isNotEmpty) plain.join('，'),
  ].where((p) => p.isNotEmpty);
  return '${parts.join('；')}。';
}

/// [reply] with [sentence] put in: before the question it ends with when it
/// ends with one ("…。他在等你批准。要回复他吗？"), else after it.
String orbWithSentence(String reply, String sentence) {
  final sentences = orbSentences(reply);
  final last = sentences.isEmpty ? null : sentences.last;
  if (last != null && RegExp(r'[？?]$').hasMatch(last)) {
    final at = reply.lastIndexOf(last);
    return '${reply.substring(0, at)}$sentence${reply.substring(at)}';
  }
  final t = reply.trimRight();
  final ended = t.isEmpty || RegExp(r'[。！？!?…]$').hasMatch(t) ? t : '$t。';
  return '$ended$sentence';
}
