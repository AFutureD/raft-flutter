import 'dart:math' as math;

import 'orb_fuzzy.dart';
import 'orb_vocabulary.dart';

/// What the words of a request name.
enum OrbKind { page, channel, dm, person, profile, task, thread }

class OrbChannelRef {
  const OrbChannelRef({
    required this.id,
    required this.name,
    this.archived = false,
    this.joined = true,
    this.unread = 0,
  });
  final String id, name;
  final bool archived, joined;
  final int unread;
}

/// A private conversation, named by the other side.
class OrbDmRef {
  const OrbDmRef({
    required this.id,
    required this.name,
    this.peerId,
    this.peerType,
    this.unread = 0,
  });
  final String id, name;
  final String? peerId, peerType;
  final int unread;
}

/// A member (`user`) or an Agent (`agent`).
class OrbPersonRef {
  const OrbPersonRef({
    required this.id,
    required this.name,
    required this.type,
  });
  final String id, name, type;
}

/// A discussion, named by the message it hangs under (from the Activity rows).
class OrbThreadRef {
  const OrbThreadRef({
    required this.parentChannelId,
    required this.parentMessageId,
    required this.title,
    this.threadChannelId,
    this.channelName,
  });
  final String parentChannelId, parentMessageId, title;
  final String? threadChannelId, channelName;
}

/// Everything a name may refer to, as the App holds it now.
class OrbDirectory {
  const OrbDirectory({
    this.channels = const [],
    this.dms = const [],
    this.people = const [],
    this.threads = const [],
  });
  final List<OrbChannelRef> channels;
  final List<OrbDmRef> dms;
  final List<OrbPersonRef> people;
  final List<OrbThreadRef> threads;
}

/// One thing a request may mean.
class OrbMatch {
  const OrbMatch({
    required this.kind,
    required this.id,
    required this.title,
    required this.score,
    required this.reason,
    this.data = const {},
  });
  final OrbKind kind;

  /// Channel/DM/thread-parent/person id, destination id, or `#<number>`.
  final String id;
  final String title;
  final double score;

  /// Why it is offered, in the user's words.
  final String reason;

  /// Kind-specific facts (`number`, `peerId`, `profileKind`, ...).
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    'title': title,
    'reason': reason,
    'score': double.parse(score.toStringAsFixed(2)),
  };
}

/// The answer: one [match], or several [candidates] to choose from, or an
/// [error] (nothing fits). [suggestion] is a near miss worth offering.
class OrbResolution {
  const OrbResolution.match(OrbMatch this.match)
    : candidates = const [],
      error = null,
      suggestion = null;
  const OrbResolution.candidates(this.candidates)
    : match = null,
      error = null,
      suggestion = null;
  const OrbResolution.none(String this.error, {this.suggestion})
    : match = null,
      candidates = const [];
  final OrbMatch? match;
  final List<OrbMatch> candidates;
  final String? error;
  final OrbMatch? suggestion;
}

bool _ascii(String word) => RegExp(r'^[a-zA-Z ]+$').hasMatch(word);

/// Phrases that only say "go": removed from either end before matching.
final List<RegExp> _fillers = [
  for (final word in const [
    '请你帮我打开',
    '请帮我打开',
    '帮我打开',
    '帮我去',
    '请你打开',
    '请打开',
    '带我去',
    '带我到',
    '我想看看',
    '我想看一下',
    '我想看',
    '我要看',
    '切换到',
    '跳转到',
    '转到',
    '进入',
    '打开',
    '查看',
    '看一下',
    '看看',
    '看下',
    '回到',
    '返回',
    '去到',
    '去',
    '到',
    '请',
    'please',
    'take me to',
    'bring me to',
    'navigate to',
    'switch to',
    'jump to',
    'go to',
    'open up',
    'open',
    'show me',
    'show',
    'the',
  ])
    RegExp(
      '^${RegExp.escape(word)}${_ascii(word) ? r'\s+' : ''}',
      caseSensitive: false,
    ),
];

final List<RegExp> _trailers = [
  for (final word in const [
    '页面',
    '界面',
    '屏幕',
    '一下',
    '吧',
    '谢谢',
    'page',
    'screen',
    'tab',
    'please',
  ])
    RegExp(
      '${_ascii(word) ? r'\s+' : ''}${RegExp.escape(word)}\$',
      caseSensitive: false,
    ),
];

