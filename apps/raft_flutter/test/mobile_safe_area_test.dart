import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_ui/raft_ui.dart';

import 'app_global_server_selector_test.dart' show RootFixture;

void windowMetrics(WidgetTester t, double bottom, {double keyboard = 0}) {
  t.view.viewPadding = FakeViewPadding(top: 59, bottom: bottom);
  t.view.padding = FakeViewPadding(top: 59, bottom: keyboard == 0 ? bottom : 0);
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    final inset = platform == TargetPlatform.iOS ? 34.0 : 48.0;
    for (final theme in ['brutal', 'elegant-light', 'elegant-dark']) {
      testWidgets(
        '$platform $theme root controls clear the system gesture area',
        (t) async {
          addTearDown(t.view.reset);
          windowMetrics(t, inset);
          final f = RootFixture();
          await f.mount(t, theme, 390, uri: Uri.parse('/s/alpha'));
          final w = f.workspace(t);
          final nav = find.byKey(const Key('workspace-mobile-navigation'));
          final screenBottom = t.view.physicalSize.height;

          void expectBarClearance() {
            expect(t.getRect(nav).bottom, closeTo(screenBottom - inset, .01));
            for (final id in ['home', 'tasks', 'members', 'settings']) {
              expect(
                t.getRect(find.byKey(Key('mobile-tab-$id'))).bottom,
                lessThanOrEqualTo(screenBottom - inset),
              );
            }
            if (theme != 'brutal') {
              final capsule = find.byKey(
                const ValueKey('mobile-nav-source-capsule'),
              );
              expect(
                t.getRect(capsule).bottom,
                closeTo(screenBottom - inset - 8, .01),
              );
            }
          }

          expectBarClearance();
          // The floating home list extends to the bottom, and its scroll padding
          // lets the last row clear both the capsule and the home indicator.
          final sidebar = find.byKey(const Key('workspace-sidebar'));
          if (theme != 'brutal') {
            expect(t.getRect(sidebar).bottom, screenBottom);
            final sliver = t.widget<CustomScrollView>(sidebar).slivers.first;
            expect(
              (sliver as SliverPadding).padding
                  .resolve(TextDirection.ltr)
                  .bottom,
              68 + inset,
            );
          }

          // The keyboard covers the tab bar rather than lifting it. Its dismissal
          // restores the same geometry, with the safe inset consumed once.
          windowMetrics(t, inset, keyboard: 300);
          await t.pump();
          expectBarClearance();
          windowMetrics(t, inset);
          await t.pump();
          expectBarClearance();

          for (final root in ['tasks', 'members', 'settings']) {
            await t.tap(find.byKey(Key('mobile-tab-$root')));
            await f.flush(t);
            await t.pump(const Duration(milliseconds: 500));
            expectBarClearance();
          }

          w.navigation.navigate(RaftLocation.parse('/s/alpha/channel/ca'));
          w.notifyListeners();
          await f.flush(t);
          await t.pump(const Duration(milliseconds: 500));
          expect(nav, findsNothing);
          final editor = find.descendant(
            of: find.byType(RaftComposer),
            matching: find.byType(EditableText),
          );
          expect(editor, findsOneWidget);
          expect(
            t.getRect(editor).bottom,
            lessThanOrEqualTo(screenBottom - inset),
            reason: 'A detail composer must also clear the home indicator.',
          );
          windowMetrics(t, inset, keyboard: 300);
          await t.pump();
          expect(
            t.getRect(editor).bottom,
            lessThanOrEqualTo(screenBottom - 300),
            reason: 'The keyboard must not add a second safe-area gap.',
          );
          await f.close(t);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
}
