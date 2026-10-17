import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/orb_avoidance.dart';
import 'package:raft_flutter/features/agent_orb/orb_controller.dart';
import 'package:raft_flutter/features/agent_orb/orb_host.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Shell of the Agent orb: the Labs switch, the floating orb above every phone
/// page, its sheet, its drag and the operating indicator. Fake audio and fake
/// voice sessions; real taps, long presses and drags.

class FakeAudio extends AgentAudio {
  FakeAudio() : super.forTesting();
  int micStarts = 0, micStops = 0;

  @override
  bool get supported => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Stream<Uint8List> microphone() {
    final c = StreamController<Uint8List>(
      onListen: () => micStarts++,
      onCancel: () => micStops++,
    );
    return c.stream;
  }

  @override
  Future<void> play(Uint8List pcm) async {}
  @override
  Future<Duration> pending() async => Duration.zero;
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<void> release() async {}
}

class FakeSession implements VoiceSession {
  FakeSession({
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onClosed,
  });

  final String systemPrompt;
  final List<Map<String, Object?>> tools;
  final connectGate = Completer<void>();
  final sentTexts = <String>[];
  bool _connected = false;
  int closes = 0;

  @override
  bool get connected => _connected;
  @override
  String? get model => 'fake-model';
  @override
  final AgentToolHandler onToolCall;
  @override
  final void Function(Uint8List pcm24k)? onAudio;
  @override
  final void Function(String text)? onInputText;
  @override
  final void Function(String text)? onOutputText;
  @override
  final void Function()? onTurnComplete;
  @override
  final void Function(String reason)? onClosed;
  @override
  void Function()? get onInterrupted => null;

  @override
  Future<void> connect() async {
    await connectGate.future;
    _connected = true;
  }

  @override
  void sendAudio(Uint8List pcm16k) {}
  @override
  void endAudio() {}
  @override
  void sendText(String text) => sentTexts.add(text);
  @override
  Future<void> close() async {
    closes++;
    _connected = false;
  }
}

/// A tab bar and a composer stand-ins the orb must keep clear of.
class FakeTabBar extends StatelessWidget {
  const FakeTabBar({super.key});
  @override
  Widget build(BuildContext context) => Container(
    height: 68,
    color: Colors.amber,
    alignment: Alignment.center,
    child: const Text('tabs'),
  );
}

class FakeComposer extends StatelessWidget {
  const FakeComposer({super.key});
  @override
  Widget build(BuildContext context) => Container(
    height: 116,
    color: Colors.pink,
    alignment: Alignment.center,
    child: const Text('composer'),
  );
}

class OrbFixture {
  OrbFixture(this.t);
  final WidgetTester t;
  late ActivityClient client;
  late WorkspaceController w;
  late FakeAudio audio;
  late OrbController controller;
  final sessions = <FakeSession>[];
  final pageTaps = <int>[];
  final navKey = GlobalKey<NavigatorState>();

  /// The voice key of the session; null is a device without one.
  String? apiKey = 'test-key';

  /// Takes the summary of a session instead of the shared agent's DM.
  OrbSummarySender? summarySender;

  Future<void> setUp() async {
    SharedPreferences.setMockInitialValues({});
    AgentOrbPreference.instance.resetForTest();
    client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
    client.selectServer('s1');
    w = WorkspaceController(client)
      ..server = RaftRecord({'id': 's1', 'role': 'owner'})
      ..channels = [
        RaftChannel({'id': 'c1', 'name': 'raft-flutter', 'joined': true}),
      ];
    audio = FakeAudio();
  }

  Future<void> tearDown() async {
    AgentOrbPreference.instance.resetForTest();
    w.dispose();
    await client.dispose();
  }

  OrbController build({List<OrbTool> tools = const []}) =>
      controller = OrbController(
        workspace: w,
        navigatorContext: () => navKey.currentState?.overlay?.context,
        appTools: tools,
        audio: audio,
        voiceKey: AgentVoiceKey.forTesting(apiKey),
        summarySender: summarySender,
        sessionFactory:
            ({
              required provider,
              required apiKey,
              required systemPrompt,
              required tools,
              required onToolCall,
              required voice,
              reasoning = AgentReasoning.low,
              onAudio,
              onInputText,
              onOutputText,
              onTurnComplete,
              onInterrupted,
              onClosed,
              playbackPending,
            }) {
              final s = FakeSession(
                systemPrompt: systemPrompt,
                tools: tools,
                onToolCall: onToolCall,
                onAudio: onAudio,
                onInputText: onInputText,
                onOutputText: onOutputText,
                onTurnComplete: onTurnComplete,
                onClosed: onClosed,
              );
              sessions.add(s);
              return s;
            },
      );

