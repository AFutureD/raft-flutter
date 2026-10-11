import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_flutter/features/message_preparation.dart';

void main() {
  testWidgets('preparation waits through route entry and predictive Back', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(platform: TargetPlatform.android),
        home: const SizedBox(),
      ),
    );
    final route = MaterialPageRoute<void>(
      allowSnapshotting: false,
      builder: (_) => const ColoredBox(color: Colors.white),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    var completed = 0;
    final owner = MessagePreparation(
      isIdle: () => messagePreparationRouteIsIdle(route),
      scheduleIdle: (job) => job(),
    );
    owner.replace([() => completed++]);
    await tester.pump(const Duration(milliseconds: 250));
    expect(completed, 0);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));
    expect(completed, 1);

    Future<void> gesture(String method, [double? progress]) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(
            method,
            progress == null
                ? null
                : <String, dynamic>{
                    'touchOffset': <double>[100, 300],
                    'progress': progress,
                    'swipeEdge': 0,
                  },
          ),
        ),
        (_) {},
      );
      await tester.pump();
    }

    await gesture('startBackGesture', 0);
    await gesture('updateBackGestureProgress', .4);
    expect(route.navigator!.userGestureInProgress, isTrue);
    owner.replace([() => completed++]);
    await tester.pump(const Duration(milliseconds: 250));
    expect(completed, 1, reason: 'A held platform gesture is not idle');
    await gesture('cancelBackGesture');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));
    expect(completed, 2, reason: 'Canceled Back resumes retained preparation');
    owner.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> advance(WidgetTester tester, Duration duration) async {
    await tester.pump(duration);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }

  testWidgets(
    'preparation waits for quiet input and runs one message at a time',
    (tester) async {
      var idle = false;
      final completed = <int>[];
      final owner = MessagePreparation(isIdle: () => idle);
      owner.replace([for (var i = 0; i < 3; i++) () => completed.add(i)]);
      await advance(tester, const Duration(milliseconds: 250));
      expect(completed, isEmpty);
      idle = true;
      await advance(tester, const Duration(milliseconds: 250));
      expect(completed, [0]);
      idle = false;
      await advance(tester, const Duration(milliseconds: 16));
      expect(completed, [0]);
      idle = true;
      await advance(tester, const Duration(milliseconds: 250));
      expect(completed, [0, 1]);
      owner.dispose();
    },
  );

  testWidgets('authority replacement and disposal retire even scheduled work', (
    tester,
  ) async {
    final completed = <String>[];
    final pending = <VoidCallback>[];
    final owner = MessagePreparation(
      isIdle: () => true,
      scheduleIdle: pending.add,
    );
    owner.replace([() => completed.add('old authority')]);
    await tester.pump(const Duration(milliseconds: 250));
    expect(pending, hasLength(1));
    owner.replace([() => completed.add('new authority')]);
    pending.removeAt(0)();
    expect(completed, isEmpty);
    await tester.pump(const Duration(milliseconds: 250));
    pending.removeAt(0)();
    expect(completed, ['new authority']);
    owner.replace([() => completed.add('disposed')]);
    await tester.pump(const Duration(milliseconds: 250));
    owner.dispose();
    pending.removeAt(0)();
    expect(completed, ['new authority']);
  });

  testWidgets('preparation bounds the retained batch to 64 messages', (
    tester,
  ) async {
    var completed = 0;
    final owner = MessagePreparation(isIdle: () => true);
    owner.replace([for (var i = 0; i < 1000; i++) () => completed++]);
    await advance(tester, const Duration(milliseconds: 250));
    for (var i = 0; i < 70; i++) {
      await advance(tester, const Duration(milliseconds: 16));
    }
    expect(completed, 64);
    owner.dispose();
  });
}
