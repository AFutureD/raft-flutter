import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

Widget _host(Widget child, {RaftFamily family = RaftFamily.elegant}) =>
    MaterialApp(
      theme: raftTheme(family),
      home: Scaffold(body: child),
    );

void main() {
  group(
    'members strip layout (getVisibleMemberLimit / getStripColumnCount)',
    () {
      test('column count follows the grid width', () {
        expect(RaftMembersStrip.columnsFor(0), 7);
        expect(RaftMembersStrip.columnsFor(416), 9); // elegant 448 - 32
        expect(RaftMembersStrip.columnsFor(510), 11); // brutal 544 - 34
        expect(RaftMembersStrip.columnsFor(10), 1);
      });
      test(
        'add keeps a slot; overflow reserves one more; never a fourth row',
        () {
          expect(RaftMembersStrip.visibleLimit(5, 9), 5);
          // 3 rows x 9 = 27 slots: 26 members + add still fit.
          expect(RaftMembersStrip.visibleLimit(26, 9), 26);
          // 27 members + add do not: show 25, then +N and add.
          expect(RaftMembersStrip.visibleLimit(27, 9), 25);
          expect(RaftMembersStrip.visibleLimit(500, 9), 25);
          expect(RaftMembersStrip.visibleLimit(3, 1), 1);
        },
      );
    },
  );

  testWidgets('drawer width: Brutal 544, Elegant 448, phones full width', (
    t,
  ) async {
    for (final (family, view, width) in [
      (RaftFamily.brutal, 1280.0, 544.0),
      (RaftFamily.elegant, 1280.0, 448.0),
      (RaftFamily.brutal, 390.0, 390.0),
      (RaftFamily.elegant, 390.0, 390.0),
    ]) {
      t.view.physicalSize = Size(view, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        _host(
          RaftOverflowSheet(title: '#work', onClose: () {}, children: const []),
          family: family,
        ),
      );
      // The theme change animates; let it land before measuring.
      await t.pumpAndSettle(const Duration(seconds: 1));
      expect(
        t.getSize(find.byKey(const ValueKey('channel-overflow-sheet'))).width,
        width,
        reason: '$family @ $view',
      );
    }
  });

  testWidgets(
    'header: title, badge, one collapsed description line; back only on phones',
    (t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var closed = 0;
      await t.pumpWidget(
        _host(
          RaftOverflowSheet(
            title: '#work',
            badge: 'Private',
            subtitle: 'line one\nline two',
            onClose: () => closed++,
            children: const [],
          ),
        ),
      );
      expect(find.text('#work'), findsOneWidget);
      expect(find.text('Private'), findsOneWidget);
      expect(find.text('line one line two'), findsOneWidget);
      expect(find.byKey(const ValueKey('channel-overflow-back')), findsNothing);
      t.view.physicalSize = const Size(390, 800);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('channel-overflow-back')));
      expect(closed, 1);
    },
  );

  testWidgets(
    'RaftConfirmDialog onConfirm: busy label, error banner, then success',
    (t) async {
      var attempt = 0;
      final gate = Completer<void>();
      Future<void> action() async {
        attempt++;
        if (attempt == 1) throw Exception('Server said no');
        await gate.future;
      }

      bool? result;
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await RaftConfirmDialog.show(
                context,
                RaftConfirmDialog(
                  title: 'Archive Channel',
                  message: 'Sure?',
                  confirmLabel: 'Archive',
                  loadingLabel: 'Archiving…',
                  confirmVariant: RaftButtonRecipeVariant.warning,
                  onConfirm: action,
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Archive'));
      await t.pumpAndSettle();
      // A failure keeps the dialog open and shows the message under the copy.
      expect(find.text('Server said no'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
      await t.tap(find.text('Archive'));
      await t.pump();
      expect(find.text('Archiving…'), findsOneWidget);
      // Cancel and close are disabled while the action runs.
      await t.tap(find.text('Cancel'), warnIfMissed: false);
      await t.pump();
      expect(find.text('Archiving…'), findsOneWidget);
      gate.complete();
      await t.pumpAndSettle();
      expect(result, isTrue);
      expect(find.text('Archive'), findsNothing);
    },
  );

  testWidgets(
    'unsaved prompt: three actions, Save and close only when savable',
    (t) async {
      final taps = <String>[];
      await t.pumpWidget(
        _host(
          RaftUnsavedChangesPrompt(
            message: 'Unsaved edits.',
            onKeepEditing: () => taps.add('keep'),
            onDiscard: () => taps.add('discard'),
            onSaveAndClose: () => taps.add('save'),
          ),
        ),
      );
      // Press through the buttons: the unwrapped test-font row may overflow.
      void press(String label) => t
          .widget<RaftSettingsRecipeButton>(
            find.widgetWithText(RaftSettingsRecipeButton, label),
          )
          .onPressed!();
      press('Keep editing');
      press('Discard changes');
      press('Save and close');
      expect(taps, ['keep', 'discard', 'save']);
      await t.pumpWidget(
        _host(
          RaftUnsavedChangesPrompt(
            message: 'Invitation unsent.',
            onKeepEditing: () {},
            onDiscard: () {},
          ),
        ),
      );
      expect(find.text('Save and close'), findsNothing);
    },
  );

  testWidgets('divide-y rows take their 1px border in layout', (t) async {
    late double firstTop, secondTop;
    await t.pumpWidget(
      _host(
        Builder(
          builder: (context) => SingleChildScrollView(
            child: raftSheetSection(
              context,
              RaftTokens.of(context),
              RaftSheetSection('Preferences', [
                RaftSheetSwitchRow(
                  title: 'A',
                  description: 'a',
                  value: false,
                  onChanged: (_) {},
                ),
                RaftSheetSwitchRow(
                  title: 'B',
                  description: 'b',
                  value: false,
                  onChanged: (_) {},
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    firstTop = t.getTopLeft(find.text('A')).dy;
    secondTop = t.getTopLeft(find.text('B')).dy;
    // py-3 + 20 title + 4 + 16 description + py-3 = 64, plus the 1px divider.
    expect(secondTop - firstTop, 65);
  });
}
