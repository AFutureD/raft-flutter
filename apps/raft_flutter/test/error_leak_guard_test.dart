import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Error-presentation guard (Kevin 2026-10-13: error messages are not aligned
/// with Web).
///
/// Web shows a failed request as the server's own `response.data.error` text or
/// the call site's localized fallback, in a raft-ui Banner / FieldError / toast.
/// It never prints an exception object. Flutter's equivalent is the single
/// mapper `userErrorText` (apps/raft_flutter/lib/data/user_error.dart) and the
/// presentation layer in packages/raft_ui/lib/src/error_presentation.dart.
///
/// This test fails when
///  1. a caught exception variable is interpolated (`'$e'`, `'${e}'`),
///     stringified (`e.toString()`) or read for its text (`e.message`) anywhere
///     but a log call, so the raw text could reach a Text, toast or banner;
///  2. a Material `SnackBar` / `ScaffoldMessenger` / `MaterialBanner` is used
///     for feedback instead of the raft_ui toast and banner.
///
/// Every exception needs an entry below, with the reason it cannot reach the
/// user. Entries are matched by file and the trimmed source line; an entry that
/// no longer matches fails the test, so the list cannot rot.
const _allow = <String, Map<String, String>>{
  // 'apps/raft_flutter/lib/x.dart': {'trimmed source line': 'reason'},
  'apps/raft_flutter/lib/features/network_settings.dart': {
    r"final text = '${error.error}'.toLowerCase();":
        'Matched against "407" / "proxy authentication" to classify the '
        'probe failure; the result shown is one of three fixed sentences.',
  },
  'apps/raft_flutter/lib/features/attachment_view.dart': {
    'final status = error.response?.statusCode;':
        'Reads the HTTP status to decide whether to re-sign a lapsed '
        'thumbnail; no text reaches the UI.',
  },
};

/// Calls whose arguments are diagnostics, not UI.
const _sinks = [
  'debugPrint(',
  'debugPrintStack(',
  'logUserError(',
  'developer.log(',
  'print(',
  'Error.throwWithStackTrace(',
  'FlutterError.reportError(',
];

class _Hit {
  const _Hit(this.file, this.line, this.text, this.kind);
  final String file;
  final int line;
  final String text;
  final String kind;
}

Iterable<File> _sources() sync* {
  for (final root in ['lib', '../../packages/raft_ui/lib']) {
    for (final e in Directory(root).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.endsWith('.g.dart')) continue;
      yield e;
    }
  }
}

/// [source] with string/comment bodies kept (interpolation matters) but
/// comments blanked, so braces and names in comments do not count.
String _blankComments(String s) {
  final b = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      final triple = s.startsWith(c * 3, i);
      final q = triple ? c * 3 : c;
      final raw = i > 0 && s[i - 1] == 'r';
      var j = i + q.length;
      while (j < s.length) {
        if (!raw && s[j] == r'\') {
          j += 2;
          continue;
        }
        if (s.startsWith(q, j)) break;
        j++;
      }
      b.write(s.substring(i, (j + q.length).clamp(0, s.length)));
      i = j + q.length;
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        b.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      while (i < s.length &&
          !(s[i] == '*' && i + 1 < s.length && s[i + 1] == '/')) {
        b.write(s[i] == '\n' ? '\n' : ' ');
        i++;
      }
      b.write('  ');
      i += 2;
      continue;
    }
    b.write(c);
    i++;
  }
  return b.toString();
}

/// Index of the `}` closing the `{` at [open], skipping string literals.
int _closeBrace(String s, int open) {
  var depth = 0, i = open;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      final triple = s.startsWith(c * 3, i);
      final q = triple ? c * 3 : c;
      var j = i + q.length;
      while (j < s.length) {
        if (s[j] == r'\') {
          j += 2;
          continue;
        }
        if (s.startsWith(q, j)) break;
        if (!triple && s[j] == r'$' && j + 1 < s.length && s[j + 1] == '{') {
          j = _closeBrace(s, j + 1) + 1;
          continue;
        }
        j++;
      }
      i = j + q.length;
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return s.length - 1;
}

