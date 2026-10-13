// Every English literal the app passes to `raftText` / `raftFormat` / a local
// `tr(...)` wrapper must have a Chinese entry in `raftChinese`, otherwise a zh
// user sees English (for example the channel "Add members" page). Run as a
// source scan of apps/raft_flutter/lib and packages/raft_ui/lib.
//
// Also rejects interpolated literals (`raftText(c, 'Joins #$name ...')`), which
// can never match a catalog key: use `raftFormat` with a `{placeholder}`.
//
// Chinese wording comes from Web's zh-cn catalog
// (packages/web/src/i18n/messages/zh-cn.ts); never invent it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart' show raftChinese;

/// Literals that are intentionally identical in every locale (no entry needed).
const _sameInEveryLocale = <String>{};

/// Error copy that has no Web zh-cn wording yet. zh users see the English until
/// Kevin decides the wording; each entry is listed in the error-presentation
/// handoff. Never invent Chinese for these.
const _pendingKevinZh = <String>{
  // Settings > Resources > Storage (native-only attachment cache; Web has no
  // counterpart). Proposed zh, not final: 存储 / 附件缓存 / 清除缓存 /
  // 缓存已清除。 / 正在清除… / 正在计算… / 缓存大小：{size}. Also shown from
  // raft_ui widget parameters: 'Storage', 'Attachment cache' and the
  // description under it.
  'Clear cache',
  'Attachments will be downloaded again the next time you open them. Your sign-in, drafts, settings and files you saved are not affected.',
  'Clearing…',
  'Cache cleared.',
  'Calculating…',
  'Cache size: {size}',
  // Settings > About > Updates card (native only; Web updates itself).
  // Proposed zh, not final: 已是最新版本 / 上次检查：{time} / 正在检查更新… /
  // 检查更新 / 无法检查更新 / 此版本不支持检查更新 / 尚未检查更新 /
  // 请检查网络连接后重试。 / iOS 版本不通过 GitHub 发布分发。 /
  // 只有 AppImage 版本可以检查更新。 / 这是没有 CI 构建号的开发版本。 /
  // 此平台不通过 GitHub 发布更新。
  "You're on the latest version",
  'Last checked: {time}',
  'Checking for updates…',
  'Check for updates',
  "Couldn't check for updates",
  'Check your connection and try again.',
  'Not checked for updates yet',
  "Update checks aren't available for this build",
  "iOS builds aren't distributed through GitHub releases.",
  'Only the AppImage build can check for updates.',
  'This is a development build without a CI build number.',
  "This platform isn't updated from GitHub releases.",
  // channel settings: a stale mounted action is refused (Web has no copy)
  'Channel editing is no longer available.',
  'Channel activity preference is no longer available.',
};

class _Use {
  const _Use(this.file, this.line, this.text, {this.interpolated = false});
  final String file;
  final int line;
  final String text;
  final bool interpolated;
}

Iterable<File> _sources() sync* {
  for (final root in ['lib', '../../packages/raft_ui/lib']) {
    for (final e in Directory(root).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.endsWith('.g.dart')) continue;
      // The catalog itself and the preview galleries are not UI.
      if (e.path.endsWith('localization.dart')) continue;
      yield e;
    }
  }
}

final _call = RegExp(
  r'(?<![\w.$])(raftText|raftFormat|raftRichText|tr|RaftUserError|showRaftToast)\(',
);

/// `userErrorText(e, fallback: 'Failed to ...')`: the fallback is a catalog key
/// shown through raftText by the display layer.
final _fallback = RegExp(r'\bfallback:\s*(?=[\x27"])');

/// Index just past the string literal starting at [i] (quote char at [i]).
int _skipString(String s, int i) {
  final q = s[i];
  var j = i + 1;
  while (j < s.length) {
    final c = s[j];
    if (c == r'\') {
      j += 2;
      continue;
    }
    if (c == r'$' && j + 1 < s.length && s[j + 1] == '{') {
      var depth = 1;
      j += 2;
      while (j < s.length && depth > 0) {
        if (s[j] == '{') depth++;
        if (s[j] == '}') depth--;
        if (s[j] == "'" || s[j] == '"') {
          j = _skipString(s, j);
          continue;
        }
        j++;
      }
      continue;
    }
    if (c == q) return j + 1;
    j++;
  }
  return s.length;
}

/// Splits the balanced argument list that starts after the `(` at [open].
List<String> _args(String s, int open) {
  final args = <String>[];
  var depth = 0, start = open + 1, i = open + 1;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
      continue;
    }
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) {
      if (depth == 0) {
        args.add(s.substring(start, i));
        return args;
      }
      depth--;
    }
    if (c == ',' && depth == 0) {
      args.add(s.substring(start, i));
      start = i + 1;
    }
    i++;
  }
  return args;
}

String _stripInterpolation(String body) => body
    .replaceAll(RegExp(r'\$\{[^}]*\}'), '')
    .replaceAll(RegExp(r'\$\w+'), '');

