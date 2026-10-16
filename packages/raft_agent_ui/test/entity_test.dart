import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

/// Fictional data only.
class _Resolver extends ChangeNotifier implements AgentEntityResolver {
  final answers = <AgentEntityRef, AgentEntityResolution>{};
  final asked = <AgentEntityRef>[];

  void put(AgentEntityRef ref, AgentEntityData data) {
    answers[ref] = AgentEntityFound(data);
    notifyListeners();
  }

  @override
  AgentEntityResolution resolve(AgentEntityRef ref) {
    asked.add(ref);
    return answers[ref] ?? const AgentEntityMissing('没有这个 id');
  }
}

const _task = AgentEntityRef(AgentEntityKind.task, 't98');
const _message = AgentEntityRef(AgentEntityKind.message, 'm1');
const _agent = AgentEntityRef(AgentEntityKind.agent, 'a1');
const _channel = AgentEntityRef(AgentEntityKind.channel, 'c1');
const _member = AgentEntityRef(AgentEntityKind.member, 'u1');
const _computer = AgentEntityRef(AgentEntityKind.computer, 'k1');
const _file = AgentEntityRef(AgentEntityKind.file, 'f1');
const _image = AgentEntityRef(AgentEntityKind.file, 'f2');

_Resolver _full() => _Resolver()
  ..put(
    _task,
    const AgentTaskData(
      number: 98,
      title: '修复搜索打开频道后无法返回',
      status: 'in_review',
      assignee: 'Aria',
      channel: 'raft-flutter',
      updated: '12 分钟前',
    ),
  )
  ..put(
    _message,
    const AgentMessageData(
      author: 'Aria',
      text: 'PR 已合入，全量检查 0 失败。',
      time: '10:32',
      channel: 'raft-flutter',
      attachmentCount: 2,
    ),
  )
  ..put(
    _agent,
    const AgentAgentData(
      name: 'Aria',
      state: AgentWorkState.busy,
      activity: '在做 #98「修复返回」',
      computer: 'build-box',
      since: '12 分钟前有进展',
    ),
  )
  ..put(
    _channel,
    const AgentChannelData(
      name: 'raft-flutter',
      unread: 3,
      mentioned: true,
      lastActivity: '5 分钟前',
    ),
  )
  ..put(
    _member,
    const AgentMemberData(
      name: 'Grace',
      role: '管理员',
      presence: AgentPresence.online,
    ),
  )
  ..put(
    _computer,
    const AgentComputerData(
      name: 'build-box',
      online: true,
      runtimes: ['codex', 'claude'],
      agentCount: 3,
    ),
  )
  ..put(
    _file,
    const AgentFileData(name: 'report.pdf', type: 'PDF', size: '1.2 MB'),
  )
  ..put(
    _image,
    AgentFileData(
      name: 'shot.png',
      type: 'PNG',
      size: '340 KB',
      isImage: true,
      thumbnail: (context, size) =>
          Container(key: const ValueKey('fake-thumb'), color: Colors.blue),
    ),
  );

void _size(WidgetTester t, [Size size = const Size(412, 915)]) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Widget _host(
  Widget child, {
  required AgentEntityResolver resolver,
  AgentEntityProblem? onProblem,
  double width = 390,
  double textScale = 1,
}) => MaterialApp(
  theme: raftTheme(RaftFamily.brutal),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: app!,
  ),
  home: HandsFree(
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: AgentEntityScope(
              resolver: resolver,
              onProblem: onProblem,
              child: child,
            ),
          ),
        ),
      ),
    ),
  ),
);

/// A card on the numbered screen: it wears [n] on its bar.
Widget _at(int n, Widget card) => HfItemScope(index: n, child: card);

/// Every font size drawn under [of].
List<double> _sizes(WidgetTester t, Finder of) => [
  for (final w in t.widgetList<RichText>(
    find.descendant(of: of, matching: find.byType(RichText)),
  ))
    ?w.text.style?.fontSize,
];

const _detail = DisplaySpec(level: AgentLevel.detail);

