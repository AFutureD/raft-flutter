import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_attention.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
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
    _decision(
      't1',
      '甲方案：Cardinal 完成了「项目设定」，等你验收',
      score: 30,
      hours: 24,
      waiters: const ['Huanan', 'Cardinal'],
      reason: '2 人在等',
    ),
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
    AgentScriptedModel? model,
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentModePage(controller: w, data: data, model: model),
      ),
    );
    await t.pumpAndSettle();
  }

  /// Types [text] to the agent, as the person would say it.
  Future<void> say(WidgetTester t, String text) async {
    if (find.byKey(const ValueKey('agent-input')).evaluate().isEmpty) {
      await t.tap(find.byKey(const ValueKey('agent-keyboard')));
      await t.pumpAndSettle();
    }
    await t.enterText(find.byKey(const ValueKey('agent-input')), text);
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pumpAndSettle();
  }

  Finder card(String id) => find.byKey(ValueKey('attention-card-$id'));

  Finder countOf(String kind, String n) => find.descendant(
    of: find.byKey(ValueKey('attention-count-$kind')),
    matching: find.text(n),
  );

  group('phone', () {
    testWidgets('header: two counts and the most urgent line, nothing else', (
      t,
    ) async {
      await open(t, _Data(w, _three()));
      expect(countOf('decision', '3'), findsOneWidget);
      expect(countOf('blocked', '1'), findsOneWidget);
      expect(find.text('件等你决定'), findsOneWidget);
      expect(find.text('件卡住了'), findsOneWidget);
      // The most urgent item gets its own line.
      expect(find.text('最急'), findsOneWidget);
      expect(find.textContaining('也在等你'), findsWidgets);
      // The scope note, the side labels and the mention badge are gone.
      expect(find.text(AgentAttention.scopeNote), findsNothing);
      expect(find.text('按紧急程度'), findsNothing);
      expect(find.text('你的事'), findsNothing);
      expect(find.text('超过 4 小时没动'), findsNothing);
      expect(
        find.byKey(const ValueKey('attention-count-mention')),
        findsNothing,
      );
      expect(find.text('处点名你'), findsNothing);
      // Mentions are one quiet row.
      expect(find.text('另有 1 处点名你'), findsOneWidget);
      expect(card('m1'), findsNothing);
      // The old query-cap sentence is gone.
      expect(find.textContaining('50 件'), findsNothing);
    });

    testWidgets('a card is a rank, one sentence and one meta line', (t) async {
      await open(t, _Data(w, _three()));
      expect(find.text('甲方案：Cardinal 完成了「项目设定」，等你验收'), findsOneWidget);
      expect(find.text('#raft-flutter · 等了 24 小时'), findsOneWidget);
      expect(find.text('#raft-flutter · 等了 11 小时'), findsOneWidget);
      // Rank numbers run over all sections.
      for (final (id, n) in [('t1', '1'), ('t2', '2'), ('t3', '3')]) {
        expect(
          find.descendant(of: card(id), matching: find.text(n)),
          findsOneWidget,
        );
      }
      // Nothing else on the card: no reason sticker, quote, ask box, where or
      // who waits, and no buttons.
      expect(find.text('2 人在等'), findsNothing);
      expect(find.text('你派的任务'), findsNothing);
      expect(find.textContaining('进展'), findsNothing);
      expect(find.text('要你做'), findsNothing);
      expect(find.text('验收「甲方」'), findsNothing);
      expect(find.text('「t1 讨论」'), findsNothing);
      expect(find.text('Huanan、Cardinal 在等你'), findsNothing);
      for (final k in ['approve', 'open', 'later']) {
        expect(find.byKey(ValueKey('attention-$k-t1')), findsNothing);
      }
      expect(find.text('通过'), findsNothing);
      expect(find.text('打开讨论'), findsNothing);
      expect(find.text('稍后'), findsNothing);
      // No section dividers on the phone: the header already counts.
      expect(find.text('等你决定'), findsNothing);
      expect(find.text('卡住了'), findsNothing);
      expect(find.text('点名你'), findsNothing);
    });

    testWidgets('at most three cards; the rest is one row', (t) async {
      await open(t, _Data(w, _three()), size: const Size(430, 1100));
      expect(card('t1'), findsOneWidget);
      expect(card('t2'), findsOneWidget);
      expect(card('t3'), findsOneWidget);
      expect(card('b1'), findsNothing);
      expect(find.byType(AgentAttentionCard), findsNWidgets(3));
      expect(find.text('还有 1 件，说“下一批”看看'), findsOneWidget);
      // Cards stay short for their type size, and the first is the biggest.
      final heights = [
        for (final id in ['t1', 't2', 't3']) t.getRect(card(id)).height,
      ];
      expect(heights[0], greaterThan(heights[1]));
      expect(heights[0], lessThanOrEqualTo(170));
      expect(heights[1], lessThanOrEqualTo(140));
      expect(heights[2], lessThanOrEqualTo(140));
      expect(t.takeException(), isNull);
    });

    testWidgets('not more than three even with many items', (t) async {
      final many = AgentAttention(
        items: [
          for (var i = 1; i <= 8; i++)
            _decision('t$i', '第$i号方案：等你验收', score: 100.0 - i),
        ],
      );
      await open(t, _Data(w, many), size: const Size(430, 1100));
      expect(find.byType(AgentAttentionCard), findsNWidgets(3));
      expect(find.text('还有 5 件，说“下一批”看看'), findsOneWidget);
    });

    testWidgets('three or fewer items: no more-row', (t) async {
      final few = AgentAttention(
        items: [_decision('t1', '甲方案：等你验收'), _decision('t2', '乙方案：等你验收')],
      );
      await open(t, _Data(w, few), size: const Size(390, 844));
      expect(find.byKey(const ValueKey('attention-more')), findsNothing);
    });

    testWidgets('the next batch by tap and by voice, wrapping at the end', (
      t,
    ) async {
      await open(t, _Data(w, _three()), model: const AgentScriptedModel());
      await t.tap(find.byKey(const ValueKey('attention-more')));
      await t.pumpAndSettle();
      expect(card('t1'), findsNothing);
      expect(card('b1'), findsOneWidget);
      // Ranks stay what they are over all items.
      expect(
        find.descendant(of: card('b1'), matching: find.text('4')),
        findsOneWidget,
      );
      expect(find.text('#raft-flutter · 5 小时没动'), findsOneWidget);
      expect(find.text('已经是最后一批，说“下一批”回到最前'), findsOneWidget);
      // The first of a later batch is not the big one.
      await say(t, '下一批');
      expect(card('t1'), findsOneWidget);
      expect(card('b1'), findsNothing);
      expect(find.textContaining('现在是第 1 到 3 条'), findsWidgets);
    });

    testWidgets(
      'type is made for arm\'s length: nothing under 16, big counts',
      (t) async {
        await open(t, _Data(w, _three()), size: const Size(430, 1100));
        // Open the team row too so its lines count.
        await t.tap(find.byKey(const ValueKey('attention-team')));
        await t.pumpAndSettle();
        double? size(InlineSpan span, double? inherited) {
          final own = span.style?.fontSize ?? inherited;
          return own;
        }

        final small = <String>[];
        final view = find.byType(AgentAttentionView);
        for (final rich in t.widgetList<RichText>(
          find.descendant(of: view, matching: find.byType(RichText)),
        )) {
          void visit(InlineSpan span, double? inherited) {
            final own = size(span, inherited);
            if (span is TextSpan) {
              final text = span.text ?? '';
              if (text.trim().isNotEmpty && (own == null || own < 16)) {
                small.add('$text @ $own');
              }
              for (final c in span.children ?? const <InlineSpan>[]) {
                visit(c, own);
              }
            }
          }

          visit(rich.text, null);
        }
        expect(small, isEmpty);

        Text count(String kind, String n) => t.widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('attention-count-$kind')),
            matching: find.text(n),
          ),
        );
        expect(
          count('decision', '3').style!.fontSize,
          greaterThanOrEqualTo(34),
        );
        expect(count('blocked', '1').style!.fontSize, greaterThanOrEqualTo(34));
        Text inCard(String id, String text) => t.widget<Text>(
          find.descendant(of: card(id), matching: find.text(text)),
        );
        // Headline 26+ bold, meta 18+; the lead card is larger still.
        final lead = inCard('t1', '甲方案：Cardinal 完成了「项目设定」，等你验收');
        final other = inCard('t2', '乙方案：Cindy 完成了「改名」，等你验收');
        expect(other.style!.fontSize, greaterThanOrEqualTo(26));
        expect(other.style!.fontWeight, FontWeight.w900);
        expect(lead.style!.fontSize, greaterThan(other.style!.fontSize!));
        expect(
          inCard('t2', '#raft-flutter · 等了 11 小时').style!.fontSize,
          greaterThanOrEqualTo(18),
        );
      },
    );

    testWidgets('a long headline keeps to two lines with an ellipsis', (
      t,
    ) async {
      final long = '很长的一句话：${'谁做了什么要你做什么' * 20}';
      final data = _Data(
        w,
        AgentAttention(
          items: [_decision('t1', long), _decision('t2', '乙方案：等你验收')],
        ),
      );
      await open(t, data, size: const Size(390, 844));
      final headline = t.widget<Text>(
        find.descendant(of: card('t1'), matching: find.text(long)),
      );
      expect(headline.maxLines, 2);
      expect(headline.overflow, TextOverflow.ellipsis);
      expect(t.getRect(card('t1')).height, lessThanOrEqualTo(170));
      final meta = t.widget<Text>(
        find.descendant(
          of: card('t1'),
          matching: find.text('#raft-flutter · 等了 3 小时'),
        ),
      );
      expect(meta.maxLines, 1);
    });

    testWidgets(
      'the phone pieces grow with system type instead of overflowing',
      (t) async {
        t.view.physicalSize = const Size(360, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final item = _decision('t1', '很长的一句话：${'谁做了什么要你做什么' * 10}');
        for (final scale in [1.0, 2.0, 3.0]) {
          await t.pumpWidget(
            MaterialApp(
              theme: raftTheme(RaftFamily.brutal),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: ListView(
                  children: [
                    const AgentAttentionSummary(
                      decision: '50+',
                      blocked: '12',
                      mention: null,
                      urgent: '甲方案：Cardinal 完成了「项目设定」，等你验收，已经等了很久很久',
                      large: true,
                    ),
                    AgentAttentionCard(data: agentCardFor(item, 1), lead: true),
                    AgentAttentionCard(data: agentCardFor(item, 2)),
                    const AgentMoreRow(text: '还有 12 件，说“下一批”看看'),
                    const AgentMentionRow(count: '3'),
                    AgentTeamRow(
                      compact: true,
                      count: '50+',
                      expanded: false,
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ),
          );
          expect(t.takeException(), isNull, reason: 'scale $scale');
        }
      },
    );

    testWidgets('a mention is not listed; its row opens it', (t) async {
      await open(t, _Data(w, _three()));
      await t.tap(find.byKey(const ValueKey('attention-mentions')));
      await t.pumpAndSettle();
      expect(find.text('第 2 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail:m1')), findsOneWidget);
      // A question to answer, not a task: no 通过, a reply button.
      expect(find.byKey(const ValueKey('attention-approve-m1')), findsNothing);
      expect(find.text('回复 Cody'), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-later-m1')), findsOneWidget);
    });

    testWidgets('tapping a card opens its detail as a new layer', (t) async {
      await open(t, _Data(w, _three()));
      await t.tap(card('t1'));
      await t.pumpAndSettle();
      expect(find.text('第 2 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail:t1')), findsOneWidget);
      // The task with its latest progress, the two before it as quotes.
      expect(find.text('甲方案：Cardinal 完成了「项目设定」，等你验收'), findsWidgets);
      expect(find.text('等验收'), findsOneWidget);
      expect(find.text('Cindy · 今天 07:20  t1 进展三'), findsOneWidget);
      expect(find.text('之前的进展'), findsOneWidget);
      expect(find.text('t1 进展一'), findsOneWidget);
      expect(find.text('t1 进展二'), findsOneWidget);
      expect(find.text('验收「甲方」'), findsOneWidget);
      // The actions live here.
      expect(
        find.byKey(const ValueKey('attention-approve-t1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('attention-open-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-later-t1')), findsOneWidget);
    });

    testWidgets('a tap and the voice request open the same layer', (t) async {
      // The layer id (its key) and everything the layer says.
      Future<String> shown() async {
        final view = t.widget<AgentSurfaceView>(find.byType(AgentSurfaceView));
        return '${view.focusPrefix} ${agentSurfaceFrame(view.spec)}';
      }

      await open(t, _Data(w, _three()), model: const AgentScriptedModel());
      await t.tap(card('t2'));
      await t.pumpAndSettle();
      final byTap = await shown();
      await say(t, '返回');
      expect(find.text('第 1 层'), findsOneWidget);

      await say(t, '展开第二条');
      expect(find.text('第 2 层'), findsOneWidget);
      expect(await shown(), byTap);
      await say(t, '返回');

      // Digits, other words, and "this one" (the most urgent).
      await say(t, '讲讲第 3 条');
      expect(find.byKey(const ValueKey('detail:t3')), findsOneWidget);
      await say(t, '返回');
      await say(t, '详细说说这个');
      expect(find.byKey(const ValueKey('detail:t1')), findsOneWidget);
      // The model then says one or two sentences, from what it was given.
      expect(find.textContaining('Cindy 最后说：「t1 进展三」'), findsWidgets);
    });

    testWidgets('expanding another card replaces the open detail', (t) async {
      await open(t, _Data(w, _three()), model: const AgentScriptedModel());
      await say(t, '展开第一条');
      await say(t, '展开第 4 条');
      expect(find.text('第 2 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail:b1')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail:t1')), findsNothing);
      // A blocked task has nothing to approve.
      expect(find.byKey(const ValueKey('attention-approve-b1')), findsNothing);
      expect(find.byKey(const ValueKey('attention-open-b1')), findsOneWidget);
    });

    testWidgets('expand_item returns grounded facts and refuses a bad number', (
      t,
    ) async {
      final results = <Map<String, Object?>>[];
      await open(t, _Data(w, _three()), model: _Calls(results));
      await say(t, 'x');
      final ok = results[0];
      expect(ok['ok'], true);
      final item = (ok['item'] as Map).cast<String, Object?>();
      expect(item['index'], 2);
      expect(item['headline'], '乙方案：Cindy 完成了「改名」，等你验收');
      expect(item['ask'], '验收「乙方」');
      expect(item['wait'], '等了 11 小时');
      expect(item['channel'], 'raft-flutter');
      expect(item['canApprove'], true);
      expect((item['progress'] as List).map((p) => (p as Map)['text']), [
        't2 进展一',
        't2 进展二',
        't2 进展三',
      ]);

      final bad = results[1];
      expect(bad['error'], contains('没有第 9 条'));
      expect(bad['error'], contains('5'));
      // "this one" without a number: the most urgent, which replaces the
      // detail of the second.
      expect((results[2]['item'] as Map)['index'], 1);
      expect(find.byKey(const ValueKey('detail:t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail:t2')), findsNothing);
      expect(find.text('第 2 层'), findsOneWidget);
    });

    testWidgets('the detail actions: 通过 asks, 稍后 hides, 打开讨论 opens', (t) async {
      await open(t, _Data(w, _three()));
      client.posts.clear();
      await t.tap(card('t2'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-approve-t2')));
      await t.pumpAndSettle();
      expect(client.posts, isEmpty);
      await t.tap(find.byKey(const ValueKey('attention-approve-confirm')));
      await t.pumpAndSettle();
      expect(client.posts, ['PATCH /tasks/t2/status']);
      // Done: back on the list, the card gone and recounted.
      expect(find.text('第 1 层'), findsOneWidget);
      expect(card('t2'), findsNothing);
      expect(countOf('decision', '2'), findsOneWidget);

      await t.tap(card('t3'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-later-t3')));
      await t.pumpAndSettle();
      expect(find.text('第 1 层'), findsOneWidget);
      expect(card('t3'), findsNothing);
      expect(countOf('decision', '1'), findsOneWidget);

      await t.tap(card('t1'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-open-t1')));
      await t.pumpAndSettle();
      expect(find.text('第 3 层'), findsOneWidget);
      expect(find.text('# raft-flutter'), findsOneWidget);
    });

    testWidgets('spotlight and marks work on the detail layer', (t) async {
      await open(t, _Data(w, _three()));
      await t.tap(card('t1'));
      await t.pumpAndSettle();
      final ids = [
        for (final f in t.widgetList<AgentFocusable>(
          find.byType(AgentFocusable),
        ))
          f.id,
      ];
      // The task card, then the two earlier quotes; the actions are not items.
      expect(ids, ['detail:t1#1', 'detail:t1#2', 'detail:t1#3']);
    });

    testWidgets('通过 asks first; nothing is written until confirmed', (t) async {
      await open(t, _Data(w, _three()));
      client.posts.clear();
      await t.tap(card('t2'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-approve-t2')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('attention-approve-confirm')),
        findsOneWidget,
      );
      expect(client.posts, isEmpty);

      await t.tap(find.byKey(const ValueKey('attention-approve-cancel')));
      await t.pumpAndSettle();
      expect(client.posts, isEmpty);
      // Still on the detail.
      expect(find.byKey(const ValueKey('detail:t2')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('attention-approve-t2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-approve-confirm')));
      await t.pumpAndSettle();
      expect(client.posts, ['PATCH /tasks/t2/status']);
      expect(client.bodies.last, {'status': 'done'});
      // Done: the card leaves and the count follows.
      expect(card('t2'), findsNothing);
      expect(countOf('decision', '2'), findsOneWidget);
    });

    testWidgets('a failed write keeps the card and says why', (t) async {
      client.responses.clear();
      final failing = _FailingClient()..user = RaftRecord({'id': 'kevin'});
      failing.selectServer('s1');
      final fw = WorkspaceController(failing)
        ..server = RaftRecord({'id': 's1', 'role': 'owner'})
        ..channels = [
          RaftChannel({'id': 'c1', 'name': 'raft-flutter'}),
        ];
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
      await t.tap(card('t1'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-approve-t1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-approve-confirm')));
      await t.pumpAndSettle();
      // The detail stays; nothing was written.
      expect(find.byKey(const ValueKey('detail:t1')), findsOneWidget);
      expect(find.textContaining('没能通过'), findsWidgets);
    });

    testWidgets('稍后 hides the card for the session and recounts', (t) async {
      final data = _Data(w, _three());
      await open(t, data);
      await t.tap(card('t1'));
      await t.pumpAndSettle();
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
      await t.tap(card('t3'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-open-t3')));
      await t.pumpAndSettle();
      expect(find.text('第 3 层'), findsOneWidget);
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
      expect(
        find.byKey(const ValueKey('attention-count-decision')),
        findsNothing,
      );
    });

    testWidgets('revisit: the last accepted result paints on the first frame', (
      t,
    ) async {
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

    testWidgets('first visit shows loading once, never an empty verdict', (
      t,
    ) async {
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

    testWidgets('master list on the left, selected detail on the right', (
      t,
    ) async {
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
      expect(
        find.byKey(const ValueKey('attention-approve-confirm')),
        findsOneWidget,
      );
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
      expect(
        find.byKey(const ValueKey('attention-approve-t1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('attention-open-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-later-t1')), findsOneWidget);
      expect(find.text('↑↓'), findsOneWidget);
      expect(find.text('切换'), findsOneWidget);
    });
  });

  group('tv', () {
    testWidgets('top three only, big type, no buttons, caption strip', (
      t,
    ) async {
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

/// Calls `expand_item` three ways and keeps what the tool answered.
class _Calls extends AgentScriptedModel {
  const _Calls(this.results);
  final List<Map<String, Object?>> results;

  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String) say,
  ) async {
    results
      ..add(await call('expand_item', {'index': 2}))
      ..add(await call('expand_item', {'index': 9}))
      ..add(await call('expand_item', const {}));
    return true;
  }
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
