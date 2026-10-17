import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_service.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_cards.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_tools.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'agent_orb_briefing_service_test.dart'
    show channelRow, dmRow, msg, threadRow;
import 'support/agent_capability_world.dart';

/// The briefing cards (design frames 05 and 06) at phone size, brutal theme,
/// and the `get_briefing` tool that hands them to the orb's immersive layer.

const _scales = [1.0, 1.3, 3.1];

OrbBriefItem needsYou({String title = 'Cody 在等你批准重构第 10 步'}) => OrbBriefItem(
  id: 'thread:th1',
  title: title,
  who: 'Cody',
  whoKind: 'agent',
  where: '#raft-flutter',
  since: '已等 20 分钟',
  ask: '批准',
  suggestedAction: const OrbSuggestedAction(
    label: '回复：批准',
    kind: 'reply',
    text: '批准',
  ),
  link: '/s/s1/channel/ca?thread=ca%3Ap1',
  sourceIds: const ['m1'],
  reason: OrbReason.awaitingApproval,
  why: '点名你',
);

OrbBriefItem progress(String who, String title, {String kind = 'agent'}) =>
    OrbBriefItem(
      id: 'p:$who',
      title: title,
      who: who,
      whoKind: kind,
      where: '#raft-flutter',
      since: '8 分钟前',
      link: '/s/s1/channel/ca',
      sourceIds: const ['m2'],
      reason: OrbReason.progress,
      why: '进展',
    );

OrbBriefing briefing({
  List<OrbBriefItem>? needs,
  List<OrbBriefItem>? prog,
  int routine = 5,
  int waitingTasks = 0,
}) => OrbBriefing(
  scope: OrbBriefScope.activity,
  overview: '3 条新动态，1 件需要你处理',
  needsYou: needs ?? [needsYou()],
  progress:
      prog ??
      [
        progress('CodexMac', 'Mac 验证通过'),
        progress('Grok', 'task #159 在修'),
        progress('系统', 'Cody 把 #136 交审', kind: 'system'),
      ],
  routineCount: routine,
  waitingTasks: waitingTasks,
);

