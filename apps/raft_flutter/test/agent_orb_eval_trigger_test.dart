import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_launcher.dart';
import 'package:raft_flutter/platform/content_coordinator.dart';
import 'package:raft_flutter/platform/native_notifications.dart';
import 'package:raft_ui/raft_ui.dart';

/// How the evaluation starts: a raft://orb-eval/run link (adb) or the Labs
/// card, in debug builds only.

class Stand extends StatelessWidget {
  const Stand(this.request, {super.key});
  final OrbEvalRequest request;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text('eval:${request.only.join('+')}:${request.runs}'));
}

OrbEvalLauncher launcher({bool debug = true}) =>
    OrbEvalLauncher(debug: debug, pageBuilder: (request) => Stand(request));

void main() {
  group('the link', () {
    test('only=…&runs=… names the scenarios and the repeats', () {
      final r = OrbEvalRequest.fromLink(
        Uri.parse('raft://orb-eval/run?only=A1,b2&runs=3'),
      )!;
      expect(r.only, ['A1', 'b2']);
      expect(r.runs, 3);
      final all = OrbEvalRequest.fromLink(Uri.parse('raft://orb-eval/run'))!;
      expect(all.only, isEmpty);
      expect(all.runs, 2);
      expect(
        OrbEvalRequest.fromLink(Uri.parse('raft://orb-eval/run?runs=99'))!.runs,
        5,
      );
      expect(
        OrbEvalRequest.fromLink(Uri.parse('raft://orb-eval/run?runs=0'))!.runs,
        1,
      );
    });

    test('no other link is an evaluation link', () {
      for (final link in [
        'raft://v1/servers/s1/channels/c1',
        'raft://oauth/callback',
        'raft://orb-eval/other',
        'raft://orb-eval/run/extra',
        'https://orb-eval/run',
        'raft://orb-eval',
      ]) {
        expect(OrbEvalRequest.fromLink(Uri.parse(link)), isNull, reason: link);
      }
    });
  });

  group('the launcher', () {
    testWidgets('a link opens the page on the app\'s Navigator', (t) async {
      final key = GlobalKey<NavigatorState>();
      final l = launcher();
      await t.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      l.attach(key);
      expect(
        l.receiveLink(Uri.parse('raft://orb-eval/run?only=A1,B2&runs=3')),
        isTrue,
      );
      await t.pumpAndSettle();
      expect(find.text('eval:A1+B2:3'), findsOneWidget);
      expect(l.isOpen, isTrue);
      // A second link while it is open does nothing.
      l.receiveLink(Uri.parse('raft://orb-eval/run?only=C'));
      await t.pumpAndSettle();
      expect(find.text('eval:C:2'), findsNothing);
      key.currentState!.pop();
      await t.pumpAndSettle();
      expect(l.isOpen, isFalse);
    });

    testWidgets('a link before the Navigator waits for it', (t) async {
      final key = GlobalKey<NavigatorState>();
      final l = launcher();
      expect(l.receiveLink(Uri.parse('raft://orb-eval/run?only=D')), isTrue);
      expect(l.pending?.only, ['D']);
      await t.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      l.attach(key);
      await t.pumpAndSettle();
      expect(find.text('eval:D:2'), findsOneWidget);
      expect(l.pending, isNull);
    });

    testWidgets('outside debug builds nothing is taken and nothing opens', (
      t,
    ) async {
      final key = GlobalKey<NavigatorState>();
      final l = launcher(debug: false);
      await t.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      l.attach(key);
      expect(l.receiveLink(Uri.parse('raft://orb-eval/run')), isFalse);
      expect(l.open(const OrbEvalRequest()), isFalse);
      expect(l.pending, isNull);
      await t.pumpAndSettle();
      expect(find.textContaining('eval:'), findsNothing);
      expect(l.isOpen, isFalse);
    });
  });

  group('the app\'s link handling', () {
    late OrbEvalLauncher original;
    setUp(() => original = OrbEvalLauncher.instance);
    tearDown(() => OrbEvalLauncher.instance = original);

    testWidgets('an evaluation link goes to the launcher, before anything '
        'else looks at it', (t) async {
      final key = GlobalKey<NavigatorState>();
      OrbEvalLauncher.instance = launcher()..attach(key);
      final coordinator = NativeContentCoordinator(
        notifications: NativeNotificationService(),
        links: const Stream.empty(),
      );
      addTearDown(coordinator.dispose);
      await t.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      coordinator.receiveLink(Uri.parse('raft://orb-eval/run?only=E1'));
      await t.pumpAndSettle();
      expect(find.text('eval:E1:2'), findsOneWidget);
    });

    testWidgets('in a release build the same link is ignored', (t) async {
      final key = GlobalKey<NavigatorState>();
      OrbEvalLauncher.instance = launcher(debug: false)..attach(key);
      final coordinator = NativeContentCoordinator(
        notifications: NativeNotificationService(),
        links: const Stream.empty(),
      );
      addTearDown(coordinator.dispose);
      await t.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      coordinator.receiveLink(Uri.parse('raft://orb-eval/run?only=E1'));
      await t.pumpAndSettle();
      expect(find.textContaining('eval:'), findsNothing);
    });
  });

  group('the Labs card', () {
    Widget host(OrbEvalLabsCard card) => MaterialApp(
      theme: raftTheme(RaftFamily.brutal),
      home: Scaffold(body: card),
    );

    testWidgets('shows the title and a run button in debug builds', (t) async {
      final l = launcher();
      await t.pumpWidget(host(OrbEvalLabsCard(debug: true, launcher: l)));
      expect(find.text('Agent 评测（开发）'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('orb-eval-open')));
      await t.pumpAndSettle();
      expect(find.text('eval::2'), findsOneWidget, reason: 'the whole batch');
    });

    testWidgets('is not there outside debug builds', (t) async {
      await t.pumpWidget(
        host(OrbEvalLabsCard(debug: false, launcher: launcher())),
      );
      expect(find.text('Agent 评测（开发）'), findsNothing);
      expect(find.byKey(const ValueKey('orb-eval-open')), findsNothing);
    });
  });
}
