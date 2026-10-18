import 'briefing/orb_briefing_models.dart';
import 'orb_driving.dart' show orbNeedsParking;
import 'orb_driving_surface.dart';

/// The rows of a driving list, made from what the app already read: the
/// Activity briefing, `list_tasks` and `read_conversation`. Nothing here asks
/// the server for anything.

String _tidy(String text) => text.replaceAll(RegExp(r'[。！？.!?]+$'), '');

/// "Alice：周五评审你来吗": who first when the title does not name them.
String _said(String who, String title) {
  final t = _tidy(title.trim());
  if (who.isEmpty) return t;
  if (t.isEmpty) return who;
  return t.contains(who) ? t : '$who：$t';
}

/// The reasons that mean someone named the person.
const _mentionReasons = {OrbReason.mentionAsk, OrbReason.mentionFyi};

/// The row of a briefing item. [waiting]: it needs the person, so the quiet
/// fact is how long it has waited (else how many are unread).
OrbListRow orbRowOfItem(OrbBriefItem item, {required bool waiting}) {
  final meta = [item.who, if (item.where.isNotEmpty) item.where].join(' · ');
  final fact = waiting && item.since.isNotEmpty
      ? item.since
      : item.unread > 0
      ? '${item.unread} 条未读'
      : item.since;
  final asksReply =
      item.suggestedAction?.kind == 'reply' ||
      item.reason == OrbReason.dmAsk ||
      item.reason == OrbReason.replyAsk ||
      item.reason == OrbReason.mentionAsk;
  return OrbListRow(
    id: item.id,
    who: item.who,
    meta: meta,
    title: item.title,
    fact: fact,
    say: _said(item.who, item.title),
    summary: item.why,
    item: item,
    canReply: waiting && asksReply && !orbNeedsParking(item),
  );
}

/// The rows of [b] for [kind] (unread, or the ones that name the person), the
/// items that need the person first, then the progress, in the briefing's own
/// order. Null for a kind a briefing does not make.
OrbList? orbListOfBriefing(OrbBriefing b, OrbListKind kind) {
  if (kind != OrbListKind.unread && kind != OrbListKind.mentions) return null;
  bool wanted(OrbBriefItem i) =>
      kind == OrbListKind.unread || _mentionReasons.contains(i.reason);
  return OrbList(
    kind: kind,
    rows: [
      for (final i in b.needsYou)
        if (wanted(i)) orbRowOfItem(i, waiting: true),
      for (final i in b.progress)
        if (wanted(i)) orbRowOfItem(i, waiting: false),
    ],
    routine: kind == OrbListKind.unread ? b.routineCount : 0,
  );
}

/// The rows of `list_tasks`' result ("我的任务").
OrbList orbListOfTasks(Map<String, Object?> result) {
  final rows = <OrbListRow>[];
  for (final t in (result['tasks'] as List? ?? const [])) {
    if (t is! Map) continue;
    final number = t['number'];
    final title = '${t['title'] ?? ''}'.trim();
    final owner = '${t['assignee'] ?? ''}'.trim();
    final channel = '${t['channel'] ?? ''}'.trim();
    final waits = '${t['waitsFor'] ?? ''}'.trim();
    final state = '${t['statusText'] ?? ''}'.trim();
    final idle = '${t['idle'] ?? ''}'.trim();
    rows.add(
      OrbListRow(
        id: 'task:$number',
        who: owner,
        meta: [
          '任务 #$number',
          if (channel.isNotEmpty)
            channel.startsWith('#') ? channel : '#$channel',
        ].join(' · '),
        title: title,
        fact: waits.isNotEmpty ? waits : state,
        say: '任务 #$number「$title」',
        summary: [
          if (state.isNotEmpty) state,
          if (owner.isNotEmpty) '$owner 负责',
          if (idle.isNotEmpty) '$idle 没动',
        ].join('，'),
        openArgs: number is int
            ? {
                'task_number': number,
                if (channel.isNotEmpty) 'channel': channel,
              }
            : null,
      ),
    );
  }
  return OrbList(kind: OrbListKind.tasks, rows: rows);
}

/// The longest a message may be on the card before it is cut (the rest is for
/// when the car is parked).
const orbRowTextCap = 60;

/// The rows of `read_conversation`'s result: the newest message first.
OrbList orbListOfConversation(Map<String, Object?> result) {
  final conv = result['conversation'];
  final name = conv is Map ? '${conv['name'] ?? ''}' : '';
  final isDm = conv is Map && conv['type'] == 'dm';
  final id = conv is Map ? '${conv['id'] ?? ''}' : '';
  final rows = <OrbListRow>[];
  final messages = [
    for (final m in (result['messages'] as List? ?? const []))
      if (m is Map && m['system'] != true && m['from'] != null) m,
  ];
  for (final m in messages.reversed) {
    final from = '${m['from']}';
    final text = '${m['text'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    final clipped = m['truncated'] == true || text.runes.length > orbRowTextCap;
    final shown = text.runes.length > orbRowTextCap
        ? '${String.fromCharCodes(text.runes.take(orbRowTextCap))}…'
        : text;
    rows.add(
      OrbListRow(
        id: 'msg:${m['id']}',
        who: m['fromMe'] == true ? '你' : from,
        meta: m['fromMe'] == true ? '你' : from,
        title: shown,
        fact: '${m['time'] ?? ''}',
        say: _said(m['fromMe'] == true ? '你' : from, shown),
        clipped: clipped,
        openArgs: id.isEmpty
            ? null
            : (isDm ? {'dm_id': id} : {'channel_id': id}),
      ),
    );
  }
  return OrbList(
    kind: isDm ? OrbListKind.person : OrbListKind.channel,
    target: isDm ? name.replaceFirst(RegExp(r'^@'), '') : name,
    rows: rows,
  );
}

/// "新的：Alice @你": a plain line for what came in while a list is up.
String orbArrivalLine(OrbBriefItem item) {
  final who = item.who.isEmpty ? '有人' : item.who;
  return _mentionReasons.contains(item.reason) ? '新的：$who @你' : '新的：$who 找你';
}
