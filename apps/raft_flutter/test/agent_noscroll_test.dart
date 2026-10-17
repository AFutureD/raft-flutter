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
  Future<AgentConversationRead> conversation(
    String id, {
    int limit = 50,
    bool withTasks = true,
    String? parentChannelId,
    String? parentMessageId,
  }) async => AgentConversationRead(
    rows: [
      for (var i = 0; i < 16; i++)
        {
          'id': 'm$i',
          'seq': '$i',
          'content': '第 $i 条消息：这里是一句比较长的话，用来看列表是不是完整地出现在页面里。',
          'senderType': i.isEven ? 'user' : 'agent',
          'senderId': i.isEven ? 'u-bo' : 'a-cindy',
          'senderName': i.isEven ? 'Bo' : 'Cindy',
          'messageType': 'chat',
          'createdAt': _now.add(Duration(minutes: i)).toIso8601String(),
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

      testWidgets('the dock stays while the page moves, and the heading '
          'moves with it on a phone (the bar floats)', (t) async {
        await open(t, size);
        // (The keyboard button opens the input bar above the dock.)
        await t.tap(find.byKey(const ValueKey('agent-keyboard')));
        await t.pumpAndSettle();
        final title = t.getRect(find.text('动态').first);
        final dock = t.getRect(find.byType(AgentVoiceDock));
        await say(t, '看看第十一个');
        expect(scroll(t).position.pixels, greaterThan(0));
        if (size.width >= 1280) {
          expect(t.getRect(find.text('动态').first), title);
        } else {
          expect(t.getRect(find.text('动态').first).top, lessThan(title.top));
        }
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

      testWidgets('a conversation layer is one scroll too; its messages scroll '
          'into view when the agent points at them', (t) async {
        await open(t, size);
        await say(t, 'raft-flutter 现在什么情况？');
        expect(find.text('第 2 层'), findsOneWidget);
        expect(layerScrolls(), findsOneWidget);
        await say(t, '看看第十个');
        expect(scroll(t).position.pixels, greaterThan(0));
        expectInWindow(t, find.byKey(const ValueKey('hf-bubble-m9')));
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

  group('the top bar and the dock float over the page', () {
    // A status bar and a gesture bar, as a phone has.
    const safe = 24.0;
    const phone = Size(412, 915);

    Future<void> openInsets(WidgetTester t) async {
      t.view.physicalSize = phone;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: safe, bottom: safe),
              viewPadding: const EdgeInsets.only(top: safe, bottom: safe),
            ),
            child: child!,
          ),
          home: AgentModePage(
            controller: w,
            data: _Data(w),
            model: const AgentScriptedModel(streamDelay: Duration.zero),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    Rect bar(WidgetTester t) =>
        t.getRect(find.byKey(const ValueKey('agent-mode-bar')));
    Rect dockRect(WidgetTester t) => t.getRect(find.byType(AgentVoiceDock));
    Rect card(WidgetTester t, int n) =>
        t.getRect(find.byKey(ValueKey('attention-card-t$n')));
    double fadeOpacity(WidgetTester t, String key) => t
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    testWidgets('the edges are the safe area and one small token', (t) async {
      await openInsets(t);
      // The top bar starts within the safe area and a small token of the
      // top; the mic row ends within them of the bottom.
      expect(bar(t).top, greaterThanOrEqualTo(safe));
      expect(bar(t).top, lessThanOrEqualTo(safe + RaftSpace.x3));
      final dock = t.getRect(find.byType(HfDock));
      expect(phone.height - dock.bottom, greaterThanOrEqualTo(safe));
      expect(
        phone.height - dock.bottom,
        lessThanOrEqualTo(safe + RaftSpace.x3),
      );
      // The sides use the same logic.
      expect(card(t, 1).left, closeTo(RaftSpace.x4, 1));
      expect(
        phone.width - card(t, 1).right,
        lessThanOrEqualTo(RaftSpace.x4 + 12),
      );
    });

    testWidgets('at rest the first row is whole below the bar and the last '
        'can be scrolled whole above the dock', (t) async {
      await openInsets(t);
      expect(card(t, 1).top, greaterThanOrEqualTo(bar(t).bottom));
      expect(find.text('动态'), findsWidgets);
      final page = scroll(t);
      page.position.jumpTo(page.position.maxScrollExtent);
      await t.pumpAndSettle();
      expect(card(t, 12).bottom, lessThanOrEqualTo(dockRect(t).top + .5));
      // Nothing is permanently hidden: the same row is whole in the window.
      expect(card(t, 12).top, greaterThanOrEqualTo(bar(t).bottom));
    });

    testWidgets('rows pass behind the bar and the dock while it scrolls', (
      t,
    ) async {
      await openInsets(t);
      final page = scroll(t);
      var behindDock = false, behindBar = false;
      for (var y = 0.0; y < page.position.maxScrollExtent; y += 40) {
        page.position.jumpTo(y);
        await t.pump();
        for (var n = 1; n <= 12; n++) {
          final r = card(t, n);
          if (r.overlaps(dockRect(t))) behindDock = true;
          if (r.overlaps(bar(t))) behindBar = true;
        }
      }
      expect(behindDock, isTrue);
      expect(behindBar, isTrue);
    });

    testWidgets('the fades are behind the bars, ignore pointers and show only '
        'while content is behind them', (t) async {
      await openInsets(t);
      const dockFade = ValueKey('hf-dock-fade'),
          topFade = ValueKey('hf-top-fade');
      for (final key in [dockFade, topFade]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key');
        expect(find.byKey(key).hitTestable(), findsNothing, reason: '$key');
        final ignore = t.widget<IgnorePointer>(
          find
              .ancestor(
                of: find.byKey(key),
                matching: find.byType(IgnorePointer),
              )
              .first,
        );
        expect(ignore.ignoring, isTrue, reason: '$key');
      }
      // From the page colour at the bar's edge to nothing, and the reverse.
      final canvas = RaftAgentTheme.of(t.element(find.byType(AgentModePage)))
          .canvas;
      LinearGradient gradient(Key key) =>
          ((t.widget<DecoratedBox>(find.byKey(key))).decoration
                      as BoxDecoration)
                  .gradient!
              as LinearGradient;
      expect(gradient(dockFade).colors.last, canvas);
      expect(gradient(dockFade).colors.first.a, 0);
      expect(gradient(topFade).colors.first, canvas);
      expect(gradient(topFade).colors.last.a, 0);
      // Solid behind the top bar's text; only its lower edge band is clear.
      // Behind the dock rows stay visible, fading out.
      expect(gradient(topFade).colors[1], canvas);
      expect(gradient(topFade).stops![1], greaterThan(0.5));
      expect(gradient(dockFade).colors, hasLength(2));
      // The fade is under the whole dock.
      final fade = t.getRect(find.byKey(dockFade));
      expect(fade.top, lessThanOrEqualTo(dockRect(t).top));
      expect(fade.bottom, greaterThanOrEqualTo(dockRect(t).bottom));

      // At rest more list is below the dock; nothing is above the bar.
      expect(fadeOpacity(t, 'hf-dock-fade'), 1);
      expect(fadeOpacity(t, 'hf-top-fade'), 0);
      final page = scroll(t);
      page.position.jumpTo(page.position.maxScrollExtent / 2);
      await t.pumpAndSettle();
      expect(fadeOpacity(t, 'hf-dock-fade'), 1);
      expect(fadeOpacity(t, 'hf-top-fade'), 1);
      page.position.jumpTo(page.position.maxScrollExtent);
      await t.pumpAndSettle();
      expect(fadeOpacity(t, 'hf-dock-fade'), 0);
      expect(fadeOpacity(t, 'hf-top-fade'), 1);
    });

    testWidgets('a tap on the fade reaches the row under it', (t) async {
      await openInsets(t);
      final page = scroll(t);
      final y = dockRect(t).top - 3;
      // Scroll until a row is under the point just above the dock's
      // controls, in the fade.
      int? under;
      for (var off = 100.0; off < page.position.maxScrollExtent; off += 7) {
        page.position.jumpTo(off);
        await t.pump();
        for (var n = 1; n <= 12; n++) {
          final r = card(t, n);
          if (r.top < y && y < r.bottom) under = n;
        }
        if (under != null) break;
      }
      expect(under, isNotNull);
      expect(find.byKey(const ValueKey('hf-stage')), findsNothing);
      await t.tapAt(Offset(card(t, under!).center.dx, y));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('hf-stage')), findsOneWidget);
    });

    testWidgets('a focused row and its detail end up between the bars', (
      t,
    ) async {
      await openInsets(t);
      for (final n in [12, 3, 9]) {
        await say(t, '看看第${const {12: '十二', 3: '三', 9: '九'}[n]}个');
        final r = card(t, n);
        final d = t.getRect(find.byKey(const ValueKey('attention-detail')));
        expect(
          r.top,
          greaterThanOrEqualTo(bar(t).bottom - 1),
          reason: 'row $n',
        );
        expect(
          r.bottom,
          lessThanOrEqualTo(dockRect(t).top + 1),
          reason: 'row $n',
        );
        if (d.expandToInclude(r).height <= dockRect(t).top - bar(t).bottom) {
          expect(
            d.bottom,
            lessThanOrEqualTo(dockRect(t).top + 1),
            reason: 'detail $n',
          );
        }
      }
    });
  });
}
