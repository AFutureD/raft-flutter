import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/row_extents.dart';

void main() {
  test('content revisions replace their numeric preparation', () {
    final message = <String, dynamic>{'content': 'hello'};
    raftRowExtents.guess('revision-churn', message, 500);
    final size = raftRowExtents.debugPreparedCacheSize;
    for (var i = 0; i < 500; i++) {
      message['content'] = 'hello-$i';
      expect(raftRowExtents.guess('revision-churn', message, 500), 66);
    }
    expect(raftRowExtents.debugPreparedCacheSize, size);
  });

  test(
    'preparations and guesses stay bounded after many metadata replacements',
    () {
      for (var i = 0; i < 4100; i++) {
        expect(
          raftRowExtents.guess('bounded-fixture-$i', {'content': 'hello'}, 500),
          66,
        );
      }
      expect(raftRowExtents.debugPreparedCacheSize, 4000);
      expect(raftRowExtents.debugGuessCacheSize, 4000);
      expect(
        raftRowExtents.guess('bounded-fixture-0', {'content': 'new'}, 700),
        66,
      );
      expect(raftRowExtents.debugPreparedCacheSize, 4000);
      expect(raftRowExtents.debugGuessCacheSize, 4000);
    },
  );

  test('empty content and non-list extras preserve their fallback rules', () {
    final message = <String, dynamic>{
      'content': null,
      'attachments': {},
      'reactions': {},
    };
    expect(raftRowExtents.guess('empty-content', message, 100), 52);
    expect(estimateMessageExtent(message, 100), 52);
  });

  test('600 unchanged messages prepare content once across resize widths', () {
    final messages = [
      for (var i = 0; i < 600; i++)
        <String, dynamic>{
          'content': List.filled(8, '中文 reading example line $i').join('\n'),
          'attachments': [
            if (i % 3 == 0) <String, dynamic>{'id': '$i'},
          ],
          'reactions': [
            if (i % 5 == 0) <String, dynamic>{'emoji': '👍'},
          ],
        },
    ];
    final before = raftRowExtents.debugContentPreparations;
    for (var step = 0; step < 12; step++) {
      for (var i = 0; i < messages.length; i++) {
        final width = 320.0 + step * 40;
        expect(
          raftRowExtents.guess('resize-fixture-$i', messages[i], width),
          estimateMessageExtent(messages[i], width),
        );
      }
    }
    expect(raftRowExtents.debugContentPreparations - before, 600);
  });

  test('same-width content edits invalidate the old guess', () {
    final message = <String, dynamic>{'content': 'hello'};
    expect(raftRowExtents.guess('edited-content', message, 300), 66);
    message['content'] = List.filled(20, '中文').join();
    expect(raftRowExtents.guess('edited-content', message, 300), 110);
  });

  test('nested attachment and reaction edits update at the same width', () {
    final attachments = <Map<String, dynamic>>[];
    final reactions = <Map<String, dynamic>>[];
    final message = <String, dynamic>{
      'content': 'hello',
      'attachments': attachments,
      'reactions': reactions,
    };
    expect(raftRowExtents.guess('edited-extras', message, 500), 66);
    attachments.add({'id': 'attachment'});
    expect(raftRowExtents.guess('edited-extras', message, 500), 206);
    reactions.add({'emoji': '👍'});
    expect(raftRowExtents.guess('edited-extras', message, 500), 238);
    attachments.clear();
    reactions.clear();
    expect(raftRowExtents.guess('edited-extras', message, 500), 66);
  });

  test(
    'replacement metadata and absent metadata cannot reuse another guess',
    () {
      expect(
        raftRowExtents.guess('replaced-content', {'content': 'hello'}, 300),
        66,
      );
      final replacement = <String, dynamic>{
        'content': List.filled(20, '中文').join(),
      };
      expect(raftRowExtents.guess('replaced-content', replacement, 300), 110);
      expect(raftRowExtents.guess('replaced-content', null, 300), 96);
    },
  );

  test(
    'fences, blank lines, CJK, emoji and clipping preserve height rules',
    () {
      final examples = <(Map<String, dynamic>, double, double)>[
        ({'content': 'abc\n\n```dart\nx\n```\ny'}, 500, 140),
        ({'content': '😀👍'}, 300, 66),
        ({'content': List.filled(20, '中文').join()}, 300, 110),
        (
          {
            'content': List.filled(5000, 'x').join(),
            'attachments': [{}, {}, {}],
            'reactions': [{}],
          },
          300,
          852,
        ),
      ];
      for (var i = 0; i < examples.length; i++) {
        final (message, width, expected) = examples[i];
        expect(estimateMessageExtent(message, width), expected);
        expect(
          raftRowExtents.guess('height-rules-$i', message, width),
          expected,
        );
      }
    },
  );
}