String _stripFillers(String input) {
  var s = input.trim();
  var changed = true;
  while (changed) {
    changed = false;
    for (final r in _fillers) {
      final next = s.replaceFirst(r, '').trim();
      if (next != s && next.isNotEmpty) {
        s = next;
        changed = true;
      }
    }
    for (final r in _trailers) {
      final next = s.replaceFirst(r, '').trim();
      if (next != s && next.isNotEmpty) {
        s = next;
        changed = true;
      }
    }
  }
  return s;
}

final _taskPatterns = <RegExp>[
  RegExp(r'第\s*(\d{1,7})\s*号?\s*(?:个)?\s*任务'),
  RegExp(r'(\d{1,7})\s*号\s*任务'),
  RegExp(
    r'(?:任务|task|tasks|ticket|issue)\s*(?:number|no\.?|编号|号)?\s*[#＃]?\s*(\d{1,7})',
    caseSensitive: false,
  ),
  RegExp(r'[#＃]\s*(\d{1,7})'),
];

final _kindWords = <(OrbKind, RegExp)>[
  (
    OrbKind.dm,
    RegExp(
      r'(?:的)?\s*(?:私信|私聊|私人消息|私人对话|(?<![a-z])(?:dms?|direct messages?)(?![a-z]))',
      caseSensitive: false,
    ),
  ),
  (
    OrbKind.profile,
    RegExp(
      r'(?:的)?\s*(?:个人资料|资料|档案|简介|(?<![a-z])(?:profile|bio)(?![a-z]))',
      caseSensitive: false,
    ),
  ),
  (
    OrbKind.thread,
    RegExp(
      r'(?:的)?\s*(?:讨论串|讨论|话题|回复串|(?<![a-z])(?:threads?)(?![a-z]))',
      caseSensitive: false,
    ),
  ),
  (
    OrbKind.channel,
    RegExp(r'(?:的)?\s*(?:频道|(?<![a-z])channel(?![a-z]))', caseSensitive: false),
  ),
];

final _chatWith = RegExp(
  r'^(?:和|跟|与|同|chat with|talk to|message|dm|with)\s*',
  caseSensitive: false,
);
final _chatTail = RegExp(r'\s*(?:聊天|对话|聊聊|聊一聊|说话|的对话)$');

/// What the request says apart from the name.
class OrbParsedTarget {
  const OrbParsedTarget({
    required this.whole,
    required this.core,
    this.hint,
    this.taskNumber,
    this.taskChannelHint,
  });

  /// The request with only the "go" phrases removed (page names match this).
  final String whole;

  /// The name left after the kind words are removed.
  final String core;
  final OrbKind? hint;
  final int? taskNumber;
  final String? taskChannelHint;
}

OrbKind? _kindArg(String? kind) => switch (kind?.trim().toLowerCase()) {
  'page' || 'destination' || 'tab' || 'screen' => OrbKind.page,
  'channel' => OrbKind.channel,
  'dm' || 'direct' || 'private' => OrbKind.dm,
  'person' || 'member' || 'agent' || 'user' || 'people' => OrbKind.person,
  'profile' => OrbKind.profile,
  'task' => OrbKind.task,
  'thread' || 'discussion' => OrbKind.thread,
  _ => null,
};

/// Takes a request apart: the task number, the kind words and the name.
OrbParsedTarget parseOrbTarget(String target, {String? kind}) {
  final explicit = _kindArg(kind);
  final whole = _stripFillers(target);
  if (explicit == null || explicit == OrbKind.task) {
    for (final p in _taskPatterns) {
      final m = p.firstMatch(whole);
      if (m == null) continue;
      final rest = whole
          .replaceRange(m.start, m.end, ' ')
          .replaceAll(RegExp(r'的|频道|channel', caseSensitive: false), ' ')
          .trim();
      return OrbParsedTarget(
        whole: whole,
        core: rest,
        hint: OrbKind.task,
        taskNumber: int.parse(m[1]!),
        taskChannelHint: rest.isEmpty ? null : rest,
      );
    }
  }
  if (explicit == OrbKind.task) {
    final bare = RegExp(r'^[#＃]?\s*(\d{1,7})$').firstMatch(whole);
    if (bare != null) {
      return OrbParsedTarget(
        whole: whole,
        core: '',
        hint: OrbKind.task,
        taskNumber: int.parse(bare[1]!),
      );
    }
  }
  var core = whole;
  OrbKind? hint = explicit;
  for (final (k, re) in _kindWords) {
    final m = re.firstMatch(core);
    if (m == null) continue;
    // "Cody 的私信" names the kind after the name; a bare "频道" is no name.
    final rest = core.replaceRange(m.start, m.end, ' ').trim();
    if (orbNormalize(rest).isEmpty) continue;
    core = rest;
    hint ??= k;
    break;
  }
  if (hint == OrbKind.dm || hint == null) {
    final withMatch = _chatWith.firstMatch(core);
    final tailMatch = _chatTail.firstMatch(core);
    if (withMatch != null || tailMatch != null) {
      var rest = core;
      if (tailMatch != null) rest = rest.replaceFirst(_chatTail, '');
      if (withMatch != null) rest = rest.replaceFirst(_chatWith, '');
      if (orbNormalize(rest).isNotEmpty) {
        core = rest.trim();
        hint ??= OrbKind.dm;
      }
    }
  }
  return OrbParsedTarget(whole: whole, core: core.trim(), hint: hint);
}