  /// A phone (or wide) window with a Labs card, a composer and a tab bar
  /// under an app Navigator, and the orb host around it all.
  Future<void> pump({
    double width = 412,
    double textScale = 1.0,
    bool enabled = true,
    bool composer = false,
    List<OrbTool> tools = const [],
  }) async {
    t.view.physicalSize = Size(width, 915);
    t.view.devicePixelRatio = 1;
    t.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    t.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    t.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      t.view.reset();
      t.platformDispatcher.clearAllTestValues();
    });
    if (enabled) AgentOrbPreference.instance.setEnabled(true);
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        theme: raftTheme(RaftFamily.brutal),
        builder: (context, child) => AgentOrbHost(
          workspace: w,
          navigatorKey: navKey,
          avoidance: OrbAvoidance.byType(const [FakeTabBar, FakeComposer]),
          createController: (w, navigatorContext) => build(tools: tools),
          child: child!,
        ),
        home: Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                const AgentOrbLabsCard(),
                Expanded(
                  child: GestureDetector(
                    key: const ValueKey('page-content'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => pageTaps.add(1),
                    child: const Center(child: Text('page')),
                  ),
                ),
                if (composer) const FakeComposer(),
                const FakeTabBar(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
    await t.pump();
  }

  static final orbFinder = find.byKey(const ValueKey('agent-orb'));

  Rect orbRect() => t.getRect(orbFinder);
}

