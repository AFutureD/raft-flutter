/// What the person said the reply should say, when they said it: "回他可以"
/// is "可以", "回复他说可以合" is "可以合", "回他“晚上看”" is "晚上看", "跟他说我
/// 马上到" is "我马上到". Null when they gave no words ("回他一下", "回复他吧").
///
/// The agent layer holds the model to it: the card must carry these words, not
/// an invention (D3: "回他可以" came out as "马上看").
String? orbReplyContent(String said) {
  var s = said.trim();
  if (s.isEmpty) return null;
  // Whatever is in quotes, when a reply verb comes before it.
  final quoted = RegExp(
    r'(?:回复|回覆|回|告诉|跟|和|对|向|发)[^“"「『]{0,12}[“"「『]([^”"」』]+)[”"」』]',
  ).firstMatch(s);
  if (quoted != null) return _content(quoted.group(1)!);
  for (final p in _patterns) {
    final m = p.firstMatch(s);
    if (m == null) continue;
    // "回复 Cody 说可以合": the name is who, not what.
    final named = RegExp(r'^[A-Za-z][\w·]{0,11}\s*(?:说|：|:)\s*(.+)$')
        .firstMatch(m.group(m.groupCount)!);
    final x = _content(named?.group(1) ?? m.group(m.groupCount)!);
    if (x != null) return x;
  }
  return null;
}

const _lead = r'^(?:(?:帮我|请你?|给我|麻烦|那就?|好[，,]?|嗯[，,]?|你)\s*)*';
const _target = r'(?:他们|她们|对方|他|她)';
const _sep = r'\s*(?:说|讲|道|[：:，,])?\s*';

// "回" alone is a verb of many words (回头, 回来): it needs the person after
// it. "回复" does not.
final _patterns = <RegExp>[
  RegExp('$_lead(?:回复|回覆)\\s*(?:$_target)?$_sep(.+)\$'),
  RegExp('$_lead回\\s*$_target$_sep(.+)\$'),
  RegExp('$_lead(?:回复|回覆|回)\\s*([\\w一-龥·]{1,12}?)\\s*(?:说|：|:)\\s*(.+)\$'),
  RegExp('$_lead(?:跟|和|对|向)\\s*$_target\\s*(?:说|讲|道)\\s*[：:，,]?\\s*(.+)\$'),
  RegExp('$_lead告诉\\s*$_target\\s*[：:，,]?\\s*(.+)\$'),
  RegExp('$_lead发(?:消息)?给\\s*$_target$_sep(.+)\$'),
  RegExp('$_lead发(?:个|一个|一句|条消息)\\s*[：:，,]?\\s*(.+)\$'),
];

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
