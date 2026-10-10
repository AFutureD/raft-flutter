import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

import 'tooltip_test.dart' show host;

/// Rows scrolled under a resting pointer are not hovered on purpose: no
/// tooltip opens until the pointer itself moves, and an open tooltip closes
/// on scroll without making the next rows open instantly.
void main() {
  Widget list(ScrollController scroll) => host(
    SizedBox(
      width: 200,
      height: 300,
      child: ListView(
        controller: scroll,
        children: [
          for (var i = 0; i < 40; i++)
            RaftTooltip(
              message: 'Tip $i',
              child: SizedBox(height: 30, child: Text('Row $i')),
            ),
        ],
      ),
    ),
  );

  testWidgets('scrolling under a resting pointer opens no tooltip', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(list(scroll));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Row 2')));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Tip 2'), findsOneWidget);

    // Scrolling closes it and rows passing under the pointer stay quiet,
    // also within the adjacent-instant window.
    for (var step = 1; step <= 6; step++) {
      scroll.jumpTo(step * 45.0);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Tip '), findsNothing);
    }
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Tip '), findsNothing);

    // A real pointer move is hover intent again.
    await mouse.moveBy(const Offset(3, 0));
    await tester.pump(const Duration(milliseconds: 599));
    expect(find.textContaining('Tip '), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('Tip '), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a tooltip repeating its text opens only when the text is cut', (
    tester,
  ) async {
    Widget line(String text) => RaftTooltip(
      message: text,
      onlyWhenTruncated: true,
      child: SizedBox(
        width: 160,
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    await tester.pumpWidget(
      host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            line('Short'),
            const SizedBox(height: 40),
            line('A very long system line that cannot fit in this width'),
          ],
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Short')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Short'), findsOneWidget);
    await mouse.moveTo(
      tester.getCenter(
        find.text('A very long system line that cannot fit in this width'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      find.text('A very long system line that cannot fit in this width'),
      findsNWidgets(2),
    );
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  Future<TestGesture> hoverRow(WidgetTester tester, String row) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text(row)));
    return mouse;
  }

  Future<void> finish(WidgetTester tester, TestGesture mouse) async {
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a continuously moving pointer never opens a tooltip', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(list(scroll));
    final mouse = await hoverRow(tester, 'Row 2');
    // Moves every 100ms for 3s: each move restarts the 600ms delay.
    for (var step = 0; step < 30; step++) {
      await mouse.moveBy(Offset(step.isEven ? 1 : -1, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Tip '), findsNothing);
    }
    // Resting opens it 600ms after the last move (100ms already elapsed).
    await tester.pump(const Duration(milliseconds: 499));
    expect(find.textContaining('Tip '), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Tip 2'), findsOneWidget);
    await finish(tester, mouse);
  });

  testWidgets(
    'an open tooltip is gone on the frame of a scroll position change',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(list(scroll));
      final mouse = await hoverRow(tester, 'Row 2');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Tip 2'), findsOneWidget);
      // Scrollbar drag / keyboard scroll move the position without a wheel.
      scroll.jumpTo(10);
      await tester.pump();
      expect(find.textContaining('Tip '), findsNothing);
      await finish(tester, mouse);
    },
  );

  testWidgets('a wheel event closes an open tooltip at once', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(list(scroll));
    final mouse = await hoverRow(tester, 'Row 2');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Tip 2'), findsOneWidget);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.text('Row 2')),
        scrollDelta: const Offset(0, 40),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Tip '), findsNothing);
    // It stays closed while the pointer rests, then needs a move and a rest.
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Tip '), findsNothing);
    await finish(tester, mouse);
  });

  testWidgets('a wheel at the scroll edge still closes the tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        RaftTooltip(
          message: 'Edge tip',
          child: const SizedBox(width: 80, height: 30, child: Text('Edge')),
        ),
      ),
    );
    final mouse = await hoverRow(tester, 'Edge');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Edge tip'), findsOneWidget);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.text('Edge')),
        scrollDelta: const Offset(0, 40),
      ),
    );
    await tester.pump();
    expect(find.text('Edge tip'), findsNothing);
    await finish(tester, mouse);
  });

  testWidgets('any ancestor scrollable closes it, nested and horizontal', (
    tester,
  ) async {
    final outer = ScrollController(), inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 300,
          height: 200,
          child: ListView(
            controller: outer,
            children: [
              SizedBox(
                height: 60,
                child: ListView(
                  controller: inner,
                  scrollDirection: Axis.horizontal,
                  children: [
                    RaftTooltip(
                      message: 'Nested tip',
                      child: const SizedBox(
                        width: 120,
                        height: 60,
                        child: Text('Nested'),
                      ),
                    ),
                    const SizedBox(width: 600),
                  ],
                ),
              ),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    );
    for (final controller in [inner, outer]) {
      final mouse = await hoverRow(tester, 'Nested');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Nested tip'), findsOneWidget);
      controller.jumpTo(5);
      await tester.pump();
      expect(find.text('Nested tip'), findsNothing);
      controller.jumpTo(0);
      await mouse.removePointer();
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a fully visible model label has no tooltip; a cut one has', (
    tester,
  ) async {
    Widget row(String model, String description) => SizedBox(
      width: 560,
      child: RaftMessageTile(
        author: 'Cindy',
        timestamp: '10/08',
        content: 'Hello',
        modelLabel: model,
        subtitle: description,
      ),
    );
    const description =
        'Engineering operator: turns your requests into shipped changes '
        'across every repository and every environment';
    await tester.pumpWidget(host(row('Claude Opus 5.5', description)));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Claude Opus 5.5')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Claude Opus 5.5'), findsOneWidget);

    // The truncated description does open one.
    await mouse.moveTo(tester.getCenter(find.text(description)));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text(description), findsNWidgets(2));
    // ...and scrolling the page would close it at once; a wheel does.
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.text(description).first),
        scrollDelta: const Offset(0, 40),
      ),
    );
    await tester.pump();
    expect(find.text(description), findsOneWidget);
    await finish(tester, mouse);
  });
}