void main() {
  late OrbFixture f;
  setUp(() async {
    // Set up inside the test: the fixture needs the tester.
  });

  Future<OrbFixture> fixture(WidgetTester t) async {
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    return f;
  }

  group('Labs switch and phone only', () {
    testWidgets('the Labs switch shows and hides the orb', (t) async {
      await fixture(t);
      await f.pump(enabled: false);
      expect(OrbFixture.orbFinder, findsNothing);
      expect(find.text('Agent 悬浮球（手机）'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('agent-orb-switch')));
      await t.pump();
      await t.pump();
      expect(AgentOrbPreference.instance.enabled, isTrue);
      expect(OrbFixture.orbFinder, findsOneWidget);

      await t.tap(find.byKey(const ValueKey('agent-orb-switch')));
      await t.pump();
      await t.pump();
      expect(OrbFixture.orbFinder, findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('the orb and its Labs card are hidden on wide layouts', (
      t,
    ) async {
      await fixture(t);
      await f.pump(width: 1100);
      expect(OrbFixture.orbFinder, findsNothing);
      expect(find.text('Agent 悬浮球（手机）'), findsNothing);
    });

    testWidgets('the switch is off by default', (t) async {
      await fixture(t);
      await f.pump(enabled: false);
      expect(AgentOrbPreference.instance.enabled, isFalse);
    });
  });

  group('orb sheet', () {
    testWidgets('a tap opens the sheet and the orb docks into its footer', (
      t,
    ) async {
      await fixture(t);
      await f.pump();
      await t.tap(OrbFixture.orbFinder);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('orb-sheet')), findsOneWidget);
      expect(f.controller.sheetOpen, isTrue);
      // One orb at a time: the floating one docks into the sheet footer.
      expect(OrbFixture.orbFinder, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('orb-sheet-footer')),
          matching: OrbFixture.orbFinder,
        ),
        findsOneWidget,
      );
      // Closing the sheet puts the orb back.
      await t.tap(find.byKey(const ValueKey('orb-sheet-close')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('orb-sheet')), findsNothing);
      expect(f.controller.sheetOpen, isFalse);
      expect(OrbFixture.orbFinder, findsOneWidget);
    });
  });

  group('drag', () {
    testWidgets('rests above the tab bar at the right edge', (t) async {
      await fixture(t);
      await f.pump();
      await t.pump(const Duration(milliseconds: 300));
      final tabs = t.getRect(find.byType(FakeTabBar));
      final orb = f.orbRect();
      expect(orb.bottom, lessThanOrEqualTo(tabs.top));
      expect(orb.right, closeTo(412 - RaftSpace.x3, 1));
    });

    testWidgets('dragging moves the orb and it snaps to the nearest edge', (
      t,
    ) async {
      await fixture(t);
      await f.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.drag(OrbFixture.orbFinder, const Offset(-250, -300));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final moved = f.orbRect();
      // Dropped left of the middle: it snaps to the left edge.
      expect(moved.left, closeTo(RaftSpace.x3, 1));
      expect(moved.top, lessThan(500));

      // Dragging back over to the right half snaps to the right edge.
      await t.drag(OrbFixture.orbFinder, const Offset(250, 0));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(f.orbRect().right, closeTo(412 - RaftSpace.x3, 1));
      expect(f.pageTaps, isEmpty);
    });

    testWidgets('never overlaps the tab bar or the composer', (t) async {
      await fixture(t);
      await f.pump(composer: true);
      await t.pump(const Duration(milliseconds: 300));
      final tabs = t.getRect(find.byType(FakeTabBar));
      final composer = t.getRect(find.byType(FakeComposer));
      expect(f.orbRect().bottom, lessThanOrEqualTo(composer.top));
      // Drag it down over both.
      await t.drag(OrbFixture.orbFinder, const Offset(0, 600));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final orb = f.orbRect();
      expect(orb.overlaps(tabs), isFalse);
      expect(orb.overlaps(composer), isFalse);
      expect(orb.bottom, lessThanOrEqualTo(composer.top));
      // And up over the status bar.
      await t.drag(OrbFixture.orbFinder, const Offset(0, -2000));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(f.orbRect().top, greaterThanOrEqualTo(24));
    });
  });

  group('operating indicator', () {
    testWidgets('shows the frame and the toast, and a touch ends it', (
      t,
    ) async {
      await fixture(t);
      await f.pump();
      expect(find.byKey(const ValueKey('orb-operating-frame')), findsNothing);
      f.controller.operating
        ..label = '#raft-flutter'
        ..value = true;
      await t.pump();
      expect(find.byKey(const ValueKey('orb-operating-frame')), findsOneWidget);
      expect(find.text('Agent 打开了 #raft-flutter · 点屏幕即可接管'), findsOneWidget);
      expect(OrbFixture.orbFinder, findsOneWidget);

      // A pointer down on the page content takes over (and the page still
      // gets its tap).
      await t.tap(find.byKey(const ValueKey('page-content')));
      await t.pump();
      expect(f.controller.operating.value, isFalse);
      expect(f.controller.operating.takeovers, 1);
      expect(find.byKey(const ValueKey('orb-operating-frame')), findsNothing);
      expect(f.pageTaps, hasLength(1));
    });

    testWidgets('a touch on the orb sheet does not take over', (t) async {
      await fixture(t);
      await f.pump();
      await t.tap(OrbFixture.orbFinder);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      f.controller.operating.value = true;
      await t.pump();
      await t.tap(find.byKey(const ValueKey('orb-sheet-input')));
      await t.pump();
      expect(f.controller.operating.value, isTrue);
      expect(f.controller.operating.takeovers, 0);
    });
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('no layout overflow at text scale $scale', (t) async {
      await fixture(t);
      await f.pump(textScale: scale, composer: true);
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);
      // Operating chip, toast and the status chips.
      f.controller.operating
        ..label = '#raft-flutter'
        ..value = true;
      await t.pump();
      expect(t.takeException(), isNull);
      f.controller.operating.value = false;
      // The orb sheet with a transcript.
      await t.tap(OrbFixture.orbFinder);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.enterText(
        find.byKey(const ValueKey('orb-sheet-input')),
        '看看动态里什么要我处理，顺便告诉我 raft-flutter 频道的情况',
      );
      await t.tap(find.byKey(const ValueKey('orb-sheet-send')));
      await t.pump();
      await t.pump();
      f.sessions.single.connectGate.complete();
      await t.pump();
      await t.pump();
      f.sessions.single.onOutputText!('第 10 步的方案 Cody 已经写好了，在等你批准。' * 3);
      await t.pump();
      expect(t.takeException(), isNull);
    });
  }
}
