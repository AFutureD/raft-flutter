import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

Widget _host(
  Widget child, {
  RaftFamily family = RaftFamily.elegant,
  bool dark = false,
}) => MaterialApp(
  theme: raftTheme(family, dark: dark),
  home: Scaffold(
    body: Align(alignment: Alignment.topRight, child: child),
  ),
);

void main() {
  for (final (family, dark) in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    group('$family/$dark', () {
      testWidgets('split: main chooses the default reason, the caret opens the '
          'menu with the default checked, a reason closes it and is chosen', (
        t,
      ) async {
        final chosen = <RaftFeedbackCloseReason>[];
        await t.pumpWidget(
          _host(
            RaftFeedbackCloseSplit(
              defaultReason: RaftFeedbackCloseReason.completed,
              onChoose: chosen.add,
            ),
            family: family,
            dark: dark,
          ),
        );
        await t.tap(find.byKey(const ValueKey('feedback-close-main')));
        expect(chosen, [RaftFeedbackCloseReason.completed]);
        await t.tap(find.byKey(const ValueKey('feedback-close-caret')));
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('feedback-close-menu')),
          findsOneWidget,
        );
        expect(find.text('Completed'), findsOneWidget);
        expect(find.text('No longer needed'), findsOneWidget);
        await t.tap(
          find.byKey(const ValueKey('feedback-close-reason-noLongerNeeded')),
        );
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('feedback-close-menu')), findsNothing);
        expect(chosen.last, RaftFeedbackCloseReason.noLongerNeeded);
      });

      testWidgets('split: the caret toggles the menu; Escape and an outside '
          'tap dismiss it without choosing', (t) async {
        final chosen = <RaftFeedbackCloseReason>[];
        await t.pumpWidget(
          _host(
            RaftFeedbackCloseSplit(
              defaultReason: RaftFeedbackCloseReason.noLongerNeeded,
              onChoose: chosen.add,
            ),
            family: family,
            dark: dark,
          ),
        );
        final caret = find.byKey(const ValueKey('feedback-close-caret'));
        await t.tap(caret);
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('feedback-close-menu')),
          findsOneWidget,
        );
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('feedback-close-menu')), findsNothing);
        await t.tap(caret);
        await t.pumpAndSettle();
        await t.tapAt(const Offset(10, 300));
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('feedback-close-menu')), findsNothing);
        expect(chosen, isEmpty);
      });

      testWidgets('split: disabled parts ignore taps', (t) async {
        final chosen = <RaftFeedbackCloseReason>[];
        await t.pumpWidget(
          _host(
            RaftFeedbackCloseSplit(
              defaultReason: RaftFeedbackCloseReason.completed,
              onChoose: chosen.add,
              disabled: true,
              keySuffix: '-t1',
            ),
            family: family,
            dark: dark,
          ),
        );
        await t.tap(find.byKey(const ValueKey('feedback-close-main-t1')));
        await t.tap(
          find.byKey(const ValueKey('feedback-close-caret-t1')),
          warnIfMissed: false,
        );
        await t.pumpAndSettle();
        expect(chosen, isEmpty);
        expect(find.byKey(const ValueKey('feedback-close-menu')), findsNothing);
      });

      for (final reason in RaftFeedbackCloseReason.values) {
        testWidgets('dialog $reason: copy, Cancel and confirm', (t) async {
          var cancelled = 0, confirmed = 0;
          await t.pumpWidget(
            _host(
              RaftFeedbackCloseDialog(
                reason: reason,
                onCancel: () => cancelled++,
                onConfirm: () => confirmed++,
              ),
              family: family,
              dark: dark,
            ),
          );
          final title = reason == RaftFeedbackCloseReason.completed
              ? 'Issue resolved — close this ticket?'
              : 'No longer need help — close this ticket?';
          // Brutal dialog titles are upper-cased by the recipe.
          expect(
            find.byWidgetPredicate(
              (w) => w is Text && w.data?.toLowerCase() == title.toLowerCase(),
            ),
            findsOneWidget,
          );
          await t.tap(find.byKey(const ValueKey('feedback-close-cancel')));
          await t.tap(find.byKey(const ValueKey('feedback-close-confirm')));
          expect([cancelled, confirmed], [1, 1]);
        });
      }

      testWidgets('dialog: the error shows in the dialog; busy disables both '
          'buttons', (t) async {
        var cancelled = 0, confirmed = 0;
        await t.pumpWidget(
          _host(
            RaftFeedbackCloseDialog(
              reason: RaftFeedbackCloseReason.completed,
              onCancel: () => cancelled++,
              onConfirm: () => confirmed++,
              busy: true,
              error: "Couldn't load feedback. Try again.",
            ),
            family: family,
            dark: dark,
          ),
        );
        expect(find.text("Couldn't load feedback. Try again."), findsOneWidget);
        await t.tap(
          find.byKey(const ValueKey('feedback-close-cancel')),
          warnIfMissed: false,
        );
        await t.tap(
          find.byKey(const ValueKey('feedback-close-confirm')),
          warnIfMissed: false,
        );
        expect([cancelled, confirmed], [0, 0]);
      });
    });
  }

  testWidgets('the portal theme keeps dark apps light for portals only', (
    t,
  ) async {
    Brightness? inside, outside;
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: true),
        home: Builder(
          builder: (context) {
            outside = RaftTokens.of(context).dark
                ? Brightness.dark
                : Brightness.light;
            return RaftFeedbackPortalTheme(
              child: Builder(
                builder: (context) {
                  inside = RaftTokens.of(context).dark
                      ? Brightness.dark
                      : Brightness.light;
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      ),
    );
    expect(outside, Brightness.dark);
    expect(inside, Brightness.light);
  });
}