String _unescape(String raw) => raw
    .replaceAll(r"\'", "'")
    .replaceAll(r'\"', '"')
    .replaceAll(r'\n', '\n')
    .replaceAll(r'…', '…')
    .replaceAll(r'\$', r'$')
    .replaceAll(r'\\', r'\');

/// The literal value when [arg] is only adjacent string literals.
({String value, bool interpolated})? _literal(String arg) {
  final a = arg.trim();
  if (a.isEmpty || (a[0] != "'" && a[0] != '"')) return null;
  final b = StringBuffer();
  var interpolated = false, i = 0;
  while (i < a.length) {
    if (a[i] == "'" || a[i] == '"') {
      final end = _skipString(a, i);
      final body = a.substring(i + 1, end - 1);
      // Only interpolation that sits inside fixed English is a defect; a
      // value-only string (`'$error'`) carries user data, not UI copy.
      if (RegExp(r'(?<!\\)\$').hasMatch(body) &&
          RegExp(r'[A-Za-z]').hasMatch(_stripInterpolation(body))) {
        interpolated = true;
      }
      b.write(_unescape(body));
      i = end;
    } else if (a[i].trim().isEmpty) {
      i++;
    } else {
      return null; // `'a' + b`, `'a'.length`, ... not a plain literal
    }
  }
  return (value: b.toString(), interpolated: interpolated);
}

/// Literals chosen by a ternary / switch argument: `c ? 'A' : 'B'`,
/// `switch (x) { 'k' => 'Text' }`. Comparison operands and switch patterns are
/// not text.
Iterable<String> _branchLiterals(String arg) sync* {
  if (!arg.contains('?') && !arg.contains('switch')) return;
  var i = 0;
  while (i < arg.length) {
    final c = arg[i];
    if (c != "'" && c != '"') {
      i++;
      continue;
    }
    final end = _skipString(arg, i);
    final before = arg.substring(0, i).trimRight();
    final after = arg.substring(end).trimLeft();
    final comparison =
        before.endsWith('==') ||
        before.endsWith('!=') ||
        before.endsWith('.contains(') ||
        before.endsWith('case') ||
        before.endsWith('[') && after.startsWith(']') ||
        after.startsWith('=>') ||
        after.startsWith(':') && !before.endsWith('?') ||
        after.startsWith(',') && before.endsWith('{');
    final body = arg.substring(i + 1, end - 1);
    final plain = !RegExp(r'(?<!\\)\$').hasMatch(body);
    if (!comparison && plain) yield _unescape(body);
    i = end;
  }
}

List<_Use> _scan() {
  final uses = <_Use>[];
  for (final file in _sources()) {
    final s = file.readAsStringSync();
    for (final m in _call.allMatches(s)) {
      final name = m[1]!;
      // Declarations: `String tr(String s) => ...`.
      final head = s.substring((m.start - 12).clamp(0, s.length), m.start);
      if (RegExp(r'(String|Widget|void)\s+$').hasMatch(head)) continue;
      final args = _args(s, m.end - 1);
      final index = name == 'tr' || name == 'RaftUserError' ? 0 : 1;
      if (args.length <= index) continue;
      final line = '\n'.allMatches(s.substring(0, m.start)).length + 1;
      final lit = _literal(args[index]);
      if (lit != null) {
        uses.add(
          _Use(file.path, line, lit.value, interpolated: lit.interpolated),
        );
      } else {
        for (final text in _branchLiterals(args[index])) {
          uses.add(_Use(file.path, line, text));
        }
      }
    }
    for (final m in _fallback.allMatches(s)) {
      final end = _skipString(s, m.end);
      final lit = _literal(s.substring(m.end, end));
      if (lit == null) continue;
      final line = '\n'.allMatches(s.substring(0, m.start)).length + 1;
      uses.add(
        _Use(file.path, line, lit.value, interpolated: lit.interpolated),
      );
    }
  }
  return uses;
}

/// English words outside `{placeholders}` (a bare `#{name}` has none).
bool _isText(String s) =>
    RegExp(r'[A-Za-z]').hasMatch(s.replaceAll(RegExp(r'\{\w+\}'), ''));

void main() {
  test('every literal passed to raftText/raftFormat/tr has a zh entry', () {
    final uses = _scan();
    expect(uses.length, greaterThan(500), reason: 'scanner found no calls');
    final missing = <String, _Use>{};
    final interpolated = <_Use>[];
    for (final u in uses) {
      if (u.interpolated) {
        interpolated.add(u);
      } else if (_isText(_stripInterpolation(u.text)) &&
          !_sameInEveryLocale.contains(u.text) &&
          !_pendingKevinZh.contains(u.text) &&
          !raftChinese.containsKey(u.text)) {
        missing.putIfAbsent(u.text, () => u);
      }
    }
    final out = Platform.environment['RAFT_ZH_MISSING_OUT'];
    if (out != null) {
      File(out).writeAsStringSync(
        missing.entries
            .map((e) => '${e.value.file}:${e.value.line}\t${e.key}')
            .join('\n'),
      );
    }
    expect(
      interpolated.map((u) => '${u.file}:${u.line} "${u.text}"'),
      isEmpty,
      reason:
          'Interpolated literals never match a catalog key; use raftFormat '
          'with a {placeholder}.',
    );
    expect(
      missing.entries.map((e) => '${e.value.file}:${e.value.line} "${e.key}"'),
      isEmpty,
      reason:
          'English shown to zh users. Add the Web zh-cn wording '
          '(packages/web/src/i18n/messages/zh-cn.ts) to raftChinese in '
          'packages/raft_ui/lib/src/localization.dart.',
    );
  });
}
