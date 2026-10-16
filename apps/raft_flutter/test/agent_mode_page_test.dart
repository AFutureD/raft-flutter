import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/agent_memory.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

final _now = DateTime.utc(2026, 10, 15, 12);

class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => _now);
  int channelReads = 0;

  @override
  Future<AgentAttention> attention() async => AgentAttention(
    items: [
      AgentAttentionItem(
        id: 't94',
        taskId: 't94',
        taskNumber: 94,
        priority: AgentPriority.decision,
        headline: 'Cindy 完成了「Personal Agent 第一版选型」，等你验收',
        ask: '验收',
        action: AgentAction.approve,
        canApprove: true,
        reason: '你派的任务',
        waitValue: 3,
        waitUnit: '小时',
        at: _now,
        waiters: const ['Cindy'],
        channelId: 'c1',
        channelName: 'raft-flutter',
      ),
      AgentAttentionItem(
        id: 't7',
        taskId: 't7',
        priority: AgentPriority.blocked,
        headline: 'Grok 的「iOS 搜索后无法返回」5 小时没动，卡住了',
        ask: '解除阻塞',
        reason: '卡住了',
        idle: true,
        waitValue: 5,
        at: _now,
      ),
    ],
  );

  @override
  Future<AgentChannelBrief> channel(
    RaftChannel c, {
    int windowHours = 6,
  }) async {
    channelReads++;
    return AgentChannelBrief(
      channel: c,
      messages: [
        {
          'id': 'm1',
          'seq': '1',
          'content': 'PR #113 已合入',
          'senderName': 'Cindy',
          'createdAt': _now.toIso8601String(),
        },
      ],
      tasks: [
        {'taskNumber': 98, 'title': '搜索返回', 'status': 'in_review'},
      ],
      windowHours: windowHours,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> openTasks() async => [
    {'taskNumber': 102, 'title': '历史上拉', 'status': 'in_progress'},
  ];
}

void main() {
  late ActivityClient client;
  late WorkspaceController w;
  setUp(() {
    AgentModeData.clearSession();
    // No voice key: typed requests use the local intents.
    FlutterSecureStorage.setMockInitialValues({});
    client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
    client.selectServer('s1');
    w = WorkspaceController(client)
      ..server = RaftRecord({'id': 's1', 'role': 'owner'})
      ..channels = [
        RaftChannel({'id': 'c1', 'name': 'raft-flutter', 'joined': true}),
        RaftChannel({'id': 'c2', 'name': 'general', 'joined': true}),
      ];
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  for (final (family, dark) in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    testWidgets(
      'layers push and pop on the Z axis: ${family.name} dark=$dark',
      (t) async {
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final data = _Data(w);
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(family, dark: dark),
            home: AgentModePage(controller: w, data: data),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('现在需要你'), findsWidgets);
        expect(find.text('第 1 层'), findsOneWidget);
        expect(
          find.text('Cindy 完成了「Personal Agent 第一版选型」，等你验收'),
          findsOneWidget,
        );

        // Voice first: typing is behind the keyboard button.
        expect(find.byKey(const ValueKey('agent-input')), findsNothing);
        expect(find.byKey(const ValueKey('agent-orb')), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('agent-keyboard')));
        await t.pumpAndSettle();
        await t.enterText(
          find.byKey(const ValueKey('agent-input')),
          'raft-flutter 现在什么情况？',
        );
        await t.testTextInput.receiveAction(TextInputAction.send);
        await t.pumpAndSettle();
        expect(find.text('第 2 层'), findsOneWidget);
        expect(find.text('# raft-flutter'), findsOneWidget);
        expect(find.text('PR #113 已合入'), findsOneWidget);
        expect(data.channelReads, 1);
        // The attention layer is still mounted behind as a peek strip.
        expect(find.textContaining('现在需要你'), findsWidgets);

        await t.enterText(find.byKey(const ValueKey('agent-input')), '返回');
        await t.testTextInput.receiveAction(TextInputAction.send);
        await t.pumpAndSettle();
        expect(find.text('第 1 层'), findsOneWidget);
        expect(find.text('# raft-flutter'), findsNothing);

        // A priority card becomes the current item (its stage opens, no layer); 展开
        // opens its full detail as a new layer.
        await t.tap(find.text('Cindy 完成了「Personal Agent 第一版选型」，等你验收'));
        await t.pumpAndSettle();
        expect(find.text('第 1 层'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('hf-stage-expand')));
        await t.pumpAndSettle();
        expect(find.text('第 2 层'), findsOneWidget);

        // System back pops one layer before leaving the page.
        final popped = await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(popped, isTrue);
        expect(find.text('第 1 层'), findsOneWidget);
      },
    );
  }

  for (final wide in [false, true]) {
    testWidgets(
      'a row of a channel is current on a tap: ${wide ? 'the slot beside '
                'the list' : 'a stage under it'} shows it',
      (t) async {
        t.view.physicalSize = wide
            ? const Size(1440, 900)
            : const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(RaftFamily.brutal),
            home: AgentModePage(controller: w, data: _Data(w)),
          ),
        );
        await t.pumpAndSettle();
        if (find.byKey(const ValueKey('agent-input')).evaluate().isEmpty) {
          await t.tap(find.byKey(const ValueKey('agent-keyboard')));
        }
        await t.pumpAndSettle();
        await t.enterText(
          find.byKey(const ValueKey('agent-input')),
          'raft-flutter 现在什么情况？',
        );
        await t.testTextInput.receiveAction(TextInputAction.send);
        await t.pumpAndSettle();
        expect(find.text('第 2 层'), findsOneWidget);
        expect(find.byKey(const ValueKey('agent-frame-stage')), findsNothing);

        await t.tap(find.text('PR #113 已合入'));
        await t.pumpAndSettle();
        // No new layer; the item is shown on the stage, in full.
        expect(find.text('第 2 层'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('agent-frame-stage')),
            matching: find.text('PR #113 已合入'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('hf-stage')),
          wide ? findsNothing : findsOneWidget,
        );
        // Its row is still in the list, lit.
        expect(find.text('PR #113 已合入'), findsNWidgets(2));
        // Going back puts the stage under a row away first; the pane beside a
        // list has nothing to put away.
        if (!wide) {
          await t.binding.handlePopRoute();
          await t.pumpAndSettle();
          expect(find.byKey(const ValueKey('hf-stage')), findsNothing);
          expect(find.text('第 2 层'), findsOneWidget);
        }
      },
    );
  }

  testWidgets('unknown requests get a hint and keep the stack', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentModePage(controller: w, data: _Data(w)),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('agent-keyboard')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('agent-input')), '帮我订机票');
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pumpAndSettle();
    expect(find.textContaining('这句我还不会'), findsOneWidget);
    expect(find.text('第 1 层'), findsOneWidget);
  });

  testWidgets('the mic explains when voice is unavailable here', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentModePage(controller: w, data: _Data(w)),
      ),
    );
    await t.pumpAndSettle();
    // The strip says what the agent announced (the most urgent thing); with
    // nothing said it says how to talk.
    expect(find.byKey(const ValueKey('agent-mic-hint')), findsOneWidget);
    final mic = await t.startGesture(
      t.getCenter(find.byKey(const ValueKey('agent-orb'))),
    );
    await t.pump(const Duration(milliseconds: 100));
    await mic.up();
    await t.pumpAndSettle();
    expect(find.textContaining('还不支持语音'), findsOneWidget);
    expect(find.text('第 1 层'), findsOneWidget);
  });

  testWidgets('voice settings are adjustable and kept', (t) async {
    SharedPreferences.setMockInitialValues({});
    await DevicePreferences.load();
    t.view.physicalSize = const Size(420, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    String? previewed;
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentVoiceSettingsPage(onPreview: (v) => previewed = v),
      ),
    );
    final s = AgentVoiceSettings.instance;
    expect(s.voice, 'Sulafat');
    await t.tap(find.text('柔和'));
    await t.pump();
    expect(s.voice, 'Achernar');
    await t.tap(find.byTooltip('试听').at(2));
    await t.pump();
    expect((previewed, s.voice), ('Vindemiatrix', 'Vindemiatrix'));
    await t.tap(find.byKey(ValueKey('agent-setting-${AgentPace.slow}')));
    await t.tap(
      find.byKey(ValueKey('agent-setting-${AgentWarmth.restrained}')),
    );
    await t.pump();
    expect(s.pace, AgentPace.slow);
    expect(s.styleNote, allOf(contains('语速放慢'), contains('克制')));
  });

  testWidgets('the current item is highlighted where it is; nothing floats', (
    t,
  ) async {
    final spotlight = AgentSpotlightController();
    addTearDown(spotlight.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(
          body: AgentSpotlight(
            controller: spotlight,
            child: ListView(
              children: [
                for (var n = 1; n <= 3; n++)
                  AgentFocusable(
                    id: 'layer#$n',
                    child: HfRow(
                      index: n,
                      tone: HfTone.decision,
                      title: 'Item $n',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // The highlight is the row's own fill.
    int lit() => t
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where(
          (d) =>
              d.decoration is BoxDecoration &&
              (d.decoration as BoxDecoration).color == const Color(0xfffff7d6),
        )
        .length;
    expect(lit(), 0);
    spotlight.focus('layer#2');
    await t.pumpAndSettle();
    // No copy floats above the page, no scrim: the row stays and lights up.
    expect(find.text('Item 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-spotlight-scrim')), findsNothing);
    expect(lit(), 1);
    // Another item takes over; letting go lights none.
    spotlight.focus('layer#3');
    await t.pumpAndSettle();
    expect(lit(), 1);
    expect(find.text('Item 3'), findsOneWidget);
    spotlight.release();
    await t.pumpAndSettle();
    expect(lit(), 0);
  });

  testWidgets('marks draw on the item text they name', (t) async {
    final marks = AgentMarkController();
    addTearDown(marks.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(
          body: AgentMarks(
            controller: marks,
            child: Column(
              children: [
                for (var n = 1; n <= 2; n++)
                  AgentFocusable(
                    id: 'layer#$n',
                    child: HfRow(
                      index: n,
                      tone: HfTone.decision,
                      title: 'Personal Agent 第一版选型',
                      detail: '#94 · 已经等了 2 小时',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    Finder painted(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            '${w.foregroundPainter.runtimeType}' == '_MarkPainter',
      ),
    );
    expect(painted('#94 · 已经等了 2 小时'), findsNothing);
    marks.add(
      const AgentMark(
        itemId: 'layer#2',
        phrase: '2 小时',
        style: AgentMarkStyle.highlight,
      ),
    );
    await t.pumpAndSettle();
    // Only item 2's detail carries the mark; item 1 and the titles do not.
    expect(painted('#94 · 已经等了 2 小时'), findsOneWidget);
    expect(painted('Personal Agent 第一版选型'), findsNothing);
    // At most two at a time; clearing removes them.
    marks
      ..add(const AgentMark(itemId: 'layer#1', phrase: '第一版'))
      ..add(const AgentMark(itemId: 'layer#2', phrase: '选型'));
    expect(marks.marks.map((m) => m.phrase), ['第一版', '选型']);
    marks.clear();
    await t.pumpAndSettle();
    expect(painted('#94 · 已经等了 2 小时'), findsNothing);
  });

  test('shared memory: prompt context', () {
    expect(AgentBrain.compose('Cindy', null, const []), contains('「Cindy」'));
    final context = AgentBrain.compose('Cindy', '喜欢简短回答', ['Kevin：发版吧']);
    expect(context, contains('Agent「Cindy」的语音形态'));
    expect(context, contains('喜欢简短回答'));
    expect(context, contains('Kevin：发版吧'));
    // The summary of a session is covered in agent_session_summary_test.dart.
  });

  test('voice keys are found inside scanned text', () {
    const key = 'AIzaSyA1234567890abcdefghijklmnopqrstu';
    expect(AgentVoiceKey.parse(key), key);
    expect(AgentVoiceKey.parse('GEMINI_API_KEY=$key\n'), key);
    expect(AgentVoiceKey.parse('https://example.com/a b'), isNull);
    expect(AgentVoiceKey.parse(null), isNull);
  });

  test('intents match the longest channel name and the back words', () {
    final channels = [
      RaftChannel({'id': 'a', 'name': 'raft'}),
      RaftChannel({'id': 'b', 'name': 'raft-flutter'}),
    ];
    expect(
      (parseAgentIntent(
        'raft-flutter 怎么样',
        channels,
      ) as AgentOpenChannel).channel.id,
      'b',
    );
    expect(parseAgentIntent('返回', channels), isA<AgentBack>());
    expect(parseAgentIntent('回到提醒', channels), isA<AgentHome>());
    expect(parseAgentIntent('看看任务', channels), isA<AgentTasks>());
  });
}
