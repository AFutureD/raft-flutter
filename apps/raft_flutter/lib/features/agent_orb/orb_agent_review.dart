import '../agent_mode/agent_steering.dart';
import 'orb_key_facts.dart';
import 'briefing/orb_briefing_models.dart' show OrbBriefScope, OrbBriefing;

/// The model asked "要发吗？" (or the like) as a question to the person.
final orbAsksToConfirm = RegExp(r'要发吗|要改吗|确认吗|要不要发|要我发|你确认|确认要|发吗[？?]|改吗[？?]');

/// The model says something was sent or changed.
final _claimsDone = RegExp(
  r'已发送|已经发送|已经发了|已发出|发出去了|发好了|已回复|已改|改好了|已经改|已标|标好了|已催|已记下|记下了',
);

final _saysNothingToDo = RegExp(r'没有.{0,8}(处理|回复|找你|新的|要紧)');
final _saysLoading = RegExp(r'加载|稍等|稍后|等一下|等等|还没读|读不到|没读出来');
final _taskWords = RegExp(r'个任务|任务在等|等你验收|待验收|验收');

/// The person is asking what is new, what matters, what waits for them.
final orbAsksWhatMatters = RegExp(
  r'新的|新消息|要紧|紧急|重要|处理|找我|等我|等着我|有什么事|有事吗|简报|最近|怎么样了|通知|待办',
);

/// The place a turn read, whichever of the reading tools it used
/// (`describe_page`, `read_conversation`): the Activity, or one conversation.
/// The last read counts. Null when it read neither, or the page was still
/// loading or could not be read.
OrbBriefScope? orbPageScope(List<AgentToolRun> runs) {
  for (final r in runs.reversed) {
    if (r.name != 'describe_page' && r.name != 'read_conversation') continue;
    if (r.result['error'] != null || r.result['loading'] == true) return null;
    if (r.result['page'] == 'activity') return OrbBriefScope.activity;
    final c = r.result['conversation'];
    if (c is Map && c['id'] is String) {
      return OrbBriefScope.conversation(c['id'] as String);
    }
    return null;
  }
  return null;
}

/// [runs] with the briefing of the place the model read, when it read it
/// instead of asking for the briefing and the person asked what is new or what
/// matters: the empty line and the order are the app's whichever tool the model
/// reached for. [brief] reads the briefing (the rules' sentences are enough);
/// when it fails, [runs] come back as they are.
Future<List<AgentToolRun>> orbWithBriefing(
  List<AgentToolRun> runs, {
  required String said,
  required Future<OrbBriefing> Function(OrbBriefScope scope) brief,
  OrbBriefScope? Function()? screen,
  Map<String, Object?>? Function(OrbBriefScope scope)? cached,
}) async {
  if (!(orbAsksWhatMatters.hasMatch(said) || orbLooksAtDm.hasMatch(said)) ||
      orbBriefingOf(runs) != null) {
    return runs;
  }
  // What it read; failing that (it answered from what it knew), the place the
  // person is on, unless a read said that place could not be read yet.
  final read = runs.any(
    (r) => r.name == 'describe_page' || r.name == 'read_conversation',
  );
  // Asked what needs the person, with no read and no page that says: it is
  // the Activity.
  final scope =
      orbPageScope(runs) ??
      (read
          ? null
          : (screen?.call() ??
                (orbAsksNeeds.hasMatch(said) ? OrbBriefScope.activity : null)));
  if (scope == null) return runs;
  // What the app already holds of that place is as good as a new read.
  final held = cached?.call(scope);
  if (held != null) {
    return [...runs, AgentToolRun('get_briefing', const {}, held)];
  }
  try {
    final b = await brief(scope);
    return [
      ...runs,
      AgentToolRun('get_briefing', const {}, b.toJson(ordered: true)),
    ];
  } on Object {
    return runs;
  }
}

/// The briefing a turn read, the last one: the map `get_briefing` returned or
/// the one `navigate` brought along. Null when none, or when it was not read
/// (an error, a page still loading).
Map<String, Object?>? orbBriefingOf(List<AgentToolRun> runs) {
  if (runs.any((r) => r.result['loading'] == true)) return null;
  for (final r in runs.reversed) {
    if (r.result['error'] != null || r.result['briefingNote'] != null) continue;
    final inner = r.result['briefing'];
    final b = r.name == 'get_briefing'
        ? r.result
        : r.name == 'navigate' && inner is Map
        ? inner.cast<String, Object?>()
        : null;
    if (b != null && b['needsYou'] is List) return b;
  }
  return null;
}

