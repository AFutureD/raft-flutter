import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

/// Fictional data only. Every optional field is filled, with a word of its
/// own, so a finder says exactly which element is on screen.
class _Resolver extends ChangeNotifier implements AgentEntityResolver {
  final answers = <AgentEntityRef, AgentEntityResolution>{};

  @override
  AgentEntityResolution resolve(AgentEntityRef ref) =>
      answers[ref] ?? const AgentEntityMissing('没有这个 id');
}

const _refs = {
  'message': AgentEntityRef(AgentEntityKind.message, 'm1'),
  'task': AgentEntityRef(AgentEntityKind.task, 't1'),
  'agent': AgentEntityRef(AgentEntityKind.agent, 'a1'),
  'channel': AgentEntityRef(AgentEntityKind.channel, 'c1'),
  'member': AgentEntityRef(AgentEntityKind.member, 'u1'),
  'computer': AgentEntityRef(AgentEntityKind.computer, 'k1'),
  'file': AgentEntityRef(AgentEntityKind.file, 'f1'),
};

_Resolver _resolver() {
  final r = _Resolver();
  void put(String kind, AgentEntityData d) =>
      r.answers[_refs[kind]!] = AgentEntityFound(d);
  put(
    'message',
    const AgentMessageData(
      author: 'Zed',
      text: 'hello-text',
      time: '10:32',
      channel: 'chan-x',
      attachmentCount: 2,
      reactions: [AgentReaction('👍', 3)],
      threadCount: 4,
    ),
  );
  put(
    'task',
    const AgentTaskData(
      number: 77,
      title: 'title-tok',
      status: 'in_review',
      assignee: 'asg-tok',
      channel: 'tch',
      updated: 'upd-tok',
      description: 'desc-tok',
      latestProgress: 'prog-tok',
    ),
  );
  put(
    'agent',
    const AgentAgentData(
      name: 'agent-nm',
      state: AgentWorkState.busy,
      activity: 'act-tok',
      computer: 'box-tok',
      since: 'since-tok',
      channel: 'ach',
      model: 'mdl-tok',
    ),
  );
  put(
    'channel',
    const AgentChannelData(
      name: 'chn-name',
      unread: 3,
      mentioned: true,
      lastActivity: 'last-tok',
      description: 'cdesc-tok',
      memberCount: 12,
    ),
  );
  put(
    'member',
    const AgentMemberData(
      name: 'mem-nm',
      role: 'role-tok',
      presence: AgentPresence.online,
    ),
  );
  put(
    'computer',
    const AgentComputerData(
      name: 'cmp-nm',
      online: true,
      runtimes: ['rt-a', 'rt-b'],
      agentCount: 3,
      version: 'ver-tok',
    ),
  );
  put(
    'file',
    const AgentFileData(
      name: 'file-nm.pdf',
      type: 'PDF',
      size: '1.2 MB',
      author: 'upl-tok',
    ),
  );
  return r;
}

/// What on screen says each element is there.
Map<String, Map<String, Finder>> _finders() => {
  'message': {
    'avatar': find.byType(HfAvatar),
    'author': find.textContaining('Zed'),
    'time': find.textContaining('10:32'),
    'channel': find.textContaining('#chan-x'),
    'text': find.textContaining('hello-text'),
    'attachments': find.textContaining('附件 2'),
    'reactions': find.textContaining('👍 3'),
    'thread_count': find.textContaining('回复 4'),
  },
  'task': {
    'number': find.textContaining('#77'),
    'title': find.textContaining('title-tok'),
    'status': find.textContaining('等验收'),
    'assignee': find.textContaining('asg-tok'),
    'channel': find.textContaining('#tch'),
    'updated': find.textContaining('upd-tok'),
    'description': find.textContaining('desc-tok'),
    'latest_progress': find.textContaining('prog-tok'),
  },
  'agent': {
    'avatar': find.byType(HfAvatar),
    'name': find.textContaining('agent-nm'),
    'state': find.textContaining('在忙'),
    'activity': find.textContaining('act-tok'),
    'since': find.textContaining('since-tok'),
    'computer': find.textContaining('box-tok'),
    'channel': find.textContaining('#ach'),
    'model': find.textContaining('mdl-tok'),
  },
  'channel': {
    'name': find.textContaining('chn-name'),
    'description': find.textContaining('cdesc-tok'),
    'unread': find.textContaining('未读 3'),
    'mentions': find.textContaining('@我'),
    'last_activity': find.textContaining('last-tok'),
    'members': find.textContaining('12'),
  },
  'member': {
    'avatar': find.byType(HfAvatar),
    'name': find.textContaining('mem-nm'),
    'role': find.textContaining('role-tok'),
    'presence': find.textContaining('在线'),
  },
  'computer': {
    'name': find.textContaining('cmp-nm'),
    'online': find.textContaining('在线'),
    'runtimes': find.textContaining('rt-a'),
    'agents': find.textContaining('3 个'),
    'version': find.textContaining('ver-tok'),
  },
  'file': {
    'name': find.textContaining('file-nm.pdf'),
    'type': find.textContaining('PDF'),
    'size': find.textContaining('1.2 MB'),
    'thumbnail': find.byKey(const ValueKey('entity-file-icon')),
    'author': find.textContaining('upl-tok'),
  },
};

