import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';

import 'agent_orb_briefing_sheet_test.dart' show needsYou;
import 'agent_orb_shell_session_test.dart' show fakeTool;
import 'agent_orb_shell_test.dart' show OrbFixture;

/// When a tool moves the app (navigate, or an item opened from a briefing),
/// the orb sheet drops to a small peek so the page shows; it comes back when
/// the person drags it up, taps the transcript or goes to type.

void main() {
  late OrbFixture f;

  Future<void> fixture(WidgetTester t, {List<OrbTool> tools = const []}) async {
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    await f.pump(tools: tools);
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
  }

  Future<void> openSheet(WidgetTester t) async {
    await t.tap(OrbFixture.orbFinder);
    await settle(t);
  }

  double sheetHeight(WidgetTester t) =>
      t.getSize(find.byType(BottomSheet)).height;

  final nav = fakeTool('navigate', (args, ctx) async {
    ctx.operating.value = true;
    ctx.operating.value = false;
    return {'route': '/s/alpha/activity', 'title': '动态'};
  });

  Future<void> runTool(WidgetTester t, String name) async {
    final done = f.controller.dispatch(name, {'target': '动态'});
    await t.pump();
    await done;
    await settle(t);
  }

  testWidgets('a navigation lowers the sheet to a peek; the page is visible', (
    t,
  ) async {
    await fixture(t, tools: [nav]);
    await openSheet(t);
    final full = sheetHeight(t);
    expect(f.controller.sheetPeeking, isFalse);

    await runTool(t, 'navigate');

    expect(f.controller.sheetOpen, isTrue, reason: 'the sheet stays');
    expect(f.controller.sheetPeeking, isTrue);
    final peek = sheetHeight(t);
    expect(peek / 915, inInclusiveRange(.25, .31));
    expect(peek, lessThan(full * .55));
    // The transcript tail and the input are still there.
    expect(find.text('已打开 动态'), findsOneWidget);
    expect(find.byKey(const ValueKey('orb-sheet-input')), findsOneWidget);
    // And the page behind is no longer covered at the top of the screen.
    final sheetTop = t.getTopLeft(find.byType(BottomSheet)).dy;
    expect(sheetTop, greaterThan(915 * .65));
  });

  testWidgets('tapping the transcript raises the sheet again', (t) async {
    await fixture(t, tools: [nav]);
    await openSheet(t);
    final full = sheetHeight(t);
    await runTool(t, 'navigate');
    expect(f.controller.sheetPeeking, isTrue);

    await t.tap(find.byKey(const ValueKey('orb-transcript')));
    await settle(t);
    expect(f.controller.sheetPeeking, isFalse);
    expect(sheetHeight(t), closeTo(full, 2));
  });

  testWidgets('dragging the handle up raises it too', (t) async {
    await fixture(t, tools: [nav]);
    await openSheet(t);
    final full = sheetHeight(t);
    await runTool(t, 'navigate');
    await t.fling(
      find.byKey(const ValueKey('raft-sheet-handle')),
      const Offset(0, -400),
      2000,
    );
    await settle(t);
    expect(f.controller.sheetPeeking, isFalse);
    expect(sheetHeight(t), greaterThanOrEqualTo(full - 2));
    expect(f.controller.sheetOpen, isTrue);
  });

  testWidgets(
    'going to type in the input raises it (the keyboard needs room)',
    (t) async {
      await fixture(t, tools: [nav]);
      await openSheet(t);
      await runTool(t, 'navigate');
      expect(f.controller.sheetPeeking, isTrue);
      await t.tap(find.byKey(const ValueKey('orb-sheet-input')));
      await settle(t);
      expect(f.controller.sheetPeeking, isFalse);
    },
  );

  testWidgets('the keyboard goes down when the sheet steps aside', (t) async {
    await fixture(t, tools: [nav]);
    await openSheet(t);
    await t.tap(find.byKey(const ValueKey('orb-sheet-input')));
    await settle(t);
    bool inputFocused() =>
        t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;
    expect(inputFocused(), isTrue);
    await runTool(t, 'navigate');
    expect(inputFocused(), isFalse, reason: 'the keyboard went down');
    expect(f.controller.sheetPeeking, isTrue);
  });

  testWidgets('tools that do not move the app, and failed moves, leave the '
      'sheet alone', (t) async {
    await fixture(
      t,
      tools: [
        fakeTool('fake_read', (a, c) async => {'page': 'activity'}),
        fakeTool('fake_missing', (a, c) async {
          c.operating.value = true;
          c.operating.value = false;
          return {'error': '没有找到「动态」'};
        }),
        fakeTool('fake_pick', (a, c) async {
          c.operating.value = true;
          c.operating.value = false;
          return {
            'candidates': [
              {'title': 'a'},
            ],
          };
        }),
      ],
    );
    await openSheet(t);
    for (final name in ['fake_read', 'fake_missing', 'fake_pick']) {
      await runTool(t, name);
      expect(f.controller.sheetPeeking, isFalse, reason: name);
    }
  });

  testWidgets('a tool that moves the app with no sheet open does nothing', (
    t,
  ) async {
    await fixture(t, tools: [nav]);
    await runTool(t, 'navigate');
    expect(f.controller.sheetOpen, isFalse);
    expect(f.controller.sheetPeeking, isFalse);
  });

  testWidgets('opening an item of a briefing steps the sheet aside too', (
    t,
  ) async {
    await fixture(t);
    await openSheet(t);
    expect(f.controller.sheetPeeking, isFalse);
    f.controller.openBriefItem(
      needsYou(),
      OrbToolContext(
        workspace: f.w,
        navigatorContext: f.navKey.currentState!.overlay!.context,
        operating: f.controller.operating,
      ),
    );
    await settle(t);
    expect(f.controller.sheetOpen, isTrue);
    expect(f.controller.sheetPeeking, isTrue);
  });
}
