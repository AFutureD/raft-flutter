import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as chat;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/message_timeline.dart';

/// Overscroll belongs to the user: dragging or flinging past an edge bounces
/// (iOS/macOS) or stretches (Android), also at the top while older history
/// may still load; the app's own moves (jump, animate, re-center) never
/// leave the scroll range. A page landing during the bounce moves nothing.
const rowHeight = 100.0;

class Host {
  Host(this.tester, this.controller, this.data);
  final WidgetTester tester;
  final RaftTimelineScrollController controller;
  final ValueNotifier<({List<int> ids, int epoch})> data;

  ScrollPosition get position => controller.position;
  double get px => position.pixels;

  /// Older rows land above (ids keep counting down).
  void prepend(int count) {
    final ids = data.value.ids;
    data.value = (
      ids: [for (var i = count; i > 0; i--) ids.first - i, ...ids],
      epoch: data.value.epoch,
    );
  }

  double? top(int id) {
    final finder = find.byKey(ValueKey('row-$id'));
    return finder.evaluate().isEmpty ? null : tester.getTopLeft(finder).dy;
  }

  /// The strength of the Android stretch effect (0 = none).
  double get stretch => find.byType(StretchEffect).evaluate().isEmpty
      ? 0
      : tester
            .widget<StretchEffect>(find.byType(StretchEffect))
            .stretchStrength;

  bool get outOfRange =>
      px < position.minScrollExtent - .01 ||
      px > position.maxScrollExtent + .01;
}