/// What the app makes of the words a turn ends with (the agent layer):
///
/// - a question "要发吗？" with no card up: the model is told once to call the
///   action tool first;
/// - "已发送" with a card still up and no `confirm` that was done: told once
///   that nothing was sent;
/// - a briefing that has nothing for the person: the line "没有要你处理的"
///   starts the reply, whatever the model made of it;
/// - tasks that wait: they come last, in a sentence of their own.
AgentReview? orbReviewReply(
  String reply,
  List<AgentToolRun> runs, {
  required bool cardUp,
  bool driving = false,
  String said = '',
  bool retries = true,
  bool inboxUnread = false,
}) {
  final loading = _stillLoading(reply, runs, said, inboxUnread);
  if (loading != null) return loading;
  final r = _reviewReply(
    reply,
    runs,
    cardUp: cardUp,
    driving: driving,
    said: said,
  );
  // A voice does not wait for a second round trip to the model when the app
  // has the words ready: they are said at once.
  if (!retries && r != null && r.retry != null && r.text != null) {
    return AgentReview(text: r.text);
  }
  return r;
}

/// Whether the words a turn is still writing ([draft], the model's text of
/// this step so far) may be spoken before the turn is over: the review of
/// [orbReviewReply] would not change their beginning. True only when the review
/// has nothing to change for [runs] (probed with a bare "好的。"; a briefing
/// to add, key facts to add, words to put first all show there), the person
/// asked nothing the review answers from a briefing the model has not read,
/// and the draft says none of what makes the review retry or replace (a
/// question to confirm, "已发送", "没有……", "加载"). [cardUp], [driving] and
/// [said] are what the review is given.
bool orbStreamSafe(
  List<AgentToolRun> runs,
  String draft, {
  required bool cardUp,
  bool driving = false,
  String said = '',
}) {
  if ((orbAsksWhatMatters.hasMatch(said) || orbLooksAtDm.hasMatch(said)) &&
      orbBriefingOf(runs) == null) {
    // The review may fetch the briefing itself and put its words first.
    return false;
  }
  final probe = orbReviewReply(
    '好的。',
    runs,
    cardUp: cardUp,
    driving: driving,
    said: said,
  );
  if (probe != null) return false;
  return !(orbAsksToConfirm.hasMatch(draft) ||
      _claimsDone.hasMatch(draft) ||
      _claimsEmpty.hasMatch(draft) ||
      _saysLoading.hasMatch(draft));
}

/// The reply says there is nothing, but what it was told by is a page that is
/// still loading, or nothing has been read of the Activity yet ([inboxUnread],
/// no tool read anything): "not read" is not "empty". The app says it is
/// loading.
final _claimsEmpty = RegExp(
  r'没有(?:任何)?(?:新|消息|内容|要你处理|需要你处理|动态)|什么都没有|空空|静悄悄|没什么(?:新|事)|都在偷懒',
);

AgentReview? _stillLoading(
  String reply,
  List<AgentToolRun> runs,
  String said,
  bool inboxUnread,
) {
  if (!orbAsksWhatMatters.hasMatch(said) || !_claimsEmpty.hasMatch(reply)) {
    return null;
  }
  if (_saysLoading.hasMatch(reply)) return null;
  final loading =
      runs.any((r) => r.result['loading'] == true) ||
      (inboxUnread && runs.isEmpty);
  return loading ? const AgentReview(text: '动态还在加载，稍后再看。') : null;
}

