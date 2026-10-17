import 'dart:math' as math;

/// What the person said the reply should say, when they said it, and whether
/// that reading is sure enough to hold the model to: [sure] is true only for
/// a pattern with no doubt about where the person's name ends and the words
/// begin (回他 X, a quotation, 回复/跟/告诉 + a name the App knows or an @name +
/// 说/：X). An unsure reading is never acted on.
typedef OrbReplyWords = ({String text, bool sure});

/// Reads the words out of what the person said: "回他可以" is "可以", "回复
/// 八戒说可以" is "可以", "回他“晚上看”" is "晚上看", "跟 Cody 说我马上到" is "我马上
/// 到", "告诉八戒周五可以" is "周五可以" (八戒 is a name [known] confirms). Null when
/// they gave no words ("回他一下", "回复他吧"), when two people are to be
/// answered ("回他可以，再跟 Alice 说明天见"), or when the words cannot be told
/// from the name.
///
/// [known] says whether a string is the name of a person, Agent or private
/// conversation the App has; without it no name is known.
///
/// The agent layer holds the model to the words: the card must carry them, not
/// an invention (D3: "回他可以" came out as "马上看").
OrbReplyWords? orbReplyWords(String said, {bool Function(String)? known}) {
  final s = said.trim();
  if (s.isEmpty || _clauses(s) >= 2) return null;
  bool isKnown(String name) => known?.call(name) ?? false;

  // Whatever is in quotes, when a reply verb comes before it.
  final quoted = RegExp(
    r'(?:回复|回覆|回|告诉|跟|和|对|向|发)[^“"「『]{0,12}[“"「『]([^”"」』]+)[”"」』]',
  ).firstMatch(s);
  if (quoted != null) {
    final x = _content(quoted.group(1)!);
    return x == null ? null : (text: x, sure: true);
  }

  // A verb, the person (any script, up to a dozen characters), then 说 or a
  // colon: what follows is the words.
  final say = _withSay.firstMatch(s);
  if (say != null) {
    final raw = say.group(1)!;
    final name = _cleanName(raw);
    final x = _content(say.group(2)!);
    if (x == null) return null;
    final sure = _pronoun.hasMatch(name) || raw.contains('@') || isKnown(name);
    return (text: x, sure: sure);
  }

  // 回他 X, 发给她 X: a pronoun ends where the words begin.
  for (final p in _withPronoun) {
    final m = p.firstMatch(s);
    if (m == null) continue;
    final x = _content(m.group(1)!);
    return x == null ? null : (text: x, sure: true);
  }

  // 告诉 X Y: X is a pronoun, or a name the App knows.
  final tell = RegExp('$_lead告诉\\s*(.+)\$').firstMatch(s);
  if (tell != null) {
    final x = _afterName(tell.group(1)!, isKnown);
    final c = x == null ? null : _content(x);
    return c == null ? null : (text: c, sure: true);
  }

  // 回复 X: a known name in front is stripped; otherwise the whole is taken as
  // the words but not trusted (it may be "回复八戒可以").
  final plain = RegExp('$_lead(?:回复|回覆)\\s*(.+)\$').firstMatch(s);
  if (plain != null) {
    final rest = plain.group(1)!;
    final afterName = _afterName(rest, isKnown);
    final x = _content(afterName ?? rest);
    return x == null ? null : (text: x, sure: afterName != null);
  }
  final send = RegExp('$_lead发(?:个|一个|一句|条消息)\\s*[：:，,]?\\s*(.+)\$')
      .firstMatch(s);
  if (send != null) {
    final x = _content(send.group(1)!);
    return x == null ? null : (text: x, sure: false);
  }
  return null;
}

/// The words alone (a sure reading or not): see [orbReplyWords].
String? orbReplyContent(String said, {bool Function(String)? known}) =>
    orbReplyWords(said, known: known)?.text;

const _lead = r'^(?:(?:帮我|请你?|给我|麻烦|那就?|好[，,]?|嗯[，,]?|你)\s*)*';
const _target = r'(?:他们|她们|对方|他|她)';

final _pronoun = RegExp(r'^(?:他们|她们|对方|他|她|它)$');

final _withSay = RegExp(
  '$_lead(?:回复|回覆|回|跟|和|对|向|告诉|发消息给|发给)'
  '\\s*([^说讲道：:，,。！？!?\\n]{1,12}?)\\s*(?:说|讲|道|[：:])\\s*[：:，,]?\\s*(.+)\$',
);

final _withPronoun = <RegExp>[
  RegExp('$_lead(?:回复|回覆|回)\\s*$_target\\s*[：:，,]?\\s*(.+)\$'),
  RegExp('$_lead发(?:消息)?给\\s*$_target\\s*[：:，,]?\\s*(.+)\$'),
];

/// "八戒" from " @八戒 ".
String _cleanName(String raw) => raw.replaceAll(RegExp(r'[\s@]+'), '');

/// What follows the person in [rest]: after a pronoun, or after the longest
/// name [isKnown] confirms (with an @ or spaces around it); null when it
/// starts with neither.
String? _afterName(String rest, bool Function(String) isKnown) {
  final r = rest.trimLeft();
  final pronoun = RegExp('^$_target\\s*[：:，,]?\\s*(.+)\$').firstMatch(r);
  if (pronoun != null) return pronoun.group(1);
  final body = r.startsWith('@') ? r.substring(1) : r;
  for (var n = math.min(12, body.length - 1); n >= 1; n--) {
    if (isKnown(_cleanName(body.substring(0, n)))) {
      return body.substring(n).replaceFirst(RegExp(r'^\s*[：:，,]?\s*'), '');
    }
  }
  return null;
}

/// How many separate things to say to someone the utterance holds: a clause
/// that begins with a reply verb counts. More than one: nothing is held.
int _clauses(String s) {
  final verb = RegExp(
    r'^(?:再|也|然后|并且|顺便|还有|另外|同时)*(?:帮我|请|麻烦)?'
    r'(?:回复|回覆|回[他她]|跟|和|告诉|发给|对[他她]|向[他她])',
  );
  return s
      .split(RegExp(r'[，,。；;！!？?\n]+|(?=再|然后|并且|顺便|还有|另外|同时)'))
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty && verb.hasMatch(c))
      .length;
}

final _fillerOnly = RegExp(
  r'^(?:吧|啊|哈|呀|呗|哦|啦|嘛|一下|一声|一句|一个|下|个|他|她|它|他们|她们|对方)+$',
);

/// The words, cut at the end of the sentence, without quotes and stray
/// punctuation; null when nothing is left, or only filler.
String? _content(String raw) {
  var x = raw.split(RegExp(r'[。！？!?\n]')).first;
  x = x.replaceAll(RegExp(r'^[\s“"「『‘’，,：:、]+|[\s”"」』‘’，,：:、]+$'), '');
  if (x.isEmpty || _fillerOnly.hasMatch(x)) return null;
  return x;
}

String _norm(String s) => s.toLowerCase().replaceAll(
  RegExp(r'[\s，,。.！!？?、；;：:“”"\x27‘’「」『』~～…]+'),
  '',
);

/// Whether [text] says [want]: the same words once spaces and punctuation are
/// ignored, with something around them allowed ("@Cody 可以"), and a trailing
/// 吧/啊/哈 of the person's speech allowed to be missing.
bool orbSameContent(String text, String want) {
  final t = _norm(text);
  final w = _norm(want);
  if (w.isEmpty) return true;
  if (t.contains(w)) return true;
  final bare = w.replaceAll(RegExp(r'[吧啊哈呀呗哦啦嘛]+$'), '');
  return bare.isNotEmpty && t.contains(bare);
}