void main() {
  late List<OrbBriefItem> opened;
  late List<(OrbBriefItem, OrbSuggestedAction)> actions;

  setUp(() {
    opened = [];
    actions = [];
  });

  Future<void> mount(
    WidgetTester t, {
    required Widget Function(BuildContext) home,
    double scale = 1.0,
  }) async {
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    t.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    t.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(() {
      t.view.reset();
      t.view.resetPadding();
      t.view.resetViewPadding();
    });
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: Builder(builder: home)),
      ),
    );
  }

  Future<void> show(WidgetTester t, OrbBriefing b, {double scale = 1.0}) async {
    await mount(
      t,
      scale: scale,
      home: (_) => SingleChildScrollView(
        child: OrbBriefingCards(
          briefing: b,
          onOpen: opened.add,
          onAction: (i, a) => actions.add((i, a)),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  group('the cards', () {
    testWidgets('renders the overview, the needs-you card, the progress rows '
        'and the routine count', (t) async {
      await show(t, briefing());
      expect(find.text('3 条新动态，1 件需要你处理'), findsOneWidget);
      expect(find.text('需要你'), findsOneWidget);
      expect(find.text('1'), findsOneWidget, reason: 'the count badge');
      expect(find.text('#raft-flutter · 点名你'), findsOneWidget);
      expect(find.text('Cody 在等你批准重构第 10 步'), findsOneWidget);
      expect(find.text('已等 20 分钟'), findsOneWidget);
      expect(find.text('回复：批准'), findsOneWidget);
      expect(find.text('进展'), findsOneWidget);
      expect(find.text('CodexMac：Mac 验证通过'), findsOneWidget);
      expect(find.text('Grok：task #159 在修'), findsOneWidget);
      expect(find.text('系统：Cody 把 #136 交审'), findsOneWidget);
      expect(find.text('其余 5 条是常规进度'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('tapping a needs-you card opens its conversation', (t) async {
      await show(t, briefing());
      await t.tap(find.text('Cody 在等你批准重构第 10 步'));
      await t.pumpAndSettle();
      expect(opened.map((i) => i.id), ['thread:th1']);
      expect(actions, isEmpty);
    });

    testWidgets('tapping a progress row opens its conversation', (t) async {
      await show(t, briefing());
      await t.tap(find.text('Grok：task #159 在修'));
      await t.pumpAndSettle();
      expect(opened.map((i) => i.who), ['Grok']);
    });

    testWidgets('the suggested action chip calls the action, not the card', (
      t,
    ) async {
      await show(t, briefing());
      await t.tap(find.text('回复：批准'));
      await t.pumpAndSettle();
      expect(actions, hasLength(1));
      expect(actions.single.$1.id, 'thread:th1');
      expect(actions.single.$2.kind, 'reply');
      expect(actions.single.$2.text, '批准');
      expect(opened, isEmpty);
    });

    testWidgets('an empty briefing is just its overview', (t) async {
      await show(
        t,
        const OrbBriefing(
          scope: OrbBriefScope.activity,
          overview: '没有新的动态',
          needsYou: [],
          progress: [],
          routineCount: 0,
        ),
      );
      expect(find.text('没有新的动态'), findsOneWidget);
      expect(find.text('需要你'), findsNothing);
      expect(find.text('进展'), findsNothing);
    });

    for (final scale in _scales) {
      testWidgets('no overflow at text scale $scale, with long text and '
          'several items', (t) async {
        final long = 'Cody 在等你批准重构第 10 步的方案并且希望今天之内给出答复' * 2;
        await show(
          t,
          briefing(
            needs: [
              needsYou(title: long),
              needsYou(title: '短').copyWith(title: '短'),
            ],
            prog: [
              progress('CodexMac', long),
              progress('Grok', 'task #159 在修'),
            ],
          ),
          scale: scale,
        );
        expect(t.takeException(), isNull);
        // Scroll to the end: the routine line is reachable.
        await t.drag(find.byType(SingleChildScrollView), const Offset(0, -800));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(find.text('其余 5 条是常规进度'), findsOneWidget);
      });
    }
  });

  group('get_briefing', () {
    late ActivityClient client;
    late CapabilityWorld w;

    setUp(() {
      AgentModeData.clearSession();
      final world = capabilityWorld();
      client = world.$1;
      w = world.$2;
      w.ledger.switchServer('s1');
      addTearDown(w.dispose);
      w.routes['/channels/inbox'] = (_) => {
        'items': [
          threadRow(),
          channelRow('ch-general', 'general', msgId: 'cm2'),
          dmRow(),
        ],
      };
      w.routes['/messages/context/p1'] = (_) => {
        'messages': [msg('p1', 9, '重构第 10 步：拆分 activity 数据层', minutes: 300)],
      };
      w.routes['/tasks/server'] = (_) => {'tasks': []};
      client.responses['GET /messages/channel/th1'] = {
        'messages': [
          msg(
            'th1-m2',
            12,
            '@Kevin 第 10 步的方案已经写好，等你批准就开工。',
            mentions: ['kevin'],
          ),
        ],
      };
      client.responses['GET /messages/channel/ch-general'] = {
        'messages': [
          msg(
            'cm2',
            5,
            'Mac 验证通过，截图已经放进 PR 描述。',
            from: 'CodexMac',
            fromId: 'codexmac',
            minutes: 8,
          ),
        ],
      };
      client.responses['GET /messages/channel/dm-1'] = {
        'messages': [
          msg(
            'dm-m1',
            3,
            '周五的设计评审你能参加吗？',
            from: 'Ada',
            fromId: 'ada',
            type: 'user',
            minutes: 47,
          ),
        ],
      };
    });

    testWidgets('declares itself in Chinese with scope, show and full', (
      t,
    ) async {
      final tool = orbBriefingTools().single;
      expect(tool.name, 'get_briefing');
      final d = tool.declaration;
      expect(d['description'], contains('overview'));
      expect(d['description'], contains('常规'));
      final props = (d['parameters'] as Map)['properties'] as Map;
      expect(props.keys, containsAll(['scope', 'show', 'full']));
    });

    testWidgets('returns the briefing JSON and, with show, hands the cards to '
        'the layer; the item link is the controller\'s to open', (t) async {
      final shownBriefings = <OrbBriefing>[];
      late BuildContext navigator;
      await mount(
        t,
        home: (c) {
          navigator = c;
          return const SizedBox.shrink();
        },
      );
      final tool = orbBriefingTools(
        showBriefing: (b, ctx) => shownBriefings.add(b),
        serviceFor: (w) => OrbBriefingService(w, now: () => worldNow),
      ).single;
      final operating = ValueNotifier(false);
      addTearDown(operating.dispose);
      final ctx = OrbToolContext(
        workspace: w,
        navigatorContext: navigator,
        operating: operating,
      );

      final quiet = (await t.runAsync(
        () => tool.handler({'scope': 'activity'}, ctx),
      ))!;
      expect(quiet['shown'], false);
      expect(shownBriefings, isEmpty);

      final out = (await t.runAsync(
        () => tool.handler({
          'scope': 'activity',
          'show': true,
          'full': true,
        }, ctx),
      ))!;
      expect(out['shown'], true);
      expect(out['overview'], '3 条新动态，2 件需要你处理');
      final needs = out['needsYou']! as List;
      expect(needs, hasLength(2));
      final cody = needs.cast<Map>().firstWhere((i) => i['who'] == 'Cody');
      expect(cody['title'], contains('批准'));
      expect(cody['since'], '已等 20 分钟');
      expect(cody['link'], contains('/channel/ch-general'));
      expect((out['progress']! as List).single['who'], 'CodexMac');
      expect(out['routineCount'], 0);

      expect(shownBriefings.single.overview, out['overview']);
      expect(shownBriefings.single.needsYou, hasLength(2));
    });

    testWidgets('without a layer to show them in, show is not claimed', (
      t,
    ) async {
      late BuildContext navigator;
      await mount(
        t,
        home: (c) {
          navigator = c;
          return const SizedBox.shrink();
        },
      );
      final operating = ValueNotifier(false);
      addTearDown(operating.dispose);
      final ctx = OrbToolContext(
        workspace: w,
        navigatorContext: navigator,
        operating: operating,
      );
      final out = (await t.runAsync(
        () => orbBriefingTools(
          serviceFor: (w) => OrbBriefingService(w, now: () => worldNow),
        ).single.handler({'scope': 'activity', 'show': true}, ctx),
      ))!;
      expect(out['shown'], false);
    });

    testWidgets('a named conversation that does not exist is an error, not '
        'a throw', (t) async {
      late BuildContext navigator;
      await mount(
        t,
        home: (c) {
          navigator = c;
          return const SizedBox.shrink();
        },
      );
      final operating = ValueNotifier(false);
      addTearDown(operating.dispose);
      final ctx = OrbToolContext(
        workspace: w,
        navigatorContext: navigator,
        operating: operating,
      );
      final out = (await t.runAsync(
        () => orbBriefingTools().single.handler({'scope': '不存在的频道'}, ctx),
      ))!;
      expect(out['error'], isNotNull);
    });
  });
}