AgentReview? _reviewReply(
  String reply,
  List<AgentToolRun> runs, {
  required bool cardUp,
  required bool driving,
  required String said,
}) {
  final text = reply.trim();
  // A turn that ended without a word after a tool: told once, and when that
  // gets nothing either, the app says what the tool found.
  if (text.isEmpty && runs.isNotEmpty) {
    return AgentReview(
      retry: '（App 提示，不是用户的话：你调用了工具，但还没有回答用户。根据工具返回的结果，用一两句话回答他。）',
      text:
          orbSummarize(runs, driving: driving) ??
          (orbAsksToReadList(said) ? _listRead('', runs, said)?.text : null),
    );
  }
  final madeCard = runs.any((r) => r.result['status'] == 'needs_confirmation');
  if (!cardUp && !madeCard && orbAsksToConfirm.hasMatch(text)) {
    return const AgentReview(
      retry:
          '（App 提示，不是用户的话：你问了要不要发，但还没有调用动作工具，屏幕上没有确认卡，用户说“确认”也发不出去。'
          '现在调用对应的动作工具（send_message、reply_in_thread、set_task_status 等），它只会出确认卡，不会执行；'
          '调用之后 App 会替你复述并问他，你不用再说。）',
    );
  }
  final confirmed = runs.any(
    (r) => r.name == 'confirm' && r.result['status'] == 'done',
  );
  if (cardUp && !confirmed && _claimsDone.hasMatch(text)) {
    return const AgentReview(
      retry:
          '（App 提示，不是用户的话：你说已经做了，但这一轮没有成功调用 confirm，什么都没有发生，确认卡还在屏幕上。'
          '用户明确同意了就调用 confirm；还没有，就如实说还没发，再问他一次。）',
    );
  }
  final listed =
      _listRead(text, runs, said) ??
      _needsRead(text, runs, said) ??
      _dmGlance(text, runs, said) ??
      _taskListRead(text, runs, said, driving);
  if (listed != null) return listed;
  // Whatever the person asked about: its key facts are in the answer.
  final missing = orbMissingFacts(orbKeyFacts(runs, said: said), text);
  if (missing.isNotEmpty) {
    // Added at once: a round trip to the model costs seconds, and the app
    // knows the fact.
    final added = orbWithSentence(text, orbFactsSentence(missing));
    return AgentReview(text: _polish(added, runs) ?? added);
  }
  final polished = _polish(text, runs);
  return polished == null ? null : AgentReview(text: polished);
}

String? _polish(String reply, List<AgentToolRun> runs) {
  final b = orbBriefingOf(runs);
  if (b == null) return null;
  var text = reply;
  final needs = (b['needsYou'] as List).length;
  final waiting = b['waitingTasks'] is int ? b['waitingTasks'] as int : 0;
  if (needs == 0 &&
      !_saysNothingToDo.hasMatch(text) &&
      !_saysLoading.hasMatch(text)) {
    text = '没有要你处理的。$text';
  }
  // The user asked about tasks themselves: leave the order to them.
  final askedTasks = runs.any(
    (r) => r.name == 'list_tasks' || r.name == 'task_detail',
  );
  if (waiting > 0 && !askedTasks) {
    final titles = [
      for (final t in (b['waitingTaskTitles'] as List? ?? const [])) '$t',
    ];
    text = _tasksLast(text, titles, waiting);
  }
  return text == reply ? null : text;
}

/// The sentences that are about the waiting tasks go after all the others; a
/// reply that does not mention them gets the one line.
String _tasksLast(String text, List<String> titles, int waiting) {
  final sentences = [
    for (final m in RegExp(r'[^。！？!?\n]+[。！？!?]*').allMatches(text))
      m.group(0)!.trim(),
  ]..removeWhere((s) => s.isEmpty);
  bool isTask(String s) =>
      titles.any((t) => t.isNotEmpty && s.contains(t)) ||
      _taskWords.hasMatch(s);
  final tasks = [
    for (final s in sentences)
      if (isTask(s)) s,
  ];
  final others = [
    for (final s in sentences)
      if (!isTask(s)) s,
  ];
  final lastOther = sentences.lastIndexWhere((s) => !isTask(s));
  final firstTask = sentences.indexWhere(isTask);
  final inOrder = tasks.isEmpty || firstTask > lastOther;
  if (tasks.isNotEmpty && inOrder) return text;
  final tail = tasks.isEmpty
      ? ['${OrbBriefing.waitingTasksTail(waiting)}。']
      : tasks;
  String end(String s) => RegExp(r'[。！？!?]$').hasMatch(s) ? s : '$s。';
  return [
    for (final s in [...others, ...tail]) end(s),
  ].join();
}

