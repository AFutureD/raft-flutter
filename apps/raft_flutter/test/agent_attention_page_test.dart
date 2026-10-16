import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_tv.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Fictional people, channels and tasks.
final _now = DateTime.utc(2026, 10, 15, 12);

AgentAttentionItem _decision(
  String id,
  String headline, {
  int hours = 3,
  double score = 10,
  bool approve = true,
  List<String> waiters = const ['Cindy'],
  String reason = '你派的任务',
}) => AgentAttentionItem(
  id: id,
  taskId: id,
  taskNumber: 1,
  priority: AgentPriority.decision,
  headline: headline,
  ask: '验收',
  askLine: '验收「${headline.substring(0, 2)}」',
  action: approve ? AgentAction.approve : AgentAction.open,
  canApprove: approve,
  reason: reason,
  waitValue: hours,
  waitUnit: '小时',
  at: _now.subtract(Duration(hours: hours)),
  score: score,
  waiters: waiters,
  channelId: 'c1',
  channelName: 'raft-flutter',
  threadTitle: '$id 讨论',
  progress: [
    AgentProgressLine(who: 'Cindy', time: '今天 07:02', text: '$id 进展一'),
    AgentProgressLine(who: 'Cindy', time: '今天 07:10', text: '$id 进展二'),
    AgentProgressLine(who: 'Cindy', time: '今天 07:20', text: '$id 进展三'),
  ],
);

AgentAttentionItem _blocked() => AgentAttentionItem(
  id: 'b1',
  taskId: 'b1',
  priority: AgentPriority.blocked,
  headline: 'Grok 的「合并检查」5 小时没动，卡住了',
  ask: '解除阻塞',
  askLine: '解除阻塞',
  action: AgentAction.open,
  reason: '卡住了',
  waitValue: 5,
  waitUnit: '小时',
  idle: true,
  at: _now.subtract(const Duration(hours: 5)),
  score: 5,
  waiters: const ['Grok'],
  channelId: 'c1',
  channelName: 'raft-flutter',
);

AgentAttentionItem _mention() => AgentAttentionItem(
  id: 'm1',
  priority: AgentPriority.mention,
  headline: 'Cody 在 M7 检测首片里 @ 了你：继续跑全量还是先调阈值？',
  ask: '回答一个问题',
  askLine: '回答一个问题',
  action: AgentAction.reply,
  reason: '点名找你',
  waitValue: 12,
  waitUnit: '分钟',
  at: _now.subtract(const Duration(minutes: 12)),
  score: 1,
  waiters: const ['Cody'],
  channelId: 'c2',
  channelName: 'general',
);

class _Data extends AgentModeData {
  _Data(super.w, this.result) : super(now: () => _now);
  AgentAttention result;
  Completer<AgentAttention>? gate;
  int reads = 0;

  @override
  Future<AgentAttention> attention() {
    reads++;
    return gate?.future ?? Future.value(result);
  }
}

AgentAttention _three() => AgentAttention(
  items: [
    _decision('t1', '甲方案：Cardinal 完成了「项目设定」，等你验收', score: 30,
        hours: 24, waiters: const ['Huanan', 'Cardinal'], reason: '2 人在等'),
    _decision('t2', '乙方案：Cindy 完成了「改名」，等你验收', score: 20, hours: 11),
    _decision('t3', '丙方案：Codex 完成了「运维重构」，等你验收', score: 10),
    _blocked(),
    _mention(),
  ],
  team: const [
    AgentTeamItem(
      id: 'x1',
      headline: 'Ming 完成了「发布说明」',
      channelName: 'Seed',
      who: 'Ming',
    ),
    AgentTeamItem(
      id: 'x2',
      headline: 'Ana 正在写「周报」',
      channelName: 'Seed',
      who: 'Ana',
    ),
  ],
);

