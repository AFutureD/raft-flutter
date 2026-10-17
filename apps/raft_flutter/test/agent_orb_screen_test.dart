import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_tool_output.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/orb_prompt.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen_contract.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen_reader.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen_snapshot.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen_tools.dart';

import 'agent_orb_nav_tools_test.dart' show Fixture;
import 'agent_orb_shell_test.dart' show OrbFixture;

// The screen contract of the Agent orb: every page tells the model what is on
// it and what can be done there, from the same semantics a screen reader gets.

Map<String, Object?> _map(Object? v) => (v as Map).cast<String, Object?>();
List<Map<String, Object?>> _list(Object? v) => [
  for (final e in (v as List? ?? const [])) _map(e),
];

/// The actions of a contract whose label contains [text].
Map<String, Object?>? _find(Map<String, Object?> contract, String text) =>
    _list(contract['actions'])
        .where((a) => '${a['label']}'.contains(text))
        .firstOrNull;

OrbScreenSnapshot _read(WidgetTester t) {
  final root =
      t.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!;
  return readOrbScreen(root, number: 1, route: '/test');
}

int _bytes(Object? v) => utf8.encode(jsonEncode(v)).length;

/// A page like a phone's: a title, a search button in the corner, a switch, a
/// field, a slider, rows that open and a button that is off.
Widget _samplePage({Widget? extra, List<Widget> rows = const []}) =>
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('收件箱'),
          actions: [
            IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.search),
              onPressed: () {},
            ),
          ],
        ),
        body: ListView(
          children: [
            const Text('今天有 3 件事要看'),
            SwitchListTile(
              title: const Text('静音'),
              value: false,
              onChanged: (_) {},
            ),
            const TextField(decoration: InputDecoration(labelText: '回复')),
            Slider(
              value: .5,
              label: '音量',
              semanticFormatterCallback: (v) => '$v',
              onChanged: (_) {},
            ),
            ListTile(
              title: const Text('Alice'),
              subtitle: const Text('周五能来评审吗'),
              onTap: () {},
              onLongPress: () {},
            ),
            const ElevatedButton(onPressed: null, child: Text('提交')),
            ?extra,
            ...rows,
          ],
        ),
      ),
    );

/// A widget test with the semantics switched on, as a screen reader's session.
void _semanticsTest(String name, Future<void> Function(WidgetTester t) body) =>
    testWidgets(name, (t) async {
      final handle = t.ensureSemantics();
      try {
        await body(t);
      } finally {
        handle.dispose();
      }
    });