void main() {
  const all = [_task, _message, _agent, _channel, _member, _computer, _file];

  group('entity cards render from the app data', () {
    testWidgets('every kind, as a numbered row', (t) async {
      _size(t);
      final r = _full();
      await t.pumpWidget(
        _host(
          Column(
            children: [
              for (final (i, e) in all.indexed)
                _at(i + 1, HfEntityCard(entity: e)),
            ],
          ),
          resolver: r,
        ),
      );
      for (final text in [
        '修复搜索打开频道后无法返回',
        '等验收',
        '#98',
        'PR 已合入，全量检查 0 失败。',
        'Aria',
        '附件 2',
        '在做 #98「修复返回」',
        '在忙',
        '#raft-flutter',
        '未读 3',
        '@我',
        'Grace',
        '管理员',
        '在线',
        'build-box',
        'report.pdf',
      ]) {
        expect(
          find.textContaining(text),
          findsWidgets,
          reason: 'missing "$text"',
        );
      }
      // The number on the bar is the handle: 1 to 7.
      expect(find.byType(HfRow), findsNWidgets(7));
      for (var n = 1; n <= 7; n++) {
        expect(find.text('$n'), findsOneWidget, reason: 'number $n');
      }
    });

    testWidgets('the detail level is a card with a row per fact', (t) async {
      _size(t);
      final r = _full();
      await t.pumpWidget(
        _host(
          Column(
            children: [
              for (final e in all) HfEntityCard(entity: e, display: _detail),
            ],
          ),
          resolver: r,
        ),
      );
      expect(find.byType(HfDetail), findsNWidgets(7));
      // Detail adds labelled facts the row folds into one line.
      for (final text in ['负责人', '频道', '更新', '电脑', '持续', '最近活动']) {
        expect(find.text(text), findsWidgets, reason: 'missing "$text"');
      }
      expect(find.text('运行环境'), findsOneWidget);
      expect(find.text('大小'), findsOneWidget);
    });

    testWidgets('minimum is the title alone', (t) async {
      _size(t);
      await t.pumpWidget(
        _host(
          const HfEntityCard(
            entity: _task,
            display: DisplaySpec(level: AgentLevel.minimum),
          ),
          resolver: _full(),
        ),
      );
      expect(find.text('修复搜索打开频道后无法返回'), findsOneWidget);
      expect(find.textContaining('等验收'), findsNothing);
      expect(find.textContaining('Aria'), findsNothing);
    });

    testWidgets('an image shows its cached thumbnail, a file an icon', (
      t,
    ) async {
      _size(t);
      await t.pumpWidget(
        _host(
          Column(
            children: const [
              HfEntityCard(entity: _image),
              HfEntityCard(entity: _file),
            ],
          ),
          resolver: _full(),
        ),
      );
      expect(find.byKey(const ValueKey('fake-thumb')), findsOneWidget);
      expect(find.byKey(const ValueKey('entity-thumb')), findsOneWidget);
      expect(find.byKey(const ValueKey('entity-file-icon')), findsOneWidget);
    });

    testWidgets('tone changes the colour, emphasis adds a tag', (t) async {
      _size(t);
      await t.pumpWidget(
        _host(
          Column(
            children: const [
              HfEntityCard(entity: _task),
              HfEntityCard(
                entity: _task,
                tone: AgentTone.good,
                emphasis: AgentEmphasis.high,
              ),
            ],
          ),
          resolver: _full(),
        ),
      );
      final rows = t.widgetList<HfRow>(find.byType(HfRow)).toList();
      // A task waiting for the person is red; the good tone makes it green.
      expect(rows[0].tone, HfTone.decision);
      expect(rows[1].tone, HfTone.progress);
      expect(rows[0].badge, isNull);
      expect(rows[1].badge, '重点');
    });
  });

  group('live data', () {
    testWidgets('the card follows the underlying data', (t) async {
      _size(t);
      final r = _full();
      await t.pumpWidget(
        _host(const HfEntityCard(entity: _task), resolver: r),
      );
      expect(find.textContaining('等验收'), findsOneWidget);
      r.put(
        _task,
        const AgentTaskData(
          number: 98,
          title: '修复搜索打开频道后无法返回',
          status: 'done',
          assignee: 'Aria',
          channel: 'raft-flutter',
          updated: '刚刚',
        ),
      );
      await t.pump();
      expect(find.textContaining('等验收'), findsNothing);
      expect(find.textContaining('已完成'), findsOneWidget);
      expect(find.textContaining('刚刚'), findsOneWidget);
    });

    testWidgets('a card that was loading draws when the data arrives', (
      t,
    ) async {
      _size(t);
      final r = _Resolver();
      r.answers[_task] = const AgentEntityLoading();
      final problems = <AgentEntityRef>[];
      await t.pumpWidget(
        _host(
          const HfEntityCard(entity: _task),
          resolver: r,
          onProblem: (ref, _) => problems.add(ref),
        ),
      );
      expect(find.textContaining('读取中'), findsOneWidget);
      r.put(_task, const AgentTaskData(title: '后来到的', status: 'todo'));
      await t.pump();
      expect(find.text('后来到的'), findsOneWidget);
      expect(problems, isEmpty, reason: 'loading is not an error');
    });

    testWidgets('the resolver is released with the card', (t) async {
      _size(t);
      final r = _full();
      await t.pumpWidget(
        _host(const HfEntityCard(entity: _task), resolver: r),
      );
      await t.pumpWidget(_host(const SizedBox(), resolver: r));
      r.notifyListeners();
      await t.pump();
    });
  });

  group('an id the app cannot read', () {
    testWidgets('draws a small 找不到 row and tells the model once', (t) async {
      _size(t);
      final r = _full();
      final problems = <(AgentEntityRef, String)>[];
      await t.pumpWidget(
        _host(
          _at(
            2,
            const HfEntityCard(
              entity: AgentEntityRef(AgentEntityKind.task, 'nope'),
            ),
          ),
          resolver: r,
          onProblem: (ref, reason) => problems.add((ref, reason)),
        ),
      );
      expect(find.textContaining('找不到任务'), findsOneWidget);
      expect(find.textContaining('nope'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(problems, [
        (const AgentEntityRef(AgentEntityKind.task, 'nope'), '没有这个 id'),
      ]);
      // Rebuilds and data changes elsewhere do not report it again.
      r.notifyListeners();
      await t.pump();
      r.notifyListeners();
      await t.pump();
      expect(problems, hasLength(1));
    });

    testWidgets('the stub is one row, not a card', (t) async {
      _size(t);
      await t.pumpWidget(
        _host(
          const HfEntityCard(
            entity: AgentEntityRef(AgentEntityKind.agent, 'nope'),
          ),
          resolver: _Resolver(),
        ),
      );
      final box = t.getSize(
        find.byKey(const ValueKey('entity-stub-agent-nope')),
      );
      expect(box.height, lessThan(90));
    });

    testWidgets('without a scope nothing is invented either', (t) async {
      _size(t);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: const HandsFree(
            child: Scaffold(body: HfEntityCard(entity: _task)),
          ),
        ),
      );
      expect(find.textContaining('找不到任务'), findsOneWidget);
    });

    testWidgets('a member that appears later is drawn, the error is cleared', (
      t,
    ) async {
      _size(t);
      final r = _Resolver();
      final problems = <AgentEntityRef>[];
      await t.pumpWidget(
        _host(
          const HfEntityCard(entity: _member),
          resolver: r,
          onProblem: (ref, _) => problems.add(ref),
        ),
      );
      expect(problems, [_member]);
      r.put(_member, const AgentMemberData(name: 'Grace'));
      await t.pump();
      expect(find.text('Grace'), findsOneWidget);
      expect(find.textContaining('找不到'), findsNothing);
    });
  });

  group('type sizes at arm\'s length', () {
    testWidgets('rows: title at least 22, nothing under 13', (t) async {
      _size(t);
      await t.pumpWidget(
        _host(
          Column(
            children: [
              for (final e in all) _at(1, HfEntityCard(entity: e)),
              const HfEntityCard(
                entity: AgentEntityRef(AgentEntityKind.task, 'nope'),
              ),
              const HfEntityCard(entity: _image),
            ],
          ),
          resolver: _full(),
        ),
      );
      final sizes = _sizes(t, find.byType(HfEntityCard));
      expect(sizes, isNotEmpty);
      for (final s in sizes) {
        expect(s, greaterThanOrEqualTo(13));
      }
      for (final text in ['修复搜索打开频道后无法返回', 'PR 已合入，全量检查 0 失败。']) {
        final w = t.widget<RichText>(
          find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == text,
          ),
        );
        expect(
          w.text.style!.fontSize,
          greaterThanOrEqualTo(22),
          reason: text,
        );
      }
    });

    testWidgets('detail and the stub keep nothing under 13 either', (t) async {
      _size(t);
      await t.pumpWidget(
        _host(
          Column(
            children: [
              for (final e in all) HfEntityCard(entity: e, display: _detail),
              const HfEntityCard(entity: _image),
            ],
          ),
          resolver: _full(),
        ),
      );
      for (final s in _sizes(t, find.byType(HfEntityCard))) {
        expect(s, greaterThanOrEqualTo(13));
      }
    });

    testWidgets('the sizes follow s: a desktop window draws them larger', (
      t,
    ) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(
        _host(
          const HfEntityCard(entity: _task),
          resolver: _full(),
          width: 700,
        ),
      );
      final w = t.widget<RichText>(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == '修复搜索打开频道后无法返回',
        ),
      );
      expect(w.text.style!.fontSize, closeTo(22 * 900 / 540, .01));
    });

    testWidgets('1.0 and 2.0 text scale lay out without overflow', (t) async {
      _size(t);
      for (final scale in [1.0, 2.0]) {
        await t.pumpWidget(
          _host(
            Column(
              children: [
                for (final e in all) _at(1, HfEntityCard(entity: e)),
              ],
            ),
            resolver: _full(),
            textScale: scale,
          ),
        );
        expect(t.takeException(), isNull, reason: 'scale $scale');
      }
    });
  });

  group('inline references', () {
    testWidgets('resolve to a one-line label, missing ones say so', (t) async {
      _size(t);
      final problems = <AgentEntityRef>[];
      await t.pumpWidget(
        _host(
          const Column(
            children: [
              HfEntityInline(entity: _task, handle: '1'),
              HfEntityInline(
                entity: AgentEntityRef(AgentEntityKind.channel, 'zz'),
              ),
            ],
          ),
          resolver: _full(),
          onProblem: (ref, _) => problems.add(ref),
        ),
      );
      expect(find.text('#98 修复搜索打开频道后无法返回'), findsOneWidget);
      expect(find.text('①'), findsOneWidget);
      expect(find.textContaining('找不到频道 zz'), findsOneWidget);
      expect(problems, hasLength(1));
    });
  });

  group('handles', () {
    test('1 to 20 are circled, anything else stays', () {
      expect(agentHandleGlyph('1'), '①');
      expect(agentHandleGlyph('20'), '⑳');
      expect(agentHandleGlyph('21'), '21');
      expect(agentHandleGlyph('③'), '③');
    });
  });
}
