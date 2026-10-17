import 'package:flutter/foundation.dart';

import 'orb_fuzzy.dart';
import 'orb_resolver.dart';
import 'orb_vocabulary.dart';

/// The ids `navigate` takes, one per kind of place. The model chooses a page
/// id from the declaration's enum, and an entity id from `list_targets` (or
/// the channel list of its prompt); the free-text `target` is only for a name
/// it could not find.
const orbIdParams = <String>[
  'page',
  'channel_id',
  'dm_id',
  'person_id',
  'thread_id',
  'task_number',
];

/// The structured line `navigate` leaves for each choice: which kind, which id
/// and how it was chosen. Never the user's words or any message content.
void Function(String line) orbNavLog = (line) {
  if (!kReleaseMode) debugPrint('orb-nav $line');
};

/// How many nearest ids an error offers.
const orbValidChoices = 5;

String? _text(Object? v) => v is String && v.trim().isNotEmpty
    ? v.trim()
    : v is num
    ? '$v'
    : null;

/// The task number of a `task_number` argument (`136`, `"136"`, `"#136"`).
int? orbTaskNumber(Object? v) {
  if (v is num) return v.toInt() > 0 ? v.toInt() : null;
  final m = RegExp(r'^[#＃]?\s*(\d{1,7})$').firstMatch(_text(v) ?? '');
  return m == null ? null : int.parse(m[1]!);
}

/// What the ids of a `navigate` call say: one [match] to go to, or an [error]
/// answer (with the nearest valid choices), or nothing when no id was given
/// (the caller then falls back to the free-text `target`).
class OrbChoice {
  const OrbChoice.match(OrbMatch this.match, this.param) : error = null;
  const OrbChoice.error(Map<String, Object?> this.error, this.param)
    : match = null;
  final OrbMatch? match;
  final Map<String, Object?>? error;

  /// The parameter that carried the choice (`page`, `channel_id`, ...).
  final String param;
}

OrbChoice _unknown(
  String param,
  String given,
  List<({String id, String name})> pool,
) {
  double score(({String id, String name}) p) {
    final a = given.toLowerCase(), b = p.id.toLowerCase();
    final idScore = a == b
        ? 1.0
        : 1 -
              orbEditDistance(a, b) /
                  (a.length > b.length ? a.length : b.length);
    // A model that put a name in an id field is still pointed at that name.
    final nameScore = orbNameScore(given, p.name);
    return idScore > nameScore ? idScore : nameScore;
  }

  final ranked = [...pool]
    ..sort((x, y) {
      final s = score(y).compareTo(score(x));
      return s != 0 ? s : x.id.compareTo(y.id);
    });
  return OrbChoice.error({
    'error':
        '没有这个 $param：「$given」。从 valid 里选一个 id 再调 navigate，或先调 list_targets',
    'valid': [
      for (final p in ranked.take(orbValidChoices))
        {'id': p.id, 'name': p.name},
    ],
  }, param);
}

