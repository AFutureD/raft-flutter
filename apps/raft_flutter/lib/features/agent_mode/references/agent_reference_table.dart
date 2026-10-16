import 'package:flutter/foundation.dart';

import '../agent_mode_data.dart' show agentOrdinal;

/// The short handle of the [n]th thing on a screen: ① ② ③ … (then ㉑, ㊱,
/// and "(51)" past that). Spoken the same way: "通过第二个", "把 ③ 指派给
/// Cody".
String agentHandle(int n) {
  if (n >= 1 && n <= 20) return String.fromCharCode(0x2460 + n - 1);
  if (n >= 21 && n <= 35) return String.fromCharCode(0x3251 + n - 21);
  if (n >= 36 && n <= 50) return String.fromCharCode(0x32B1 + n - 36);
  return '($n)';
}

/// The number a handle glyph stands for, or null.
int? agentHandleNumber(int codeUnit) {
  if (codeUnit >= 0x2460 && codeUnit <= 0x2473) return codeUnit - 0x2460 + 1;
  if (codeUnit >= 0x3251 && codeUnit <= 0x325F) return codeUnit - 0x3251 + 21;
  if (codeUnit >= 0x32B1 && codeUnit <= 0x32BF) return codeUnit - 0x32B1 + 36;
  return null;
}

/// The kinds of thing a screen can show.
abstract final class AgentEntityTypes {
  static const message = 'message';
  static const task = 'task';
  static const agent = 'agent';
  static const channel = 'channel';
  static const member = 'member';
  static const computer = 'computer';
  static const thread = 'thread';

  static const all = [message, task, agent, channel, member, computer, thread];

  /// Words that name a type, longest first inside each type.
  static const words = <String, List<String>>{
    task: ['任务', 'task'],
    agent: ['agent', '智能体', '机器人'],
    thread: ['消息串', '讨论', 'thread', '话题'],
    message: ['消息', '这句', '那句', 'message', '留言'],
    channel: ['频道', 'channel'],
    member: ['成员', '同事', 'member'],
    computer: ['电脑', '机器', 'computer'],
  };

  static const labels = <String, String>{
    task: '任务',
    agent: 'Agent',
    message: '消息',
    channel: '频道',
    member: '成员',
    computer: '电脑',
    thread: '讨论',
  };
}

/// One thing on screen: what it is, its id, how to call it.
@immutable
class AgentEntityRef {
  const AgentEntityRef({
    required this.type,
    required this.label,
    this.id,
    this.hints = const [],
    this.handle = '',
    this.index = 0,
  });

  final String type;

  /// The id in the app's data. Null only when the card was made from
  /// something that carries none (then it cannot be acted on, only talked
  /// about).
  final String? id;

  /// What the card says, short.
  final String label;

  /// Other words people use for it: the owner, the sender, the channel,
  /// `#129`.
  final List<String> hints;
  final String handle;

  /// Its number on the screen (the handle's number), from 1.
  final int index;

  AgentEntityRef at(int n) => AgentEntityRef(
    type: type,
    id: id,
    label: label,
    hints: hints,
    handle: agentHandle(n),
    index: n,
  );

