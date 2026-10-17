import '../agent_mode/agent_steering.dart';
import 'briefing/orb_briefing_models.dart' show OrbBriefing;
import 'nav/orb_resolver.dart';
import 'orb_key_facts.dart';
import 'orb_open.dart';

/// A command the app can carry out with no model at all: unambiguous words,
/// one tool, a sentence made from what the tool returned.
class OrbFastCommand {
  const OrbFastCommand(this.kind, this.tool, [this.args = const {}]);

  /// `next`, `previous`, `park`, `drive`, `item`, `open`.
  final String kind;
  final String tool;
  final Map<String, Object?> args;
}

String _plain(String said) => said
    .trim()
    .replaceAll(RegExp(r'[\s。.！!，,？?、~～…]+$'), '')
    .replaceFirst(RegExp(r'^(?:好的?[，,]?|嗯[，,]?|那|请|麻烦)+'), '')
    .replaceAll(RegExp(r'\s+'), '');

final _next = RegExp(r'^(?:下一[件个条位项]|next)(?:吧|啊|呀)?$', caseSensitive: false);
final _previous = RegExp(r'^(?:上一[件个条位项]|返回上一[件个条]|回到上一[件个条])(?:吧|啊|呀)?$');
final _park = RegExp(r'^(?:我?停车了|停好车了|(?:退出|结束|关闭|关掉)驾驶(?:模式)?|不开车了|我?不开车了)$');
final _drive = RegExp(
  r'^(?:开始驾驶(?:模式)?|进入驾驶(?:模式)?|开启驾驶(?:模式)?|打开驾驶模式|我在开车|我要开车了|开车模式)$',
);
final _item = RegExp(
  r'^(?:打开|读|念|看|读一下|念一下|看一下)?动态[里中]的?第([0-9一二三四五六七八九十两]+)[条个件](?:消息)?$',
);

int? _number(String s) {
  final n = int.tryParse(s);
  if (n != null) return n;
  const digit = {
    '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, //
    '六': 6, '七': 7, '八': 8, '九': 9,
  };
  if (s == '十') return 10;
  if (s.startsWith('十')) return 10 + (digit[s.substring(1)] ?? -100);
  if (s.endsWith('十')) return (digit[s.substring(0, s.length - 1)] ?? 0) * 10;
  if (s.length == 3 && s[1] == '十') {
    return (digit[s[0]] ?? 0) * 10 + (digit[s[2]] ?? -100);
  }
  return digit[s];
}

/// What [said] is, when it is exactly one of the commands the app can do by
/// itself; null for everything else (the model decides). [driving] and
/// [onActivity] say where the person is; [queue]: a pass over the stale tasks
/// is under way (then "下一个" is its next task).
OrbFastCommand? orbFastCommand(
  String said, {
  required bool driving,
  required bool onActivity,
  required bool queue,
  required OrbDirectory directory,
}) {
  final s = _plain(said);
  if (s.isEmpty) return null;
  if (driving) {
    if (_next.hasMatch(s)) {
      return queue
          ? const OrbFastCommand('next', 'next_task')
          : const OrbFastCommand('next', 'driving_next');
    }
    if (_previous.hasMatch(s)) {
      return const OrbFastCommand('previous', 'driving_previous');
    }
    if (_park.hasMatch(s)) {
      return const OrbFastCommand('park', 'set_driving_mode', {'on': false});
    }
  } else if (_drive.hasMatch(s)) {
    return const OrbFastCommand('drive', 'set_driving_mode', {'on': true});
  }
  final item = _item.firstMatch(s);
  if (item != null && onActivity) {
    final n = _number(item.group(1)!);
    if (n != null && n >= 1 && n <= 50) {
      return OrbFastCommand('item', 'open_item', {'n': n});
    }
  }
  final open = orbOpenArgs(said, directory);
  if (open != null) return OrbFastCommand('open', 'navigate', open);
  return null;
}

String _tidy(String text) => text.replaceAll(RegExp(r'[。！？.!?]+$'), '');

/// "第 2 件，共 3 件：Alice 问你：周五能来评审吗，已等 15 分钟。", or the end of
/// the cards.
String? orbDrivingSay(Map result, {OrbBriefing? briefing}) {
  if (result['error'] != null) return null;
  if (result['done'] == true) {
    final routine = briefing?.routineCount ?? 0;
    final waiting = briefing?.waitingTasks ?? 0;
    return '就这些。'
        '${routine > 0 ? '其余 $routine 条是常规进度。' : ''}'
        '${waiting > 0 ? '${OrbBriefing.waitingTasksTail(waiting)}。' : ''}';
  }
  final item = result['item'];
  if (item is! Map) return null;
  return '第 ${result['index']} 件，共 ${result['total']} 件：${_cardLine(item)}。';
}

/// How long a card has waited, as a clause: "已等 20 分钟" is said "已经等了
/// 20 分钟".
String _waited(String since) {
  final s = since.trim();
  return s.startsWith('已等') ? '已经等了${s.substring(2)}' : s;
}

