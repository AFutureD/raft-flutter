import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_mood.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_tv.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// The mood badge: an emoji for what the agent is doing, set by the app, that
/// the model may override sparingly with set_mood. Fictional data only.
final _now = DateTime.utc(2026, 10, 15, 12);

class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => _now);
  Completer<void>? gate;

  @override
  Future<AgentAttention> attention() async => const AgentAttention(items: []);

  @override
  Future<List<AgentRuntimeInfo>> agents() async {
    await gate?.future;
    return const [
      AgentRuntimeInfo(
        id: 'a1',
        name: 'Aria',
        state: AgentWorkState.busy,
        activity: '在做 #102',
      ),
      AgentRuntimeInfo(
        id: 'a2',
        name: 'Bo',
        state: AgentWorkState.idle,
        activity: '空闲',
      ),
    ];
  }
}

class _Scripted extends AgentScriptedModel {
  _Scripted(this.run) : super(streamDelay: Duration.zero);
  final Future<void> Function(AgentToolHandler call) run;

  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String) say,
  ) async {
    await run(call);
    return true;
  }
}

void main() {
  group('the controller', () {
    late AgentMoodController mood;
    setUp(() => mood = AgentMoodController());
    tearDown(() => mood.dispose());

    // The badge changes at most once per 600 ms: step past it.
    Future<void> settle(WidgetTester t) =>
        t.pump(const Duration(milliseconds: 700));

    testWidgets('each state has its emoji, idle first', (t) async {
      expect(mood.emoji, '🙂');
      final expected = {
        AgentMoodPhase.listening: '👂',
        AgentMoodPhase.thinking: '🤔',
        AgentMoodPhase.reading: '🔎',
        AgentMoodPhase.composing: '✍️',
        AgentMoodPhase.speaking: '🗣️',
        AgentMoodPhase.idle: '🙂',
      };
      expect(agentMoodByPhase, expected);
      for (final e in expected.entries) {
        mood.setPhase(e.key);
        expect(mood.emoji, e.value, reason: '${e.key}');
        await settle(t);
      }
      expect(mood.label, '待命');
    });

    test('set_mood takes one allowlisted emoji and nothing else', () {
      expect(agentMoodAllowlist, hasLength(30));
      for (final e in agentMoodAllowlist) {
        expect(e.characters.length, 1, reason: '$e is one grapheme');
      }
      // What the model is told is what is accepted.
      expect(agentMoodAllowlistText, agentMoodAllowlist.join(' '));
      // The ones named by the product owner are in.
      for (final e in '😄😊🤔😮😅😟🎉👀💪🙌☕🧐😴🔥✅⚠️'.characters) {
        expect(agentMoodMatch(e), isNotNull, reason: e);
      }

      for (final bad in [
        'x',
        '',
        '  ',
        '😄😊',
        '🎉🎉',
        '🙈',
        '😄 ',
        'ok 😄',
        '🏳️‍🌈',
      ]) {
        final fresh = AgentMoodController();
        final r = fresh.setMood(bad, 'x');
        if (bad == '😄 ') {
          // Surrounding space is not a second emoji.
          expect(r['ok'], isTrue, reason: bad);
        } else {
          expect(r['error'], isNotNull, reason: '"$bad"');
          expect(r['allowed'], agentMoodAllowlist);
          expect(fresh.moodOverride, isNull);
        }
        fresh.dispose();
      }
      expect(mood.setMood(null, null)['error'], isNotNull);
      expect(mood.setMood(7, null)['error'], isNotNull);
      // The variation selector of ⚠️ may be missing.
      final warn = AgentMoodController();
      expect(warn.setMood('⚠', 'careful')['emoji'], '⚠️');
      warn.dispose();
    });

    testWidgets('a mood overrides the state, once per turn', (t) async {
      mood.setPhase(AgentMoodPhase.speaking);
      await settle(t);
      expect(mood.emoji, '🗣️');
      final r = mood.setMood('🎉', '没有事在等你');
      expect(r['ok'], isTrue);
      expect(mood.emoji, '🎉');
      expect(mood.moodOverride, '🎉');
      expect(mood.reason, '没有事在等你');
      // Not twice in a turn, however it is asked.
      expect(mood.setMood('😟', 'x')['error'], isNotNull);
      expect(mood.moodOverride, '🎉');
      // A new turn may set again.
      mood.newTurn();
      await settle(t);
      expect(mood.setMood('😅', 'x')['ok'], isTrue);
      await t.pump(const Duration(seconds: 7));
    });

    testWidgets('a mood lasts about six seconds', (t) async {
      mood.setMood('😟', '卡住了');
      expect(mood.emoji, '😟');
      await t.pump(const Duration(milliseconds: 5900));
      expect(mood.emoji, '😟');
      await t.pump(const Duration(milliseconds: 200));
      // Back to the state's emoji.
      expect(mood.moodOverride, isNull);
      expect(mood.emoji, '🙂');
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('a mood ends at the next state change', (t) async {
      mood.setPhase(AgentMoodPhase.speaking);
      await settle(t);
      mood.setMood('🎉', 'x');
      await settle(t);
      expect(mood.emoji, '🎉');
      mood.setPhase(AgentMoodPhase.idle);
      expect(mood.moodOverride, isNull);
      expect(mood.emoji, '🙂');
      // The same phase again is not a change.
      await settle(t);
      mood.newTurn();
      mood.setMood('😊', 'x');
      mood.setPhase(AgentMoodPhase.idle);
      expect(mood.moodOverride, '😊');
      await t.pump(const Duration(seconds: 7));
    });

    testWidgets('the badge changes at most once per 600 ms', (t) async {
      final shown = <String>[];
      mood.addListener(() => shown.add(mood.emoji));
      mood.setPhase(AgentMoodPhase.listening); // at once: nothing before it
      expect(shown, ['👂']);
      // A flurry of states: none shows yet.
      mood.setPhase(AgentMoodPhase.thinking);
      mood.setPhase(AgentMoodPhase.reading);
      mood.setPhase(AgentMoodPhase.composing);
      await t.pump(const Duration(milliseconds: 300));
      expect(shown, ['👂']);
      mood.setPhase(AgentMoodPhase.speaking);
      await t.pump(const Duration(milliseconds: 299));
      expect(shown, ['👂']);
      // Then the latest wanted one, not every one in between.
      await t.pump(const Duration(milliseconds: 2));
      expect(shown, ['👂', '🗣️']);
      // And the next change waits for its own 600 ms.
      mood.setPhase(AgentMoodPhase.idle);
      await t.pump(const Duration(milliseconds: 500));
      expect(shown, ['👂', '🗣️']);
      await t.pump(const Duration(milliseconds: 150));
      expect(shown, ['👂', '🗣️', '🙂']);
      // A change that comes back to what is shown shows nothing.
      mood.setPhase(AgentMoodPhase.reading);
      mood.setPhase(AgentMoodPhase.idle);
      await t.pump(const Duration(seconds: 2));
      expect(shown, ['👂', '🗣️', '🙂']);
    });

    testWidgets('a mood waits its turn like any change', (t) async {
      mood.setPhase(AgentMoodPhase.listening);
      final r = mood.setMood('🎉', 'x');
      expect(r['ok'], isTrue);
      // Wanted at once, shown when the 600 ms is up.
      expect(mood.emoji, '👂');
      await t.pump(const Duration(milliseconds: 650));
      expect(mood.emoji, '🎉');
      await t.pump(const Duration(seconds: 7));
    });
  });

  group('the badge', () {
    Widget app(Widget child, {bool reduced = false}) => MaterialApp(
      theme: raftTheme(RaftFamily.brutal),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(body: Center(child: child)),
      ),
    );

    testWidgets('a large emoji in a sticker bubble that keeps its size', (
      t,
    ) async {
      await t.pumpWidget(app(const AgentMoodBadge(emoji: '🙂', label: '待命')));
      await t.pumpAndSettle();
      final bubble = find.byKey(const ValueKey('agent-mood-badge'));
      final size = t.getSize(bubble);
      expect(size.width, greaterThanOrEqualTo(52));
      final glyph = t.widget<Text>(find.text('🙂'));
      expect(glyph.style!.fontSize, greaterThanOrEqualTo(28));
      expect(glyph.textScaler, TextScaler.noScaling);
      expect(find.bySemanticsLabel('待命 🙂'), findsOneWidget);
      await t.pumpWidget(app(const AgentMoodBadge(emoji: '🔎', label: '在查数据')));
      await t.pumpAndSettle();
      expect(t.getSize(bubble), size);
    });

    testWidgets('a new emoji pops in', (t) async {
      await t.pumpWidget(app(const AgentMoodBadge(emoji: '🙂')));
      await t.pumpAndSettle();
      await t.pumpWidget(app(const AgentMoodBadge(emoji: '🤔')));
      await t.pump(const Duration(milliseconds: 40));
      // Mid-swap the new one is still growing and the old one is leaving.
      ScaleTransition pop() => t.widget<ScaleTransition>(
        find.ancestor(
          of: find.text('🤔'),
          matching: find.byType(ScaleTransition),
        ),
      );
      expect(pop().scale.value, lessThan(1));
      expect(find.text('🙂'), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.text('🙂'), findsNothing);
      expect(pop().scale.value, 1);
    });

    testWidgets('reduced motion: it just changes', (t) async {
      await t.pumpWidget(app(const AgentMoodBadge(emoji: '🙂'), reduced: true));
      await t.pumpWidget(app(const AgentMoodBadge(emoji: '🤔'), reduced: true));
      await t.pump();
      expect(find.text('🤔'), findsOneWidget);
      expect(find.text('🙂'), findsNothing);
    });

    testWidgets('the TV mirror shows it next to the caption', (t) async {
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final spotlight = AgentSpotlightController();
      final marks = AgentMarkController();
      addTearDown(spotlight.dispose);
      addTearDown(marks.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(
            body: AgentTvScreen(
              frame: {
                'caption': '都处理完了',
                'mood': '🎉',
                'layers': [
                  {
                    'id': 'attention',
                    'title': '现在需要你',
                    'attention': const AgentAttention(items: []).toJson(),
                  },
                ],
              },
              spotlight: spotlight,
              marks: marks,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('都处理完了'), findsOneWidget);
      expect(find.text('🎉'), findsOneWidget);
    });
  });

  group('on the page', () {
    late ActivityClient client;
    late WorkspaceController w;
    late _Data data;
    setUp(() {
      AgentModeData.clearSession();
      FlutterSecureStorage.setMockInitialValues({});
      client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
      client.selectServer('s1');
      w = WorkspaceController(client)
        ..server = RaftRecord({'id': 's1', 'role': 'owner'});
      data = _Data(w);
    });
    tearDown(() async {
      w.dispose();
      await client.dispose();
    });

    Future<void> open(WidgetTester t, AgentScriptedModel model) async {
      t.view.physicalSize = const Size(390, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(controller: w, data: data, model: model),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('agent-keyboard')));
      await t.pumpAndSettle();
    }

    Future<void> send(WidgetTester t, String text) async {
      await t.enterText(find.byKey(const ValueKey('agent-input')), text);
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pump();
    }

    // The newest is on top while one swaps for another.
    String badge(WidgetTester t) => t
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('agent-mood-badge')),
            matching: find.byType(Text),
          ),
        )
        .last
        .data!;

    testWidgets('it follows reading, composing and the end of the answer', (
      t,
    ) async {
      data.gate = Completer<void>();
      await open(
        t,
        const AgentScriptedModel(streamDelay: Duration(milliseconds: 700)),
      );
      expect(badge(t), '🙂');
      await send(t, '现在所有的 Agent 都在干什么？');
      // Asked: thinking, at once.
      expect(badge(t), '🤔');
      // The read is out: reading, as soon as the badge may change.
      await t.pump(const Duration(milliseconds: 700));
      expect(badge(t), '🔎');
      data.gate!.complete();
      // The screen is being composed.
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 700));
      expect(badge(t), '✍️');
      // Done: back to idle.
      await t.pump(const Duration(seconds: 2));
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(badge(t), '🙂');
    });

    testWidgets('set_mood from the model shows, a bad one is refused', (
      t,
    ) async {
      Map<String, Object?>? good, bad, twice;
      final talking = Completer<void>();
      await open(
        t,
        _Scripted((call) async {
          bad = await call('set_mood', {'emoji': '🙈', 'reason': 'x'});
          good = await call('set_mood', {'emoji': '🎉', 'reason': '没有事在等你'});
          twice = await call('set_mood', {'emoji': '😟', 'reason': 'x'});
          // Still answering: the mood holds until the state changes.
          await talking.future;
        }),
      );
      await send(t, '随便');
      await t.pump(const Duration(milliseconds: 700));
      expect(bad!['error'], isNotNull);
      expect(good!['ok'], isTrue);
      expect(twice!['error'], isNotNull);
      expect(badge(t), '🎉');
      // The answer ends: the state changed, so the mood is over.
      talking.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 700));
      expect(badge(t), '🙂');
      await t.pumpAndSettle();
    });

    testWidgets('a mood also ends by itself after about six seconds', (
      t,
    ) async {
      final talking = Completer<void>();
      await open(
        t,
        _Scripted((call) async {
          await call('set_mood', {'emoji': '😅', 'reason': '读取失败'});
          await talking.future;
        }),
      );
      await send(t, '随便');
      await t.pump(const Duration(milliseconds: 700));
      expect(badge(t), '😅');
      await t.pump(const Duration(seconds: 6));
      await t.pump(const Duration(milliseconds: 700));
      // Back to what the app is doing: still waiting for the answer.
      expect(badge(t), '🤔');
      talking.complete();
      await t.pumpAndSettle();
    });

    testWidgets('the badge sits beside the mic and the dock keeps its height', (
      t,
    ) async {
      await open(t, const AgentScriptedModel());
      final orb = t.getRect(find.byKey(const ValueKey('agent-orb')));
      final bubble = t.getRect(find.byKey(const ValueKey('agent-mood-badge')));
      expect(bubble.left, greaterThan(orb.right));
      expect(bubble.top, lessThan(orb.bottom));
      expect(bubble.overlaps(orb), isFalse);
    });
  });

  test('set_mood is declared, non-blocking, with the list the app accepts', () {
    final tool = agentToolDeclarations.firstWhere(
      (d) => d['name'] == 'set_mood',
    );
    expect(tool['behavior'], 'NON_BLOCKING');
    expect(tool['description'], contains(agentMoodAllowlistText));
    expect(
      GeminiLiveSession.nonBlockingNames(agentToolDeclarations),
      contains('set_mood'),
    );
    expect(
      agentSystemPrompt(channels: 'a'),
      allOf(contains('set_mood'), contains('每一轮最多一次')),
    );
  });
}
