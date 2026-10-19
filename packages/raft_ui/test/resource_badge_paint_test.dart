import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

import 'control_transition_paint_test.dart' show pixel;

void main() {
  for (final dark in raftThemeMatrix([false, true])) {
    testWidgets(
      '${dark ? 'dark' : 'light'} resource badge paints its source shape',
      (tester) async {
        const outside = Color(0xffff8000);
        await tester.pumpWidget(
          MaterialApp(
            theme: raftTheme(dark: dark),
            home: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: const ValueKey('paint'),
                child: const ColoredBox(
                  color: outside,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: RaftResourceBadge(
                      label: 'Unread',
                      variant: RaftBadgeRecipeVariant.accent,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byType(RaftResourceBadge));
        expect(rect.height, 18);
        final corner = await pixel(tester, rect.topLeft);
        expect(
          corner,
          outside,
          reason: 'CSS rounded-full leaves the corner clear.',
        );

        expect(
          await pixel(tester, Offset(rect.center.dx, rect.top + 1)),
          isNot(outside),
          reason: 'The capsule still paints its top center.',
        );
        expect(find.text('Unread'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
