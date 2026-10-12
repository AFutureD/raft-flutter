import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Media UI draws its own rails (video_controls.dart, inline_media.dart): the
/// Material `Slider` (yellow thumb, tick marks, its own semantics) must not
/// come back in the app or in raft_ui.
void main() {
  test('no Material slider in app or raft_ui lib code', () {
    final roots = [Directory('lib'), Directory('../../packages/raft_ui/lib')];
    final banned = RegExp(
      r'(?<![A-Za-z0-9_])(?:Slider|RangeSlider|CupertinoSlider|SliderTheme|SliderThemeData)\b',
    );
    final hits = <String>[];
    for (final root in roots) {
      expect(root.existsSync(), isTrue, reason: root.path);
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trimLeft();
          if (line.startsWith('//')) continue;
          if (banned.hasMatch(line)) hits.add('${file.path}:${i + 1}: $line');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('the media viewer and cards use the shared rails', () {
    final controls = File('../../packages/raft_ui/lib/src/video_controls.dart')
        .readAsStringSync();
    expect(controls, contains('class RaftVideoControlBar'));
    expect(controls, contains('class _VideoRail'));
    for (final name in const ['inline_media.dart', 'video_viewer.dart']) {
      final src = File('../../packages/raft_ui/lib/src/$name')
          .readAsStringSync();
      expect(src, isNot(contains("material.dart' show Slider")));
    }
  });
}
