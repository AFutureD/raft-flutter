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

/// The rows of [b] for [kind] (unread, the ones that name the person, or the
/// recent ones), the items that need the person first, then the progress, in
/// the briefing's own order. Null for a kind a briefing does not make.
OrbList? orbListOfBriefing(OrbBriefing b, OrbListKind kind) {
  if (kind != OrbListKind.unread &&
      kind != OrbListKind.mentions &&
      kind != OrbListKind.recent) {
    return null;
  }
  bool wanted(OrbBriefItem i) =>
      kind != OrbListKind.mentions || _mentionReasons.contains(i.reason);
  return OrbList(
    kind: kind,
    rows: [
      for (final i in b.needsYou)
        if (wanted(i)) orbRowOfItem(i, waiting: true),
      for (final i in b.progress)
        if (wanted(i)) orbRowOfItem(i, waiting: false),
    ],
    routine: kind == OrbListKind.mentions ? 0 : b.routineCount,
  );
}

/// The rows of `list_tasks`' result ("我的任务").
OrbList orbListOfTasks(Map<String, Object?> result) {
  final rows = <OrbListRow>[];
  final counts = <String, int>{};
  for (final t in (result['tasks'] as List? ?? const [])) {
    if (t is! Map) continue;
    final number = t['number'];
    final title = '${t['title'] ?? ''}'.trim();
    final owner = '${t['assignee'] ?? ''}'.trim();
    final channel = '${t['channel'] ?? ''}'.trim();
    final waits = '${t['waitsFor'] ?? ''}'.trim();
    final state = '${t['statusText'] ?? ''}'.trim();
    final idle = '${t['idle'] ?? ''}'.trim();
    if (state.isNotEmpty) counts[state] = (counts[state] ?? 0) + 1;
    // How it stands, and how long it has sat: the card shows what is said.
    final stands = waits.isNotEmpty ? waits : state;
    rows.add(
      OrbListRow(
        id: 'task:$number',
        who: owner,
        meta: [
          '任务 #$number',
          if (channel.isNotEmpty)
            channel.startsWith('#') ? channel : '#$channel',
          // Who has it is on the card, since it is said (unless the words of
          // what it waits for already name them).
          if (owner.isNotEmpty && !waits.contains(owner)) owner,
        ].join(' · '),
        title: title,
        fact: [
          if (stands.isNotEmpty) stands,
          if (idle.isNotEmpty) '$idle没动',
        ].join(' · '),
        say: '任务 #$number「$title」',
        listSay:
            '任务 #$number「$title」'
            '${owner.isEmpty ? '' : '，$owner 负责'}'
            '${stands.isEmpty ? '' : '，$stands'}',
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
  return OrbList(
    kind: OrbListKind.tasks,
    rows: rows,
    // "进行中 2、等验收 1": how they stand, on the heading and in the line.
    note: rows.length < 2
        ? ''
        : [for (final e in counts.entries) '${e.key} ${e.value}'].join('、'),
  );
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

/// The sentence and its cap on a card: the longest a line of a card may be
/// (the rest is for when the car is parked).
String _cap(String text) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.runes.length <= orbRowTextCap
      ? one
      : '${String.fromCharCodes(one.runes.take(orbRowTextCap))}…';
}

/// The rows of `describe_page` on the Activity: the page's items, as the person
/// would see them. A row opens the conversation behind it.
OrbList orbListOfPageItems(Map<String, Object?> result) {
  final rows = <OrbListRow>[];
  for (final i in (result['items'] as List? ?? const [])) {
    if (i is! Map) continue;
    final who = '${i['who'] ?? ''}'.trim();
    final where = '${i['where'] ?? ''}'.trim();
    final preview = '${i['preview'] ?? i['title'] ?? ''}'.trim();
    final unread = i['unread'];
    final id = '${i['id'] ?? ''}'.replaceFirst('activity:', '');
    final dm = id.startsWith('dm:') ? id.substring(3) : null;
    final channel = id.startsWith('channel:') ? id.substring(8) : null;
    rows.add(
      OrbListRow(
        id: 'page:$id',
        who: who,
        meta: [who, if (where.isNotEmpty && where != who) where].join(' · '),
        title: _cap(preview.isEmpty ? who : preview),
        fact: unread is int && unread > 0
            ? '$unread 条未读'
            : '${i['time'] ?? ''}',
        say: _said(who, _cap(preview)),
        clipped: preview.runes.length > orbRowTextCap,
        openArgs: dm != null
            ? {'dm_id': dm}
            : channel != null
            ? {'channel_id': channel}
            : null,
      ),
    );
  }
  return OrbList(kind: OrbListKind.recent, rows: rows);
}

/// What `list_targets` found (channels, private conversations, people,
/// threads), or what a `query` returned when it is a list of named things:
/// one row each. [heading] names the list ("频道", "找到").
OrbList orbListOfTargets(Map<String, Object?> result) {
  final rows = <OrbListRow>[];
  void add(String type, Object? list, String Function(Map) name) {
    for (final e in (list as List? ?? const [])) {
      if (e is! Map) continue;
      final title = _cap(name(e));
      if (title.isEmpty) continue;
      final unread = e['unread'];
      rows.add(
        OrbListRow(
          id: '$type:${e['id'] ?? title}',
          who: title,
          meta: type,
          title: title,
          fact: unread is int && unread > 0 ? '$unread 条未读' : '',
          say: '$type $title',
          openArgs: switch (type) {
            '频道' => {'channel_id': e['id']},
            '私信' => {'dm_id': e['id']},
            '人' => e['id'] == null ? null : {'person_id': e['id']},
            '讨论' => e['id'] == null ? null : {'thread_id': e['id']},
            _ => null,
          },
        ),
      );
    }
  }

  add('频道', result['channels'], (m) => '${m['name'] ?? ''}');
  add('私信', result['dms'], (m) => '${m['name'] ?? ''}');
  add('人', result['people'], (m) => '${m['name'] ?? ''}');
  add('讨论', result['threads'], (m) => '${m['excerpt'] ?? ''}');
  if (rows.isEmpty) {
    // A `query`: the first list of named things in the result.
    for (final v in result.values) {
      if (v is! List || v.isEmpty || v.first is! Map) continue;
      for (final e in v) {
        if (e is! Map) continue;
        final title = _cap(
          '${e['title'] ?? e['name'] ?? e['text'] ?? e['summary'] ?? ''}',
        );
        if (title.isEmpty) continue;
        rows.add(
          OrbListRow(
            id: 'result:${e['id'] ?? rows.length}',
            who: '${e['assignee'] ?? e['from'] ?? ''}',
            meta: '${e['channel'] ?? e['status'] ?? ''}',
            title: title,
            fact: '${e['statusText'] ?? e['time'] ?? ''}',
            say: title,
          ),
        );
      }
      if (rows.isNotEmpty) break;
    }
  }
  return OrbList(kind: OrbListKind.results, rows: rows);
}

/// The sentences of what the agent says about a discussion, as the card: at
/// most [orbSummaryLines], each cut at [orbRowTextCap] (what was cut is for
/// when the car is parked). The rows ARE the spoken sentences: [where] is
/// where the discussion is.
const orbSummaryLines = 3;

OrbList orbListOfSummary(List<String> sentences, {String where = ''}) {
  final rows = <OrbListRow>[];
  for (final s in sentences.take(orbSummaryLines)) {
    final line = _cap(s);
    rows.add(
      OrbListRow(
        id: 'summary:${rows.length}',
        who: '',
        meta: where,
        title: line,
        fact: '',
        say: line,
        clipped: s.trim().runes.length > orbRowTextCap,
      ),
    );
  }
  return OrbList(kind: OrbListKind.summary, rows: rows, target: where);
}
