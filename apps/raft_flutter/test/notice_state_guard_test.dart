import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'notice_state_allowlist.dart';

/// Transient-notice guard (Kevin 2026-10-13: the "wait for uploads" banner
/// outlived its cause because the notice was a free-floating string that only
/// some paths remembered to clear).
///
/// A notice, error row or inline warning is set imperatively and must stop
/// showing when its cause ends. lib/data/cause_notice.dart (`CauseNotice` /
/// `CauseNotices`) binds a message to a cause predicate and a scope, so it
/// cannot go stale. This test lists every imperative notice holder:
///
///  1. a field declaration whose name says error / notice / warning / failure
///     and whose type is a plain String / bool / Map holding the message;
///  2. a call of the controller setters `setError(` / `setComposerError(`.
///
/// Each must be either a `CauseNotice` (not listed) or allowlisted in
/// notice_state_allowlist.dart with the clear condition that ends it. Entries
/// are matched by file and trimmed source line; one that no longer matches
/// fails the test, so the list cannot rot. Set RAFT_NOTICE_GUARD_OUT to a path
/// to write the unlisted hits in allowlist format.
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

String _rel(String path) => path.startsWith('lib/')
    ? 'apps/raft_flutter/$path'
    : path.replaceFirst('../../', '');

/// `String? error;`, `String error = '', billingNotice = '';`,
/// `bool selectionNotice = false;`, `Map<String, String> _composerErrors`.
final _field = RegExp(
  r'^\s*(?:late\s+)?(?:String\??|bool|var|Map<[^>]*String[^>]*>)\s+'
  r'(?:\w+\s*(?:=\s*[^,;()]+)?,\s*)*'
  r'_?\w*(?:[eE]rror|[nN]otice|[wW]arning|[fF]ailure)s?\b[^(]*;\s*$',
);
final _setter = RegExp(r'\b(?:setError|setComposerError)\(');
final _definition = RegExp(r'\bvoid\s+(?:setError|setComposerError)\(');

List<_Hit> _hits() {
  final hits = <_Hit>[];
  for (final file in _sources()) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final t = line.trim();
      if (t.startsWith('//') || t.startsWith('///')) continue;
      if (_field.hasMatch(line) && !t.contains(' get ')) {
        hits.add(_Hit(file.path, i + 1, t, 'field'));
      } else if (_setter.hasMatch(line) && !_definition.hasMatch(line)) {
        hits.add(_Hit(file.path, i + 1, t, 'setter call'));
      }
    }
  }
  return hits;
}

void main() {
  test('every imperative notice holder is cause-bound or documented', () {
    final used = <String, Set<String>>{};
    final bad = <_Hit>[];
    for (final h in _hits()) {
      final file = _rel(h.file);
      if (noticeStateAllow[file]?.containsKey(h.text) ?? false) {
        (used[file] ??= {}).add(h.text);
      } else {
        bad.add(_Hit(file, h.line, h.text, h.kind));
      }
    }
    final stale = <String>[
      for (final f in noticeStateAllow.entries)
        for (final line in f.value.keys)
          if (!(used[f.key]?.contains(line) ?? false)) '${f.key}: $line',
    ];
    final out = Platform.environment['RAFT_NOTICE_GUARD_OUT'];
    if (out != null) {
      File(out).writeAsStringSync(
        bad.map((h) => '${h.file}\t${h.line}\t${h.kind}\t${h.text}').join('\n'),
      );
    }
    expect(
      bad.map((h) => '${h.file}:${h.line} [${h.kind}] ${h.text}'),
      isEmpty,
      reason:
          'A transient notice must end with its cause. Hold it in a '
          'CauseNotice / CauseNotices (lib/data/cause_notice.dart) so it '
          'expires when its predicate turns false or its scope changes, or '
          'add an entry to test/notice_state_allowlist.dart naming the '
          'conditions that clear it (cause gone, input changed, retry '
          'succeeded, navigation, dialog closed, sign-out or server switch).',
    );
    expect(
      stale,
      isEmpty,
      reason: 'Remove allowlist entries that no longer match.',
    );
  });
}
