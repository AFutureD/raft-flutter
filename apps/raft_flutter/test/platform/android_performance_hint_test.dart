import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:raft_flutter/platform/android_performance_hint.dart';

class FakeBackend implements PerformanceHintBackend {
  bool supported = true;
  int result = 0;
  int resetResult = 0;
  final calls = <String>[];
  @override
  bool open(int targetNanos) {
    calls.add('open:$targetNanos');
    return supported;
  }

  @override
  int updateTarget(int targetNanos) {
    calls.add('target:$targetNanos');
    return result;
  }

  @override
  int report(int actualNanos) {
    calls.add('report:$actualNanos');
    return result;
  }

  @override
  int reset() {
    calls.add('reset');
    return resetResult;
  }

  @override
  void close() => calls.add('close');
}

void main() {
  testWidgets('production entrypoint preserves an existing test binding', (
    tester,
  ) async {
    expect(RaftWidgetsFlutterBinding.ensureInitialized(), same(tester.binding));
    await tester.pumpWidget(const SizedBox());
  });
  test('refresh targets follow display, with safe unknown-rate fallback', () {
    expect(PerformanceHintController.targetForRefreshRate(120), 8333333);
    expect(PerformanceHintController.targetForRefreshRate(60), 16666667);
    expect(
      PerformanceHintController.targetForRefreshRate(double.nan),
      16666667,
    );
    expect(PerformanceHintController.targetForRefreshRate(0), 16666667);
  });
  test('burst opens once; feedback and refresh changes use same session', () {
    final backend = FakeBackend();
    final controller = PerformanceHintController(backend);
    addTearDown(controller.close);
    controller.begin(120);
    controller.report(11000000);
    controller.begin(120);
    controller.begin(60);
    expect(backend.calls, [
      'open:8333333',
      'reset',
      'report:11000000',
      'target:16666667',
    ]);
    expect(controller.reports, 1);
  });
  test('background closes immediately and never opens until resumed', () {
    final backend = FakeBackend();
    final controller = PerformanceHintController(backend);
    addTearDown(controller.close);
    controller.begin(120);
    controller.setForeground(false);
    controller.begin(120);
    controller.report(5);
    expect(backend.calls, ['open:8333333', 'reset', 'close']);
    controller.setForeground(true);
    controller.begin(60);
    expect(backend.calls.last, 'reset');
    expect(controller.sessionsOpened, 2);
  });
  test('unsupported session does not repeatedly call system service', () {
    final backend = FakeBackend()..supported = false;
    final controller = PerformanceHintController(backend);
    controller.begin(120);
    controller.begin(120);
    expect(backend.calls, ['open:8333333']);
    expect(controller.active, false);
  });
  test('rate limiting is tolerated, service errors close and disable', () {
    final backend = FakeBackend()..resetResult = 16;
    final controller = PerformanceHintController(backend);
    controller.begin(120);
    expect(controller.active, true);
    backend.result = 32;
    controller.report(100);
    controller.begin(120);
    expect(backend.calls, ['open:8333333', 'reset', 'report:100', 'close']);
    expect(controller.errors, 1);
    expect(controller.active, false);
  });
  test('idle session releases without continued frame feedback', () async {
    final backend = FakeBackend();
    final controller = PerformanceHintController(backend);
    addTearDown(controller.close);
    controller.begin(120);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(controller.active, false);
    expect(backend.calls.last, 'close');
  });
  test('no backend and nonpositive duration are harmless', () {
    final controller = PerformanceHintController(null);
    controller.begin(120);
    controller.report(1);
    expect(controller.active, false);
    final backend = FakeBackend();
    final active = PerformanceHintController(backend);
    addTearDown(active.close);
    active.begin(60);
    active.report(0);
    expect(active.reports, 0);
  });
}
