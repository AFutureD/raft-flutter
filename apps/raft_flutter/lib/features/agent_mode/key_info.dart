/// What a spoken answer has to get right, whatever its wording: the facts that
/// make it correct (who, which number, what will be done, that it is a
/// question to confirm). Paraphrase, another order and filler words are fine;
/// a missing or a contradicting fact is not.
class KeyRequirement {
  const KeyRequirement(this.label, this.met);

  /// What is needed, shortly ("数字 136", "收件人 Cody").
  final String label;

  /// Whether the spoken words (see [keyCompact]) carry it.
  final bool Function(String spoken) met;
}

class KeyInfo {
  const KeyInfo({
    this.needs = const [],
    this.numbers = const {},
    this.names = const {},
    this.checkNumbers = false,
  });

  final List<KeyRequirement> needs;

  /// The digits the speech may use, when [checkNumbers] (a number that is in
  /// none of them contradicts the answer).
  final Set<String> numbers;
  final bool checkNumbers;

  /// Names (lower case) that belong to the answer; any other name of
  /// [knownNames] said contradicts it.
  final Set<String> names;

  KeyInfo operator +(KeyInfo other) => KeyInfo(
    needs: [...needs, ...other.needs],
    numbers: {...numbers, ...other.numbers},
    names: {...names, ...other.names},
    checkNumbers: checkNumbers || other.checkNumbers,
  );

  /// The labels of what [spokenText] leaves out.
  List<String> missingIn(String spokenText) {
    final spoken = keyCompact(spokenText);
    return [
      for (final n in needs)
        if (!n.met(spoken)) n.label,
    ];
  }

  /// What [spokenText] says that the answer does not: a number it does not
  /// have, a name of [knownNames] that is not its.
  List<String> contradictionsIn(
    String spokenText, {
    Iterable<String> knownNames = const [],
  }) {
    final out = <String>[];
    if (checkNumbers) {
      for (final n in numbersIn(spokenText)) {
        if (!numbers.contains(n)) out.add('多出数字 $n');
      }
    }
    final spoken = keyCompact(spokenText);
    for (final k in knownNames) {
      final name = keyCompact(k);
      if (name.isNotEmpty && !names.contains(name) && spoken.contains(name)) {
        out.add('多出人名 $k');
      }
    }
    return out;
  }
}

/// Letters and digits of [text], lower case: what two wordings of the same
/// thing agree on (no spaces, no punctuation). Two digit runs that something
/// stood between stay apart ("09:26" is 09 and 26, not 0926).
String keyCompact(String text) => text
    .replaceAll(_digitBreak, '')
    .replaceAllMapped(
      RegExp(r'(\d)[^\p{L}\p{N}]+(?=\d)', unicode: true),
      (m) => '${m[1]}$_digitBreak',
    )
    .replaceAll(RegExp('[^\\p{L}\\p{N}$_digitBreak]', unicode: true), '')
    .toLowerCase();

const _digitBreak = '\uE000';

/// The digit runs of [text] ("第 10 步" -> 10, "#136" -> 136).
List<String> numbersIn(String text) => [
  for (final m in RegExp(r'\d+').allMatches(text)) m.group(0)!,
];

const _digits = '零一二三四五六七八九';

String _cardinal(int n) {
  if (n < 10) return _digits[n];
  if (n < 20) return n == 10 ? '十' : '十${_digits[n % 10]}';
  if (n < 100) {
    return '${_digits[n ~/ 10]}十${n % 10 == 0 ? '' : _digits[n % 10]}';
  }
  if (n < 1000) {
    final rest = n % 100;
    final tail = rest == 0
        ? ''
        : rest < 10
        ? '零${_digits[rest]}'
        : _cardinal(rest);
    return '${_digits[n ~/ 100]}百$tail';
  }
  return '';
}

/// The ways [digits] may be said aloud: as written, as a Chinese number
/// ("136" -> 一百三十六), digit by digit (一三六), "两" for 2.
List<String> numberForms(String digits) {
  final n = int.tryParse(digits);
  if (n == null) return [digits];
  final stripped = '$n';
  return {
    digits,
    stripped,
    if (n < 1000) _cardinal(n),
    if (n >= 10 && n < 20) '一${_cardinal(n)}',
    if (n == 2 || n == 200) '两${n == 200 ? '百' : ''}',
    stripped.split('').map((c) => _digits[int.parse(c)]).join(),
  }.where((s) => s.isNotEmpty).toList();
}

/// Whether the (compact) [spoken] has the number [digits] in some form.
bool saysNumber(String spoken, String digits) {
  for (final form in numberForms(digits)) {
    final written = RegExp(r'^\d+$').hasMatch(form);
    // "十" is not in "十一", nor "136" in "1360".
    final pattern = written
        ? '(?<!\\d)$form(?!\\d)'
        : '(?<![零一二三四五六七八九十百两])$form(?![零一二三四五六七八九十百])';
    if (RegExp(pattern).hasMatch(spoken)) return true;
  }
  return false;
}

/// How much of [content] (compact) is in [spoken] (compact): the share of its
/// two-character stretches that are there, 0 to 1. A short content (under 3
/// characters) counts as there or not.
double contentCoverage(String content, String spoken) {
  if (content.isEmpty) return 1;
  if (content.length < 3) return spoken.contains(content) ? 1 : 0;
  var total = 0, found = 0;
  for (var i = 0; i + 2 <= content.length; i++) {
    total++;
    if (spoken.contains(content.substring(i, i + 2))) found++;
  }
  return found / total;
}

/// The words that ask for a yes ("要发吗", "对不对", "确认吗", "行不行").
final asksForYes = RegExp(
  r'吗|[?？]|要不要|是否|对不对|行不行|好不好|是不是|可不可以|对吧|好吧|行吧|可以吧|发吧|确认',
);

/// Latin names and words in [text] ("Cody", "raft-flutter"), without the
/// words that are not names.
List<String> latinNamesIn(String text) => [
  for (final m in RegExp(
    r'[A-Za-z][A-Za-z0-9]*(?:[-_][A-Za-z0-9]+)*',
  ).allMatches(text))
    if (!_notNames.contains(m.group(0)!.toLowerCase()) &&
        m.group(0)!.length > 1)
      m.group(0)!,
];

const _notNames = {'app', 'agent', 'ok', 'okay', 'raft', 'ai', 'task'};
