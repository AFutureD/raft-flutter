import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

class _Resolver extends ChangeNotifier implements AgentEntityResolver {
  @override
  AgentEntityResolution resolve(AgentEntityRef ref) => const AgentEntityFound(
    AgentTaskData(title: 'inline-task', status: 'todo'),
  );
}

Widget _host(Widget child) => MaterialApp(
  theme: raftTheme(RaftFamily.brutal),
  home: HandsFree(
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: 390,
          child: SingleChildScrollView(
            child: AgentEntityScope(resolver: _Resolver(), child: child),
          ),
        ),
      ),
    ),
  ),
);

/// One component, drawn with [spec], and the elements it can show: each has a
/// finder, and a preset says which of them are there at each level.
Future<void> _show(
  WidgetTester t,
  Widget Function(DisplaySpec?) make,
  DisplaySpec? spec,
) async {
  t.view.physicalSize = const Size(412, 915);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(_host(make(spec)));
  await t.pumpAndSettle();
}

/// A component under test: how to draw it, and how to see each element.
class _Case {
  const _Case(
    this.kind,
    this.make,
    this.finders, {
    this.elsewhere = const {},
    this.neverEmpty = true,
  });
  final String kind;

  /// Elements the component itself does not draw (the summary row does).
  final Set<String> elsewhere;
  final bool neverEmpty;
  final Widget Function(DisplaySpec?) make;
  final Map<String, Finder Function()> finders;
}

final _cases = <_Case>[
  _Case(
    'AgentStatusCard',
    (d) => HfStatusCard(
      name: 'nm-tok',
      state: AgentWorkState.busy,
      activity: 'act-tok',
      since: 'since-tok',
      channel: 'ch-tok',
      display: d,
    ),
    {
      'name': () => find.textContaining('nm-tok'),
      'state': () => find.textContaining('在忙'),
      'activity': () => find.textContaining('act-tok'),
      'since': () => find.textContaining('since-tok'),
      'channel': () => find.textContaining('#ch-tok'),
    },
  ),
  _Case(
    'TaskCard',
    (d) => HfTaskCard(
      title: 'title-tok',
      status: 'in_review',
      number: 98,
      assignee: 'asg-tok',
      channel: 'ch-tok',
      quote: 'quote-tok',
      ask: 'ask-tok',
      display: d,
    ),
    {
      'number': () => find.textContaining('#98'),
      'status': () => find.textContaining('等验收'),
      'title': () => find.textContaining('title-tok'),
      'assignee': () => find.textContaining('asg-tok'),
      'channel': () => find.textContaining('#ch-tok'),
      'latest_progress': () => find.textContaining('quote-tok'),
      'ask': () => find.textContaining('ask-tok'),
    },
  ),
  _Case(
    'MessageQuote',
    (d) => HfMessageQuote(
      author: 'au-tok',
      text: 'text-tok',
      time: 'time-tok',
      channel: 'ch-tok',
      display: d,
    ),
    {
      'author': () => find.textContaining('au-tok'),
      'time': () => find.textContaining('time-tok'),
      'channel': () => find.textContaining('#ch-tok'),
      'text': () => find.textContaining('text-tok'),
      'bar': () => find.byKey(const ValueKey('hf-row-bar')),
    },
  ),
  _Case(
    'StatRow',
    (d) => HfStatStrip(
      stats: const [HfStat('label-tok', '3')],
      display: d,
    ),
    {'label': () => find.text('label-tok')},
  ),
  _Case(
    'AgentStatusGroup',
    (d) => HfGroup(
      title: 'group-tok',
      displayKind: 'AgentStatusGroup',
      display: d,
      children: [for (var i = 0; i < 7; i++) const SizedBox(height: 4)],
    ),
    {
      'title': () => find.textContaining('group-tok'),
      'count': () => find.text('7'),
    },
    elsewhere: {'collapse'},
    neverEmpty: false,
  ),
  _Case(
    'Section',
    (d) => HfGroup(
      title: 'sect-tok',
      display: d,
      children: const [SizedBox(height: 10)],
    ),
    {
      'title': () => find.textContaining('sect-tok'),
      'count': () => find.text('1'),
    },
    elsewhere: {'collapse'},
    neverEmpty: false,
  ),
  _Case(
    'Table',
    (d) => HfTable(
      columns: const ['col-a', 'col-b'],
      rows: const [
        [AgentTableCell.text('x1'), AgentTableCell.text('y1')],
        [AgentTableCell.text('x2'), AgentTableCell.text('y2')],
      ],
      display: d,
    ),
    {
      'header': () => find.text('col-a'),
      'borders': () => _tableBorder(true),
      'zebra': () => _zebra(),
    },
  ),
  _Case(
    'Timeline',
    (d) => HfTimeline(
      items: const [
        AgentTimelineItem(
          time: 'time-tok',
          title: 'title-tok',
          entity: AgentEntityRef(AgentEntityKind.task, 't'),
        ),
        AgentTimelineItem(time: 'later', title: 'second'),
      ],
      display: d,
    ),
    {
      'time': () => find.text('time-tok'),
      'icon': () => find.byKey(const ValueKey('timeline-icon-0')),
      'title': () => find.text('title-tok'),
      'entity': () => find.textContaining('inline-task'),
    },
  ),
  _Case(
    'CodeBlock',
    (d) => HfCodeBlock(
      title: 'file-tok.dart',
      code: List.generate(44, (i) => 'line $i').join('\n'),
      display: d,
    ),
    {
      'title': () => find.text('file-tok.dart'),
      'line_numbers': () => find.text('40'),
      'more': () => find.textContaining('还有 4 行'),
    },
  ),
  _Case(
    'Callout',
    (d) => HfCallout(text: 'say-tok', tone: AgentTone.good, display: d),
    {
      'icon': () => find.byIcon(Icons.check_circle_outline),
      'text': () => find.textContaining('say-tok'),
    },
  ),
  _Case(
    'ConfirmCard',
    (d) => HfConfirm(
      message: 'conf-tok',
      changes: const ['状态-tok: 进行中 → 已完成'],
      display: d,
    ),
    {
      'label': () => find.text('将要修改'),
      'field_names': () => find.text('状态-tok'),
    },
  ),
];