/// What the last tool of a turn found, in words, for when the model said
/// nothing: a task list (how many, and for each who has it and what it waits
/// for), one task, or the briefing's overview. At most two sentences, and
/// three tasks while [driving]. Null when there is nothing to say.
String? orbSummarize(List<AgentToolRun> runs, {bool driving = false}) {
  for (final r in runs.reversed) {
    if (r.result['error'] != null) continue;
    switch (r.name) {
      case 'list_tasks':
        final tasks = [
          for (final t in (r.result['tasks'] as List? ?? const []))
            if (t is Map) t,
        ];
        final total = r.result['total'];
        if (tasks.isEmpty) return '没有符合的任务。';
        final waiting = r.result['waitingOnMe'];
        final head =
            '共 ${total ?? tasks.length} 个任务'
            '${waiting is int && waiting > 0 ? '，其中 $waiting 个在等你验收' : ''}。';
        final lines = [
          for (final t in tasks.take(driving ? 3 : 5)) _taskLine(t),
        ];
        return '$head${lines.join('；')}。';
      case 'task_detail':
        final t = r.result['task'];
        if (t is! Map) continue;
        final n = t['number'];
        return '任务${n == null ? '' : ' #$n'}：${_taskLine(t)}。';
      case 'get_briefing':
        final o = r.result['overview'];
        if (o is String && o.trim().isNotEmpty) {
          return o.trim().endsWith('。') ? o.trim() : '${o.trim()}。';
        }
    }
  }
  return null;
}

String _taskLine(Map t) {
  final owner = t['assignee'] is String ? t['assignee'] as String : '';
  final waits = t['waitsFor'] is String ? t['waitsFor'] as String : '';
  final idle = t['idle'] is String ? t['idle'] as String : '';
  return [
    '${t['title']}',
    // "八戒 在做" already says who; "等你验收" does not.
    if (owner.isNotEmpty && !waits.contains(owner)) '$owner 负责',
    if (waits.isNotEmpty) waits else if (owner.isEmpty) '没人认领',
    if (idle.isNotEmpty) '$idle没动',
  ].join('，');
}

/// The person asks to have the list read ("读一下动态", "念一下", "都有什么").
/// A request for one thing ("读 Alice 那条原文", "最新那条") is not.
bool orbAsksToReadList(String said) =>
    _readsList.hasMatch(said) && !_oneThing.hasMatch(said);

final _readsList = RegExp(
  r'(?:读|念)(?:一下|一遍|读|念)?\s*(?:动态|活动|通知|消息|收件箱)|动态里(?:都)?有(?:什么|哪些)|都有什么|有哪些(?:消息|动态|通知)|逐条|每一条',
);
final _oneThing = RegExp(
  r'那条|那封|这条|第\s*[0-9一二三四五六七八九十]+\s*[条件个]|最新|原文|最后一条|哪条',
);

/// The Activity items the turn read, when there are at least two.
List<Map<String, Object?>>? _activityItems(List<AgentToolRun> runs) {
  for (final r in runs.reversed) {
    if (r.name != 'describe_page') continue;
    if (r.result['error'] != null ||
        r.result['loading'] == true ||
        r.result['page'] != 'activity') {
      return null;
    }
    final items = [
      for (final i in (r.result['items'] as List? ?? const []))
        if (i is Map) Map<String, Object?>.from(i),
    ];
    return items.length >= 2 ? items : null;
  }
  return null;
}

String _whoOf(Map<String, Object?> item) {
  final who = item['who'];
  if (who is String && who.isNotEmpty) return who;
  final where = item['where'];
  return where is String ? where : '';
}

/// Reading the Activity out: every item (the first five), in the page's order,
/// is named. The model that stops after the first is sent back once; if it
/// still falls short the app reads the list itself.
AgentReview? _listRead(String reply, List<AgentToolRun> runs, String said) {
  if (!orbAsksToReadList(said)) return null;
  final items = _activityItems(runs);
  if (items == null) return null;
  final shown = items.take(5).toList();
  var at = 0;
  var all = true;
  for (final item in shown) {
    final who = _whoOf(item);
    if (who.isEmpty) continue;
    final i = reply.indexOf(who, at);
    if (i < 0) {
      all = false;
      break;
    }
    at = i + who.length;
  }
  if (all) return null;
  return AgentReview(
    retry:
        '（App 提示，不是用户的话：用户要听动态里的每一条，共 ${items.length} 条。'
        '按页面顺序一条条说，每条说谁、在哪、说了什么，最多 5 条，不要只说第一条。）',
    text: _compactList(items, shown),
  );
}