final _catchHead = RegExp(
  r'\bcatch\s*\(\s*(\w+)\s*(?:,\s*\w+\s*)?\)\s*\{|'
  r'\bcatchError\(\s*\(\s*(\w+)\s*(?:,\s*\w+\s*)?\)\s*\{|'
  r'\bonError:\s*\(\s*(\w+)\s*(?:,\s*\w+\s*)?\)\s*\{',
);

List<_Hit> _leaks() {
  final hits = <_Hit>[];
  for (final file in _sources()) {
    final raw = file.readAsStringSync();
    final s = _blankComments(raw);
    final lines = raw.split('\n');
    for (final m in _catchHead.allMatches(s)) {
      final name = m[1] ?? m[2] ?? m[3]!;
      final open = m.end - 1;
      final close = _closeBrace(s, open);
      final body = s.substring(open, close + 1);
      final use = RegExp(
        '\\\$$name\\b|\\\$\\{\\s*$name\\s*\\}|\\b$name\\.toString\\(\\)|'
        '\\b$name\\.(?:message|error|response|stackTrace)\\b|'
        '\\bText\\(\\s*$name\\s*[,)]',
      );
      for (final u in use.allMatches(body)) {
        final at = open + u.start;
        // The statement that holds the use.
        var from = at;
        while (from > open &&
            s[from - 1] != ';' &&
            s[from - 1] != '{' &&
            s[from - 1] != '}') {
          from--;
        }
        final statement = s.substring(from, at);
        if (_sinks.any(statement.contains)) continue;
        final line = '\n'.allMatches(s.substring(0, at)).length;
        if (hits.any((h) => h.file == file.path && h.line == line + 1)) {
          continue;
        }
        hits.add(
          _Hit(
            file.path,
            line + 1,
            lines[line].trim(),
            'caught exception text',
          ),
        );
      }
    }
    for (final m in RegExp(
      r'\b(SnackBar|ScaffoldMessenger|MaterialBanner|showSnackBar)\b',
    ).allMatches(s)) {
      final line = '\n'.allMatches(s.substring(0, m.start)).length;
      if (hits.any((h) => h.file == file.path && h.line == line + 1)) continue;
      hits.add(
        _Hit(file.path, line + 1, lines[line].trim(), 'Material feedback'),
      );
    }
  }
  return hits;
}

String _rel(String path) => path.startsWith('lib/')
    ? 'apps/raft_flutter/$path'
    : path.replaceFirst('../../', '');

void main() {
  test('no raw exception text or Material feedback reaches the UI', () {
    final hits = _leaks();
    final used = <String, Set<String>>{};
    final bad = <String>[];
    for (final h in hits) {
      final file = _rel(h.file);
      final allowed = _allow[file]?.containsKey(h.text) ?? false;
      if (allowed) {
        (used[file] ??= {}).add(h.text);
      } else {
        bad.add('$file:${h.line} [${h.kind}] ${h.text}');
      }
    }
    final stale = <String>[
      for (final f in _allow.entries)
        for (final line in f.value.keys)
          if (!(used[f.key]?.contains(line) ?? false)) '${f.key}: $line',
    ];
    final out = Platform.environment['RAFT_ERROR_LEAKS_OUT'];
    if (out != null) File(out).writeAsStringSync(bad.join('\n'));
    expect(
      bad,
      isEmpty,
      reason:
          'Route the error through userErrorText(e, fallback: <Web fallback '
          'copy>) and show it in RaftErrorBanner / RaftFormField(error:) / '
          'showRaftToast (packages/raft_ui/lib/src/error_presentation.dart), '
          'or add an allowlist entry with the reason it never reaches the UI.',
    );
    expect(
      stale,
      isEmpty,
      reason: 'Remove allowlist entries that no longer match.',
    );
  });
}
