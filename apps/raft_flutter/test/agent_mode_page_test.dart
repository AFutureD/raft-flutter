import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
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
  Future<List<AgentAttentionItem>> attention() async => [
    AgentAttentionItem(
      priority: AgentPriority.decision,
      weight: 5,
      title: 'Personal Agent 第一版选型',
      detail: '#94 等你验收 · Cindy',
      chips: const ['等了 3 小时'],
      hot: true,
      at: _now,
      channelId: 'c1',
    ),
    AgentAttentionItem(
      priority: AgentPriority.blocked,
      weight: 3,
      title: 'iOS 搜索后无法返回',
      at: _now,
    ),
  ];

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
        expect(find.text('Personal Agent 第一版选型'), findsOneWidget);

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

        // A priority card opens its channel as a new layer.
        await t.tap(find.text('Personal Agent 第一版选型'));
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
    expect(find.text('按住说话 · 点一下实时对话'), findsOneWidget);
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

  testWidgets('a spotlit item lifts above the page and goes back', (t) async {
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
                    child: AgentPriorityCard(
                      priority: AgentPriority.decision,
                      title: 'Item $n',
                      weight: n,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Item 2'), findsOneWidget);
    spotlight.focus('layer#2');
    await t.pumpAndSettle();
    // The lifted copy floats above the page; its place stays reserved.
    expect(find.text('Item 2'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('agent-spotlight-scrim')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('agent-spotlight-scrim')));
    await t.pumpAndSettle();
    expect(spotlight.focused, isNull);
    expect(find.text('Item 2'), findsOneWidget);
    // Switching items flies the first back before lifting the next.
    spotlight.focus('layer#1');
    await t.pumpAndSettle();
    spotlight.focus('layer#3');
    await t.pumpAndSettle();
    expect(find.text('Item 3'), findsNWidgets(2));
    expect(find.text('Item 1'), findsOneWidget);
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
