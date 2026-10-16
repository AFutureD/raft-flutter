import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

class _Resolver extends ChangeNotifier implements AgentEntityResolver {
  final answers = <AgentEntityRef, AgentEntityData>{};
  @override
  AgentEntityResolution resolve(AgentEntityRef ref) {
    final d = answers[ref];
    return d == null
        ? const AgentEntityMissing('没有这个 id')
        : AgentEntityFound(d);
  }
}

const _task = AgentEntityRef(AgentEntityKind.task, 't98');

Widget _host(
  Widget child, {
  _Resolver? resolver,
  AgentEntityProblem? onProblem,
}) {
  final r =
      resolver ??
      (_Resolver()
        ..answers[_task] = const AgentTaskData(
          number: 98,
          title: '修复返回',
          status: 'done',
        ));
  return MaterialApp(
    theme: raftTheme(RaftFamily.brutal),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 390,
          child: SingleChildScrollView(
            child: AgentEntityScope(
              resolver: r,
              onProblem: onProblem,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

List<double> _sizes(WidgetTester t, Finder of) => [
  for (final w in t.widgetList<Text>(
    find.descendant(of: of, matching: find.byType(Text)),
  ))
    ?(w.style?.fontSize ?? w.textSpan?.style?.fontSize),
];

Finder _lines(String prefix) => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(prefix) &&
      // 'code-line-' also starts the hot ones' siblings only by index.
      !(w.key! as ValueKey<String>).value.startsWith('code-line-hot-') ==
          !prefix.contains('hot'),
);

void main() {
  group('table', () {
    testWidgets('plain text and entity cells, header, every row', (t) async {
      await t.pumpWidget(
        _host(
          AgentTableView(
            columns: const ['任务', '负责人', '状态'],
            rows: [
              [
                const AgentTableCell.entity(_task, handle: '1'),
                const AgentTableCell.text('Aria'),
                const AgentTableCell.text('已完成'),
              ],
              [
                const AgentTableCell.text('#7 旧任务'),
                const AgentTableCell.text('Bo'),
                const AgentTableCell.text('进行中'),
              ],
            ],
          ),
        ),
      );
      for (final s in ['任务', '负责人', '状态', 'Aria', 'Bo', '#7 旧任务']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('#98 修复返回'), findsOneWidget);
      expect(find.text('①'), findsOneWidget);
    });

    testWidgets('five columns scroll sideways instead of squeezing', (t) async {
      await t.pumpWidget(
        _host(
          AgentTableView(
            columns: const ['一', '二', '三', '四', '五'],
            rows: [
              [for (final c in 'abcde'.split('')) AgentTableCell.text(c)],
            ],
          ),
        ),
      );
      expect(find.byType(SingleChildScrollView), findsNWidgets(2));
      expect(t.takeException(), isNull);
      final first = t.getSize(find.text('一'));
      expect(first.width, lessThan(120));
    });

    testWidgets('twenty rows draw, a missing entity cell says so', (t) async {
      final problems = <AgentEntityRef>[];
      await t.pumpWidget(
        _host(
          AgentTableView(
            columns: const ['名'],
            rows: [
              for (var i = 0; i < AgentBlockLimits.tableRows; i++)
                [AgentTableCell.text('行$i')],
              [
                const AgentTableCell.entity(
                  AgentEntityRef(AgentEntityKind.agent, 'zz'),
                ),
              ],
            ],
          ),
          onProblem: (ref, _) => problems.add(ref),
        ),
      );
      expect(find.text('行19'), findsOneWidget);
      expect(find.textContaining('找不到Agent zz'), findsOneWidget);
      expect(problems, hasLength(1));
    });

    testWidgets('nothing under 16', (t) async {
      await t.pumpWidget(
        _host(
          AgentTableView(
            columns: const ['任务', '人'],
            rows: [
              [
                const AgentTableCell.entity(_task),
                const AgentTableCell.text('A'),
              ],
            ],
          ),
        ),
      );
      for (final s in _sizes(t, find.byType(AgentTableView))) {
        expect(s, greaterThanOrEqualTo(16));
      }
    });
  });

  group('timeline', () {
    testWidgets('time, title and the entity each item concerns', (t) async {
      await t.pumpWidget(
        _host(
          const AgentTimelineView(
            items: [
              AgentTimelineItem(time: '09:10', title: '创建任务'),
              AgentTimelineItem(
                time: '10:32',
                title: '进入验收',
                entity: _task,
                handle: '2',
              ),
              AgentTimelineItem(time: '11:00', title: '检查通过'),
            ],
          ),
        ),
      );
      for (final s in ['09:10', '10:32', '11:00', '创建任务', '进入验收', '检查通过']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('#98 修复返回'), findsOneWidget);
      expect(find.text('②'), findsOneWidget);
      for (final s in _sizes(t, find.byType(AgentTimelineView))) {
        expect(s, greaterThanOrEqualTo(16));
      }
    });
  });

  group('code and diff', () {
    const diff =
        '--- a/x.dart\n+++ b/x.dart\n@@ -1,2 +1,2 @@\n context\n-old line\n+new line\n';

    testWidgets('+ and - lines are tinted only in diff mode', (t) async {
      await t.pumpWidget(
        _host(const AgentCodeBlockView(code: diff, diff: true)),
      );
      // +new, -old, @@ hunk.
      expect(_lines('code-line-hot-'), findsNWidgets(3));
      expect(find.text('+new line'), findsOneWidget);
      await t.pumpWidget(_host(const AgentCodeBlockView(code: diff)));
      expect(_lines('code-line-hot-'), findsNothing);
    });

    testWidgets('monospace, 16 or more, one widget per line', (t) async {
      await t.pumpWidget(
        _host(const AgentCodeBlockView(code: 'a\nb\nc', title: 'x.dart')),
      );
      final mono = RaftTokens.of(t.element(find.byType(AgentCodeBlockView)))
          .monoFont;
      final w = t.widget<Text>(find.text('a'));
      expect(w.style!.fontFamily, mono);
      expect(w.style!.fontSize, greaterThanOrEqualTo(16));
      expect(_lines('code-line-'), findsNWidgets(3));
      expect(find.text('x.dart'), findsOneWidget);
    });

    testWidgets('forty lines are drawn, the rest is counted not drawn', (
      t,
    ) async {
      final code = [for (var i = 0; i < 45; i++) 'line $i'].join('\n');
      await t.pumpWidget(_host(AgentCodeBlockView(code: code)));
      expect(_lines('code-line-'), findsNWidgets(40));
      expect(find.text('… 还有 5 行'), findsOneWidget);
    });
  });

  group('callout', () {
    testWidgets('one sentence per tone', (t) async {
      await t.pumpWidget(
        _host(
          const Column(
            children: [
              AgentCalloutView(text: '全量检查通过，可以合。', tone: AgentTone.good),
              AgentCalloutView(text: '有 2 个检查没跑完。', tone: AgentTone.warn),
              AgentCalloutView(text: '仅供参考。'),
            ],
          ),
        ),
      );
      expect(find.text('全量检查通过，可以合。'), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-callout-good')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-callout-warn')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-callout-neutral')),
        findsOneWidget,
      );
      for (final s in _sizes(t, find.byType(AgentCalloutView))) {
        expect(s, greaterThanOrEqualTo(20));
      }
    });
  });

  group('confirm card', () {
    testWidgets('turns into its outcome: result, thing made, undo, retry', (
      t,
    ) async {
      var undone = 0, retried = 0, dismissed = 0;
      Widget card(AgentActionOutcome? outcome) => _host(
        AgentConfirmCardView(
          title: '把 #98 改为 进行中',
          changes: const ['状态: 待办 → 进行中'],
          outcome: outcome,
          attachment: const AgentEntityCard(entity: _task),
          onConfirm: () {},
          onCancel: () {},
        ),
      );
      await t.pumpWidget(card(null));
      expect(find.text('确认'), findsOneWidget);
      expect(find.text('将要修改'), findsOneWidget);

      await t.pumpWidget(
        card(
          AgentActionOutcome(
            kind: AgentOutcomeKind.done,
            text: '已改为 进行中',
            undoLabel: '改回 待办',
            onUndo: () => undone++,
            onDismiss: () => dismissed++,
          ),
        ),
      );
      // The same card: the buttons gave way to the result, the thing stays
      // (the card eases to its new height first).
      await t.pumpAndSettle();
      expect(find.text('确认'), findsNothing);
      expect(find.text('已完成'), findsWidgets);
      expect(find.text('已改为 进行中 ✅'), findsOneWidget);
      expect(find.textContaining('修复返回'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('confirm-card-undo')));
      await t.tap(find.byKey(const ValueKey('confirm-card-dismiss')));
      expect((undone, dismissed), (1, 1));

      await t.pumpWidget(
        card(
          AgentActionOutcome(
            kind: AgentOutcomeKind.failed,
            text: '没有成功',
            onRetry: () => retried++,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('没有成功 ⚠️'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('confirm-card-retry')));
      expect(retried, 1);
      expect(find.byKey(const ValueKey('confirm-card-undo')), findsNothing);

      await t.pumpWidget(
        card(const AgentActionOutcome(kind: AgentOutcomeKind.running, text: '正在发送')),
      );
      expect(find.text('正在发送…'), findsOneWidget);
      expect(find.byKey(const ValueKey('confirm-card-retry')), findsNothing);
    });

    test('changes parse as field: from → to', () {
      final c = AgentChange.parse('状态: 进行中 → 已完成');
      expect((c.field, c.from, c.to), ('状态', '进行中', '已完成'));
      final d = AgentChange.parse('负责人：无 -> Aria');
      expect((d.field, d.from, d.to), ('负责人', '无', 'Aria'));
      expect(AgentChange.wellFormed('状态: 进行中 → 已完成'), isTrue);
      expect(AgentChange.wellFormed('改一下状态'), isFalse);
      expect(AgentChange.wellFormed('状态: 已完成'), isFalse);
      final e = AgentChange.parse('备注: 空 → 时间: 12:00');
      expect(e.to, '时间: 12:00');
    });

    testWidgets('title, every change and both buttons', (t) async {
      var confirmed = 0, cancelled = 0;
      await t.pumpWidget(
        _host(
          AgentConfirmCardView(
            title: '把 #98 标记为已完成？',
            changes: const ['状态: 等验收 → 已完成', '负责人: Aria → Aria'],
            onConfirm: () => confirmed++,
            onCancel: () => cancelled++,
          ),
        ),
      );
      expect(find.text('把 #98 标记为已完成？'), findsOneWidget);
      expect(find.text('状态'), findsOneWidget);
      expect(find.text('等验收'), findsOneWidget);
      expect(find.text('已完成'), findsWidgets);
      expect(find.text('将要修改'), findsOneWidget);
      await t.tap(find.text('确认'));
      await t.pump();
      expect((confirmed, cancelled), (1, 0));
      // Decided: the buttons are gone and a second tap cannot decide again.
      expect(find.text('确认'), findsNothing);
      expect(
        find.byKey(const ValueKey('confirm-card-confirmed')),
        findsOneWidget,
      );
    });

    testWidgets('cancel reports once', (t) async {
      var confirmed = 0, cancelled = 0;
      await t.pumpWidget(
        _host(
          AgentConfirmCardView(
            title: '删除这个频道？',
            risk: AgentConfirmRisk.sensitive,
            changes: const ['频道: raft-flutter → 已删除'],
            onConfirm: () => confirmed++,
            onCancel: () => cancelled++,
          ),
        ),
      );
      expect(find.text('敏感操作'), findsOneWidget);
      expect(find.text('确认执行'), findsOneWidget);
      expect(find.byKey(const ValueKey('entity-strip')), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pump();
      expect((confirmed, cancelled), (0, 1));
      expect(
        find.byKey(const ValueKey('confirm-card-cancelled')),
        findsOneWidget,
      );
    });

    testWidgets('the owner can set the outcome', (t) async {
      await t.pumpWidget(
        _host(
          const AgentConfirmCardView(
            title: '合入？',
            changes: ['分支: 未合入 → 已合入'],
            result: AgentConfirmResult.confirmed,
          ),
        ),
      );
      expect(find.text('已确认'), findsOneWidget);
      expect(find.text('确认'), findsNothing);
    });

    testWidgets('compact title is at least 26, nothing under 16', (t) async {
      await t.pumpWidget(
        _host(
          const AgentConfirmCardView(
            title: '合入 #98？',
            changes: ['分支: 未合入 → 已合入'],
          ),
        ),
      );
      expect(
        t.widget<Text>(find.text('合入 #98？')).style!.fontSize,
        greaterThanOrEqualTo(26),
      );
      for (final s in _sizes(t, find.byType(AgentConfirmCardView))) {
        expect(s, greaterThanOrEqualTo(16));
      }
    });
  });

  group('choice and toggle', () {
    testWidgets('choice reports the pick and locks', (t) async {
      final picks = <(int, String)>[];
      await t.pumpWidget(
        _host(
          AgentChoiceView(
            prompt: '合到哪里？',
            options: const ['integration', 'main', '先不合'],
            onChoose: (i, l) => picks.add((i, l)),
          ),
        ),
      );
      expect(find.text('合到哪里？'), findsOneWidget);
      await t.tap(find.text('main'));
      await t.pump();
      await t.tap(find.text('先不合'));
      await t.pump();
      expect(picks, [(1, 'main')]);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('choice shows a pick the owner already knows', (t) async {
      await t.pumpWidget(
        _host(const AgentChoiceView(options: ['a', 'b'], selected: 0)),
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('toggle flips and reports', (t) async {
      final seen = <bool>[];
      await t.pumpWidget(
        _host(AgentToggleView(label: '完成后通知我', onChanged: seen.add)),
      );
      expect(find.text('关'), findsOneWidget);
      await t.tap(find.text('完成后通知我'));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('开'), findsOneWidget);
      await t.tap(find.text('完成后通知我'));
      await t.pump(const Duration(milliseconds: 200));
      expect(seen, [true, false]);
    });

    testWidgets('sizes: nothing under 16', (t) async {
      await t.pumpWidget(
        _host(
          const Column(
            children: [
              AgentChoiceView(options: ['a', 'b'], prompt: '选一个'),
              AgentToggleView(label: '开关'),
            ],
          ),
        ),
      );
      for (final s in _sizes(t, find.byType(Column).first)) {
        expect(s, greaterThanOrEqualTo(16));
      }
    });
  });
}