Finder _tableBorder(bool on) => find.byWidgetPredicate(
  (w) =>
      w is Table && w.key == const ValueKey('agent-table') && w.border != null,
);

Finder _zebra() => find.byWidgetPredicate(
  (w) => w is Table && w.children.skip(1).any((r) => r.decoration != null),
);

void main() {
  for (final c in _cases) {
    group(c.kind, () {
      final kind = agentDisplayKinds[c.kind]!;

      test('has the inventory it documents', () {
        expect(
          c.finders.keys.toSet().union(c.elsewhere),
          {...kind.elements}..remove('handle'),
        );
      });

      for (final level in AgentLevel.values) {
        testWidgets('draws exactly the ${level.name} preset', (t) async {
          await _show(t, c.make, DisplaySpec(level: level));
          final preset = kind.preset(level);
          for (final e in c.finders.entries) {
            expect(
              e.value(),
              preset.contains(e.key) ? findsWidgets : findsNothing,
              reason: '${c.kind}.${e.key} at ${level.name}',
            );
          }
        });
      }

      for (final e in c.finders.entries) {
        testWidgets('${e.key} off at detail, on at minimum', (t) async {
          await _show(t, c.make, const DisplaySpec(level: AgentLevel.detail));
          expect(
            e.value(),
            findsWidgets,
            reason: '${e.key} is there at detail',
          );
          await _show(
            t,
            c.make,
            DisplaySpec(level: AgentLevel.detail, show: {e.key: false}),
          );
          expect(e.value(), findsNothing, reason: '${e.key} turned off');
          await _show(
            t,
            c.make,
            DisplaySpec(level: AgentLevel.minimum, show: {e.key: true}),
          );
          expect(e.value(), findsWidgets, reason: '${e.key} turned on');
        });
      }

      testWidgets('with every element off it still says something', (t) async {
        if (!c.neverEmpty) return;
        await _show(
          t,
          c.make,
          DisplaySpec(show: {for (final e in kind.elements) e: false}),
        );
        expect(find.byType(Text), findsWidgets);
      });

      testWidgets('no display keeps what it always drew', (t) async {
        await _show(t, c.make, null);
        final legacy = kind.preset(kind.legacy);
        for (final e in c.finders.entries) {
          expect(
            e.value(),
            legacy.contains(e.key) ? findsWidgets : findsNothing,
            reason: '${c.kind}.${e.key}',
          );
        }
      });
    });
  }

  group('summary row', () {
    Widget row(DisplaySpec? d) => HfSummaryRow(
      title: 'grp-tok',
      count: 3,
      text: 'members-tok',
      onTap: () {},
      display: d,
    );

    testWidgets('title, count and the arrow are elements', (t) async {
      await _show(t, row, null);
      expect(find.textContaining('grp-tok 3'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      await _show(t, row, const DisplaySpec(show: {'count': false}));
      expect(find.textContaining('grp-tok'), findsOneWidget);
      expect(find.textContaining('grp-tok 3'), findsNothing);
      await _show(t, row, const DisplaySpec(show: {'collapse': false}));
      expect(find.byIcon(Icons.expand_more), findsNothing);
      await _show(t, row, const DisplaySpec(show: {'title': false}));
      expect(find.textContaining('grp-tok'), findsNothing);
      expect(find.textContaining('members-tok'), findsOneWidget);
    });
  });

  group('the blocks keep what must not be hidden', () {
    testWidgets('a confirmation always shows its changes and its buttons', (
      t,
    ) async {
      await _show(
        t,
        (d) => HfConfirm(
          message: 'conf-tok',
          changes: const ['状态: 进行中 → 已完成'],
          display: d,
        ),
        DisplaySpec(
          show: {
            for (final e in agentDisplayKinds['ConfirmCard']!.elements)
              e: false,
          },
        ),
      );
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('确认'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('a sensitive confirmation always says so', (t) async {
      await _show(
        t,
        (d) => HfConfirm(
          message: 'conf-tok',
          changes: const ['状态: 进行中 → 已完成'],
          risk: AgentConfirmRisk.sensitive,
          display: d,
        ),
        const DisplaySpec(show: {'label': false}),
      );
      expect(find.text('敏感操作'), findsOneWidget);
    });
  });

  group('a property change moves the card smoothly', () {
    testWidgets('a status card grows and shrinks over time', (t) async {
      Widget card(DisplaySpec d) => _host(
        HfStatusCard(
          name: 'nm-tok',
          state: AgentWorkState.busy,
          activity: 'act-tok act-tok act-tok act-tok act-tok act-tok',
          since: 'since-tok',
          channel: 'ch-tok',
          display: d,
        ),
      );
      double height() => t.getSize(find.byType(HfStatusCard)).height;
      await t.pumpWidget(card(const DisplaySpec(level: AgentLevel.minimum)));
      await t.pumpAndSettle();
      final small = height();
      await t.pumpWidget(card(const DisplaySpec(level: AgentLevel.detail)));
      expect(height(), small);
      await t.pump(const Duration(milliseconds: 100));
      final mid = height();
      expect(mid, greaterThan(small));
      await t.pumpAndSettle();
      final big = height();
      expect(big, greaterThan(mid));
      await t.pumpWidget(card(const DisplaySpec(level: AgentLevel.minimum)));
      expect(height(), big);
      await t.pump(const Duration(milliseconds: 100));
      expect(height(), lessThan(big));
    });
  });
}
