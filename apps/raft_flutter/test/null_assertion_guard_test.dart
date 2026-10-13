import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'null_assertion_allowlist.dart';

/// Hard-assertion guard (a user crashed with "Null check operator used on a
/// null value" in `_RuntimeFormFieldsState.field`: the form controller
/// published its definition before its text editors existed, and a rebuild in
/// between ran `c.editors[f.key]!`).
///
/// Widgets render whatever state the controller exposes, and that state can be
/// partial while an async load, a stream event, a disposal or an odd server
/// payload is in flight. A hard assertion in render code turns that window into
/// a red screen. This test scans lib code (apps/raft_flutter/lib and every
/// packages/*/lib, generated `*.g.dart` skipped) for, inside render code,
///
///  1. a map-index null assertion `expr[key]!`;
///  2. `.single` (throws unless the collection has exactly one element);
///  3. `firstWhere(...)` without `orElse:` (throws when nothing matches).
///
/// "Render code" is: the body of any function, method or getter declared with
/// a widget return type (`Widget`, `PreferredSizeWidget`, `List<Widget>`,
/// `Iterable<Widget>`, `Widget?`, `Sliver...`), which includes every
/// `build(` and the helpers it calls, and the value of any named `...builder:`
/// argument (`builder`, `itemBuilder`, `separatorBuilder`, `pageBuilder`, ...).
///
/// Exempt by rule, not by list: a theme token lookup (`...colors['x']!`, a
/// fixed generated map) and an integer-literal index (`m[1]!`, a RegExpMatch
/// group or fixed tuple slot). Everything else needs an entry in
/// null_assertion_allowlist.dart (file -> trimmed source line -> reason); an
/// entry that no longer matches fails the test, so the list cannot rot. Set
/// RAFT_NULL_GUARD_OUT to a path to write the unlisted hits in allowlist form.
///
/// Known blind spots (a line-level scanner, not the analyzer): it does not look
/// at `x!` on plain variables or fields, `.first` / `.last`, `as` casts or
/// `late` reads; it does not look at controller logic or event handlers that
/// are not nested in a widget function or builder (the 2026-10 sweep reviewed
/// those by hand); it keys exceptions on the trimmed source line, so one entry
/// covers every identical line in the file; a widget helper declared with an
/// alias type or with a return type of `Object` is not recognised as render
/// code.
class NullHit {
  const NullHit(this.file, this.line, this.text, this.kind);
  final String file;
  final int line;
  final String text;
  final String kind;
}