/// The number on the card's bar is its handle.
final _handle = find.text('2');

Widget _host(
  Widget child, {
  required AgentEntityResolver resolver,
  double width = 390,
}) => MaterialApp(
  theme: raftTheme(RaftFamily.brutal),
  home: HandsFree(
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: AgentEntityScope(resolver: resolver, child: child),
          ),
        ),
      ),
    ),
  ),
);

/// The card as the second thing on the screen: number 2 on its bar.
Widget _card(String kind, DisplaySpec? display, {Key? key}) => HfItemScope(
  index: 2,
  child: HfEntityCard(key: key, entity: _refs[kind]!, display: display),
);

Future<void> _show(
  WidgetTester t,
  String kind,
  DisplaySpec? display, {
  _Resolver? resolver,
}) async {
  t.view.physicalSize = const Size(412, 915);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    _host(_card(kind, display), resolver: resolver ?? _resolver()),
  );
  await t.pumpAndSettle();
}

List<double> _sizes(WidgetTester t, Finder of) => [
  for (final w in t.widgetList<Text>(
    find.descendant(of: of, matching: find.byType(Text)),
  ))
    ?(w.style?.fontSize ?? w.textSpan?.style?.fontSize),
];

void main() {
  final kinds = _refs.keys.toList();

  test('the finder table covers every element but the handle', () {
    for (final kind in kinds) {
      final elements = agentDisplayKinds[kind]!.elements.toSet()
        ..remove('handle');
      expect(_finders()[kind]!.keys.toSet(), elements, reason: kind);
    }
  });

  group('every level draws exactly its preset', () {
    for (final kind in kinds) {
      for (final level in AgentLevel.values) {
        testWidgets('$kind at ${level.name}', (t) async {
          await _show(t, kind, DisplaySpec(level: level));
          final preset = agentDisplayKinds[kind]!.preset(level);
          for (final e in _finders()[kind]!.entries) {
            expect(
              e.value,
              preset.contains(e.key) ? findsWidgets : findsNothing,
              reason: '$kind.${e.key} at ${level.name}',
            );
          }
          expect(
            _handle,
            preset.contains('handle') ? findsOneWidget : findsNothing,
          );
        });
      }
    }
  });

  group('every element toggle shows and hides it', () {
    for (final kind in kinds) {
      for (final e in agentDisplayKinds[kind]!.elements) {
        testWidgets('$kind.$e off at detail, on at minimum', (t) async {
          final finder = e == 'handle' ? _handle : _finders()[kind]![e]!;
          await _show(t, kind, const DisplaySpec(level: AgentLevel.detail));
          expect(finder, findsWidgets, reason: '$kind.$e is there at detail');
          await _show(
            t,
            kind,
            DisplaySpec(level: AgentLevel.detail, show: {e: false}),
          );
          expect(finder, findsNothing, reason: '$kind.$e turned off');
          // The others stay: only this one went.
          for (final other in _finders()[kind]!.entries) {
            if (other.key == e) continue;
            // Elements that share words with the one turned off would hide
            // with it (a channel is both a name and a member count of 12).
            if (other.key == 'members' && e == 'name') continue;
            expect(other.value, findsWidgets, reason: '$kind.${other.key}');
          }

          await _show(t, kind, const DisplaySpec(level: AgentLevel.minimum));
          if (agentDisplayKinds[kind]!.preset(AgentLevel.minimum).contains(e)) {
            expect(finder, findsWidgets);
          } else {
            expect(finder, findsNothing, reason: '$kind.$e is off at minimum');
          }
          await _show(
            t,
            kind,
            DisplaySpec(level: AgentLevel.minimum, show: {e: true}),
          );
          expect(finder, findsWidgets, reason: '$kind.$e turned on');
        });
      }
    }
  });

  group('the card is never empty', () {
    for (final kind in kinds) {
      testWidgets('$kind with every element off still says what it is', (
        t,
      ) async {
        await _show(
          t,
          kind,
          DisplaySpec(
            show: {for (final e in agentDisplayKinds[kind]!.elements) e: false},
          ),
        );
        final card = find.byKey(ValueKey('entity-card-$kind'));
        expect(card, findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.byType(Text)),
          findsWidgets,
        );
      });
    }
  });

  group('lines', () {
    int? headlineLines(WidgetTester t, String text) {
      final w = t.widget<Text>(
        find.descendant(
          of: find.byType(HfEntityCard),
          matching: find.textContaining(text),
        ),
      );
      return w.maxLines;
    }

    testWidgets('clamp the main text', (t) async {
      for (final n in [1, 3, 8]) {
        await _show(t, 'task', DisplaySpec(lines: n));
        expect(headlineLines(t, 'title-tok'), n);
      }
      await _show(t, 'message', const DisplaySpec(level: AgentLevel.detail));
      expect(headlineLines(t, 'hello-text'), 8);
      await _show(
        t,
        'message',
        const DisplaySpec(level: AgentLevel.detail, lines: 2),
      );
      expect(headlineLines(t, 'hello-text'), 2);
    });

    testWidgets('minimum is one line', (t) async {
      await _show(t, 'message', const DisplaySpec(level: AgentLevel.minimum));
      expect(headlineLines(t, 'hello-text'), 1);
    });
  });

  group('handles', () {
    testWidgets('a hidden number is still the card\'s handle', (t) async {
      final semantics = t.ensureSemantics();
      await _show(t, 'task', const DisplaySpec(show: {'handle': false}));
      expect(_handle, findsNothing);
      expect(find.bySemanticsLabel(RegExp('②')), findsOneWidget);
      await _show(t, 'task', null);
      expect(_handle, findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('②')), findsWidgets);
      semantics.dispose();
    });

    testWidgets('the number is the bar at the left of the title', (t) async {
      await _show(t, 'task', const DisplaySpec(level: AgentLevel.minimum));
      final badge = t.getRect(_handle);
      final title = t.getRect(find.textContaining('title-tok'));
      expect((badge.center.dy - title.center.dy).abs(), lessThan(40));
      expect(badge.right, lessThanOrEqualTo(title.left));
    });
  });

  group('type sizes', () {
    for (final kind in kinds) {
      for (final level in AgentLevel.values) {
        testWidgets('$kind ${level.name}: nothing under 13', (t) async {
          await _show(
            t,
            kind,
            DisplaySpec(
              level: level,
              show: {
                for (final e in agentDisplayKinds[kind]!.elements) e: true,
              },
            ),
          );
          final sizes = _sizes(t, find.byType(HfEntityCard));
          expect(sizes, isNotEmpty);
          for (final s in sizes) {
            expect(s, greaterThanOrEqualTo(13), reason: '$kind ${level.name}');
          }
        });
      }
    }

    testWidgets('the headline at minimum is 22 or more', (t) async {
      for (final kind in kinds) {
        await _show(t, kind, const DisplaySpec(level: AgentLevel.minimum));
        final headline = {
          'message': 'hello-text',
          'task': 'title-tok',
          'agent': 'agent-nm',
          'channel': 'chn-name',
          'member': 'mem-nm',
          'computer': 'cmp-nm',
          'file': 'file-nm.pdf',
        }[kind]!;
        final w = t.widget<Text>(find.textContaining(headline));
        expect(w.style!.fontSize, greaterThanOrEqualTo(22), reason: kind);
      }
    });

    testWidgets('size is read, but one type ramp draws the same', (t) async {
      double headline() =>
          t.widget<Text>(find.textContaining('title-tok')).style!.fontSize!;
      final sizes = <double>[];
      for (final s in AgentSize.values) {
        await _show(t, 'task', DisplaySpec(size: s));
        sizes.add(headline());
      }
      expect(sizes.toSet(), hasLength(1));
      expect(sizes.first, greaterThanOrEqualTo(22));
    });

    testWidgets('the largest size lays out at 390 wide without overflow', (
      t,
    ) async {
      for (final kind in kinds) {
        await _show(
          t,
          kind,
          DisplaySpec(
            level: AgentLevel.detail,
            size: AgentSize.large,
            show: {for (final e in agentDisplayKinds[kind]!.elements) e: true},
          ),
        );
        expect(t.takeException(), isNull, reason: kind);
      }
    });
  });

  group('changing a property moves the card smoothly', () {
    double height(WidgetTester t) =>
        t.getSize(find.byKey(const ValueKey('entity-card-task'))).height;

    testWidgets('minimum to detail grows over time, with no jump', (t) async {
      final r = _resolver();
      await _show(
        t,
        'task',
        const DisplaySpec(level: AgentLevel.minimum),
        resolver: r,
      );
      final before = height(t);
      // The same card, now with more of itself: pump the new description in
      // without letting the clock run.
      await t.pumpWidget(
        _host(
          _card('task', const DisplaySpec(level: AgentLevel.detail)),
          resolver: r,
        ),
      );
      expect(
        height(t),
        before,
        reason: 'the first frame still has the old size',
      );
      await t.pump(const Duration(milliseconds: 100));
      final mid = height(t);
      expect(mid, greaterThan(before));
      await t.pump(const Duration(milliseconds: 60));
      final later = height(t);
      expect(later, greaterThanOrEqualTo(mid));
      await t.pumpAndSettle();
      final after = height(t);
      expect(after, greaterThan(mid));
      expect(mid, lessThan(after), reason: 'it was still on its way');
    });

    testWidgets('hiding an element shrinks it over time', (t) async {
      final r = _resolver();
      await _show(
        t,
        'task',
        const DisplaySpec(level: AgentLevel.detail),
        resolver: r,
      );
      final before = height(t);
      await t.pumpWidget(
        _host(
          _card(
            'task',
            const DisplaySpec(
              level: AgentLevel.detail,
              show: {'description': false, 'latest_progress': false},
            ),
          ),
          resolver: r,
        ),
      );
      expect(height(t), before);
      await t.pump(const Duration(milliseconds: 100));
      final mid = height(t);
      expect(mid, lessThan(before));
      await t.pumpAndSettle();
      expect(height(t), lessThan(mid));
    });

    testWidgets('the card is not rebuilt: its state and size carry over', (
      t,
    ) async {
      final r = _resolver();
      final key = GlobalKey();
      Widget card(DisplaySpec d) =>
          _host(_card('task', d, key: key), resolver: r);
      await t.pumpWidget(card(const DisplaySpec(level: AgentLevel.minimum)));
      await t.pumpAndSettle();
      final element = key.currentContext!;
      await t.pumpWidget(card(const DisplaySpec(level: AgentLevel.detail)));
      expect(identical(key.currentContext, element), isTrue);
      await t.pumpAndSettle();
    });
  });

  group('the display follows the data', () {
    testWidgets('data an element has none of draws nothing for it', (t) async {
      final r = _resolver();
      r.answers[_refs['message']!] = const AgentEntityFound(
        AgentMessageData(author: 'Zed', text: 'hello-text'),
      );
      await _show(
        t,
        'message',
        const DisplaySpec(level: AgentLevel.detail),
        resolver: r,
      );
      expect(find.textContaining('回复'), findsNothing);
      expect(find.textContaining('附件'), findsNothing);
      expect(find.textContaining('hello-text'), findsOneWidget);
    });

    testWidgets('a member without presence data claims none', (t) async {
      final r = _resolver();
      r.answers[_refs['member']!] = const AgentEntityFound(
        AgentMemberData(name: 'mem-nm', role: 'role-tok'),
      );
      await _show(
        t,
        'member',
        const DisplaySpec(show: {'presence': true}),
        resolver: r,
      );
      expect(find.text('在线'), findsNothing);
      expect(find.text('离线'), findsNothing);
    });
  });
}
