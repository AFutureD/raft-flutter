// Leak-tracking regressions: each test builds the widget, tears it down and
// ends; the object-leak report that `flutter_test_config.dart` enables fails
// this file when the widget leaves a TextPainter or OverlayEntry undisposed.
// None of these classes may ever be added to that file's ignore list.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';
import 'package:raft_ui/raft_ui.dart';

void main() {
  test('the raft_ui leak ignore list never hides what these tests guard', () {
    final ignored = LeakTesting.settings.ignoredLeaks.notDisposed.byClass.keys;
    expect(ignored, isNot(contains('TextPainter')));
    expect(ignored, isNot(contains('OverlayEntry')));
  });

  testWidgets('DM header measures its texts with painters it disposes', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: false),
        home: const Scaffold(
          body: RaftDmHeader(
            name: 'A rather long peer display name',
            avatar: SizedBox(width: 36, height: 36),
            activity: RaftActivityTone.working,
            activityText: 'Thinking about something long',
            muted: true,
          ),
        ),
      ),
    );
    // Every rebuild measures again.
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: true),
        home: const Scaffold(
          body: RaftDmHeader(
            name: 'Peer',
            avatar: SizedBox(width: 36, height: 36),
          ),
        ),
      ),
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the toast host keeps one overlay entry and disposes it', (
    t,
  ) async {
    final controller = RaftToastController();
    addTearDown(controller.dispose);
    Widget app(String label) => MaterialApp(
      theme: raftTheme(RaftFamily.elegant, dark: false),
      home: RaftToastHost(
        controller: controller,
        child: Scaffold(body: Text(label)),
      ),
    );
    await t.pumpWidget(app('one'));
    // A host rebuild used to create (and drop) a fresh OverlayEntry each time.
    await t.pumpWidget(app('two'));
    await t.pumpWidget(app('three'));
    controller.show('Copied', dismissible: false);
    await t.pump();
    expect(find.text('Copied'), findsOneWidget);
    await t.pump(const Duration(seconds: 30)); // the auto-dismiss timer
    await t.pumpWidget(const SizedBox());
  });
}