/// A name must score at least this to be offered; a short name must be exact.
double _threshold(String normalizedCore) => normalizedCore.length <= 3
    ? 0.99
    : normalizedCore.length <= 5
    ? 0.8
    : 0.72;

/// Two matches this close are not told apart: the person chooses.
const _ambiguityMargin = 0.06;

int _kindRank(OrbKind k) => switch (k) {
  OrbKind.page => 0,
  OrbKind.channel => 1,
  OrbKind.dm => 2,
  OrbKind.profile => 3,
  OrbKind.person => 3,
  OrbKind.task => 4,
  OrbKind.thread => 5,
};

double _dice(String a, String b) {
  if (a.length < 2 || b.length < 2) return a == b ? 1 : 0;
  Map<String, int> grams(String s) {
    final m = <String, int>{};
    for (var i = 0; i < s.length - 1; i++) {
      m.update(s.substring(i, i + 2), (v) => v + 1, ifAbsent: () => 1);
    }
    return m;
  }

  final x = grams(a), y = grams(b);
  var hit = 0;
  for (final e in x.entries) {
    hit += math.min(e.value, y[e.key] ?? 0);
  }
  return 2 * hit / ((a.length - 1) + (b.length - 1));
}

/// Page names match by spelling only (a recognizer mishears names, not the
/// App's own words), and a name inside a sentence is not a page.
double _pageScore(String heard, OrbDestination d) {
  final h = orbNormalize(heard);
  if (h.isEmpty) return 0;
  var best = 0.0;
  for (final name in d.names) {
    final n = orbNormalize(name);
    if (n.isEmpty) continue;
    if (h == n) return 1;
    if (n.length >= 5 && h.length >= 5) {
      final s = 1 - orbEditDistance(h, n) / math.max(h.length, n.length);
      if (s >= 0.85) best = math.max(best, s * 0.95);
    }
  }
  return best;
}

List<OrbMatch> _rank(List<OrbMatch> found) {
  final list = [...found];
  list.sort((a, b) {
    final s = b.score.compareTo(a.score);
    if (s != 0) return s;
    final k = _kindRank(a.kind).compareTo(_kindRank(b.kind));
    if (k != 0) return k;
    final t = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return t != 0 ? t : a.id.compareTo(b.id);
  });
  return list;
}

