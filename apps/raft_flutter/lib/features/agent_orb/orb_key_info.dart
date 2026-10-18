import '../agent_mode/key_info.dart';
import 'actions/orb_action_declarations.dart' show orbActionCapabilities;
import 'actions/orb_actions.dart' show OrbCardRow, OrbPendingAction;

/// The key information of what the app says, for judging how it was spoken
/// (wording is free; these facts are not).

/// Numbers written as Chinese words in [text] ("三件事", "第十步"), as digits.
Iterable<String> _chineseNumbers(String text) sync* {
  const digit = {
    '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, //
    '六': 6, '七': 7, '八': 8, '九': 9,
  };
  for (final m in RegExp('[零一二三四五六七八九两十百]+').allMatches(text)) {
    var total = 0, current = 0;
    for (final c in m.group(0)!.split('')) {
      if (digit.containsKey(c)) {
        current = digit[c]!;
      } else if (c == '十') {
        total += (current == 0 ? 1 : current) * 10;
        current = 0;
      } else if (c == '百') {
        total += (current == 0 ? 1 : current) * 100;
        current = 0;
      }
    }
    yield '${total + current}';
  }
}

/// A quoted title or message ("任务 #136「重构第 10 步」"): the numbers in it
/// may be said, but need not be.
final _quoted = RegExp('「[^」]*」|“[^”]*”|"[^"]*"');

/// What an answer says that has to survive its wording: every number outside
/// a quoted title, every Latin name.
KeyInfo orbSayKeyInfo(String say) {
  final numbers = numbersIn(say);
  final needed = numbersIn(say.replaceAll(_quoted, ' '));
  final names = latinNamesIn(say);
  return KeyInfo(
    needs: [
      for (final n in {...needed})
        KeyRequirement('数字 $n', (spoken) => saysNumber(spoken, n)),
      for (final name in {...names})
        KeyRequirement('名字 $name', (spoken) {
          return spoken.contains(keyCompact(name));
        }),
    ],
    numbers: {...numbers, ..._chineseNumbers(say)},
    names: {for (final n in names) keyCompact(n)},
    checkNumbers: true,
  );
}

/// How the verb of a card may be said aloud, by capability.
const _verbs = <String, List<String>>{
  'messages.send': ['发', '回复', '回', '告诉', '说', '跟他', '留言'],
  'messages.reply_thread': ['发', '回复', '回', '告诉', '说', '跟他', '留言'],
  'tasks.set_status': [
    '标成',
    '标为',
    '改成',
    '改为',
    '设为',
    '设成',
    '完成',
    '关闭',
    '状态',
    '改',
    '通过',
  ],
  'tasks.assign': ['指派', '交给', '分给', '给', '负责', '改'],
  'tasks.unassign': ['取消', '清', '负责', '改'],
  'tasks.reject': ['打回', '退回', '驳回', '改'],
  'tasks.nudge': ['催', '提醒', '问问', '问一下', '问下'],
  'attention.snooze': [
    '记下',
    '稍后',
    '晚点',
    '之后',
    '提醒',
    '放一放',
    '推迟',
    '明天',
    '今晚',
    '一会',
  ],
};

/// "Cody：旧消息" -> "Cody"; "私信 Ada" -> "Ada"; "#general" -> "general".
String _target(String value) {
  var v = value.split(RegExp('[：:]')).first.trim();
  v = v.replaceFirst(RegExp(r'^私信\s*'), '').replaceFirst(RegExp('^#'), '');
  return v;
}

const _targetRows = {'发到', '回复', '催', '指派给', '负责人', '交给', '频道'};

/// Rows that say where something is, not what is done: the voice may leave
/// them out.
const _placeRows = {'所在'};

/// Target rows that name a person, and those that name where it is posted.
const _personRows = {'回复', '催', '指派给', '负责人', '交给'};
const _whereRows = {'发到', '频道'};

