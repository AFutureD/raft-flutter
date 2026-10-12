import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flutter's built-in `TextDecoration.underline` hugs the glyphs and cannot
/// be offset, so it differs from the hyperlink underline. All underlined text
/// goes through RaftUnderlines / RaftUnderlineSpan / RaftUnderlinedText
/// (lib/src/raft_underline.dart).
///
/// Rendering code only: tests that merely detect Flutter's missing-Material
/// fallback style (a yellow double underline) read the constant and are not
/// scanned.
const _allowlist = <String, String>{
  // 'path/relative/to/repo': 'reason',
};

void main() {
  test('no built-in TextDecoration.underline outside the shared helper', () {
    final root = Directory.current.path.endsWith('packages/raft_ui')
        ? Directory('../..')
        : Directory.current;
    final dirs = <Directory>[
      for (final group in ['packages', 'apps'])
        if (Directory('${root.path}/$group').existsSync())
          for (final entry in Directory('${root.path}/$group').listSync())
            if (entry is Directory &&
                Directory('${entry.path}/lib').existsSync())
              Directory('${entry.path}/lib'),
      Directory('${root.path}/apps/raft_flutter/test/parity/cases'),
    ];
    final offenders = <String>[];
    for (final dir in dirs.where((d) => d.existsSync())) {
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final relative = file.path.substring(root.path.length + 1);
        if (_allowlist.containsKey(relative)) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trimLeft();
          if (line.startsWith('//')) continue;
          if (RegExp(r'TextDecoration\s*\.\s*underline').hasMatch(line)) {
            offenders.add('$relative:${i + 1}: ${line.trim()}');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use RaftUnderlinedText / RaftUnderlineSpan + RaftUnderlines '
          '(raft_underline.dart) instead of TextDecoration.underline.',
    );
  });
}
