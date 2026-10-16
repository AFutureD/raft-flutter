import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Agent mode has no scroll but the page: each layer is one scroll view below
/// its fixed header and above its fixed dock; focusing an item scrolls the
/// page to it. Fictional data only.
final _now = DateTime.utc(2026, 10, 15, 12);

AgentAttentionItem _item(int n) => AgentAttentionItem(
  id: 't$n',
  taskId: 't$n',
  taskNumber: n,
  priority: n <= 8 ? AgentPriority.decision : AgentPriority.blocked,
  headline: '第 $n 号方案：Cindy 完成了「选型」，等你验收',
  ask: '验收',
  action: AgentAction.approve,
  canApprove: true,
  reason: '你派的任务',
  waitValue: n,
  waitUnit: '小时',
  at: _now,
  score: 100.0 - n,
  waiters: const ['Cindy'],
  channelId: 'c1',
  channelName: 'raft-flutter',
  progress: [
    AgentProgressLine(who: 'Cindy', time: '今天 07:02', text: 't$n 进展一'),
    AgentProgressLine(
      who: 'Cindy',
      time: '今天 07:20',
      text: 't$n 的最后进展：整段话都写在详情里',
    ),
  ],
);

class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => _now);

  @override
  Future<AgentAttention> attention() async =>
      AgentAttention(items: [for (var n = 1; n <= 12; n++) _item(n)]);

  @override
  Future<AgentChannelBrief> channel(
    RaftChannel c, {
    int windowHours = 6,
  }) async => AgentChannelBrief(
    channel: c,
    messages: [
      for (var i = 0; i < 8; i++)
        {
          'id': 'm$i',
          'seq': '$i',
          'content': '第 $i 条消息：这里是一句比较长的话，用来看列表是不是完整地出现在页面里。',
          'senderName': 'Cindy',
          'createdAt': _now.toIso8601String(),
        },
    ],
    tasks: [
      for (var i = 0; i < 4; i++)
        {
          'taskNumber': 90 + i,
          'title': '任务 $i',
          'status': i.isEven ? 'in_review' : 'in_progress',
        },
    ],
    windowHours: windowHours,
  );
}

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
      ];
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<void> open(WidgetTester t, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentModePage(
          controller: w,
          data: _Data(w),
          model: const AgentScriptedModel(streamDelay: Duration.zero),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> say(WidgetTester t, String text) async {
    if (find.byKey(const ValueKey('agent-input')).evaluate().isEmpty) {
      await t.tap(find.byKey(const ValueKey('agent-keyboard')));
      await t.pumpAndSettle();
    }
    await t.enterText(find.byKey(const ValueKey('agent-input')), text);
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pumpAndSettle();
    // What the speech sync waits for before it lights an item.
    await t.pump(const Duration(seconds: 4));
    await t.pumpAndSettle();
  }

  /// The page of the layer in front, and its window.
  Finder page() => find.byKey(const ValueKey('hf-page'));
  Rect window(WidgetTester t) => t.getRect(page());
  ScrollableState scroll(WidgetTester t) => t.state<ScrollableState>(
    find.descendant(of: page(), matching: find.byType(Scrollable)),
  );

  /// Scrollables in the layers (the dock's text field is not a layer's).
  Finder layerScrolls() => find.descendant(
    of: find.byType(ZLayerStack),
    matching: find.byType(Scrollable),
  );

  void expectInWindow(WidgetTester t, Finder f, {String? reason}) {
    final view = window(t), r = t.getRect(f);
    expect(r.top, greaterThanOrEqualTo(view.top - 1), reason: '$reason top');
    expect(
      r.bottom,
      lessThanOrEqualTo(view.bottom + 1),
      reason: '$reason bottom',
    );
  }

  for (final (name, size) in [
    ('phone', const Size(412, 915)),
    ('desktop', const Size(1440, 900)),
  ]) {
    group(name, () {
      testWidgets('the home layer is one scroll, with or without a stage', (
        t,
      ) async {
        await open(t, size);
        expect(layerScrolls(), findsOneWidget);
        await t.tap(
          find.byKey(const ValueKey('attention-card-t1')).evaluate().isEmpty
              ? find.byKey(const ValueKey('attention-row-t2'))
              : find.byKey(const ValueKey('attention-card-t1')),
        );
        await t.pumpAndSettle();
        expect(layerScrolls(), findsOneWidget);
        expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
      });

      testWidgets('the header and the dock stay while the page moves', (
        t,
      ) async {
        await open(t, size);
        // (The keyboard button opens the input bar above the dock.)
        await t.tap(find.byKey(const ValueKey('agent-keyboard')));
        await t.pumpAndSettle();
        final title = t.getRect(find.text('现在需要你').first);
        final dock = t.getRect(find.byType(AgentVoiceDock));
        await say(t, '看看第十一个');
        expect(scroll(t).position.pixels, greaterThan(0));
        expect(t.getRect(find.text('现在需要你').first), title);
        expect(t.getRect(find.byType(AgentVoiceDock)), dock);
      });

      testWidgets('focusing an item scrolls it, and its detail, into view', (
        t,
      ) async {
        await open(t, size);
        for (final n in [9, 12, 3, 1]) {
          await say(t, '看看第${const {9: '九', 12: '十二', 3: '三', 1: '一'}[n]}个');
          final id = 't$n';
          final row = find.byKey(
            ValueKey(
              size.width >= 1280 ? 'attention-row-$id' : 'attention-card-$id',
            ),
          );
          // The row and its detail are whole inside the page's window: the
          // detail under the row on a phone, level with it beside the list.
          // When both are taller than the window, the detail comes first.
          final detail = find.byKey(const ValueKey('attention-detail'));
          expect(detail, findsOneWidget, reason: 'detail $n');
          final view = window(t);
          // The page keeps some air around what it shows: 2 x 12 s.
          final air = 24 * HfScale.of(size);
          final r = t.getRect(row), d = t.getRect(detail);
          bool inside(Rect x) =>
              x.top >= view.top - 1 && x.bottom <= view.bottom + 1;
          if (d.expandToInclude(r).height <= view.height - air) {
            expect(inside(r), isTrue, reason: 'row $n $r in $view');
            expect(inside(d), isTrue, reason: 'detail $n $d in $view');
          } else if (d.height <= view.height - air) {
            expect(inside(d), isTrue, reason: 'detail $n $d in $view');
          } else {
            // Taller than the window itself: its top is at the top.
            expect(
              d.top,
              inInclusiveRange(view.top - 1, view.top + 70),
              reason: 'detail $n top',
            );
          }
        }
      });

      testWidgets('a detail is whole: no clip, no scroll, no cut line', (
        t,
      ) async {
        await open(t, size);
        await say(t, '看看第二个');
        final detail = find.byKey(const ValueKey('attention-detail'));
        for (final kind in [
          Scrollable,
          ClipRect,
          ClipRRect,
          ClipPath,
          ShaderMask,
        ]) {
          expect(
            find.descendant(of: detail, matching: find.byType(kind)),
            findsNothing,
            reason: '$kind',
          );
        }
        for (final p in t.renderObjectList<RenderParagraph>(
          find.descendant(of: detail, matching: find.byType(RichText)),
        )) {
          expect(p.didExceedMaxLines, isFalse, reason: p.text.toPlainText());
        }
        // The long last line of progress is there in full.
        expect(find.textContaining('t2 的最后进展'), findsOneWidget);
      });

      testWidgets('a channel layer is one scroll too; its rows scroll into '
          'view when the agent points at them', (t) async {
        await open(t, size);
        await say(t, 'raft-flutter 现在什么情况？');
        expect(find.text('第 2 层'), findsOneWidget);
        expect(layerScrolls(), findsOneWidget);
        await say(t, '看看第十个');
        expect(scroll(t).position.pixels, greaterThan(0));
        expectInWindow(t, find.byKey(const ValueKey('frame-row-10')));
        expect(layerScrolls(), findsOneWidget);
        // Nothing fades the page out at an edge.
        expect(find.byKey(const ValueKey('agent-fade-bottom')), findsNothing);
      });

      testWidgets('the full detail layer is one scroll', (t) async {
        await open(t, size);
        await say(t, '展开第一条');
        // A wide window shows it beside the list; a phone opens the page.
        expect(layerScrolls(), findsOneWidget);
      });
    });
  }

  testWidgets('"下一批" moves the front layer on by a screen and back to the '
      'top after the end', (t) async {
    await open(t, const Size(412, 915));
    final s = scroll(t);
    expect(s.position.pixels, 0);
    var steps = 0;
    while (s.position.pixels < s.position.maxScrollExtent - 1 && steps < 20) {
      await say(t, '下一批');
      steps++;
    }
    expect(steps, greaterThan(1));
    expect(s.position.pixels, s.position.maxScrollExtent);
    await say(t, '下一批');
    expect(s.position.pixels, 0);
  });
}
