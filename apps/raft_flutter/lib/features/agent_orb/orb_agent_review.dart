import '../agent_mode/agent_steering.dart';
import 'briefing/orb_briefing_models.dart' show OrbBriefing;

/// The model asked "要发吗？" (or the like) as a question to the person.
final orbAsksToConfirm = RegExp(r'要发吗|要改吗|确认吗|要不要发|要我发|你确认|确认要|发吗[？?]|改吗[？?]');

/// The model says something was sent or changed.
final _claimsDone = RegExp(
  r'已发送|已经发送|已经发了|已发出|发出去了|发好了|已回复|已改|改好了|已经改|已标|标好了|已催|已记下|记下了',
);

final _saysNothingToDo = RegExp(r'没有.{0,8}(处理|回复|找你|新的|要紧)');
final _saysLoading = RegExp(r'加载|稍等|稍后|等一下|等等|还没读|读不到|没读出来');
final _taskWords = RegExp(r'个任务|任务在等|等你验收|待验收|验收');

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
}) {
  final text = reply.trim();
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