/// Resolves the id arguments of `navigate` against [directory]. Null when the
/// call carries no id.
OrbChoice? chooseOrbById(Map<String, Object?> args, OrbDirectory directory) {
  final given = <String, String>{
    for (final p in orbIdParams) p: ?_text(args[p]),
  };
  if (given.isEmpty) return null;

  final taskGiven = given.containsKey('task_number');
  // A task may name its channel (`channel_id` narrows it); nothing else mixes.
  final others = given.keys.where(
    (k) => k != 'task_number' && !(taskGiven && k == 'channel_id'),
  );
  if (others.length + (taskGiven ? 1 : 0) > 1) {
    return OrbChoice.error({
      'error':
          '一次只给一个目的地（${given.keys.join('、')} 同时给了）；只有 task_number 可以配 channel_id',
    }, given.keys.first);
  }

  if (taskGiven) {
    final n = orbTaskNumber(args['task_number']);
    if (n == null) {
      return const OrbChoice.error({
        'error': 'task_number 要是任务编号（整数），比如 136',
      }, 'task_number');
    }
    String? hint;
    final channelId = given['channel_id'];
    if (channelId != null) {
      final c = directory.channels.where((c) => c.id == channelId).firstOrNull;
      if (c == null) return _channelUnknown(channelId, directory);
      hint = c.name;
    }
    return OrbChoice.match(
      OrbMatch(
        kind: OrbKind.task,
        id: '#$n',
        title: '任务 #$n',
        score: 1,
        reason: '任务编号 $n',
        data: {'number': n, 'channelHint': hint},
      ),
      'task_number',
    );
  }

  final param = given.keys.single;
  final id = given[param]!;
  switch (param) {
    case 'page':
      final d = orbVocabulary.where((d) => d.id == id).firstOrNull;
      if (d == null) {
        return _unknown(param, id, [
          for (final d in orbVocabulary) (id: d.id, name: d.zhName),
        ]);
      }
      return OrbChoice.match(
        OrbMatch(
          kind: OrbKind.page,
          id: d.id,
          title: d.zhName,
          score: 1,
          reason: '页面「${d.zhName}」',
        ),
        param,
      );
    case 'channel_id':
      final c = directory.channels.where((c) => c.id == id).firstOrNull;
      if (c == null) return _channelUnknown(id, directory);
      return OrbChoice.match(
        OrbMatch(
          kind: OrbKind.channel,
          id: c.id,
          title: '#${c.name}',
          score: 1,
          reason: '频道 #${c.name}',
        ),
        param,
      );
    case 'dm_id':
      final d = directory.dms.where((d) => d.id == id).firstOrNull;
      if (d == null) {
        return _unknown(param, id, [
          for (final d in directory.dms) (id: d.id, name: d.name),
        ]);
      }
      return OrbChoice.match(
        OrbMatch(
          kind: OrbKind.dm,
          id: d.id,
          title: '和 ${d.name} 的私信',
          score: 1,
          reason: '和 ${d.name} 的私信',
          data: {'peerId': d.peerId, 'peerType': d.peerType},
        ),
        param,
      );
    case 'person_id':
      final p = directory.people.where((p) => p.id == id).firstOrNull;
      if (p == null) {
        return _unknown(param, id, [
          for (final p in directory.people) (id: p.id, name: p.name),
        ]);
      }
      final agent = p.type == 'agent';
      return OrbChoice.match(
        OrbMatch(
          kind: OrbKind.profile,
          id: p.id,
          title: '${p.name} 的资料',
          score: 1,
          reason: '${agent ? 'Agent' : '成员'} ${p.name} 的资料',
          data: {'profileKind': agent ? 'agent' : 'human', 'name': p.name},
        ),
        param,
      );
    case 'thread_id':
      final t = directory.threads
          .where((t) => t.parentMessageId == id)
          .firstOrNull;
      if (t == null) {
        return _unknown(param, id, [
          for (final t in directory.threads)
            (id: t.parentMessageId, name: t.title),
        ]);
      }
      return OrbChoice.match(
        OrbMatch(
          kind: OrbKind.thread,
          id: t.parentMessageId,
          title:
              '${t.channelName == null ? '' : '#${t.channelName} › '}${t.title}',
          score: 1,
          reason: '讨论：${t.title}',
          data: {
            'parentChannelId': t.parentChannelId,
            'parentMessageId': t.parentMessageId,
            'threadChannelId': t.threadChannelId,
          },
        ),
        param,
      );
  }
  return null;
}

OrbChoice _channelUnknown(String id, OrbDirectory directory) => _unknown(
  'channel_id',
  id,
  [for (final c in directory.channels) (id: c.id, name: c.name)],
);

// --- the directory the model chooses from -----------------------------------

/// Channels with unread first, then joined ones, then by name.
List<OrbChannelRef> orbChannelsByInterest(OrbDirectory d) =>
    [...d.channels.where((c) => !c.archived)]..sort((a, b) {
      final u = b.unread.compareTo(a.unread);
      if (u != 0) return u;
      if (a.joined != b.joined) return a.joined ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

const _channelCap = 60, _dmCap = 30, _peopleCap = 60, _threadCap = 15;

/// The result of `list_targets`: the ids `navigate` takes. Token-bounded:
/// each list is capped and says how many it left out. [only] is one of
/// `channels`, `dms`, `people`, `threads`; null for all of them.
Map<String, Object?> orbTargetsJson(OrbDirectory d, {String? only}) {
  bool want(String k) => only == null || only == k;
  Map<String, Object?> out = {};
  void add(String key, List<Map<String, Object?>> all, int cap) {
    out[key] = all.take(cap).toList();
    if (all.length > cap) out['${key}Omitted'] = all.length - cap;
  }

  if (want('channels')) {
    add('channels', [
      for (final c in orbChannelsByInterest(d))
        {
          'id': c.id,
          'name': c.name,
          'joined': c.joined,
          if (c.unread > 0) 'unread': c.unread,
        },
    ], _channelCap);
  }
  if (want('dms')) {
    final dms = [...d.dms]
      ..sort((a, b) {
        final u = b.unread.compareTo(a.unread);
        return u != 0
            ? u
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    add('dms', [
      for (final m in dms)
        {
          'id': m.id,
          'name': m.name,
          if (m.peerId != null) 'person_id': m.peerId,
          if (m.unread > 0) 'unread': m.unread,
        },
    ], _dmCap);
  }
  if (want('people')) {
    add('people', [
      for (final p in d.people)
        {
          'id': p.id,
          'name': p.name,
          'type': p.type == 'agent' ? 'agent' : 'member',
        },
    ], _peopleCap);
  }
  if (want('threads')) {
    add('threads', [
      for (final t in d.threads)
        {
          'id': t.parentMessageId,
          'excerpt': t.title,
          if (t.channelName != null) 'channel': t.channelName,
        },
    ], _threadCap);
  }
  return out;
}

/// The channel line of the system prompt: `name [id]`, the ones with unread
/// first, bounded; `list_targets` has the rest.
String orbChannelsLine(OrbDirectory d, {int max = 40}) => [
  for (final c in orbChannelsByInterest(
    d,
  ).where((c) => c.name.isNotEmpty).take(max))
    '${c.name} [${c.id}]',
].join('、');
