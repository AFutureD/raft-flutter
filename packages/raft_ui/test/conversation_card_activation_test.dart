import 'dart:ui' show SemanticsAction, SemanticsActionEvent;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

void main() {
  for (final (family, dark) in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets(
      'N24 activation $family/$dark first click is immediate; keyboard and nested actions stay distinct',
      (tester) async {
        final activation = <int>[];
        var legacy = 0, nested = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: raftTheme(family, dark: dark),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  child: RaftConversationCard(
                    semanticLabel: 'Open conversation',
                    onOpen: () => legacy++,
                    onActivate: activation.add,
                    actions: RaftIconButton(
                      glyph: RaftGlyph.check,
                      tooltip: 'Done',
                      onPressed: () => nested++,
                    ),
                    child: const SizedBox(
                      height: 64,
                      child: Text('A real activity row'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final point =
            tester.getTopLeft(find.byType(RaftConversationCard)) +
            const Offset(40, 40);
        await tester.tapAt(point);
        expect(activation, [1]); // No framework double-tap wait.
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(point);
        expect(activation, [1, 2]);
        expect(legacy, 0);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tapAt(point);
        expect(activation, [1, 2, 1]);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        // Focus the row's actual InkWell rather than invoking its callback.
        final ink = tester.element(
          find
              .descendant(
                of: find.byType(RaftConversationCard),
                matching: find.byType(InkWell),
              )
              .first,
        );
        Focus.of(ink).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(activation, [1, 2, 1, 1]);
        final count = activation.length;
        await tester.tap(find.byTooltip('Done'));
        expect(nested, 1);
        expect(activation, hasLength(count));
        expect(
          tester.getSemantics(find.byType(RaftConversationCard)).label,
          contains('Open conversation'),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'card consumers without activation detail retain immediate onOpen',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(
            body: RaftConversationCard(
              onOpen: () => opened++,
              child: const SizedBox(height: 64, child: Text('Saved item')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Saved item'));
      expect(opened, 1);
    },
  );
  testWidgets(
    'host system interval changes recognition, never first-click latency',
    (tester) async {
      final details = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: RaftConversationCard(
            onOpen: () {},
            onActivate: details.add,
            doubleClickInterval: const Duration(milliseconds: 500),
            child: const SizedBox(height: 64, child: Text('System interval')),
          ),
        ),
      );
      await tester.tap(find.text('System interval'));
      expect(details, [1]);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('System interval'));
      expect(details, [1, 2]);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('System interval'));
      expect(details, [1, 2, 1]);
    },
  );
  testWidgets('adaptive reparent does not dispatch a conversation activation', (
    tester,
  ) async {
    final key = GlobalKey();
    final details = <int>[];
    Widget host(bool flipped) => MaterialApp(
      theme: raftTheme(RaftFamily.elegant),
      home: Scaffold(
        body: Row(
          children: [
            if (flipped) const SizedBox(width: 40),
            SizedBox(
              width: 360,
              child: RaftConversationCard(
                key: key,
                onOpen: () {},
                onActivate: details.add,
                child: const SizedBox(height: 64, child: Text('Retained card')),
              ),
            ),
            if (!flipped) const SizedBox(width: 40),
          ],
        ),
      ),
    );
    await tester.pumpWidget(host(false));
    await tester.pumpWidget(host(true));
    expect(details, isEmpty);
    await tester.tap(find.text('Retained card'));
    expect(details, [1]);
  });
  testWidgets(
    'pointer override excludes keyboard, semantics and nested actions',
    (tester) async {
      final pointer = <int>[], activation = <int>[];
      var nested = 0;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: Scaffold(
            body: RaftConversationCard(
              onOpen: () {},
              onActivate: activation.add,
              onPointerActivate: pointer.add,
              actions: RaftIconButton(
                glyph: RaftGlyph.check,
                tooltip: 'Done',
                onPressed: () => nested++,
              ),
              child: const SizedBox(
                height: 64,
                child: Text('Pointer override'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pointer override'));
      expect(pointer, [1]);
      expect(activation, isEmpty);
      Focus.of(tester.element(find.text('Pointer override'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(activation, [1]);
      expect(pointer, [1]);
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.tap,
          viewId: tester.view.viewId,
          nodeId: tester.getSemantics(find.byType(RaftConversationCard)).id,
        ),
      );
      expect(activation, [1, 1]);
      expect(pointer, [1]);
      await tester.tap(find.byTooltip('Done'));
      expect(nested, 1);
      expect(pointer, [1]);
      expect(activation, [1, 1]);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );
}
