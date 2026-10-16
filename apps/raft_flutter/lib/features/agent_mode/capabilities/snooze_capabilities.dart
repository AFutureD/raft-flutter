import '../../../data/workspace_controller.dart';
import '../agent_mode_data.dart';
import 'action_support.dart';
import 'agent_capability.dart';
import 'agent_snooze.dart';
import 'capability_support.dart';

/// "稍后 / 明天再看": set an attention item aside until a time, see what is
/// set aside, put one back. Kept on the device (see [AgentSnoozeStore]); it
/// touches no server data, so there is no parity entry.

/// "今天 19:00", "明天 09:00", "10-20 09:00".
String whenWord(DateTime at, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final l = at.toLocal(), n = now.toLocal();
  final days = DateTime(l.year, l.month, l.day)
      .difference(DateTime(n.year, n.month, n.day))
      .inDays;
  final clock = '${two(l.hour)}:${two(l.minute)}';
  return switch (days) {
    0 => '今天 $clock',
    1 => '明天 $clock',
    _ => '${two(l.month)}-${two(l.day)} $clock',
  };
}

/// The attention item [ref] means: its id, its task id or number, the
/// channel of a mention, or words of its sentence. Looks at everything the
/// attention layer holds (set aside or not).
Future<AgentAttentionItem> attentionItemFor(
  WorkspaceController w,
  AgentCapabilityEnv env,
  String ref,
) async {
  final all =
      AgentModeData.cached(w) ?? await env.dataFor(w).attention();
  final want = ref.trim();
  if (want.isEmpty) throw const AgentCapabilityError('需要 item：要稍后再看的那一件');
  List<AgentAttentionItem> hits(bool Function(AgentAttentionItem) test) => [
    for (final i in all.items)
      if (test(i)) i,
  ];
  final number = int.tryParse(want.replaceAll(RegExp(r'^#'), ''));
  final tests = <bool Function(AgentAttentionItem)>[
    (i) => i.id == want,
    (i) => i.taskId == want,
    (i) => number != null && i.taskNumber == number,
    (i) => i.id == 'mention:$want' || i.channelId == want,
    (i) =>
        want.length >= 2 &&
        '${i.headline} ${i.channelName ?? ''}'.toLowerCase().contains(
          want.toLowerCase(),
        ),
  ];
  for (final test in tests) {
    final found = hits(test);
    if (found.length == 1) return found.single;
    if (found.length > 1) {
      throw AgentCapabilityError(
        '“$ref”对得上多件事，请问用户是哪一件',
        candidates: [
          for (final i in found.take(6))
            {
              'id': i.id,
              'number': i.taskNumber,
              'text': clip(i.headline, 60),
            },
        ],
      );
    }
  }
  throw AgentCapabilityError('“现在需要你”里没有“$ref”这一件');
}

DateTime _until(Map<String, Object?> args, DateTime now) {
  final given = text(args['until']);
  if (given != null) {
    final at = DateTime.tryParse(given);
    if (at == null) {
      throw AgentCapabilityError(
        '时间“$given”看不懂，请用 2026-10-18T09:00:00 这样的写法，或改用 when / hours',
      );
    }
    return at.toLocal();
  }
  final hours = args['hours'] as int?;
  if (hours != null) return now.add(Duration(hours: hours));
  return AgentSnoozeStore.untilFor('${args['when'] ?? 'later'}', now);
}

DateTime _checked(Map<String, Object?> args, DateTime now) {
  final at = _until(args, now);
  if (!at.isAfter(now)) {
    throw const AgentCapabilityError('这个时间已经过了：请说一个之后的时间');
  }
  if (at.isAfter(now.add(const Duration(days: 30)))) {
    throw const AgentCapabilityError('最多能稍后 30 天');
  }
  return at;
}

final _itemArg = strArg('要稍后再看的那一件：任务 id、任务编号（#98）、讨论所在频道，或它那句话里的几个字', max: 120);

final snoozeCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'attention.snooze',
    title: '把“现在需要你”里的一件事稍后再看（今晚 / 明天早上 / 几小时后）：先从首页拿掉，到点再提醒；记在手机上，退出 Agent 模式也不丢',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    keywords: const [
      '稍后',
      '稍后再看',
      '晚点再看',
      '待会儿再说',
      '明天再看',
      '明天提醒我',
      '先放一放',
      '过会儿再说',
      '这个先不管',
      '回头再看',
      '下周再看',
      '提醒我再看',
      'snooze',
      'later',
    ],
    paramsSchema: objectSchema(
      {
        'item': _itemArg,
        'when': strArg(
          'later 3 小时后（默认）/ tonight 今晚 / tomorrow 明天早上 9 点 / next_week 下周一早上',
          values: const ['later', 'tonight', 'tomorrow', 'next_week'],
        ),
        'hours': intArg('几小时后再提醒，1 到 720；比 when 优先', min: 1, max: 720),
        'until': strArg('具体时间，如 2026-10-18T09:00:00；最优先', max: 40),
      },
      required: const ['item'],
    ),
    resultSummary: 'done, entity=task（任务时）, id, until（到点再提醒的时间）',
    prepareUndo: (w, args, env) async {
      final item = await attentionItemFor(w, env, '${args['item']}');
      final store = env.snoozeFor(w);
      final before = store.entry(item.id);
      return AgentUndoPlan(
        label: before == null ? '放回现在需要你' : '改回 ${whenWord(before.until, env.snoozeFor(w).now())}',
        run: () async {
          if (before == null) {
            store.unsnooze(item.id);
            return '已放回“现在需要你”';
          }
          store.snooze(item, before.until);
          return '已改回 ${whenWord(before.until, env.snoozeFor(w).now())} 再提醒';
        },
      );
    },
    preview: (w, args, env) async {
      final item = await attentionItemFor(w, env, '${args['item']}');
      final now = env.snoozeFor(w).now();
      final at = _checked(args, now);
      final label = _item(item);
      final held = env.snoozeFor(w).entry(item.id);
      return AgentActionPreview(
        summary: '把 $label 先放一放，${whenWord(at, now)}再提醒你',
        changes: [
          change(
            '现在需要你',
            held == null ? '待处理' : '稍后（${whenWord(held.until, now)}）',
            '稍后（${whenWord(at, now)}）',
          ),
        ],
        reversible: true,
        refs: [
          if (item.taskId != null) AgentPreviewRef('task', item.taskId!),
        ],
      );
    },
    run: (w, args, env) async {
      final item = await attentionItemFor(w, env, '${args['item']}');
      final now = env.snoozeFor(w).now();
      final at = _checked(args, now);
      env.snoozeFor(w).snooze(item, at);
      return actionResult(
        '已放一放，${whenWord(at, now)}再提醒你',
        entity: item.taskId == null ? null : 'task',
        id: item.taskId,
        extra: {'until': at.toIso8601String()},
      );
    },
  ),
  AgentCapability(
    id: 'attention.unsnooze',
    title: '把稍后再看的一件事马上放回“现在需要你”',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    keywords: const [
      '取消稍后',
      '现在就看',
      '放回来',
      '不用等了',
      '把稍后的拿回来',
      '提前提醒',
      'unsnooze',
    ],
    paramsSchema: objectSchema(
      {'item': strArg('稍后里的那一件：任务 id、任务编号（#98），或它那句话里的几个字', max: 120)},
      required: const ['item'],
    ),
    resultSummary: 'done, entity=task（任务时）, id',
    prepareUndo: (w, args, env) async {
      final held = _held(w, env, '${args['item']}');
      final item = await attentionItemFor(w, env, held.id);
      final store = env.snoozeFor(w);
      return AgentUndoPlan(
        label: '再放回稍后',
        run: () async {
          store.snooze(item, held.until);
          return '已改回 ${whenWord(held.until, env.snoozeFor(w).now())} 再提醒';
        },
      );
    },
    preview: (w, args, env) async {
      final held = _held(w, env, '${args['item']}');
      final now = env.snoozeFor(w).now();
      return AgentActionPreview(
        summary: '把稍后的“${quote(held.headline, 30)}”现在就放回来',
        changes: [
          change('现在需要你', '稍后（${whenWord(held.until, now)}）', '待处理'),
        ],
        reversible: true,
      );
    },
    run: (w, args, env) async {
      final held = _held(w, env, '${args['item']}');
      env.snoozeFor(w).unsnooze(held.id);
      return actionResult(
        '已放回“现在需要你”',
        entity: _isTask(held.id) ? 'task' : null,
        id: _isTask(held.id) ? held.id : null,
      );
    },
  ),
  AgentCapability(
    id: 'attention.snoozed',
    title: '我稍后再看的有哪些：每一件几点再提醒我',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    keywords: const [
      '我稍后的',
      '稍后的有哪些',
      '稍后再看的',
      '我放一放的',
      '什么时候提醒我',
      '之前说稍后的',
      '待会儿要看的',
      '明天要看的',
    ],
    paramsSchema: noArgs,
    resultSummary: 'count, snoozed[{id,number,text,channel,until,remindIn}] 最先到点的在前',
    run: (w, args, env) async {
      final now = env.snoozeFor(w).now();
      final rows = env.snoozeFor(w).active;
      return {
        'count': rows.length,
        if (rows.isEmpty) 'message': '没有稍后再看的事',
        'snoozed': [
          for (final e in rows)
            compact({
              'id': e.id,
              'number': e.taskNumber,
              'text': clip(e.headline, 100),
              'channel': e.channel,
              'until': whenWord(e.until, now),
              'remindIn': _in(e.until.difference(now)),
            }),
        ],
      };
    },
  ),
];

bool _isTask(String id) => !id.startsWith('mention:');

String _item(AgentAttentionItem i) => i.taskNumber == null
    ? '“${quote(i.headline, 30)}”'
    : '#${i.taskNumber} “${quote(i.headline, 24)}”';

AgentSnoozed _held(WorkspaceController w, AgentCapabilityEnv env, String ref) {
  final want = ref.trim().replaceAll(RegExp(r'^#'), '').toLowerCase();
  final rows = env.snoozeFor(w).active;
  bool match(AgentSnoozed e) =>
      e.id.toLowerCase() == want ||
      '${e.taskNumber}' == want ||
      (want.length >= 2 && e.headline.toLowerCase().contains(want));
  final hits = rows.where(match).toList();
  if (hits.length == 1) return hits.single;
  if (hits.isEmpty) throw AgentCapabilityError('稍后的事里没有“$ref”');
  throw AgentCapabilityError(
    '“$ref”对得上多件事，请问用户是哪一件',
    candidates: [
      for (final e in hits.take(6))
        {'id': e.id, 'number': e.taskNumber, 'text': clip(e.headline, 60)},
    ],
  );
}

String _in(Duration d) {
  if (d.inMinutes < 1) return '马上';
  if (d.inHours < 1) return '${d.inMinutes} 分钟后';
  if (d.inHours < 48) return '${d.inHours} 小时后';
  return '${d.inDays} 天后';
}
