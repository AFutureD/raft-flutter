import 'dart:math' as math;

/// Matching that survives speech recognition: "Roughslutter", "RA flutter" and
/// "raftflutter" all mean `raft-flutter`.
///
/// Two readings of a name are compared and the better one counts:
///  * the spelling, normalized (case, spaces, hyphens, punctuation gone) and
///    compared by edit distance;
///  * the sound, a consonant skeleton (vowels gone, doubled letters merged,
///    `ph`->`f`, `ck`->`k`, `ough`->`uf`, ...) compared by an edit distance
///    in which consonants a recognizer mixes up (f/s, t/d, p/b, ...) cost
///    less than a different one.
/// Everything is pure and deterministic.

/// Lower case, full-width to ASCII, and only letters, digits and CJK left:
/// `#Raft-Flutter` and `raft flutter` both become `raftflutter`.
String orbNormalize(String input) {
  final out = StringBuffer();
  for (final rune in input.runes) {
    var c = rune;
    // Full-width ASCII (ＡＢＣ１２３) to ASCII.
    if (c >= 0xFF01 && c <= 0xFF5E) c = c - 0xFEE0;
    final ch = String.fromCharCode(c).toLowerCase();
    if (_isWordChar(ch.runes.first)) out.write(ch);
  }
  return out.toString();
}

bool _isWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0xC0 && c <= 0x24F) ||
    (c >= 0x3040 && c <= 0x30FF) ||
    (c >= 0x3400 && c <= 0x4DBF) ||
    (c >= 0x4E00 && c <= 0x9FFF) ||
    (c >= 0xAC00 && c <= 0xD7AF);

bool _isCjk(int c) =>
    (c >= 0x3040 && c <= 0x30FF) ||
    (c >= 0x3400 && c <= 0x4DBF) ||
    (c >= 0x4E00 && c <= 0x9FFF) ||
    (c >= 0xAC00 && c <= 0xD7AF);

const _vowels = 'aeiouy';

/// The sound skeleton of an already normalized string (see the file doc).
/// Characters other than a-z (digits, CJK) stay as they are.
String orbPhonetic(String normalized) {
  var s = normalized;
  for (final rule in _soundRules) {
    s = s.replaceAllMapped(rule.$1, rule.$2);
  }
  final out = StringBuffer();
  String? last;
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    if (_vowels.contains(ch)) continue;
    if (ch == last) continue;
    out.write(ch);
    last = ch;
  }
  return out.toString();
}

final List<(RegExp, String Function(Match))> _soundRules = [
  (RegExp('ough'), (_) => 'uf'),
  (RegExp('augh'), (_) => 'af'),
  (RegExp('igh'), (_) => 'i'),
  (RegExp('gh'), (_) => 'g'),
  (RegExp('gn'), (_) => 'n'),
  (RegExp('mb\$'), (_) => 'm'),
  (RegExp('ph'), (_) => 'f'),
  (RegExp('ck'), (_) => 'k'),
  (RegExp('^kn'), (_) => 'n'),
  (RegExp('^wr'), (_) => 'r'),
  (RegExp('qu'), (_) => 'kw'),
  (RegExp('x'), (_) => 'ks'),
  (RegExp('q'), (_) => 'k'),
  (RegExp('sh'), (_) => 'x'),
  (RegExp('th'), (_) => 't'),
  (RegExp('dg'), (_) => 'j'),
  (RegExp('c(?=[eiy])'), (_) => 's'),
  (RegExp('c(?!h)'), (_) => 'k'),
  (RegExp('z'), (_) => 's'),
  (RegExp('v'), (_) => 'f'),
  (RegExp('w'), (_) => 'u'),
];

/// Consonants a recognizer or a listener mixes up. Substituting one for the
/// other costs [_confusableCost]; any other substitution costs 1.
const _confusable = <String>{
  'fs', 'sz', 'td', 'pb', 'kg', 'mn', 'lr', 'fh', 'sx', 'tk', 'ds', 'ts', 'jg',
};
const _confusableCost = 0.4;

bool _confusableChars(String a, String b) =>
    _confusable.contains('$a$b') || _confusable.contains('$b$a');

/// Edit distance with cheap confusable substitutions.
double _weightedDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length.toDouble();
  if (b.isEmpty) return a.length.toDouble();
  final x = a.runes.map(String.fromCharCode).toList();
  final y = b.runes.map(String.fromCharCode).toList();
  var prev = List<double>.generate(y.length + 1, (j) => j.toDouble());
  for (var i = 1; i <= x.length; i++) {
    final cur = List<double>.filled(y.length + 1, 0);
    cur[0] = i.toDouble();
    for (var j = 1; j <= y.length; j++) {
      final sub = x[i - 1] == y[j - 1]
          ? 0.0
          : (_confusableChars(x[i - 1], y[j - 1]) ? _confusableCost : 1.0);
      cur[j] = math.min(
        math.min(cur[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + sub,
      );
    }
    prev = cur;
  }
  return prev[y.length];
}

/// Plain edit distance of two strings (insert, delete, replace cost 1).
int orbEditDistance(String a, String b) {
  if (a == b) return 0;
  final x = a.runes.toList(), y = b.runes.toList();
  if (x.isEmpty) return y.length;
  if (y.isEmpty) return x.length;
  var prev = List<int>.generate(y.length + 1, (j) => j);
  for (var i = 1; i <= x.length; i++) {
    final cur = List<int>.filled(y.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= y.length; j++) {
      cur[j] = math.min(
        math.min(cur[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1),
      );
    }
    prev = cur;
  }
  return prev[y.length];
}

bool _hasCjk(String s) => s.runes.any(_isCjk);

/// How well [heard] names [name], 0..1. Both are raw text; they are
/// normalized here.
///
/// 1.0 is the same name once case, spaces and punctuation are ignored. A
/// part of the name (at least 4 letters, or 2 Chinese characters) scores 0.86,
/// the name inside a longer phrase 0.9. Otherwise the better of the spelling
/// similarity and the (discounted) sound similarity.
double orbNameScore(String heard, String name) {
  final h = orbNormalize(heard), n = orbNormalize(name);
  if (h.isEmpty || n.isEmpty) return 0;
  if (h == n) return 1;
  final cjk = _hasCjk(h) || _hasCjk(n);
  final minPart = cjk ? 2 : 4;
  var best = 0.0;
  if (n.length >= minPart && h.contains(n)) best = 0.9;
  if (h.length >= minPart && n.contains(h)) best = math.max(best, 0.86);
  final spelling =
      1 - orbEditDistance(h, n) / math.max(h.length, n.length).toDouble();
  best = math.max(best, spelling);
  // A name inside the other is a partial name, not a mishearing of it.
  final partial = h.contains(n) || n.contains(h);
  if (!cjk && !partial) {
    final ph = orbPhonetic(h), pn = orbPhonetic(n);
    if (ph.length >= 3 && pn.length >= 3) {
      final d = _weightedDistance(ph, pn);
      final sound = 1 - d / math.max(ph.length, pn.length).toDouble();
      best = math.max(best, sound * 0.95);
    } else if (ph.isNotEmpty && ph == pn && spelling >= 0.5) {
      // A short name that sounds the same ("Cody", "Kodi").
      best = math.max(best, 0.8);
    }
  }
  return best;
}
