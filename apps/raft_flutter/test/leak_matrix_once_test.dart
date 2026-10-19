// ignore_for_file: implementation_imports, depend_on_referenced_packages
// On the gate, tool/testing/matrix_leaks.dart leak-tracks only the first case
// of a declaration that expands to more than 8 cases; the nightly tracks all.
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';
import 'package:raft_ui/test_themes.dart' show raftFullMatrix;
import 'package:test_api/src/backend/invoker.dart' show Invoker;

void main() {
  final big = <bool>[];
  final small = <bool>[];
  for (var i = 0; i < 10; i++) {
    testWidgets('a ten case matrix, case $i', (t) async {
      big.add(LeakTesting.settings.ignore);
    });
  }
  for (var i = 0; i < 8; i++) {
    testWidgets('an eight case matrix, case $i', (t) async {
      small.add(LeakTesting.settings.ignore);
    });
  }

  testWidgets('a matrix of more than 8 cases is tracked once on the gate', (
    t,
  ) async {
    if (Invoker.current!.liveTest.test.trace == null) {
      markTestSkipped('no test traces without a JSON reporter');
      return;
    }
    expect(big, hasLength(10));
    expect(
      big.where((ignored) => !ignored),
      hasLength(raftFullMatrix ? 10 : 1),
    );
    expect(big.first, isFalse, reason: 'the first case stays tracked');
    expect(
      small.where((ignored) => ignored),
      isEmpty,
      reason: '8 or fewer stay tracked',
    );
    expect(LeakTesting.settings.ignore, isFalse, reason: 'restored afterwards');
  });
}