  /// Parsed from the `entity` map of a frame item; null when it has none.
  static AgentEntityRef? fromJson(Object? raw) {
    if (raw is! Map || raw['type'] is! String) return null;
    return AgentEntityRef(
      type: raw['type'] as String,
      id: raw['id'] is String && (raw['id'] as String).isNotEmpty
          ? raw['id'] as String
          : null,
      label: '${raw['label'] ?? ''}',
      hints: [
        for (final h in (raw['hints'] as List?) ?? const [])
          if ('$h'.trim().isNotEmpty) '$h',
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'handle': handle,
    'n': index,
    'type': type,
    'id': ?id,
    'label': label,
  };

  String get haystack => [label, ...hints].join(' ').toLowerCase();

  @override
  bool operator ==(Object other) =>
      other is AgentEntityRef &&
      other.type == type &&
      other.id == id &&
      other.label == label &&
      other.index == index;

  @override
  int get hashCode => Object.hash(type, id, label, index);
}

/// What is on the front screen, by handle: the table the model resolves
/// "第二个", "③", "Cody 那个任务" against. Handles restart at ① on every
/// screen; only the front screen is addressable.
class AgentReferenceTable {
  AgentReferenceTable(
    this.layerId,
    Iterable<AgentEntityRef> entries, {
    this.title = '',
  }) : entries = List.unmodifiable(entries);

  static final empty = AgentReferenceTable('', const []);

  final String layerId;
  final String title;
  final List<AgentEntityRef> entries;

  bool get isEmpty => entries.isEmpty;

  /// Built from a serialized layer (`_frame`): the items that carry an
  /// `entity` get the handle of their position, counted as the voice tools
  /// count (sections do not count).
  factory AgentReferenceTable.fromFrame(
    String layerId,
    Map<String, Object?> frame,
  ) {
    final entries = <AgentEntityRef>[];
    var n = 0;
    for (final item in (frame['items'] as List?) ?? const []) {
      if (item is! Map || item['kind'] == 'section') continue;
      n++;
      final entity = AgentEntityRef.fromJson(item['entity']);
      if (entity != null) entries.add(entity.at(n));
    }
    return AgentReferenceTable(
      layerId,
      entries,
      title: '${frame['title'] ?? ''}',
    );
  }

  AgentEntityRef? byIndex(int n) =>
      entries.where((e) => e.index == n).firstOrNull;

  AgentEntityRef? byHandle(String handle) {
    final h = handle.trim();
    if (h.isEmpty) return null;
    for (final unit in h.runes) {
      final n = agentHandleNumber(unit);
      if (n != null) return byIndex(n);
    }
    return entries.where((e) => e.handle == h).firstOrNull;
  }

  /// The entry of a focus id (`layer#3`), when it belongs to this table.
  AgentEntityRef? byFocusId(String focusId) {
    final at = focusId.lastIndexOf('#');
    if (at < 0 || focusId.substring(0, at) != layerId) return null;
    final n = int.tryParse(focusId.substring(at + 1));
    return n == null ? null : byIndex(n);
  }

  /// The compact text the model reads each turn: one line, handle first.
  /// [pointed] is the card the person tapped.
  String contextText({AgentEntityRef? pointed, int max = 12}) {
    if (entries.isEmpty && pointed == null) return '';
    final buf = StringBuffer('【屏幕引用】');
    if (title.isNotEmpty) buf.write('「$title」');
    buf.write(entries.isEmpty ? ' 没有可指的东西' : ' ');
    buf.write(
      [
        for (final e in entries.take(max))
          '${e.handle}${AgentEntityTypes.labels[e.type] ?? e.type}'
              '${e.id == null ? '' : '(${e.id})'}'
              '「${_short(e.label)}」',
      ].join(' '),
    );
    if (entries.length > max) buf.write(' …共 ${entries.length} 个');
    if (pointed != null) {
      buf.write(
        ' 用户刚点了：${pointed.handle}${AgentEntityTypes.labels[pointed.type] ?? pointed.type}'
        '${pointed.id == null ? '' : '(${pointed.id})'}「${_short(pointed.label)}」，“这个”就是它',
      );
    }
    return buf.toString();
  }

  static String _short(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 24 ? one : '${one.substring(0, 24)}…';
  }

  List<Map<String, Object?>> toJson() => [for (final e in entries) e.toJson()];
}

/// The card the person tapped, for the next thing they say ("这个怎么了").
/// It stays until another card is tapped, the screen changes, or [ttl]
/// passes.
class AgentPointer extends ChangeNotifier {
  AgentPointer({
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 2),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration ttl;
  AgentEntityRef? _entity;
  String? _layerId;
  DateTime? _at;

  AgentEntityRef? get entity {
    final at = _at;
    if (_entity == null || at == null) return null;
    if (_now().difference(at) > ttl) return null;
    return _entity;
  }

  String? get layerId => entity == null ? null : _layerId;

  void point(String layerId, AgentEntityRef entity) {
    if (_entity == entity && _layerId == layerId) {
      _at = _now();
      return;
    }
    _entity = entity;
    _layerId = layerId;
    _at = _now();
    notifyListeners();
  }

  void clear() {
    if (_entity == null) return;
    _entity = null;
    _layerId = null;
    _at = null;
    notifyListeners();
  }

  /// A new front screen has new handles: what was pointed at no longer has
  /// a place on it.
  void screenChanged(String layerId) {
    if (_layerId != null && _layerId != layerId) clear();
  }
}

/// The answer to "which one do you mean".
@immutable
class AgentResolution {
  const AgentResolution.resolved(AgentEntityRef this.entity, this.how)
    : candidates = const [];
  const AgentResolution.ambiguous(this.candidates, this.how) : entity = null;
  const AgentResolution.none(this.candidates, this.how) : entity = null;

  final AgentEntityRef? entity;

  /// For an ask-back: what it could be.
  final List<AgentEntityRef> candidates;

  /// How it was found: handle / ordinal / pointed / name / only / none.
  final String how;

  bool get isResolved => entity != null;

  Map<String, Object?> toJson() => entity != null
      ? {'status': 'resolved', 'how': how, 'entity': entity!.toJson()}
      : {
          'status': candidates.length > 1 ? 'ambiguous' : 'none',
          'how': how,
          'message': candidates.length > 1
              ? '对得上多个，请问用户是哪一个，不要自己猜'
              : '屏幕上找不到，请问用户指的是什么，不要猜 id',
          'candidates': [for (final c in candidates.take(6)) c.toJson()],
        };
}

/// Maps what a person says to something on screen.
///
/// In order: a handle (③), an ordinal ("第二个", "最后一条"), a name with or
/// without a type ("Cody 那个任务", "#129"), then "这个/这条/它" (the card
/// tapped, else the only thing there is). It never guesses between several:
/// those come back as candidates to ask about.
AgentResolution resolveAgentReference(
  String phrase,
  AgentReferenceTable table, {
  AgentEntityRef? pointed,
}) {
  final text = phrase.trim();
  final entries = table.entries;
  if (text.isEmpty) return AgentResolution.none(entries, 'none');

  // 1. A handle glyph.
  for (final unit in text.runes) {
    final n = agentHandleNumber(unit);
    if (n != null) {
      final hit = table.byIndex(n);
      return hit != null
          ? AgentResolution.resolved(hit, 'handle')
          : AgentResolution.none(entries, 'handle');
    }
  }

  final lower = text.toLowerCase();
  final type = _typeOf(lower);

  // 2. An ordinal.
  final nth = agentOrdinal(text);
  final last = RegExp(r'最后|倒数第一|最末').hasMatch(text);
  if (nth != null || last) {
    final pool = type == null
        ? entries
        : [
            for (final e in entries)
              if (e.type == type) e,
          ];
    if (last && nth == null) {
      return pool.isEmpty
          ? AgentResolution.none(entries, 'ordinal')
          : AgentResolution.resolved(pool.last, 'ordinal');
    }
    if (type == null) {
      final hit = table.byIndex(nth!);
      return hit != null
          ? AgentResolution.resolved(hit, 'ordinal')
          : AgentResolution.none(entries, 'ordinal');
    }
    return nth! >= 1 && nth <= pool.length
        ? AgentResolution.resolved(pool[nth - 1], 'ordinal')
        : AgentResolution.none(entries, 'ordinal');
  }

  // 3. A name, a number, with or without a type.
  final names = _nameTokens(lower);
  if (names.isNotEmpty) {
    final pool = type == null
        ? entries
        : [
            for (final e in entries)
              if (e.type == type) e,
          ];
    final hits = [
      for (final e in pool)
        if (names.every((n) => e.haystack.contains(n))) e,
    ];
    if (hits.length == 1) return AgentResolution.resolved(hits.single, 'name');
    if (hits.length > 1) return AgentResolution.ambiguous(hits, 'name');
    return AgentResolution.none(pool.isEmpty ? entries : pool, 'name');
  }

  // 4. "这个", "那个任务", a bare type.
  final pool = type == null
      ? entries
      : [
          for (final e in entries)
            if (e.type == type) e,
        ];
  if (pointed != null && (type == null || pointed.type == type)) {
    return AgentResolution.resolved(pointed, 'pointed');
  }
  if (pool.length == 1) return AgentResolution.resolved(pool.single, 'only');
  if (pool.isEmpty) return AgentResolution.none(entries, 'none');
  return AgentResolution.ambiguous(pool, 'none');
}

String? _typeOf(String lower) {
  String? best;
  var bestAt = -1;
  for (final e in AgentEntityTypes.words.entries) {
    for (final w in e.value) {
      final at = lower.lastIndexOf(w);
      if (at > bestAt) {
        bestAt = at;
        best = e.key;
      }
    }
  }
  return best;
}

const _fillers = [
  '这个',
  '这条',
  '这张',
  '这位',
  '这件',
  '那个',
  '那条',
  '那张',
  '那位',
  '那件',
  '刚才',
  '刚刚',
  '上面',
  '下面',
  '的',
  '它',
  '这',
  '那',
  '个',
  '条',
  '张',
  '位',
  '件',
  '一',
  '把',
  '帮我',
  '我',
  '看看',
  '看下',
  '怎么样',
  '怎么了',
  '什么',
  '情况',
  '现在',
  '号',
  '说',
  '叫',
];

/// What is left of a phrase once types, deictic words and filler go: the
/// name or number the person used.
List<String> _nameTokens(String lower) {
  var s = lower;
  for (final words in AgentEntityTypes.words.values) {
    for (final w in words) {
      s = s.replaceAll(w, ' ');
    }
  }
  for (final f in _fillers) {
    s = s.replaceAll(f, ' ');
  }
  return [
    for (final t in s.split(RegExp(r'[\s,，。.？?！!:：、]+')))
      if (t.trim().isNotEmpty) t.trim(),
  ];
}
