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
  // Image viewer on phones (native-only: Web has no photo-library save). The
  // long-press menu items and their result copy; Web's closest string is
  // "Save image" (message.selectShare.saveImage), a different action.
  'Save to Photos',
  'Save to Gallery',
  'Saved to Photos.',
  'Saved to Gallery.',
  'The image could not be saved.',
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
  // Browser page after a desktop social sign-in (lib/platform/oauth_return_page.dart).
  // It carries its own en/zh table (the page is served as HTML, not drawn
  // through raftText), so these are tracked here only. Web zh-cn is used where
  // Web has the string (finishingSignIn, approvedDescription, finishFailed).
  // Proposed zh, not final: 正在返回 Raft (Web: 正在返回 App) / 请返回 Raft 重试。 /
  // 登录已取消，或授权被拒绝。 / 这个登录请求已过期。 / 这个登录请求已被使用或已失效。 /
  // 这个登录链接与 Raft 发起的请求不匹配。 / 该邮箱对应的账户已存在。 / 当前已关闭注册。 /
  // 登录提供方无法确认你的账户。 / 无法连接到 Raft，它可能已被关闭。 / 无法完成登录。
  'Returning to Raft',
  'Return to Raft and try again.',
  'Sign-in was cancelled, or access was denied.',
  'This sign-in request has expired.',
  'This sign-in request was already used or is no longer valid.',
  "This sign-in link doesn't match the request Raft started.",
  'An account with this email already exists.',
  'Registration is currently disabled.',
  "The sign-in provider couldn't confirm your account.",
  'Raft could not be reached. It may have been closed.',
  'Sign-in could not be completed.',
  // channel settings: a stale mounted action is refused (Web has no copy)
  'Channel editing is no longer available.',
  'Channel activity preference is no longer available.',
  // Settings > About > Updates card, Linux AppImage in-place update (native-only;
  // Web has no counterpart). English until Kevin decides the wording; each
  // failure sentence names its cause and the next step.
  'Updating to {version} ({build})',
  'Comparing with your current version…',
  'Downloading the changes… {percent}%',
  'Verifying the update…',
  'Installing the update…',
  'Raft {version} ({build}) is installed',
  'Restart Raft to finish updating.',
  "Raft couldn't restart itself. Quit it and start it again to finish updating.",
  'Restart to finish',
  "Couldn't install the update",
  "Couldn't reach {host}. Check your connection and try again.",
  'The update server answered with an unexpected status ({status}). Try again later or download the update from the release page.',
  'This release has no update file for in-place updates. Download the new AppImage from the release page.',
  "The update files don't match this release. Download the new AppImage from the release page.",
  "The server doesn't support partial downloads. Download the new AppImage from the release page.",
  'There is not enough free space in {folder} for the update.',
  "Raft can't write to {folder}. Move the AppImage to a folder you own, or download the update from the release page.",
  'This release has no checksum to verify the update against. Download it from the release page.',
  'The downloaded update failed its integrity check and was discarded. Your current version is unchanged. Try again or download the update from the release page.',
  "The new version couldn't be moved into place. Your current version is unchanged. Download the update from the release page.",
  'The update was cancelled. Your current version is unchanged.',
  'The update stopped unexpectedly. Your current version is unchanged. Download the update from the release page.',
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