void main() {
  group('the reader', () {
    _semanticsTest('lists the visible text and the actions of a page', (
      t,
    ) async {
      await t.pumpWidget(_samplePage());
      final s = _read(t);

      expect(s.text, containsAll(['收件箱', '今天有 3 件事要看']));
      final byLabel = {for (final n in s.nodes) n.label: n};
      final search = byLabel['搜索']!;
      expect(search.role, 'button');
      expect(search.actions, ['tap']);
      expect(search.at, '右上', reason: 'the corner where the user looks');
      expect(search.enabled, isTrue);

      final mute = s.nodes.firstWhere((n) => n.label.contains('静音'));
      expect(mute.role, 'switch');
      expect(mute.checked, isFalse);

      final field = s.nodes.firstWhere((n) => n.role == 'textField');
      expect(field.label, '回复');
      expect(field.actions, contains('setText'));

      final slider = s.nodes.firstWhere((n) => n.role == 'slider');
      expect(slider.actions, containsAll(['increase', 'decrease']));

      final row = s.nodes.firstWhere((n) => n.label.contains('Alice'));
      expect(row.actions, containsAll(['tap', 'longPress']));

      final off = s.nodes.firstWhere((n) => n.label == '提交');
      expect(off.enabled, isFalse, reason: 'a grey button is listed as off');
      expect(off.actions, isEmpty);

      // The same thing as the JSON the model reads.
      final json = orbScreenContract(s);
      expect(_find(json, '搜索'), {
        'id': search.id,
        'role': 'button',
        'label': '搜索',
        'at': '右上',
        'do': ['tap'],
      });
      expect(_find(json, '提交')!['disabled'], isTrue);
      expect(json['text'], contains('今天有 3 件事要看'));
    });

    _semanticsTest('leaves out everything the orb draws', (t) async {
      await t.pumpWidget(
        _samplePage(
          extra: Semantics(
            identifier: orbSemanticsIdentifier,
            container: true,
            child: Column(
              children: [
                const Text('向下划收起'),
                ElevatedButton(onPressed: () {}, child: const Text('Agent')),
              ],
            ),
          ),
        ),
      );
      final s = _read(t);
      expect(s.text, contains('收件箱'));
      expect(s.nodes.map((n) => n.label), isNot(contains('Agent')));
      expect(s.text, isNot(contains('向下划收起')));
    });

    _semanticsTest('a control nobody can name is flagged; a wrapper is not', (
      t,
    ) async {
      await t.pumpWidget(
        _samplePage(
          extra: Column(
            children: [
              IconButton(icon: const Icon(Icons.star), onPressed: () {}),
              InkWell(
                onTap: () {},
                child: Row(
                  children: [
                    Semantics(
                      container: true,
                      label: '收藏',
                      child: TextButton(
                        onPressed: () {},
                        child: const Text('收藏'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      final s = _read(t);
      final unnamed = s.nodes.where((n) => n.unnamed).toList();
      expect(unnamed, hasLength(1));
      expect(unnamed.single.role, 'button');
    });

    _semanticsTest(
      'a long page stays within the budget, the visible part first',
      (t) async {
        // A tall window, so that all of it is on the screen at once.
        t.view.physicalSize = const Size(412, 40000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  for (var i = 0; i < 400; i++)
                    SizedBox(
                      height: 40,
                      child: InkWell(
                        onTap: () {},
                        child: Text('第 $i 行 ${'很长的一行消息内容 ' * 12}'),
                      ),
                    ),
                  for (var i = 0; i < 300; i++)
                    SizedBox(height: 20, child: Text('说明文字 $i ${'字' * 100}')),
                ],
              ),
            ),
          ),
        );
        final s = _read(t);
        expect(
          s.nodes.length,
          greaterThan(300),
          reason: 'the page has them all',
        );
        final full = orbScreenContract(s);
        expect(_bytes(full), lessThanOrEqualTo(orbScreenBudgetFull));
        final arrival = orbScreenContract(s, detail: OrbScreenDetail.arrival);
        expect(_bytes(arrival), lessThanOrEqualTo(orbScreenBudgetArrival));
        expect(arrival.containsKey('text'), isFalse);
        // The first of the page comes first, and what was left out is said.
        final actions = _list(full['actions']);
        expect(actions, isNotEmpty);
        expect(actions.first['label'], startsWith('第 0 行'));
        expect(full['actionsOmitted'], greaterThan(0));
        expect(_list(arrival['actions']).first['label'], startsWith('第 0 行'));
        expect(arrival['actionsOmitted'], greaterThan(0));
        // And the guard of the wire does not have to cut it.
        final guarded = guardToolOutput({'screen': full, 'page': 'other'});
        expect(guarded.truncated, isFalse);
      },
    );
  });

  group('with the orb layer open', () {
    testWidgets('reads the page below it, and not the layer or the ball', (
      t,
    ) async {
      final f = OrbFixture(t);
      await f.setUp();
      addTearDown(f.tearDown);
      await f.pump();
      await f.openLayer();
      expect(find.text('向下划收起'), findsOneWidget);

      final screen = OrbScreen.of(f.w);
      final context = f.navKey.currentState!.overlay!.context;
      OrbScreenSnapshot? s;
      unawaited(screen.read(context).then((v) => s = v));
      for (var i = 0; i < 12 && s == null; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(s, isNotNull);
      expect(
        [...s!.text, ...s!.nodes.map((n) => n.label)],
        contains('page'),
        reason: 'the page behind the layer',
      );
      final labels = s!.nodes.map((n) => n.label).toList();
      expect(s!.text, isNot(contains('向下划收起')));
      expect(labels, isNot(contains('Agent')));
      expect(labels, isNot(contains('发送')));
      expect(screen.revealing.value, 0);

      // The layer blocks the page again for everyone else once it is read.
      await t.pump(const Duration(milliseconds: 100));
      final handle = t.ensureSemantics();
      await t.pump();
      final blocked = _read(t);
      handle.dispose();
      expect(blocked.nodes.map((n) => n.label), isNot(contains('page')));
    });
  });

  group('the tools', () {
    late Fixture fx;
    late OrbScreen screen;

    Future<Map<String, Object?>> run(
      WidgetTester t,
      OrbTool tool,
      Map<String, Object?> args,
    ) async {
      Map<String, Object?>? out;
      Object? failure;
      unawaited(
        tool
            .handler(args, fx.ctx)
            .then((v) => out = v, onError: (Object e) => failure = e),
      );
      for (var i = 0; i < 40 && out == null && failure == null; i++) {
        await fx.f.flush(t);
      }
      if (failure != null) throw failure!;
      expect(out, isNotNull, reason: '${tool.name} did not answer');
      return out!;
    }

    Future<Map<String, Object?>> nav(
      WidgetTester t,
      String name, [
      Map<String, Object?> args = const {},
    ]) => run(t, orbNavigationTools().firstWhere((x) => x.name == name), args);

    Future<Map<String, Object?>> act(
      WidgetTester t,
      Map<String, Object?> args,
    ) => run(t, orbScreenTools().single, args);

    /// The contract of the screen now, read by the same call the tools make.
    Future<Map<String, Object?>> readScreen(WidgetTester t) async {
      Map<String, Object?>? seen;
      unawaited(screen.contract(fx.ctx.navigatorContext).then((v) => seen = v));
      for (var i = 0; i < 20 && seen == null; i++) {
        await fx.f.flush(t);
      }
      return seen!;
    }

    Future<void> mount(WidgetTester t) async {
      fx = Fixture();
      await fx.mount(t);
      screen = OrbScreen.of(fx.ctx.workspace);
    }

    testWidgets('screen_action is the one tool of the screen', (t) async {
      final tools = orbScreenTools();
      expect(tools.map((e) => e.name), ['screen_action']);
      final params = tools.single.declaration['parameters']! as Map;
      expect(params['required'], ['id', 'action']);
      expect(
        ((params['properties']! as Map)['action']! as Map)['enum'],
        containsAll(['tap', 'longPress', 'setText', 'increase', 'decrease']),
      );
    });

    testWidgets('navigate brings the screen of the page it arrived at', (
      t,
    ) async {
      await mount(t);
      final r = await nav(t, 'navigate', {'page': 'activity'});
      final page = _map(r['page']);
      final screenJson = _map(page['screen']);
      expect(page['page'], 'activity');
      // The page's text is the data: only the controls ride on the screen.
      expect(screenJson.containsKey('text'), isFalse);
      expect(_find(screenJson, 'Unread')!['role'], 'checkbox');
      expect(_find(screenJson, 'Mark all read'), isNotNull);
      expect(_bytes(r), lessThan(agentToolOutputLimit));
      expect(guardToolOutput(r).truncated, isFalse);

      final other = await nav(t, 'navigate', {'target': '设置'});
      final settings = _map(_map(other['page'])['screen']);
      expect(
        settings['text'],
        isNotEmpty,
        reason: 'a page without a describer brings its visible text',
      );
      expect(_list(settings['actions']), isNotEmpty);
      await fx.f.close(t);
    });

    testWidgets('open_item brings the screen of the page it opened', (t) async {
      await mount(t);
      await nav(t, 'navigate', {'page': 'activity'});
      final r = await run(
        t,
        orbNavigationTools().firstWhere((x) => x.name == 'open_item'),
        {'n': 3},
      );
      expect(r['opened'], 3);
      final s = _map(r['screen']);
      expect(_list(s['actions']), isNotEmpty);
      await fx.f.close(t);
    });

    testWidgets('describe_page carries the data and the screen', (t) async {
      await mount(t);
      await nav(t, 'navigate', {'channel_id': 'ca'});
      final d = await nav(t, 'describe_page');
      expect(d['page'], 'conversation');
      expect(d['messages'], isNotEmpty, reason: 'the data layer stays');
      final s = _map(d['screen']);
      expect(_list(s['actions']), isNotEmpty);
      expect(_list(s['actions']).any((a) => a['role'] == 'textField'), isTrue);
      await fx.f.close(t);
    });

    testWidgets('screen_action taps a real button and the page shows it', (
      t,
    ) async {
      await mount(t);
      final r = await nav(t, 'navigate', {'page': 'activity'});
      final contract = _map(_map(r['page'])['screen']);
      final unread = _find(contract, 'Unread')!;
      expect(unread['checked'], isFalse);

      final done = await act(t, {'id': unread['id'], 'action': 'tap'});
      expect(done['ok'], isTrue, reason: '$done');
      final after = _map(done['snapshot']);
      expect(_find(after, 'Unread')!['checked'], isTrue);
      expect(_find(after, 'All')!['checked'], isFalse);
      await fx.f.close(t);
    });

    testWidgets('screen_action sets the text of a field without sending it', (
      t,
    ) async {
      await mount(t);
      final r = await nav(t, 'navigate', {'channel_id': 'ca'});
      final field = _list(_map(_map(r['page'])['screen'])['actions'])
          .firstWhere((a) => a['role'] == 'textField');
      expect((field['do']! as List), contains('setText'));

      final posts = fx.f.adapter.calls.length;
      final done = await act(t, {
        'id': field['id'],
        'action': 'setText',
        'text': '周五可以',
      });
      expect(done['ok'], isTrue, reason: '$done');
      expect(
        t
            .widgetList<EditableText>(find.byType(EditableText))
            .map((e) => e.controller.text),
        contains('周五可以'),
      );
      final written = fx.f.adapter.calls
          .skip(posts)
          .where((q) => q.method != 'GET');
      expect(written, isEmpty, reason: 'filled in, not sent');
      await fx.f.close(t);
    });

    testWidgets('a stale id is refused with a fresh snapshot', (t) async {
      await mount(t);
      final r = await nav(t, 'navigate', {'page': 'activity'});
      final old = _find(_map(_map(r['page'])['screen']), 'Unread')!;
      await nav(t, 'navigate', {'channel_id': 'ca'});
      final tapped = await act(t, {'id': old['id'], 'action': 'tap'});
      expect(tapped['ok'], isNull);
      expect(tapped['error'], isA<String>());
      final fresh = _map(tapped['snapshot']);
      expect(_list(fresh['actions']), isNotEmpty);
      expect(
        _find(fresh, 'Unread'),
        isNull,
        reason: 'the snapshot is of the page the person is on now',
      );
      expect((fresh['snapshot']! as int), greaterThan(0));

      final guess = await act(t, {'id': 'a99999', 'action': 'tap'});
      expect(guess['error'], isA<String>());
      expect(_map(guess['snapshot'])['actions'], isNotEmpty);
      // The retry the answer asks for works.
      final input = _list(fresh['actions'])
          .firstWhere((a) => a['role'] == 'textField');
      final retry = await act(t, {
        'id': input['id'],
        'action': 'setText',
        'text': 'ok',
      });
      expect(retry['ok'], isTrue, reason: '$retry');
      await fx.f.close(t);
    });

    testWidgets('an action the control does not offer says what it offers', (
      t,
    ) async {
      await mount(t);
      final r = await nav(t, 'navigate', {'page': 'activity'});
      final all = _find(_map(_map(r['page'])['screen']), 'All')!;
      final bad = await act(t, {
        'id': all['id'],
        'action': 'setText',
        'text': 'x',
      });
      expect(bad['error'], isA<String>());
      expect(bad['available'], ['tap']);
      await fx.f.close(t);
    });

    testWidgets('a button that sends asks first; only a retry goes through', (
      t,
    ) async {
      await mount(t);
      var sent = 0;
      unawaited(
        showDialog<void>(
          context: fx.ctx.navigatorContext,
          builder: (_) => AlertDialog(
            title: const Text('回复 Cody'),
            actions: [
              TextButton(onPressed: () {}, child: const Text('取消')),
              TextButton(onPressed: () => sent++, child: const Text('发送')),
              TextButton(
                onPressed: () => sent += 10,
                child: const Text('Delete channel'),
              ),
            ],
          ),
        ),
      );
      await fx.f.flush(t);
      final seen = await readScreen(t);
      final send = _find(seen, '发送')!;
      final remove = _find(seen, 'Delete')!;

      // Not even `confirmed` before the question was asked.
      final blind = await act(t, {
        'id': send['id'],
        'action': 'tap',
        'confirmed': true,
      });
      expect(blind['needsConfirm'], isTrue);
      expect(blind['describe'], contains('发送'));
      expect(sent, 0);

      final again = await act(t, {'id': send['id'], 'action': 'tap'});
      expect(again['needsConfirm'], isTrue);
      expect(sent, 0);

      final yes = await act(t, {
        'id': send['id'],
        'action': 'tap',
        'confirmed': true,
      });
      expect(yes['ok'], isTrue, reason: '$yes');
      expect(sent, 1);

      // An English word asks too, and a retry for another control does not
      // pass for this one.
      final del = await act(t, {'id': remove['id'], 'action': 'tap'});
      expect(del['needsConfirm'], isTrue);
      await fx.f.close(t);
    });

    testWidgets('the orb\'s confirm card is asked instead when it has one', (
      t,
    ) async {
      await mount(t);
      var sent = 0;
      unawaited(
        showDialog<void>(
          context: fx.ctx.navigatorContext,
          builder: (_) => AlertDialog(
            actions: [
              TextButton(onPressed: () => sent++, child: const Text('批准')),
            ],
          ),
        ),
      );
      await fx.f.flush(t);
      final approve = _find(await readScreen(t), '批准')!;
      final asked = <Map<String, Object?>>[];
      screen.ask = (args) async {
        asked.add(args);
        return {'status': 'needs_confirmation', 'preview': '点「批准」'};
      };
      addTearDown(() => screen.ask = null);
      final r = await act(t, {'id': approve['id'], 'action': 'tap'});
      expect(r['status'], 'needs_confirmation');
      expect(r.containsKey('needsConfirm'), isFalse);
      expect(asked, [
        {'id': approve['id'], 'action': 'tap'},
      ]);
      expect(sent, 0, reason: 'nothing is pressed until the card is agreed');
      await fx.f.close(t);
    });

    test('which labels are risky', () {
      for (final label in const [
        '发送',
        '删除频道',
        '移除成员',
        '批准',
        '合并',
        '发布',
        '退出',
        '归档',
        '退出登录',
        'Send',
        'Delete',
        'Remove member',
        'Approve',
        'Merge',
        'Publish',
        'Leave channel',
        'Archive',
        'Sign out',
        'Log out',
      ]) {
        expect(orbScreenRisky(label, 'button'), isTrue, reason: label);
      }
      for (final label in const [
        '搜索',
        'Search',
        'Resend later',
        'Sender',
        'Unread',
      ]) {
        expect(orbScreenRisky(label, 'button'), isFalse, reason: label);
      }
      expect(orbScreenRisky('Alice · ${'周五我们发送一份很长的说明 ' * 6}', 'row'), isFalse);
    });
  });

  group('the prompt', () {
    test('has a short 【屏幕】 section', () {
      final prompt = orbSystemPrompt(channels: '');
      final i = prompt.indexOf('【屏幕】');
      expect(i, greaterThanOrEqualTo(0));
      final section = prompt.substring(i, prompt.indexOf('\n', i));
      expect(section, contains('screen_action'));
      expect(section, contains('先读'));
      expect(section, contains('id'));
      expect(section.length, lessThan(420));
    });
  });
}