/// What the words that ask the person to confirm a card must carry: what it
/// does (the verb), to whom, the exact words, every number, and that it is a
/// question to answer (or, for a sensitive card, that the buttons confirm).
KeyInfo orbCardInfo({
  required String capabilityId,
  required String summary,
  required List<OrbCardRow> rows,
  bool sensitive = false,
}) {
  final needs = <KeyRequirement>[];
  final verbs = _verbs[capabilityId];
  if (verbs != null) {
    needs.add(
      KeyRequirement(
        '动作（${verbs.first}…）',
        (spoken) => verbs.any((v) => spoken.contains(keyCompact(v))),
      ),
    );
  }
  final targets = <String>{};
  String? content;
  // Where it goes is only a place when a person is named too ("催 八戒",
  // posted in the task's thread).
  final hasPerson = rows.any(
    (r) => _personRows.contains(r.label) && r.value.isNotEmpty,
  );
  for (final r in rows) {
    if (r.label == '内容') {
      content = r.value;
    } else if (_targetRows.contains(r.label) &&
        r.value.isNotEmpty &&
        !(hasPerson && _whereRows.contains(r.label))) {
      final t = _target(r.value);
      if (t.isNotEmpty) targets.add(t);
    }
  }
  final names = [
    ...targets,
    ...latinNamesIn(
      '${summary.replaceAll(_quoted, ' ')} ${rows.where((r) => r.label != '内容' && !_targetRows.contains(r.label) && !_placeRows.contains(r.label)).map((r) => r.value).join(' ')}',
    ),
  ];
  final seen = <String>{};
  for (final name in names) {
    final c = keyCompact(name);
    if (c.isEmpty || !seen.add(c)) continue;
    needs.add(KeyRequirement('对象 $name', (spoken) => spoken.contains(c)));
  }
  if (content != null && content.isNotEmpty) {
    final c = keyCompact(content);
    needs.add(
      KeyRequirement(
        '内容「${content.length <= 20 ? content : '${content.substring(0, 20)}…'}」',
        (spoken) => contentCoverage(c, spoken) >= .5,
      ),
    );
  }
  // The numbers that say which one and when: a task number (#136) and a time
  // (09:26) in the summary. A title's numbers ("重构第 10 步"), the quoted
  // words and the rows' old values may be said but need not be.
  final all =
      '$summary ${rows.where((r) => !_targetRows.contains(r.label) && !_placeRows.contains(r.label)).map((r) => r.value).join(' ')}';
  final numbers = numbersIn(all);
  final bare = summary.replaceAll(_quoted, ' ');
  final needed = {
    for (final m in RegExp(r'#(\d+)').allMatches(bare)) m.group(1)!,
    for (final m in RegExp(r'(\d{1,2})[:：](\d{2})').allMatches(bare)) ...[
      m.group(1)!,
      m.group(2)!,
    ],
  };
  for (final n in needed) {
    needs.add(KeyRequirement('数字 $n', (spoken) => saysNumber(spoken, n)));
  }
  needs.add(
    sensitive
        ? KeyRequirement(
            '请他点屏幕上的确认',
            (spoken) => RegExp('点|屏幕|按钮').hasMatch(spoken),
          )
        : KeyRequirement(
            '问他要不要做（等他确认）',
            (spoken) => asksForYes.hasMatch(spoken),
          ),
  );
  return KeyInfo(
    needs: needs,
    numbers: {...numbers, ..._chineseNumbers(all)},
    names: {for (final n in names) keyCompact(n)},
    checkNumbers: true,
  );
}

/// [orbCardInfo] of the card that is waiting.
KeyInfo orbCardKeyInfo(OrbPendingAction p) => orbCardInfo(
  capabilityId: p.capabilityId,
  summary: p.summary,
  rows: p.rows,
  sensitive: p.sensitive,
);

/// [orbCardInfo] from what an action tool answered (`needs_confirmation`:
/// the preview's summary and changes), for the evaluation, which sees the
/// tool results and not the card. Null when [result] is no card.
KeyInfo? orbCardKeyInfoOfResult(
  String tool,
  Map<String, Object?> args,
  Map<String, Object?> result,
) {
  if (result['status'] != 'needs_confirmation') return null;
  final preview = result['preview'];
  if (preview is! Map) return null;
  final capability =
      orbActionCapabilities[tool] ??
      '${args['capability'] ?? args['id'] ?? args['capability_id'] ?? ''}';
  return orbCardInfo(
    capabilityId: capability,
    summary: '${preview['summary'] ?? ''}',
    rows: [
      for (final line in (preview['changes'] as List? ?? const []))
        ?OrbCardRow.parse('$line'),
    ],
    sensitive: '${result['next']}'.contains('敏感操作'),
  );
}