void main() {
  late ActivityClient client;
  late WorkspaceController w;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    AgentModeData.clearSession();
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

  Future<void> open(
    WidgetTester t,
    AgentModeData data, {
    Size size = const Size(390, 5000),
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentModePage(controller: w, data: data),
      ),
    );
    await t.pumpAndSettle();
  }

  Finder countOf(String kind, String n) => find.descendant(
    of: find.byKey(ValueKey('attention-count-$kind')),
    matching: find.text(n),
  );

  group('phone', () {
    testWidgets('header counts are real and carry the scope note', (t) async {
      await open(t, _Data(w, _three()));
      expect(countOf('decision', '3'), findsOneWidget);
      expect(countOf('blocked', '1'), findsOneWidget);
      expect(find.text('件等你决定'), findsOneWidget);
      expect(find.text('件卡住了'), findsOneWidget);
      expect(countOf('mention', '1'), findsOneWidget);
      expect(find.text('处点名你'), findsOneWidget);
      expect(find.text(AgentAttention.scopeNote), findsOneWidget);
      expect(find.text('按紧急程度'), findsOneWidget);
      // The most urgent item gets its own line.
      expect(find.text('最急'), findsOneWidget);
      expect(find.textContaining('也在等你'), findsWidgets);
      // The old query-cap sentence is gone.
      expect(find.textContaining('50 件'), findsNothing);
    });

    testWidgets('cards show headline, location, ask, quote and a rank', (t) async {
      await open(t, _Data(w, _three()));
      expect(find.text('甲方案：Cardinal 完成了「项目设定」，等你验收'), findsOneWidget);
      expect(find.text('等了 24 小时'), findsOneWidget);
      expect(find.text('2 人在等'), findsOneWidget);
      expect(find.text('#raft-flutter'), findsWidgets);
      expect(find.text('「t1 讨论」'), findsOneWidget);
      expect(find.text('Huanan、Cardinal 在等你'), findsOneWidget);
      // Grey quote of the latest progress.
      expect(find.textContaining('t1 进展三'), findsOneWidget);
      expect(find.textContaining('t1 进展一'), findsNothing);
      expect(find.text('要你做'), findsWidgets);
      expect(find.text('验收「甲方」'), findsOneWidget);
      // Rank numbers run over all sections.
      for (final (id, n) in [
        ('t1', '1'),
        ('t2', '2'),
        ('t3', '3'),
        ('b1', '4'),
        ('m1', '5'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('attention-card-$id')),
            matching: find.text(n),
          ),
          findsOneWidget,
        );
      }
      expect(find.text('5 小时没动'), findsOneWidget);
      // Section labels.
      expect(find.text('等你决定'), findsOneWidget);
      expect(find.text('卡住了'), findsWidgets);
      expect(find.text('点名你'), findsOneWidget);
    });

    testWidgets('only a decision with a task offers 通过', (t) async {
      await open(t, _Data(w, _three()));
      expect(find.byKey(const ValueKey('attention-approve-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-approve-b1')), findsNothing);
      expect(find.byKey(const ValueKey('attention-approve-m1')), findsNothing);
      expect(find.byKey(const ValueKey('attention-open-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-later-m1')), findsOneWidget);
    });

    testWidgets('通过 asks first; nothing is written until confirmed', (t) async {
      await open(t, _Data(w, _three()));
      client.posts.clear();
      await t.tap(find.byKey(const ValueKey('attention-approve-t2')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-approve-confirm')), findsOneWidget);
      expect(client.posts, isEmpty);

      await t.tap(find.byKey(const ValueKey('attention-approve-cancel')));
      await t.pumpAndSettle();
      expect(client.posts, isEmpty);
      expect(find.byKey(const ValueKey('attention-card-t2')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('attention-approve-t2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-approve-confirm')));
      await t.pumpAndSettle();
      expect(client.posts, ['PATCH /tasks/t2/status']);
      expect(client.bodies.last, {'status': 'done'});
      // Done: the card leaves and the count follows.
      expect(find.byKey(const ValueKey('attention-card-t2')), findsNothing);
      expect(countOf('decision', '2'), findsOneWidget);
    });

    testWidgets('a failed write keeps the card and says why', (t) async {
      client.responses.clear();
      final failing = _FailingClient()..user = RaftRecord({'id': 'kevin'});
      failing.selectServer('s1');
      final fw = WorkspaceController(failing)
        ..server = RaftRecord({'id': 's1', 'role': 'owner'})
        ..channels = [RaftChannel({'id': 'c1', 'name': 'raft-flutter'})];
      addTearDown(() async {
        fw.dispose();
        await failing.dispose();
      });
      t.view.physicalSize = const Size(390, 5000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(controller: fw, data: _Data(fw, _three())),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-approve-t1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-approve-confirm')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-card-t1')), findsOneWidget);
      expect(find.textContaining('没能通过'), findsWidgets);
    });

    testWidgets('稍后 hides the card for the session and recounts', (t) async {
      final data = _Data(w, _three());
      await open(t, data);
      await t.tap(find.byKey(const ValueKey('attention-later-t1')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-card-t1')), findsNothing);
      expect(countOf('decision', '2'), findsOneWidget);
      expect(client.posts.where((p) => p.startsWith('PATCH')), isEmpty);

      // Opening agent mode again keeps it hidden.
      await t.pumpWidget(const SizedBox());
      await open(t, data);
      expect(find.byKey(const ValueKey('attention-card-t1')), findsNothing);
      expect(find.byKey(const ValueKey('attention-card-t2')), findsOneWidget);
    });

    testWidgets('打开讨论 opens the item\'s channel as a layer', (t) async {
      await open(t, _Data(w, _three()));
      await t.tap(find.byKey(const ValueKey('attention-open-t3')));
      await t.pumpAndSettle();
      expect(find.text('第 2 层'), findsOneWidget);
      expect(find.text('# raft-flutter'), findsOneWidget);
    });

    testWidgets('team progress is collapsed and counted', (t) async {
      await open(t, _Data(w, _three()));
      expect(find.text('团队进度 2 件（不需要你）'), findsOneWidget);
      expect(find.text('Ming 完成了「发布说明」'), findsNothing);
      await t.tap(find.byKey(const ValueKey('attention-team')));
      await t.pumpAndSettle();
      expect(find.text('Ming 完成了「发布说明」'), findsOneWidget);
      expect(find.text('Ana 正在写「周报」'), findsOneWidget);
    });

    testWidgets('a capped team count reads 50+', (t) async {
      final capped = AgentAttention(
        items: [_decision('t1', '甲方案：等你验收')],
        team: const [],
        teamCount: 50,
        capped: true,
      );
      await open(t, _Data(w, capped));
      expect(find.text('团队进度 50+ 件（不需要你）'), findsOneWidget);
    });

    testWidgets('nothing waiting says so', (t) async {
      await open(t, _Data(w, const AgentAttention(items: [])));
      expect(find.text('现在没有需要你处理的事'), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-count-decision')), findsNothing);
    });

    testWidgets('revisit: the last accepted result paints on the first frame', (t) async {
      final first = _Data(w, _three());
      await open(t, first);
      await t.pumpWidget(const SizedBox());

      final second = _Data(w, _three())..gate = Completer<AgentAttention>();
      t.view.physicalSize = const Size(390, 5000);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(controller: w, data: second),
        ),
      );
      // One frame, refresh still pending: already the final cards.
      expect(find.text('甲方案：Cardinal 完成了「项目设定」，等你验收'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(second.reads, 1);

      // The silent refresh replaces in place.
      second.gate!.complete(
        AgentAttention(items: [_decision('t9', '新的一条：等你验收')]),
      );
      await t.pumpAndSettle();
      expect(find.text('新的一条：等你验收'), findsOneWidget);
      expect(find.text('甲方案：Cardinal 完成了「项目设定」，等你验收'), findsNothing);
    });

    testWidgets('first visit shows loading once, never an empty verdict', (t) async {
      final data = _Data(w, _three())..gate = Completer<AgentAttention>();
      t.view.physicalSize = const Size(390, 5000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(controller: w, data: data),
        ),
      );
      await t.pump();
      expect(find.text('现在没有需要你处理的事'), findsNothing);
      data.gate!.complete(_three());
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-card-t1')), findsOneWidget);
    });
  });

  group('wide', () {
    const wide = Size(1400, 900);

    testWidgets('master list on the left, selected detail on the right', (t) async {
      await open(t, _Data(w, _three()), size: wide);
      expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
      // The first item is selected; its progress lines (last 3) are shown.
      Finder inDetail(String text) => find.descendant(
        of: find.byKey(const ValueKey('attention-detail')),
        matching: find.textContaining(text),
      );
      expect(inDetail('t1 进展一'), findsOneWidget);
      expect(inDetail('t1 进展三'), findsOneWidget);
      expect(inDetail('甲方案'), findsOneWidget);
      // Rows are compact: headline, no quote, no ask box.
      expect(find.byKey(const ValueKey('attention-row-t2')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-card-t2')), findsNothing);
      expect(find.textContaining('t2 进展三'), findsNothing);

      final list = t.getRect(find.byKey(const ValueKey('attention-row-t1')));
      final detail = t.getRect(find.byKey(const ValueKey('attention-detail')));
      expect(list.width, lessThanOrEqualTo(540));
      expect(detail.width, lessThanOrEqualTo(560));
      expect(detail.left, greaterThan(list.right));
    });

    testWidgets('tapping a row selects it', (t) async {
      await open(t, _Data(w, _three()), size: wide);
      await t.tap(find.byKey(const ValueKey('attention-row-t3')));
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('attention-detail')),
          matching: find.textContaining('t3 进展三'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('t1 进展三'), findsNothing);
    });

    testWidgets('arrows select, S snoozes, Enter asks to approve', (t) async {
      await open(t, _Data(w, _three()), size: wide);
      Finder inDetail(String text) => find.descendant(
        of: find.byKey(const ValueKey('attention-detail')),
        matching: find.textContaining(text),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(inDetail('t2 进展三'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pumpAndSettle();
      expect(inDetail('t2 进展三'), findsOneWidget);

      client.posts.clear();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-approve-confirm')), findsOneWidget);
      expect(client.posts, isEmpty);
      await t.tap(find.byKey(const ValueKey('attention-approve-cancel')));
      await t.pumpAndSettle();

      await t.sendKeyEvent(LogicalKeyboardKey.keyS);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-row-t2')), findsNothing);
      // The next item takes its place in the detail pane.
      expect(inDetail('t3 进展三'), findsOneWidget);
      expect(client.posts, isEmpty);
    });

    testWidgets('detail has the ask box and its three actions', (t) async {
      await open(t, _Data(w, _three()), size: wide);
      expect(find.byKey(const ValueKey('attention-approve-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-open-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-later-t1')), findsOneWidget);
      expect(find.text('↑↓'), findsOneWidget);
      expect(find.text('切换'), findsOneWidget);
    });
  });

  group('tv', () {
    testWidgets('top three only, big type, no buttons, caption strip', (t) async {
      final attention = AgentAttention(
        items: [
          _decision('t1', '甲方案：等你验收', hours: 24),
          _decision('t2', '乙方案：等你验收'),
          _decision('t3', '丙方案：等你验收'),
          _decision('t4', '丁方案：等你验收'),
          _blocked(),
        ],
      );
      final frame = attention.tvFrame(caption: 'Cardinal 那条已经等了 24 小时，先看这个？');
      expect((frame['items'] as List), hasLength(3));
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(body: AgentTvAttention(frame: frame)),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('甲方案：等你验收'), findsOneWidget);
      expect(find.text('乙方案：等你验收'), findsOneWidget);
      expect(find.text('丙方案：等你验收'), findsOneWidget);
      expect(find.text('丁方案：等你验收'), findsNothing);
      expect(find.text('最急'), findsOneWidget);
      expect(find.text('24'), findsOneWidget);
      expect(find.text('在手机上处理'), findsOneWidget);
      expect(find.text('Cardinal 那条已经等了 24 小时，先看这个？'), findsOneWidget);
      expect(find.text('AGENT'), findsOneWidget);
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      // 10-foot type.
      final size = t.getSize(find.text('甲方案：等你验收'));
      expect(size.height, greaterThan(30));
    });

    testWidgets('an empty list says so on the TV too', (t) async {
      final frame = const AgentAttention(items: []).tvFrame(caption: '');
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(body: AgentTvAttention(frame: frame)),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('现在没有需要你处理的事'), findsOneWidget);
    });
  });
}

class _FailingClient extends ActivityClient {
  @override
  Future<dynamic> request(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    bool authorized = true,
    bool retried = false,
    UploadCancellation? cancellation,
    void Function(int, int)? onSendProgress,
    Map<String, dynamic>? headers,
    bool acceptServerExit = false,
    Duration? receiveTimeout,
  }) async {
    if (method == 'PATCH') throw StateError('offline');
    return super.request(method, path, data: data, query: query);
  }
}
