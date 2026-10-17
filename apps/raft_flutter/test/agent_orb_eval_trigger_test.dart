import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_thinking.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_launcher.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_result.dart'
    show OrbEvalHarness;
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

OrbEvalLauncher launcher({bool debug = true, GlobalKey<NavigatorState>? key}) =>
    OrbEvalLauncher(
      debug: debug,
      pageBuilder: (request) => Stand(request),
      navigator: key == null ? null : () => key.currentState,
    );

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

    test('harness=agent picks the text agent; anything else is realtime', () {
      OrbEvalHarness of(String query) =>
          OrbEvalRequest.fromLink(Uri.parse('raft://orb-eval/run$query'))!
              .harness;
      expect(of(''), OrbEvalHarness.realtime);
      expect(of('?harness=agent'), OrbEvalHarness.agent);
      expect(of('?only=A1&runs=3&harness=Agent'), OrbEvalHarness.agent);
      expect(of('?harness=realtime'), OrbEvalHarness.realtime);
      expect(of('?harness=other'), OrbEvalHarness.realtime);
      final r = OrbEvalRequest.fromLink(
        Uri.parse('raft://orb-eval/run?only=A1&runs=3&harness=agent'),
      )!;
      expect(r.only, ['A1']);
      expect(r.runs, 3);
    });

    test('thinking=minimal|low|medium|high is for the text agent, this run '
        'only', () {
      AgentThinking? of(String query) =>
          OrbEvalRequest.fromLink(Uri.parse('raft://orb-eval/run$query'))!
              .thinking;
      expect(of(''), isNull);
      expect(of('?harness=agent&thinking=minimal'), AgentThinking.minimal);
      expect(of('?thinking=Low'), AgentThinking.low);
      expect(of('?thinking=medium'), AgentThinking.medium);
      expect(of('?thinking=high&runs=2'), AgentThinking.high);
      expect(of('?thinking=extreme'), isNull);
    });

    test('harness=genkit picks the Genkit text agent; model= names the model '
        'for the text agents, and only a plain id', () {
      OrbEvalRequest of(String query) =>
          OrbEvalRequest.fromLink(Uri.parse('raft://orb-eval/run$query'))!;
      expect(of('?harness=genkit').harness, OrbEvalHarness.genkit);
      expect(OrbEvalHarness.genkit.isTextAgent, isTrue);
      expect(OrbEvalHarness.agent.isTextAgent, isTrue);
      expect(OrbEvalHarness.realtime.isTextAgent, isFalse);
      expect(of('').model, isNull);
      expect(
        of('?harness=genkit&model=gemini-3.5-flash-lite').model,
        'gemini-3.5-flash-lite',
      );
      expect(
        of('?model=googleai/gemini-3-flash-preview').model,
        'googleai/gemini-3-flash-preview',
      );
      expect(of('?model=a%20b').model, isNull);
      expect(of('?model=x?y%26z').model, isNull);
      expect(of('?model=').model, isNull);
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
      final l = launcher(key: key);
      await t.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
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

    testWidgets('without a test Navigator it finds the app\'s outermost one', (
      t,
    ) async {
      final l = OrbEvalLauncher(
        debug: true,
        pageBuilder: (request) => Stand(request),
      );
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      l.receiveLink(Uri.parse('raft://orb-eval/run?only=F'));
      await t.pumpAndSettle();
      expect(find.text('eval:F:2'), findsOneWidget);
    });

    testWidgets('a link before the Navigator exists waits for it, frame by '
        'frame', (t) async {
      final key = GlobalKey<NavigatorState>();
      final l = launcher(key: key);
      expect(l.receiveLink(Uri.parse('raft://orb-eval/run?only=D')), isTrue);
      expect(l.pending?.only, ['D']);
      await t.pump();
      expect(l.pending, isNotNull, reason: 'still no Navigator');
      await t.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      await t.pumpAndSettle();
      expect(find.text('eval:D:2'), findsOneWidget);
      expect(l.pending, isNull);
    });

    testWidgets('outside debug builds nothing is taken and nothing opens', (
      t,
    ) async {
      final key = GlobalKey<NavigatorState>();
      final l = launcher(debug: false, key: key);
      await t.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
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
      OrbEvalLauncher.instance = launcher(key: key);
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
      OrbEvalLauncher.instance = launcher(debug: false, key: key);
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
