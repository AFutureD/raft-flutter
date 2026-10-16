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
import 'package:raft_flutter/features/agent_mode/capabilities/agent_snooze.dart';
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

  /// A tap on a card makes it the current item (its detail opens under it);
  /// the stage's 展开 goes to the full detail page.
  Future<void> openDetail(WidgetTester t, String id) async {
    await t.tap(card(id));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('hf-stage-expand')));
    await t.pumpAndSettle();
  }

  /// The one scroll of the front layer: its page.
  Finder page() => find.byKey(const ValueKey('hf-page'));
  ScrollableState pageScroll(WidgetTester t) => t.state<ScrollableState>(
    find.descendant(of: page(), matching: find.byType(Scrollable)),
  );

  Finder countOf(String kind, String n) => find.descendant(
    of: find.byKey(ValueKey('attention-count-$kind')),
    matching: find.text(n),
  );

  group('phone', () {
    testWidgets('header: the counts, then one feed', (t) async {
      await open(t, _Data(w, _three()));
      expect(countOf('decision', '3'), findsOneWidget);
      expect(countOf('blocked', '1'), findsOneWidget);
      expect(countOf('mention', '1'), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-count-unread')), findsNothing);
      expect(find.text('件等你决定'), findsOneWidget);
      expect(find.text('件卡住了'), findsOneWidget);
      expect(find.text('处点名你'), findsOneWidget);
      // One label heads all the rows: the feed is not cut into sections by
      // how urgent each thing is, and no row is called the most urgent.
      expect(find.text('最新动态'), findsOneWidget);
      expect(find.text('最急'), findsNothing);
      expect(find.text('等你决定'), findsNothing);
      expect(find.text('点名你'), findsNothing);
      // The scope note and the side labels are gone.
      expect(find.text(AgentAttention.scopeNote), findsNothing);
      expect(find.text(AgentAttentionView.layerMeta), findsNothing);
      expect(card('m1'), findsOneWidget);
      // The old query-cap sentence is gone.
      expect(find.textContaining('50 件'), findsNothing);
    });

    testWidgets(
      'a row is a rank, a meta line, one sentence and what is asked',
      (t) async {
        await open(t, _Data(w, _three()));
        expect(find.text('甲方案：Cardinal 完成了「项目设定」，等你验收'), findsOneWidget);
        // Where and why in the meta, what is asked under the sentence.
        expect(
          find.descendant(
            of: card('t1'),
            matching: find.text('#raft-flutter · 2 人在等'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card('t1'), matching: find.text('验收「甲方」')),
          findsOneWidget,
        );
        // How long: the stat block at the right.
        expect(
          find.descendant(of: card('t1'), matching: find.text('已等')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card('t1'), matching: find.text('24')),
          findsOneWidget,
        );
        // Rank numbers run over all sections.
        for (final (id, n) in [
          ('t1', '1'),
          ('t2', '2'),
          ('t3', '3'),
          ('b1', '4'),
        ]) {
          expect(
            find.descendant(
              of: find.descendant(
                of: card(id),
                matching: find.byKey(const ValueKey('hf-row-bar')),
              ),
              matching: find.text(n),
            ),
            findsOneWidget,
            reason: id,
          );
        }
        // Nothing else on a row: no quote, no who-waits, and no buttons.
        expect(find.textContaining('进展'), findsNothing);
        expect(find.text('Huanan、Cardinal 在等你'), findsNothing);
        for (final k in ['approve', 'open', 'later']) {
          expect(find.byKey(ValueKey('attention-$k-t1')), findsNothing);
        }
        expect(find.text('通过'), findsNothing);
        expect(find.text('打开讨论'), findsNothing);
        expect(find.text('稍后'), findsNothing);
      },
    );

    testWidgets('every row is in the one page: no pager, no paging text', (
      t,
    ) async {
      await open(t, _Data(w, _three()), size: const Size(430, 1100));
      for (final id in ['t1', 't2', 't3', 'b1', 'm1']) {
        expect(card(id), findsOneWidget, reason: id);
      }
      // Five rows and the team row, none behind a pager.
      expect(find.byType(HfRow), findsNWidgets(6));
      expect(find.textContaining('下一批'), findsNothing);
      expect(find.textContaining('/ 5'), findsNothing);
      expect(find.byKey(const ValueKey('attention-more')), findsNothing);
      // Rows stay short for their type size.
      for (final id in ['t1', 't2', 't3', 'b1']) {
        expect(t.getRect(card(id)).height, lessThanOrEqualTo(150), reason: id);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('three rows fit above the voice dock on 412x915', (t) async {
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(controller: w, data: _Data(w, _three())),
        ),
      );
      await t.pumpAndSettle();
      final dock = t.getRect(find.byType(AgentVoiceDock));
      for (final id in ['t1', 't2', 't3']) {
        expect(card(id), findsOneWidget);
        final r = t.getRect(card(id));
        // Every line of the row is on screen, not just its top (worst case:
        // every headline takes two lines).
        expect(
          r.bottom,
          lessThanOrEqualTo(dock.top),
          reason: 'row $id bottom ${r.bottom} vs dock top ${dock.top}',
        );
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('many items: all of them are in the page, which scrolls as '
        'a whole and is the only scroll in the layer', (t) async {
      final many = AgentAttention(
        items: [
          for (var i = 1; i <= 9; i++)
            _decision('t$i', '第$i号方案：等你验收', score: 100.0 - i),
        ],
      );
      await open(t, _Data(w, many), size: const Size(430, 1100));
      for (var i = 1; i <= 9; i++) {
        expect(card('t$i'), findsOneWidget, reason: 't$i');
      }
      expect(page(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AgentAttentionView),
          matching: find.byType(Scrollable),
        ),
        findsOneWidget,
      );
      expect(pageScroll(t).position.maxScrollExtent, greaterThan(0));
      expect(find.textContaining('下一批'), findsNothing);
      expect(find.byKey(const ValueKey('attention-more')), findsNothing);
    });

    testWidgets('a short list has nothing to scroll', (t) async {
      final few = AgentAttention(
        items: [
          _decision('t1', '甲方案：等你验收'),
          _decision('t2', '乙方案：等你验收'),
          _decision('t3', '丙方案：等你验收'),
          _decision('t4', '丁方案：等你验收'),
        ],
      );
      await open(t, _Data(w, few), size: const Size(390, 5000));
      expect(pageScroll(t).position.maxScrollExtent, 0);
    });

    testWidgets('"下一批" by voice scrolls the page on by a screen, and back '
        'to the top after the end', (t) async {
      final many = AgentAttention(
        items: [
          for (var i = 1; i <= 9; i++)
            _decision('t$i', '第$i号方案：等你验收', score: 100.0 - i),
        ],
      );
      await open(
        t,
        _Data(w, many),
        size: const Size(430, 900),
        model: const AgentScriptedModel(),
      );
      final scroll = pageScroll(t);
      expect(scroll.position.pixels, 0);
      await say(t, '下一批');
      expect(scroll.position.pixels, greaterThan(0));
      expect(find.textContaining('往后翻了一屏'), findsWidgets);
      for (var i = 0; i < 6; i++) {
        if (scroll.position.pixels >= scroll.position.maxScrollExtent - 1) {
          break;
        }
        await say(t, '下一批');
      }
      expect(scroll.position.pixels, scroll.position.maxScrollExtent);
      await say(t, '下一批');
      expect(scroll.position.pixels, 0);
      expect(find.textContaining('回到最前面'), findsWidgets);
    });

    testWidgets('"下一批" when everything is on the screen says so', (t) async {
      await open(
        t,
        _Data(w, _three()),
        size: const Size(390, 5000),
        model: const AgentScriptedModel(),
      );
      await say(t, '下一批');
      expect(find.textContaining('已经全部显示在一屏里'), findsWidgets);
    });

    testWidgets(
      'type is made for arm\'s length: nothing under 13, big counts',
      (t) async {
        await open(
          t,
          _Data(
            w,
            AgentAttention(
              items: _three().items.take(4).toList(),
              team: _three().team,
            ),
          ),
          size: const Size(430, 1100),
        );
        // Open the team row too so its lines count.
        await t.tap(find.byKey(const ValueKey('attention-team')));
        await t.pumpAndSettle();
        final small = <String>[];
        final view = find.byType(AgentAttentionView);
        for (final rich in t.widgetList<RichText>(
          find.descendant(of: view, matching: find.byType(RichText)),
        )) {
          void visit(InlineSpan span, double? inherited) {
            final own = span.style?.fontSize ?? inherited;
            if (span is TextSpan) {
              final text = span.text ?? '';
              if (text.trim().isNotEmpty && (own == null || own < 13)) {
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
          greaterThanOrEqualTo(22),
        );
        expect(count('blocked', '1').style!.fontSize, greaterThanOrEqualTo(22));
        Text inCard(String id, String text) => t.widget<Text>(
          find.descendant(of: card(id), matching: find.text(text)),
        );
        // Headline 22 bold, meta 13.
        final other = inCard('t2', '乙方案：Cindy 完成了「改名」，等你验收');
        expect(other.style!.fontSize, greaterThanOrEqualTo(22));
        expect(other.style!.fontWeight, FontWeight.w900);
        expect(
          inCard('t2', '#raft-flutter · 你派的任务').style!.fontSize,
          greaterThanOrEqualTo(13),
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
      expect(t.getRect(card('t1')).height, lessThanOrEqualTo(150));
      final meta = t.widget<Text>(
        find.descendant(
          of: card('t1'),
          matching: find.text('#raft-flutter · 你派的任务'),
        ),
      );
      expect(meta.maxLines, 1);
    });

    testWidgets(
      'the phone view grows with system type instead of overflowing',
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
                body: HandsFree(
                  child: AgentAttentionView(
                    attention: AgentAttention(
                      items: [
                        item,
                        _decision('t2', '乙方案：等你验收'),
                        _blocked(),
                        _mention(),
                        _decision('t3', '丙方案：等你验收'),
                      ],
                      teamCount: 50,
                      capped: true,
                    ),
                    focusPrefix: 'attention',
                    onApprove: (_) {},
                    onOpen: (_) {},
                    onLater: (_) {},
                  ),
                ),
              ),
            ),
          );
          expect(t.takeException(), isNull, reason: 'scale $scale');
        }
      },
    );

    testWidgets('a mention is the last row; its row opens it', (t) async {
      await open(t, _Data(w, _three()));
      await openDetail(t, 'm1');
      expect(find.text('第 2 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail:m1')), findsOneWidget);
      // A question to answer, not a task: no 通过, a reply button.
      expect(find.byKey(const ValueKey('attention-approve-m1')), findsNothing);
      expect(find.text('回复 Cody'), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-later-m1')), findsOneWidget);
    });

    testWidgets('tapping a card opens its detail under it; 展开 goes to the '
        'full page and back finds it current', (t) async {
      await open(t, _Data(w, _three()));
      await t.tap(card('t1'));
      await t.pumpAndSettle();
      // No layer: the card is current, and its detail is under it.
      expect(find.text('第 1 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('hf-stage')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('hf-stage-expand')));
      await t.pumpAndSettle();
      expect(find.text('第 2 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail:t1')), findsOneWidget);
      // The task with its latest progress, the two before it as quotes.
      expect(find.text('甲方案：Cardinal 完成了「项目设定」，等你验收'), findsWidgets);
      expect(
        find.descendant(
          of: find.byType(HfDetail),
          matching: find.textContaining('等验收'),
        ),
        findsOneWidget,
      );
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

      // Back: the card is still the current one, so its detail is there.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('第 1 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('hf-stage')), findsOneWidget);
      // Back again puts the detail away before it leaves the screen.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('hf-stage')), findsNothing);
      expect(find.text('第 1 层'), findsOneWidget);
    });

    testWidgets('a tap on the current card again, or the stage\'s close, '
        'puts the stage away', (t) async {
      await open(t, _Data(w, _three()));
      await t.tap(card('t1'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('hf-stage')), findsOneWidget);
      // Its row stays on the screen, with its number.
      expect(card('t1'), findsOneWidget);
      await t.tap(card('t1'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('hf-stage')), findsNothing);

      await t.tap(card('t2'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('hf-stage')), findsOneWidget);
      // Another card takes the stage over: one stage, the new item in it.
      await t.tap(card('t3'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('hf-stage')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('attention-approve-t3')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('attention-approve-t2')), findsNothing);
      await t.tap(find.byKey(const ValueKey('hf-stage-close')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('hf-stage')), findsNothing);
    });

    testWidgets('the voice makes an item current the same way a tap does: '
        'the stage, the same actions, and 展开 for the full page', (t) async {
      await open(t, _Data(w, _three()), model: const _Spot());
      await say(t, 'x');
      // The model's words are not heard in a test: the item comes after the
      // wait the speech sync allows.
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      expect(find.text('第 1 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('hf-stage')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('attention-approve-t2')),
        findsOneWidget,
      );
      // 通过 acts on the current one: it asks about t2.
      await t.tap(find.byKey(const ValueKey('attention-approve-t2')));
      await t.pumpAndSettle();
      expect(find.textContaining('乙方案'), findsWidgets);
      expect(
        find.byKey(const ValueKey('attention-approve-confirm')),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('attention-approve-cancel')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('hf-stage-expand')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail:t2')), findsOneWidget);
    });

    testWidgets('a tap and the voice request open the same layer', (t) async {
      // The layer id (its key) and everything the layer says.
      Future<String> shown() async {
        final view = t.widget<AgentSurfaceView>(find.byType(AgentSurfaceView));
        return '${view.focusPrefix} ${agentSurfaceFrame(view.spec)}';
      }

      await open(t, _Data(w, _three()), model: const AgentScriptedModel());
      await openDetail(t, 't2');
      final byTap = await shown();
      await say(t, '返回');
      expect(find.text('第 1 层'), findsOneWidget);

      await say(t, '展开第二条');
      expect(find.text('第 2 层'), findsOneWidget);
      expect(await shown(), byTap);
      await say(t, '返回');

      // Digits, other words, and "this one": the current item, which is the
      // one just gone back to.
      await say(t, '讲讲第 3 条');
      expect(find.byKey(const ValueKey('detail:t3')), findsOneWidget);
      await say(t, '返回');
      await say(t, '详细说说这个');
      expect(find.byKey(const ValueKey('detail:t3')), findsOneWidget);
      // The model then says one or two sentences, from what it was given.
      expect(find.textContaining('Cindy 最后说：「t3 进展三」'), findsWidgets);
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
      await openDetail(t, 't2');
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

      await openDetail(t, 't3');
      await t.tap(find.byKey(const ValueKey('attention-later-t3')));
      await t.pumpAndSettle();
      expect(find.text('第 1 层'), findsOneWidget);
      expect(card('t3'), findsNothing);
      expect(countOf('decision', '1'), findsOneWidget);

      await openDetail(t, 't1');
      await t.tap(find.byKey(const ValueKey('attention-open-t1')));
      await t.pumpAndSettle();
      expect(find.text('第 3 层'), findsOneWidget);
      expect(find.text('# raft-flutter'), findsOneWidget);
    });

    testWidgets('spotlight and marks work on the detail layer', (t) async {
      await open(t, _Data(w, _three()));
      await openDetail(t, 't1');
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
      await openDetail(t, 't2');
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
      await openDetail(t, 't1');
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
      // It is kept (on the device) until it is due, not just hidden: a
      // question can ask for it, and it comes back by itself.
      final kept = AgentSnoozeStore.of(w).active.single;
      expect(kept.id, 't1');
      expect(
        kept.until.isAfter(DateTime.now().add(const Duration(hours: 2))),
        isTrue,
      );

      // Opening agent mode again keeps it hidden.
      await t.pumpWidget(const SizedBox());
      await open(t, data);
      expect(find.byKey(const ValueKey('attention-card-t1')), findsNothing);
      expect(find.byKey(const ValueKey('attention-card-t2')), findsOneWidget);
    });

    testWidgets('打开讨论 opens the item\'s channel as a layer', (t) async {
      await open(t, _Data(w, _three()));
      await openDetail(t, 't3');
      await t.tap(find.byKey(const ValueKey('attention-open-t3')));
      await t.pumpAndSettle();
      expect(find.text('第 3 层'), findsOneWidget);
      expect(find.text('# raft-flutter'), findsOneWidget);
    });

    testWidgets('team progress is collapsed and counted', (t) async {
      await open(
        t,
        _Data(
          w,
          AgentAttention(
            items: [_decision('t1', '甲方案：等你验收')],
            team: _three().team,
          ),
        ),
      );
      expect(find.text('团队在推进 2 件'), findsOneWidget);
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
      expect(find.text('团队在推进 50+ 件'), findsOneWidget);
    });

    testWidgets('nothing waiting says so', (t) async {
      await open(t, _Data(w, const AgentAttention(items: [])));
      expect(find.text(AgentAttentionView.emptyHeadline), findsOneWidget);
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
      expect(find.text(AgentAttentionView.emptyHeadline), findsNothing);
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
      // The first item is selected; its last progress line is shown.
      Finder inDetail(String text) => find.descendant(
        of: find.byKey(const ValueKey('attention-detail')),
        matching: find.textContaining(text),
      );
      expect(inDetail('t1 进展三'), findsOneWidget);
      expect(inDetail('t1 进展二'), findsNothing);
      expect(inDetail('甲方案'), findsOneWidget);
      // Every row is in the page; rows are compact: headline, no quote.
      expect(find.byKey(const ValueKey('attention-row-t2')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-card-t2')), findsNothing);
      expect(find.byKey(const ValueKey('attention-row-b1')), findsOneWidget);
      expect(find.textContaining('/ 5'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AgentAttentionView),
          matching: find.byType(Scrollable),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('t2 进展三'), findsNothing);

      final list = t.getRect(find.byKey(const ValueKey('attention-row-t1')));
      final detail = t.getRect(find.byKey(const ValueKey('attention-detail')));
      expect(detail.left, greaterThan(list.right));
      // The selected row is marked.
      expect(
        t
            .widget<HfRow>(find.byKey(const ValueKey('attention-row-t1')))
            .selected,
        isTrue,
      );
    });

    testWidgets('expand_item in a wide window selects in place: no layer, '
        'the pane and the row follow', (t) async {
      await open(
        t,
        _Data(w, _three()),
        size: wide,
        model: const AgentScriptedModel(),
      );
      await say(t, '展开第二条');
      expect(find.text('第 1 层'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail:t2')), findsNothing);
      Finder inDetail(String text) => find.descendant(
        of: find.byKey(const ValueKey('attention-detail')),
        matching: find.textContaining(text),
      );
      expect(inDetail('t2 进展三'), findsOneWidget);
      expect(inDetail('t1 进展三'), findsNothing);
      expect(
        t
            .widget<HfRow>(find.byKey(const ValueKey('attention-row-t2')))
            .selected,
        isTrue,
      );
      // And the actions act on it.
      expect(
        find.byKey(const ValueKey('attention-approve-t2')),
        findsOneWidget,
      );
    });

    testWidgets('the pane follows the voice (spotlight), and a tap after it '
        'moves it again', (t) async {
      await open(t, _Data(w, _three()), size: wide, model: const _Spot());
      await say(t, 'x');
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      Finder inDetail(String text) => find.descendant(
        of: find.byKey(const ValueKey('attention-detail')),
        matching: find.textContaining(text),
      );
      expect(inDetail('t2 进展三'), findsOneWidget);
      // The page scrolled to the second row and its detail; the first row is
      // a scroll away.
      await t.ensureVisible(find.byKey(const ValueKey('attention-row-t1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-row-t1')));
      await t.pumpAndSettle();
      expect(inDetail('t1 进展三'), findsOneWidget);
      expect(find.text('第 1 层'), findsOneWidget);
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

    testWidgets('the selection moves the page: down past the last row, the '
        'row and its detail scroll into view', (t) async {
      await open(t, _Data(w, _three()), size: wide);
      for (var i = 0; i < 4; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pumpAndSettle();
      }
      // The mention (the fifth) is current: the page moved to show it and
      // its detail, still the same page. The detail is whole when it fits the
      // window, else its top is at the top.
      final view = t.getRect(page());
      final row = t.getRect(find.byKey(const ValueKey('attention-row-m1')));
      final detail = t.getRect(find.byKey(const ValueKey('attention-detail')));
      expect(pageScroll(t).position.pixels, greaterThan(0));
      expect(row.top, greaterThanOrEqualTo(view.top - 1));
      expect(row.bottom, lessThanOrEqualTo(view.bottom + 1));
      expect(detail.top, greaterThanOrEqualTo(view.top - 1));
      // (The page keeps some air around what it shows: 2 x 12 s.)
      if (detail.height <= view.height - 2 * 12 * 900 / 540) {
        expect(detail.bottom, lessThanOrEqualTo(view.bottom + 1));
      }
      // The detail stands level with its row.
      expect(detail.top, closeTo(row.top, 2));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('attention-detail')),
          matching: find.textContaining('点名找你'),
        ),
        findsWidgets,
      );
    });

    testWidgets('detail has the ask and its three actions', (t) async {
      await open(t, _Data(w, _three()), size: wide);
      expect(
        find.byKey(const ValueKey('attention-approve-t1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('attention-open-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-later-t1')), findsOneWidget);
      expect(find.text('要你做'), findsOneWidget);
    });
  });

  group('tv', () {
    Future<void> tv(
      WidgetTester t,
      AgentAttention a, {
      String caption = '',
    }) async {
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
                'caption': caption,
                'mood': '🤔',
                'layers': [
                  {
                    'id': 'attention',
                    'title': '现在需要你',
                    'attention': a.toJson(),
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
    }

    testWidgets('the same list and detail as a desktop, voice hints for the '
        'buttons, caption strip', (t) async {
      final attention = AgentAttention(
        items: [
          _decision('t1', '甲方案：等你验收', hours: 24),
          _decision('t2', '乙方案：等你验收'),
          _decision('t3', '丙方案：等你验收'),
          _decision('t4', '丁方案：等你验收'),
          _blocked(),
        ],
      );
      await tv(t, attention, caption: 'Cardinal 那条已经等了 24 小时，先看这个？');
      // The whole list is one page, as on a desktop; no pager.
      expect(find.text('甲方案：等你验收'), findsWidgets);
      expect(find.text('乙方案：等你验收'), findsOneWidget);
      expect(find.text('丙方案：等你验收'), findsOneWidget);
      expect(find.text('丁方案：等你验收'), findsOneWidget);
      expect(find.textContaining('/ 5'), findsNothing);
      expect(find.text('最急'), findsNothing);
      expect(find.text('24'), findsOneWidget);
      // The detail of the first row, beside the list.
      expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
      // The buttons are pills that say what to say; nothing is pressable.
      expect(find.textContaining('「通过」'), findsOneWidget);
      expect(find.textContaining('「稍后」'), findsOneWidget);
      expect(find.text('通过'), findsNothing);
      expect(find.text('在手机上处理'), findsNothing);
      expect(find.text('下一批'), findsNothing);
      expect(find.text('Cardinal 那条已经等了 24 小时，先看这个？'), findsOneWidget);
      expect(find.text('AGENT'), findsOneWidget);
      expect(find.byType(HfDock), findsNothing);
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      // The type ramp scaled by s = 2: the headline is 44.
      final title = t.widget<Text>(find.text('乙方案：等你验收'));
      expect(title.style!.fontSize, 22 * 2);
    });

    testWidgets('an empty list says so on the TV too', (t) async {
      await tv(t, const AgentAttention(items: []));
      expect(find.text(AgentAttentionView.emptyHeadline), findsOneWidget);
    });
  });
}

/// Makes the second item the current one, as the model does when it starts
/// talking about it.
class _Spot extends AgentScriptedModel {
  const _Spot();

  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String) say,
  ) async {
    await call('spotlight', {'number': 2});
    return true;
  }
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