String _compactList(
  List<Map<String, Object?>> all,
  List<Map<String, Object?>> shown,
) {
  String one(Map<String, Object?> i) {
    final who = _whoOf(i);
    final where = i['where'] is String ? i['where'] as String : '';
    final p = i['preview'];
    var what = p is String
        ? p
              .replaceAll(RegExp(r'\s+'), ' ')
              .replaceAll(RegExp(r'[。！？.!?]+$'), '')
              .trim()
        : '';
    if (what.length > 24) what = '${what.substring(0, 24)}…';
    return [
      who,
      if (where.isNotEmpty && where != who) where,
      if (what.isNotEmpty) what,
    ].join('，');
  }

  final more = all.length > shown.length
      ? '还有 ${all.length - shown.length} 条。'
      : '';
  return '共 ${all.length} 条：${[for (final i in shown) one(i)].join('；')}。$more';
}

// ---- the answers that must be complete ---------------------------------------

/// Each of [names] appears in [reply], in this order (a name that comes up
/// again later is found again later).
bool _inOrder(String reply, Iterable<String> names) {
  var at = 0;
  for (final name in names) {
    if (name.isEmpty) continue;
    final i = reply.indexOf(name, at);
    if (i < 0) return false;
    at = i + name.length;
  }
  return true;
}

/// The person asks what needs them.
final orbAsksNeeds = RegExp(
  r'什么(?:需要|要|该)(?:我)?(?:处理|紧|做)|有什么(?:要|需要)(?:我)?(?:处理|做)|要紧|谁(?:找|在等)我|有什么(?:新的|事)|需要我|等我处理|简报',
);

/// What needs the person, as the briefing the turn read has it: every one (the
/// first five) is named, in the briefing's order. A reply that leaves one out
/// is sent back once; if it still does, the app says them.
AgentReview? _needsRead(String reply, List<AgentToolRun> runs, String said) {
  if (!orbAsksNeeds.hasMatch(said)) return null;
  final b = orbBriefingOf(runs);
  if (b == null) return null;
  final items = [
    for (final i in (b['needsYou'] as List))
      if (i is Map) Map<String, Object?>.from(i),
  ];
  if (items.isEmpty) return null;
  final shown = items.take(5).toList();
  if (_inOrder(reply, [for (final i in shown) '${i['who'] ?? ''}'])) {
    return null;
  }
  String one(Map<String, Object?> i) {
    final title = '${i['title'] ?? i['who']}'.replaceAll(
      RegExp(r'[。！？.!?]+$'),
      '',
    );
    final since = i['since'];
    return since is String && since.isNotEmpty ? '$title，$since' : title;
  }

  final waiting = b['waitingTasks'];
  final tail = waiting is int && waiting > 0
      ? '${OrbBriefing.waitingTasksTail(waiting)}。'
      : '';
  return AgentReview(
    retry:
        '（App 提示，不是用户的话：有 ${items.length} 件事需要用户处理。按顺序逐件说：谁、要他做什么，'
        '一件一句，最多 5 件，不要漏掉任何一个人。）',
    text:
        '有 ${items.length} 件事在等你：${[for (final i in shown) one(i)].join('；')}。'
        '${items.length > shown.length ? '还有 ${items.length - shown.length} 件。' : ''}$tail',
  );
}

/// "看看 Cody 私信": a private conversation is to be looked at.
final orbLooksAtDm = RegExp(
  r'(?:看看|看下|看一下|看一眼|查看|打开|读读?|读一下|念一下).*私信|私信.*(?:怎么样|说了什么|有什么)',
);

/// Whether the reply says a reply is (or is not) needed.
final _saysReplyNeed = RegExp(
  r'要回|回他|回她|回复|回一下|回一句|回吗|不用回|不需要回|不必回|要不要回|需要你回|要你回|等你回|该回',
);

