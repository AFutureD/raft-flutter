import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

import 'parity/parity_harness.dart' show loadParityFonts;

void main() {
  testWidgets(
    'Source task row measures fractional card without stretching it',
    (tester) async {
      await tester.runAsync(loadParityFonts);
      var opens = 0;
      final theme = raftTheme();
      final tokens = theme.extension<RaftTokens>()!;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: DefaultTextStyle(
                style: RaftTaskSectionRecipe(tokens).documentStyle,
                child: SizedBox(
                  width: 358,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SourceTaskRowExtent(
                        // The Raft card's own height is a whole number of
                        // pixels, so force the fractional box the DOM can
                        // measure (a quarter pixel over the natural height).
                        child: SizedBox(
                          height: 167.25,
                          child: RaftTaskCard(
                            title: 'Align the tabbar capture crops between React and Android',
                            description: 'Both providers must wrap exactly the tabbar at width 390.',
                            channel: 'design',
                            number: '214',
                            status: 'todo',
                            statusOptions: raftTaskStatuses,
                            onStatus: (_) {},
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SourceTaskRowExtent(
                        child: RaftTaskCard(
                          title: 'Review the thread header strip baselines',
                          channel: 'design',
                          number: '210',
                          status: 'in_review',
                          statusOptions: raftTaskStatuses,
                          onStatus: (_) {},
                          onTap: () => opens++,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final cards = find.byType(RaftTaskCard);
      final rows = find.byType(SourceTaskRowExtent);
      // A fractional first card of 167.25px: tanstack rounds the observed
      // extent to 167px, then adds its 10px inter-row gap.
      expect(tester.getSize(cards.first).height, 167.25);
      expect(tester.getSize(rows.first).height, 167);
      expect(tester.getTopLeft(cards.last).dy, 177);
      await tester.tap(find.text('Review the thread header strip baselines'));
      expect(opens, 1);
      await tester.tap(find.text('In Review'));
      await tester.pumpAndSettle();
      expect(find.byType(RaftInlineBadgeMenu), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
