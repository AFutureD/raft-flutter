import '../agent_mode/app_speech.dart' show orbSentences;
import 'orb_driving_rows.dart';
import 'orb_driving_surface.dart';

/// What the screen shows of what the agent read, while driving: decided by the
/// app, never by the model. "说到的东西，屏幕上都有对应": every read tool has a
/// surface it is shown on, so the model chooses WHAT to fetch and never WHETHER
/// to show it (the industry pattern: the UI is bound to the tool and drawn by
/// the host, not picked by the model).
///
/// This file decides the surface of a result (pure: a test walks through it);
/// the controller puts it on the screen, says the line of it, and replaces what
/// the model says about a set of things with that line.

/// A result as a surface: a list, or one row of it opened.
class OrbPresentation {
  const OrbPresentation(this.list, {this.openFirst = false});

  final OrbList list;

  /// The one row is opened as a detail (one message, one task).
  final bool openFirst;

  /// What the app says of it: the total and the top one or two, or the row.
  String get say => openFirst && list.rows.isNotEmpty
      ? orbRowSay(list.rows.first)
      : (list.say ?? '');
}

/// The person asks for what a discussion came to (a summary), not for its
/// messages one by one.
final orbAsksSummary = RegExp(r'意见|讨论|总结|概括|摘要|结论|定了什么|怎么说|说了什么|聊了什么|大家');

/// The read tools the app puts on the screen while driving, and what each is
/// shown as. The parity test asks every read tool to have a place here (or in
/// [orbPresentedElsewhere]).
const orbPresentedTools = {
  'list_tasks': '任务列表',
  'task_detail': '任务详情',
  'read_conversation': '消息列表（一条是详情，问“大家意见”是摘要）',
  'list_targets': '结果列表',
  'query': '结果列表',
  'describe_page': '动态页的条目列表',
};

/// Read tools shown by the controller, which has what they need (the briefing
/// it laid out, the page it moved to).
const orbPresentedElsewhere = {
  'get_briefing': '牌组；没有要处理的时候是最近动态的列表，或“就这些”',
  'navigate': '任务是详情；其余是页面本身',
  'open_item': '动态里的那一条',
  'find': '（找能力，不是数据）',
};

/// The surface of [result], the answer of the tool [name] called with [args],
/// or null when it is nothing to show (an error, nothing found, another kind
/// of page). [said] is what the person asked.
OrbPresentation? orbPresent(
  String name,
  Map<String, Object?> args,
  Map<String, Object?> result, {
  String said = '',
}) {
  if (result['error'] != null ||
      result['loading'] == true ||
      result['candidates'] != null) {
    return null;
  }
  switch (name) {
    case 'list_tasks':
      final list = orbListOfTasks(result);
      return list.rows.isEmpty ? null : OrbPresentation(list);
    case 'task_detail':
      final t = result['task'];
      if (t is! Map) return null;
      final list = orbListOfTasks({
        'tasks': [t],
      });
      return list.rows.isEmpty ? null : OrbPresentation(list, openFirst: true);
    case 'read_conversation':
      final list = orbListOfConversation(result);
      if (list.rows.isEmpty) return null;
      // What the discussion came to is a summary, shown with the answer.
      if (orbAsksSummary.hasMatch(said)) return null;
      if (list.rows.length == 1) return OrbPresentation(list, openFirst: true);
      return OrbPresentation(list);
    case 'list_targets':
    case 'query':
      final list = orbListOfTargets(result);
      return list.rows.isEmpty ? null : OrbPresentation(list);
    case 'describe_page':
      if (result['page'] != 'activity') return null;
      final list = orbListOfPageItems(result);
      return list.rows.isEmpty ? null : OrbPresentation(list);
  }
  return null;
}

/// How many of [rows] the words [reply] name (by who, or a stretch of the
/// title): a reply that names two or more is reading the set out.
int orbRowsNamed(String reply, List<OrbListRow> rows) {
  final text = reply.toLowerCase();
  var named = 0;
  for (final r in rows) {
    final who = r.who.trim().toLowerCase();
    final title = r.title.trim().toLowerCase();
    final head = title.length > 6 ? title.substring(0, 6) : title;
    if ((who.isNotEmpty && text.contains(who)) ||
        (head.length >= 4 && text.contains(head))) {
      named++;
    }
  }
  return named;
}

/// The sentences of what the agent said, for the lines of a summary card (the
/// card keeps the first [orbSummaryLines]).
List<String> orbSummarySentences(String reply) => orbSentences(reply);