({String name, List<Map<String, Object?>> messages})? _dmRead(
  List<AgentToolRun> runs,
) {
  for (final r in runs.reversed) {
    Map? page;
    switch (r.name) {
      case 'navigate':
        final m = r.result['matched'];
        if (m is Map && m['kind'] == 'dm') {
          final p = r.result['page'];
          page = p is Map ? p : {'conversation': {}};
          final name = r.result['title'];
          if (name is String && name.isNotEmpty) {
            return (name: name, messages: _messagesOf(page));
          }
        }
      case 'describe_page' || 'read_conversation':
        page = r.result;
    }
    final c = page?['conversation'];
    if (page != null && c is Map && c['type'] == 'dm' && c['name'] is String) {
      return (name: c['name'] as String, messages: _messagesOf(page));
    }
  }
  return null;
}

List<Map<String, Object?>> _messagesOf(Map page) => [
  for (final m in (page['messages'] as List? ?? const []))
    if (m is Map) Map<String, Object?>.from(m),
];

final _asks = RegExp(r'[？?]|吗|呢|能不能|可不可以|行不行|好不好|怎么|什么|哪');

/// Looking at somebody's private conversation: the reply names the person
/// and says whether a reply is wanted. The briefing of the conversation says
/// it (an unanswered ask to the user); without one, a question as the last
/// thing they said. Short of either, the model is sent back once and then the
/// app says it: "Cody 问你：…，要回吗？" / "Cody 说：…，不用回。"
AgentReview? _dmGlance(String reply, List<AgentToolRun> runs, String said) {
  if (!orbLooksAtDm.hasMatch(said)) return null;
  final dm = _dmRead(runs);
  if (dm == null) return null;
  if (reply.contains(dm.name) && _saysReplyNeed.hasMatch(reply)) return null;
  Map<String, Object?>? last;
  for (final m in dm.messages.reversed) {
    if ('${m['from']}' == dm.name) {
      last = m;
      break;
    }
  }
  final b = orbBriefingOf(runs);
  final asked = b != null && (b['needsYou'] as List).isNotEmpty;
  final said_ = last == null ? '' : '${last['text'] ?? ''}'.trim();
  final needs = b != null ? asked : _asks.hasMatch(said_);
  String clip(String t) {
    final one = t
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[。！？.!?]+$'), '');
    return one.length <= 40 ? one : '${one.substring(0, 40)}…';
  }

  return AgentReview(
    retry:
        '（App 提示，不是用户的话：用户要看 ${dm.name} 的私信。回答要说出 ${dm.name} 的名字，'
        '他说了什么，以及用户要不要回他。）',
    text: said_.isEmpty
        ? null
        : needs
        ? '${dm.name} 问你：${clip(said_)}，要回吗？'
        : '${dm.name} 说：${clip(said_)}，不用回。',
  );
}

/// "看看那些任务": the tasks are to be listed, not counted.
final _listsTasks = RegExp(
  r'(?:看看|看下|看一下|说说|讲讲|念念|列出|有哪些|查看)[^，。]*任务|任务.*(?:有哪些|都有)',
);
final _notAList = RegExp(r'状态|多少|几个任务|打开|处理掉|全部处理|催|通过|标');

/// After a task list, on a request to see the tasks: each one listed (three
/// while driving, five otherwise) is named by its title, and its owner is said.
/// What leaves one out is sent back once; if it still does, the app lists them.
AgentReview? _taskListRead(
  String reply,
  List<AgentToolRun> runs,
  String said,
  bool driving,
) {
  if (!_listsTasks.hasMatch(said) || _notAList.hasMatch(said)) return null;
  Map<String, Object?>? result;
  for (final r in runs.reversed) {
    if (r.name == 'list_tasks' && r.result['error'] == null) {
      result = r.result;
      break;
    }
  }
  final tasks = [
    for (final t in (result?['tasks'] as List? ?? const []))
      if (t is Map) t,
  ];
  if (tasks.isEmpty) return null;
  final shown = tasks.take(driving ? 3 : 5).toList();
  var complete = true;
  for (final t in shown) {
    final title = '${t['title'] ?? ''}';
    final owner = t['assignee'];
    if (title.isNotEmpty && !reply.contains(title)) complete = false;
    if (owner is String && owner.isNotEmpty && !reply.contains(owner)) {
      complete = false;
    }
  }
  if (complete) return null;
  return AgentReview(
    retry:
        '（App 提示，不是用户的话：用户要看任务。把列出的每个任务都说到，说清标题、谁在做、卡在哪，'
        '${driving ? '最多 3 个' : '最多 5 个'}，不要只说一个。）',
    text: orbSummarize(runs, driving: driving),
  );
}