/// Source with comments and string contents blanked (newlines and the code
/// inside `${...}` interpolations kept), so brace and bracket matching is
/// reliable and line numbers are unchanged.
String blankCommentsAndStrings(String s) {
  final out = StringBuffer();
  final stack = <_Str>[];
  var i = 0;
  final n = s.length;
  bool identStart(int c) =>
      (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
  void blank(String c) => out.write(c == '\n' ? '\n' : ' ');
  while (i < n) {
    final c = s[i];
    final top = stack.isEmpty ? null : stack.last;
    if (top == null || top.inCode) {
      if (c == '/' && i + 1 < n && s[i + 1] == '/') {
        while (i < n && s[i] != '\n') {
          out.write(' ');
          i++;
        }
        continue;
      }
      if (c == '/' && i + 1 < n && s[i + 1] == '*') {
        final end = s.indexOf('*/', i + 2);
        final stop = end < 0 ? n : end + 2;
        for (; i < stop; i++) {
          blank(s[i]);
        }
        continue;
      }
      if (c == "'" || c == '"') {
        final raw =
            i > 0 &&
            s[i - 1] == 'r' &&
            (i < 2 || !identStart(s.codeUnitAt(i - 2)));
        final triple = s.startsWith(c * 3, i);
        stack.add(_Str(c, triple, raw));
        out.write(triple ? c * 3 : c);
        i += triple ? 3 : 1;
        continue;
      }
      if (top != null) {
        if (c == '{') top.brace++;
        if (c == '}') {
          top.brace--;
          if (top.brace == 0) {
            top.inCode = false;
            out.write(' ');
            i++;
            continue;
          }
        }
      }
      out.write(c);
      i++;
      continue;
    }
    // Inside string content.
    if (!top.raw && c == r'\') {
      blank(c);
      if (i + 1 < n) blank(s[i + 1]);
      i += 2;
      continue;
    }
    if (!top.raw && c == r'$' && i + 1 < n && s[i + 1] == '{') {
      top.inCode = true;
      top.brace = 1;
      out.write('  ');
      i += 2;
      continue;
    }
    if (!top.raw && c == r'$' && i + 1 < n && identStart(s.codeUnitAt(i + 1))) {
      out.write(' ');
      i++;
      while (i < n &&
          (identStart(s.codeUnitAt(i)) ||
              (s.codeUnitAt(i) >= 48 && s.codeUnitAt(i) <= 57))) {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (top.triple ? s.startsWith(top.quote * 3, i) : c == top.quote) {
      stack.removeLast();
      out.write(top.triple ? top.quote * 3 : top.quote);
      i += top.triple ? 3 : 1;
      continue;
    }
    blank(c);
    i++;
  }
  return out.toString();
}

class _Str {
  _Str(this.quote, this.triple, this.raw);
  final String quote;
  final bool triple;
  final bool raw;
  bool inCode = false;
  int brace = 0;
}

final _widgetDecl = RegExp(
  r'(?<![\w.])(?:static\s+)?'
  r'(?:Widget\??|PreferredSizeWidget|ObstructingPreferredSizeWidget|'
  r'List<Widget>|Iterable<Widget>|Sliver\w*)'
  r'\s+(?:get\s+)?(?!Function\b)_?\w+\s*(?:<[^>(){}]*>)?\s*(?=\(|=>|\{)',
);
final _builderArg = RegExp(r'\b\w*[bB]uilder\s*:\s*');

/// Marks the characters of [code] that are render code.
List<bool> renderMask(String code) {
  final n = code.length;
  final depthBefore = List<int>.filled(n + 1, 0);
  var d = 0;
  for (var i = 0; i < n; i++) {
    depthBefore[i] = d;
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') d++;
    if (c == ')' || c == ']' || c == '}') d--;
  }
  depthBefore[n] = d;
  final mask = List<bool>.filled(n, false);
  void region(int start) {
    final d0 = depthBefore[start];
    var depth = d0;
    for (var i = start; i < n; i++) {
      final c = code[i];
      mask[i] = true;
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') {
        depth--;
        if (depth < d0) return;
        // A block body that closes back to the starting depth ends the region.
        if (depth == d0 && c == '}') return;
      }
      if (depth == d0 && (c == ';' || c == ',')) return;
    }
  }

  for (final m in _widgetDecl.allMatches(code)) {
    region(m.end);
  }
  for (final m in _builderArg.allMatches(code)) {
    region(m.end);
  }
  return mask;
}

int _openBracket(String code, int close) {
  var depth = 0;
  for (var i = close; i >= 0; i--) {
    if (code[i] == ']') depth++;
    if (code[i] == '[') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

int _closeParen(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return code.length;
}

final _indexAssert = RegExp(r'\]\s*!(?!=)');
final _single = RegExp(r'\.single\b');
final _firstWhere = RegExp(r'\bfirstWhere\s*\(');

/// Hits in [source], as (offset, kind) pairs in source order.
List<(int, String)> scanSource(String source) {
  final code = blankCommentsAndStrings(source);
  final mask = renderMask(code);
  final hits = <(int, String)>[];
  for (final m in _indexAssert.allMatches(code)) {
    if (!mask[m.start]) continue;
    final open = _openBracket(code, m.start);
    if (open < 0) continue;
    final index = code.substring(open + 1, m.start).trim();
    if (RegExp(r'^\d+$').hasMatch(index)) continue;
    final before = code.substring(0, open);
    if (RegExp(r'\bcolors\s*$').hasMatch(before)) continue;
    hits.add((m.start, 'map index !'));
  }
  for (final m in _single.allMatches(code)) {
    if (mask[m.start]) hits.add((m.start, '.single'));
  }
  for (final m in _firstWhere.allMatches(code)) {
    if (!mask[m.start]) continue;
    final close = _closeParen(code, m.end - 1);
    if (!code.substring(m.end, close).contains('orElse')) {
      hits.add((m.start, 'firstWhere without orElse'));
    }
  }
  hits.sort((a, b) => a.$1.compareTo(b.$1));
  return hits;
}

List<NullHit> _hits() {
  final roots = <String>['lib'];
  for (final p in Directory('../../packages').listSync()) {
    if (p is Directory && Directory('${p.path}/lib').existsSync()) {
      roots.add('${p.path}/lib');
    }
  }
  final hits = <NullHit>[];
  for (final root in roots) {
    for (final e in Directory(root).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.endsWith('.g.dart')) continue;
      final source = e.readAsStringSync();
      final lines = source.split('\n');
      final starts = <int>[];
      var offset = 0;
      for (final l in lines) {
        starts.add(offset);
        offset += l.length + 1;
      }
      for (final (at, kind) in scanSource(source)) {
        var lo = 0, hi = starts.length - 1;
        while (lo < hi) {
          final mid = (lo + hi + 1) ~/ 2;
          if (starts[mid] <= at) {
            lo = mid;
          } else {
            hi = mid - 1;
          }
        }
        hits.add(NullHit(e.path, lo + 1, lines[lo].trim(), kind));
      }
    }
  }
  return hits;
}

String _rel(String path) => path.startsWith('lib/')
    ? 'apps/raft_flutter/$path'
    : path.replaceFirst('../../', '');

const _rule =
    "Don't hard-assert values that async loading or server data can leave "
    'absent; publish state atomically or render a loading/fallback state. If '
    'it is provably safe, add it to test/null_assertion_allowlist.dart with '
    'the reason.';

void main() {
  test('render code has no unreviewed hard null assertions', () {
    final used = <String, Set<String>>{};
    final bad = <NullHit>[];
    for (final h in _hits()) {
      final file = _rel(h.file);
      if (nullAssertionAllow[file]?.containsKey(h.text) ?? false) {
        (used[file] ??= {}).add(h.text);
      } else {
        bad.add(NullHit(file, h.line, h.text, h.kind));
      }
    }
    final stale = <String>[
      for (final f in nullAssertionAllow.entries)
        for (final line in f.value.keys)
          if (!(used[f.key]?.contains(line) ?? false)) '${f.key}: $line',
    ];
    final out = Platform.environment['RAFT_NULL_GUARD_OUT'];
    if (out != null) {
      File(out).writeAsStringSync(
        bad.map((h) => '${h.file}\t${h.line}\t${h.kind}\t${h.text}').join('\n'),
      );
    }
    expect(
      bad.map((h) => '${h.file}:${h.line} [${h.kind}] ${h.text}'),
      isEmpty,
      reason: _rule,
    );
    expect(
      stale,
      isEmpty,
      reason: 'Remove allowlist entries that no longer match.',
    );
    expect(
      [
        for (final f in nullAssertionAllow.entries)
          for (final e in f.value.entries)
            if (e.value.trim().isEmpty) '${f.key}: ${e.key}',
      ],
      isEmpty,
      reason: 'Every allowlist entry needs a one-line reason.',
    );
  });

  group('scanner', () {
    List<String> kinds(String src) => [for (final h in scanSource(src)) h.$2];

    test('flags the runtime form crash shape', () {
      expect(
        kinds('''
class F extends State<W> {
  Widget field(Field f) {
    return TextField(controller: c.editors[f.key]!);
  }
}
'''),
        ['map index !'],
      );
    });

    test('flags builder closures and arrow helpers, not other code', () {
      expect(
        kinds('''
void load() { final a = m['k']!; }
Widget row() => Text(rows[id]!.title);
Widget build(BuildContext c) {
  return ListView.builder(itemBuilder: (c, i) => Text(names[i]!));
}
int sort(a, b) => order[a]!.compareTo(order[b]!);
'''),
        ['map index !', 'map index !'],
      );
    });

    test('flags .single and firstWhere without orElse only', () {
      expect(
        kinds('''
Widget a() => Text(items.single.name);
Widget b() => Text(items.firstWhere((i) => i.ok).name);
Widget c() => Text(items.firstWhere((i) => i.ok, orElse: () => d).name);
Widget d() => Text(items.singleWhere((i) => i.ok).name);
'''),
        ['.single', 'firstWhere without orElse'],
      );
    });

    test('exempts theme tokens, literal indexes, strings and comments', () {
      expect(
        kinds('''
Widget a(t) {
  // x[1]! in a comment
  final s = 'not code m[k]!';
  final c = t.colors[t.brutal ? 'a' : 'b']!;
  final g = match[1]!;
  return Text('\${items[id]!.name}');
}
'''),
        ['map index !'],
      );
    });

    test('stops at the end of the function', () {
      expect(
        kinds('''
Widget a() {
  return const SizedBox();
}
void b() { final x = m['k']!; }
Widget c() => const SizedBox();
'''),
        isEmpty,
      );
    });
  });
}
