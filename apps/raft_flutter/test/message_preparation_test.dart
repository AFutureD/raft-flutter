import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:raft_flutter/features/message_preparation.dart';

void main() {
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