/// Resolves what the person said to one place, or to the choices.
///
/// Deterministic: the same words and directory always give the same answer.
/// [kind] is the optional hint of the tool (`page`, `channel`, `dm`, `person`,
/// `profile`, `task`, `thread`).
OrbResolution resolveOrbTarget(
  String target,
  OrbDirectory directory, {
  String? kind,
}) {
  if (orbNormalize(target).isEmpty) {
    return const OrbResolution.none('没听清要去哪里，请说一个页面、频道、私信或任务');
  }
  final parsed = parseOrbTarget(target, kind: kind);
  final hint = parsed.hint;

  if (hint == OrbKind.task && parsed.taskNumber != null) {
    final n = parsed.taskNumber!;
    return OrbResolution.match(
      OrbMatch(
        kind: OrbKind.task,
        id: '#$n',
        title: '任务 #$n',
        score: 1,
        reason: '任务编号 $n',
        data: {'number': n, 'channelHint': parsed.taskChannelHint},
      ),
    );
  }

  final found = <OrbMatch>[];
  final coreKey = orbNormalize(parsed.core);
  final wholeKey = orbNormalize(parsed.whole);

  // Pages (the App's own destinations).
  if (hint == null || hint == OrbKind.page) {
    for (final d in orbVocabulary) {
      var score = _pageScore(parsed.whole, d);
      if (hint == null) score = math.max(score, _pageScore(parsed.core, d));
      if (score >= 0.85) {
        found.add(
          OrbMatch(
            kind: OrbKind.page,
            id: d.id,
            title: d.zhName,
            score: score,
            reason: '页面「${d.zhName}」',
          ),
        );
      }
    }
  }

  final threshold = _threshold(coreKey.isEmpty ? wholeKey : coreKey);

  // Channels.
  if (hint == null || hint == OrbKind.channel) {
    for (final c in directory.channels) {
      final score = orbNameScore(parsed.core, c.name);
      if (score >= threshold) {
        found.add(
          OrbMatch(
            kind: OrbKind.channel,
            id: c.id,
            title: '#${c.name}',
            score: c.archived ? score * 0.97 : score,
            reason: score >= 0.99 ? '频道 #${c.name}' : '频道名相近：#${c.name}',
          ),
        );
      }
    }
  }

  // Private conversations.
  final dmPeers = <String>{};
  if (hint == null || hint == OrbKind.dm) {
    for (final d in directory.dms) {
      final score = orbNameScore(parsed.core, d.name);
      if (score >= threshold) {
        if (d.peerId != null) dmPeers.add(d.peerId!);
        found.add(
          OrbMatch(
            kind: OrbKind.dm,
            id: d.id,
            title: '和 ${d.name} 的私信',
            score: score,
            reason: score >= 0.99 ? '和 ${d.name} 的私信' : '私信对象名字相近：${d.name}',
            data: {'peerId': d.peerId, 'peerType': d.peerType},
          ),
        );
      }
    }
  }

  // People (a profile page; or the DM that does not exist yet).
  final people = <OrbMatch>[];
  if (hint == null ||
      hint == OrbKind.person ||
      hint == OrbKind.profile ||
      hint == OrbKind.dm) {
    for (final p in directory.people) {
      final score = orbNameScore(parsed.core, p.name);
      if (score < threshold) continue;
      final agent = p.type == 'agent';
      people.add(
        OrbMatch(
          kind: OrbKind.profile,
          id: p.id,
          title: '${p.name} 的资料',
          score: score,
          reason: score >= 0.99
              ? '${agent ? 'Agent' : '成员'} ${p.name} 的资料'
              : '${agent ? 'Agent' : '成员'}名字相近：${p.name}',
          data: {'profileKind': agent ? 'agent' : 'human', 'name': p.name},
        ),
      );
    }
  }
  if (hint == OrbKind.profile || hint == OrbKind.person) {
    found.addAll(people);
  } else if (hint == null) {
    // A person who already has a DM is that DM; the profile is only for
    // someone to whom there is no DM.
    found.addAll([
      for (final p in people)
        if (!dmPeers.contains(p.id)) p,
    ]);
  } else if (hint == OrbKind.dm && !found.any((m) => m.kind == OrbKind.dm)) {
    // "Cody 的私信" with no DM: the person exists, the conversation does not.
    final best = _rank(people);
    if (best.isNotEmpty) {
      return OrbResolution.none(
        '还没有和 ${best.first.data['name']} 的私信',
        suggestion: best.first,
      );
    }
  }

  // Discussions, by the message they hang under.
  if (hint == OrbKind.thread) {
    for (final t in directory.threads) {
      final title = orbNormalize(t.title);
      if (coreKey.isEmpty || title.isEmpty) continue;
      final score = title.contains(coreKey) && coreKey.length >= 2
          ? 0.9
          : _dice(coreKey, title);
      if (score >= 0.5) {
        found.add(
          OrbMatch(
            kind: OrbKind.thread,
            id: t.parentMessageId,
            title:
                '${t.channelName == null ? '' : '#${t.channelName} › '}${t.title}',
            score: score,
            reason: '讨论：${t.title}',
            data: {
              'parentChannelId': t.parentChannelId,
              'parentMessageId': t.parentMessageId,
              'threadChannelId': t.threadChannelId,
            },
          ),
        );
      }
    }
  }

  if (found.isEmpty) {
    return OrbResolution.none('没有找到和「${parsed.whole}」对得上的页面、频道、私信或成员');
  }
  final ranked = _rank(found);
  final top = ranked.first;
  final close = [
    for (final m in ranked)
      if (top.score - m.score <= _ambiguityMargin) m,
  ];
  if (close.length == 1) return OrbResolution.match(top);
  return OrbResolution.candidates(ranked.take(6).toList());
}