Future<Host> pump(
  WidgetTester tester,
  TargetPlatform platform, {
  int count = 40,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(600, 600);
  addTearDown(tester.view.reset);
  final controller = RaftTimelineScrollController(bottomAnchored: true);
  addTearDown(controller.dispose);
  final data = ValueNotifier((
    ids: [for (var i = 0; i < count; i++) i],
    epoch: 0,
  ));
  addTearDown(data.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: data,
          builder: (_, value, _) {
            final ids = value.ids;
            return RaftMessageTimeline(
              controller: controller,
              messages: [
                for (final id in ids)
                  chat.Message.text(id: '$id', authorId: 'a', text: '$id'),
              ],
              // The latest row is the center; older rows build above it.
              centerIndex: ids.length - 1,
              epoch: value.epoch,
              hasOlder: true,
              indexOfId: (id) => ids.indexOf(int.parse(id)),
              estimateRow: (_) => rowHeight,
              rowBuilder: (_, index) => SizedBox(
                key: ValueKey('row-${ids[index]}'),
                height: rowHeight,
                child: Text('${ids[index]}'),
              ),
              slivers: (history, forward) => [history, forward],
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return Host(tester, controller, data);
}

const bouncing = [TargetPlatform.iOS, TargetPlatform.macOS];

void main() {
  for (final platform in bouncing) {
    for (final top in [true, false]) {
      testWidgets('$platform: dragging past the ${top ? 'top' : 'bottom'} '
          'bounces and springs back', (tester) async {
        final h = await pump(tester, platform);
        final edge = top
            ? h.position.minScrollExtent
            : h.position.maxScrollExtent;
        h.controller.jumpTo(edge);
        await tester.pump();
        final gesture = await tester.startGesture(const Offset(300, 300));
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(Offset(0, top ? 40 : -40));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          top ? h.px < edge - 10 : h.px > edge + 10,
          isTrue,
          reason: '${h.px}',
        );
        expect(h.outOfRange, isTrue);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(h.px, closeTo(edge, .5));
        expect(h.outOfRange, isFalse);
      });
    }
  }

  for (final top in [true, false]) {
    testWidgets('android: dragging past the ${top ? 'top' : 'bottom'} '
        'stretches and recedes', (tester) async {
      final h = await pump(tester, TargetPlatform.android);
      final edge = top
          ? h.position.minScrollExtent
          : h.position.maxScrollExtent;
      h.controller.jumpTo(edge);
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(300, 300));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(Offset(0, top ? 40 : -40));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(h.stretch, isNot(0));
      expect(h.px, edge, reason: 'the stretch never moves the scroll offset');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(h.stretch, 0);
      expect(h.px, edge);
    });
  }

  for (final platform in [...bouncing, TargetPlatform.android]) {
    testWidgets(
      '$platform: a page landing during a held top bounce moves no row',
      (tester) async {
        final h = await pump(tester, platform);
        h.controller.jumpTo(h.position.minScrollExtent);
        await tester.pump();
        final min = h.position.minScrollExtent;
        final gesture = await tester.startGesture(const Offset(300, 300));
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(const Offset(0, 40));
          await tester.pump(const Duration(milliseconds: 16));
        }
        final first = h.data.value.ids.first;
        final before = h.top(first)!;
        expect(h.stretch != 0 || h.px < min, isTrue);
        h.prepend(20);
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(h.top(first), before, reason: 'frame $i');
        }
        expect(h.position.minScrollExtent, lessThan(min - 1500));
        await gesture.up();
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          final now = h.top(first);
          if (now != null) expect((now - before).abs(), lessThan(rowHeight));
        }
        await tester.pumpAndSettle();
        expect(h.outOfRange, isFalse);
        expect(h.stretch, 0);
      },
    );

    testWidgets(
      '$platform: a page landing during the fling into the top keeps the '
      'rows continuous',
      (tester) async {
        final h = await pump(tester, platform);
        h.controller.jumpTo(h.position.minScrollExtent + 300);
        await tester.pump();
        final first = h.data.value.ids.first;
        await tester.fling(
          find.byType(RaftMessageTimeline),
          const Offset(0, 300),
          4000,
        );
        var landed = false;
        double? last;
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          final now = h.top(first);
          if (!landed && (h.outOfRange || h.stretch != 0)) {
            // The fling reached the top edge: the page lands now.
            landed = true;
            last = now;
            h.prepend(20);
            continue;
          }
          if (landed && now != null && last != null) {
            expect((now - last).abs(), lessThan(rowHeight), reason: 'frame $i');
          }
          last = now;
          if (landed && !h.position.isScrollingNotifier.value) break;
        }
        expect(landed, isTrue);
        await tester.pumpAndSettle();
        expect(h.outOfRange, isFalse);
        expect(h.stretch, 0);
      },
    );
  }

  for (final platform in bouncing) {
    testWidgets('$platform: a fling into the latest end bounces past it and '
        'springs back', (tester) async {
      final h = await pump(tester, platform);
      h.controller.jumpTo(h.position.maxScrollExtent - 600);
      await tester.pump();
      await tester.fling(
        find.byType(RaftMessageTimeline),
        const Offset(0, -300),
        4000,
      );
      var overshoot = 0.0;
      double? last;
      var jumps = 0;
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final past = h.px - h.position.maxScrollExtent;
        if (past > overshoot) overshoot = past;
        // The spring moves the content smoothly: no frame snaps it back.
        if (last != null && (h.px - last).abs() > 250) jumps++;
        last = h.px;
        if (!h.position.isScrollingNotifier.value) break;
      }
      expect(overshoot, greaterThan(10), reason: 'no visible bounce');
      expect(jumps, 0);
      await tester.pumpAndSettle();
      expect(h.px, h.position.maxScrollExtent);
    });
  }

  for (final platform in [...bouncing, TargetPlatform.android]) {
    testWidgets('$platform: programmatic moves never leave the scroll range', (
      tester,
    ) async {
      final h = await pump(tester, platform);
      final min = h.position.minScrollExtent, max = h.position.maxScrollExtent;
      Future<void> frames(String what, [int n = 40]) async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(h.outOfRange, isFalse, reason: '$what frame $i px=${h.px}');
          expect(h.stretch, 0, reason: '$what frame $i');
        }
      }

      h.controller.jumpTo(min - 700);
      expect(h.px, min);
      await frames('jump past top', 5);
      h.controller.jumpTo(max + 700);
      expect(h.px, max);
      await frames('jump past bottom', 5);
      for (final curve in [Curves.linear, Curves.easeOut, Curves.easeInOut]) {
        h.controller.animateTo(
          min - 900,
          duration: const Duration(milliseconds: 300),
          curve: curve,
        );
        await frames('animate past top $curve');
        expect(h.px, min);
        h.controller.animateTo(
          max + 900,
          duration: const Duration(milliseconds: 300),
          curve: curve,
        );
        await frames('animate past bottom $curve');
        expect(h.px, max);
        expect(h.position.isScrollingNotifier.value, isFalse);
      }
      // To an inner target and then onto the edge: no coasting past it.
      h.controller.animateTo(
        min + 200,
        duration: const Duration(milliseconds: 200),
        curve: Curves.linear,
      );
      await frames('animate inside');
      h.controller.animateTo(
        min,
        duration: const Duration(milliseconds: 200),
        curve: Curves.linear,
      );
      await frames('animate to the edge');
      // Re-center and return to latest.
      h.controller.align(RaftTimelineAlignment.start);
      h.data.value = (ids: h.data.value.ids, epoch: 1);
      await frames('re-center at the start');
      h.controller.followEnd();
      h.controller.align(RaftTimelineAlignment.end);
      h.data.value = (ids: h.data.value.ids, epoch: 2);
      await frames('re-center at the end');
      expect(h.px, h.position.maxScrollExtent);
    });
  }
}