/// A card in a line: who first (the title may not name them), what, how long.
String _cardLine(Map item) {
  final who = '${item['who'] ?? ''}'.trim();
  var title = _tidy('${item['title'] ?? ''}'.trim());
  if (title.isEmpty) title = who;
  if (who.isNotEmpty && !title.contains(who)) title = '$who：$title';
  final since = _waited('${item['since'] ?? ''}');
  return since.isEmpty ? title : '$title，$since';
}

/// Driving mode is on and the deck is laid out (`get_briefing` with show): the
/// first card, or that nothing needs the person. Null when it did not read.
String? orbDriveSay(Map briefing) {
  if (briefing['error'] != null || briefing['loading'] == true) return null;
  final items = [
    for (final i in (briefing['needsYou'] as List? ?? const []))
      if (i is Map) i,
  ];
  if (items.isEmpty) {
    final routine = briefing['routineCount'];
    return '好，驾驶模式。没有要你处理的。'
        '${routine is int && routine > 0 ? '其余 $routine 条是常规进度。' : ''}';
  }
  return '好，驾驶模式。第 1 件，共 ${items.length} 件：${_cardLine(items.first)}。';
}

/// A task of the pass over the stale tasks.
String? orbTaskPassSay(Map result) {
  if (result['error'] != null) return null;
  if (result['done'] == true) return '就这些。';
  final t = result['current'];
  if (t is! Map) return null;
  final owner = '${t['assignee'] ?? ''}';
  final waits = '${t['waitsFor'] ?? ''}';
  // "等你验收" goes on the task itself; "八戒 在做" is a clause of its own.
  final tail = waits.isNotEmpty
      ? (waits.startsWith('等') ? waits : '，$waits')
      : (owner.isNotEmpty ? '，由 $owner 负责' : '');
  return '第 ${result['index']} 个任务：#${t['number']}「${t['title']}」$tail。';
}

/// What `navigate` brought, as a sentence to say: where, then what needs the
/// person (or that nothing does); a task is its title, state and owner. Null
/// when the arrival is not clear (an error, choices, no briefing yet).
String? orbArrivalSay(Map result, {String said = ''}) {
  if (result['error'] != null ||
      result['candidates'] != null ||
      result['briefingNote'] != null) {
    return null;
  }
  final title = '${result['title'] ?? ''}'.trim();
  final run = AgentToolRun(
    'navigate',
    const {},
    Map<String, Object?>.from(result),
  );
  final page = result['page'];
  if (page is Map && page['page'] == 'task') {
    final facts = orbKeyFacts([run], said: said);
    if (facts.isEmpty) return title.isEmpty ? null : '到了$title。';
    return orbFactsSentence(facts);
  }
  if (result['loading'] == true) {
    return title.isEmpty ? '页面还在加载。' : '到了$title，内容还在加载。';
  }
  final b = result['briefing'];
  final where = title.isEmpty ? '到了。' : '到了$title。';
  if (b is! Map) return where;
  final matched = result['matched'];
  if (matched is Map && matched['kind'] == 'dm') {
    return _dmArrival(title, result, b);
  }
  final items = [
    for (final i in (b['needsYou'] as List? ?? const []))
      if (i is Map) i,
  ];
  final waiting = b['waitingTasks'];
  final tail = waiting is int && waiting > 0
      ? '${OrbBriefing.waitingTasksTail(waiting)}。'
      : '';
  if (items.isEmpty) return '$where没有要你处理的。$tail';
  String one(Map i) {
    final since = _waited('${i['since'] ?? ''}');
    return '${_tidy('${i['title'] ?? i['who']}')}${since.isEmpty ? '' : '，$since'}';
  }

  final shown = items.take(3).toList();
  return '$where有 ${items.length} 件事在等你：${shown.map(one).join('；')}。'
      '${items.length > shown.length ? '还有 ${items.length - shown.length} 件。' : ''}'
      '$tail';
}

/// A private conversation: who, what they asked, and whether to answer.
String _dmArrival(String name, Map result, Map briefing) {
  final items = [
    for (final i in (briefing['needsYou'] as List? ?? const []))
      if (i is Map) i,
  ];
  if (items.isNotEmpty) return '${_cardLine(items.first)}。要回吗？';
  final page = result['page'];
  String? last;
  if (page is Map) {
    for (final m in (page['messages'] as List? ?? const []).reversed) {
      if (m is Map && '${m['from']}' == name && m['fromMe'] != true) {
        last = '${m['text'] ?? ''}'.trim();
        break;
      }
    }
  }
  if (last == null || last.isEmpty) return '到了$name的私信。没有要你处理的。';
  final one = last.replaceAll(RegExp(r'\s+'), ' ');
  final clip = one.length <= 40 ? one : '${one.substring(0, 40)}…';
  return '$name 说：${_tidy(clip)}。不用回。';
}

/// The opened item of the Activity.
String? orbItemSay(Map result, int n) {
  if (result['error'] != null || result['opened'] == null) return null;
  final title = '${result['title'] ?? ''}'.trim();
  return title.isEmpty ? '打开了第 $n 条。' : '打开了第 $n 条：$title。';
}
