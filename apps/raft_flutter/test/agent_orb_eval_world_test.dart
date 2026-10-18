import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_service.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_run.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenarios.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_world.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/orb_open.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_services_fixture.dart';

/// The fixture workspace: it serves what a scenario declares to the app's own
/// WorkspaceController, and every write is recorded and answered, never sent.

OrbEvalScenario scenario(String id) =>
    orbEvalScenarios.firstWhere((s) => s.id == id);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the workspace holds the channels, DMs, unread counts and people the '
      'scenario declares', () async {
    final world = await OrbEvalWorld.create(scenario('A1').data());
    addTearDown(world.dispose);
    final w = world.workspace;
    expect(w.channels.map((c) => c.name), [
      'raft-flutter',
      'design',
      'swift-workflow',
    ]);
    expect(w.channels.firstWhere((c) => c.name == 'design').joined, isFalse);
    expect(w.dms.map((c) => c.peerLabel), ['Cody', 'Alice']);
    expect(w.unread[evalId('raft-flutter')], 3);
    expect(w.client.user!.id, evalMe.id);
    expect(w.server!.string('slug'), 'fixture');
    // Members and agents come by the app's own reads.
    final agents = await w.query('/agents') as List;
    expect(agents.map((a) => a['displayName']), [
      'Cody',
      'Grok',
      'CodexMac',
      '八戒',
    ]);
    final members = await w.query('/servers/$evalServerId/members') as List;
    expect(members.map((m) => m['displayName']), ['Sam', 'Alice']);
    expect(world.writes.where((x) => !orbEvalIsBenignWrite(x)), isEmpty);
  });

  test('messages, the Activity and tasks answer as the server would', () async {
    final world = await OrbEvalWorld.create(scenario('C3').data());
    addTearDown(world.dispose);
    final w = world.workspace;
    final tasks = await w.query(
      '/tasks/server',
      query: {'status': 'in_review'},
    );
    expect((tasks['tasks'] as List).single['taskNumber'], 136);
    expect(
      (await w.query('/tasks/server', query: {'status': 'done'}))['tasks'],
      isEmpty,
    );
    final channel = await w.query(
      '/tasks/channel/${evalId('raft-flutter')}/number/136',
    );
    expect(channel['task']['claimedByName'], 'Cody');
    final thread = await w.query('/messages/channel/${evalId('thread:t136')}');
    expect(thread['messages'], hasLength(1));

    final a1 = await OrbEvalWorld.create(scenario('A1').data());
    addTearDown(a1.dispose);
    final page = await a1.workspace.query(
      '/messages/channel/${evalId('raft-flutter')}',
      query: {'limit': 2},
    );
    final texts = [for (final m in page['messages'] as List) m['content']];
    expect(texts, ['@Sam 第 10 步可以合入吗？', '我看过了，没有问题。']);
    expect(page['hasMore'], isTrue);
    final inbox = await a1.workspace.query('/channels/inbox');
    expect((inbox['items'] as List).single['hasMention'], isTrue);
    expect(inbox['totalUnreadCount'], 3);
  });

  test('a write is recorded and answered OK, and nothing is sent', () async {
    final world = await OrbEvalWorld.create(scenario('A1').data());
    addTearDown(world.dispose);
    final w = world.workspace;
    expect(world.client.origin, endsWith('.invalid'));
    final answer = await w.command(
      'POST',
      '/channels/${evalId('raft-flutter')}/messages',
      data: {'content': '可以合'},
    );
    expect(answer, {'ok': true});
    await w.command('PATCH', '/tasks/x/status', data: {'status': 'done'});
    await w.command('DELETE', '/messages/y');
    expect(
      [for (final x in world.writes) x.toString()],
      containsAll([
        'POST /channels/${evalId('raft-flutter')}/messages',
        'PATCH /tasks/x/status',
        'DELETE /messages/y',
      ]),
    );
    final send = world.writes.firstWhere((x) => x.path.endsWith('/messages'));
    expect(send.body, {'content': '可以合'});
    // The app's read receipts and flag checks are not actions.
    expect(world.writes.where((x) => !orbEvalIsBenignWrite(x)), hasLength(3));
    expect(
      orbEvalIsBenignWrite(
        const OrbEvalWrite('POST', '/channels/c1/read', null),
      ),
      isTrue,
    );
    expect(
      orbEvalIsBenignWrite(const OrbEvalWrite('PUT', '/tasks/1', null)),
      isFalse,
    );
  });

  test(
    'a held Activity never answers; it is released when the world goes',
    () async {
      final data = scenario('B1').data()..holdInbox = true;
      final world = await OrbEvalWorld.create(data);
      var answered = false;
      final read = world.workspace
          .query('/channels/inbox')
          .then((_) => answered = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(answered, isFalse);
      await world.dispose();
      await read;
      expect(answered, isTrue);
    },
  );

  test('every scenario builds a workspace; its ids are fixture ids', () async {
    for (final s in orbEvalScenarios) {
      final data = s.data();
      final world = await OrbEvalWorld.create(data);
      expect(world.workspace.channels, isNotEmpty, reason: s.id);
      expect(data.allIds, contains(evalMe.id), reason: s.id);
      expect(
        data.allIds.where(
          (id) => id.length > 30 && !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id),
        ),
        isEmpty,
        reason: '${s.id}: ids look like uuids',
      );
      await world.dispose();
    }
  });

  test('driving scenarios: the Activity puts Cody\'s question first, so '
      '"回他" means him', () async {
    for (final id in ['D1', 'D3', 'D8']) {
      final world = await OrbEvalWorld.create(scenario(id).data());
      addTearDown(world.dispose);
      // The rules' own words: no model, the same order as the app has.
      final b = await OrbBriefingService(world.workspace)
          .brief(OrbBriefScope.activity, full: true, remember: false);
      expect(b.needsYou.map((i) => i.who).take(3), [
        'Cody',
        'Alice',
        'Grok',
      ], reason: id);
    }
  });

  test(
    '"打开 X" is a navigate when X is one place the resolver is sure of',
    () async {
      final world = await OrbEvalWorld.create(scenario('C1').data());
      addTearDown(world.dispose);
      final directory = orbDirectoryOf(world.workspace);
      Map<String, Object?>? of(String said) => orbOpenArgs(said, directory);

      expect(of('打开 task 136'), {'task_number': 136});
      expect(of('打开任务 136'), {'task_number': 136});
      expect(of('帮我打开 #136'), {'task_number': 136});
      expect(of('进入动态'), {'page': 'activity'});
      expect(of('去 raft-flutter'), {'channel_id': evalId('raft-flutter')});
      expect(of('打开 Cody 私信'), {'dm_id': evalId('dm:cody')});

      // Not an order to open one place: more is asked, or nothing is named.
      expect(of('打开动态，什么需要我处理'), isNull);
      expect(of('去 raft-flutter 看看谁找我'), isNull);
      expect(of('去 Roughslutter'), isNull);
      expect(of('任务 136 怎么样了'), isNull);
      expect(of('打开动态里的第一条消息'), isNull);
      expect(of('确认'), isNull);
      expect(of('看看 Cody 私信'), isNull);
      expect(of(''), isNull);
    },
  );

  testWidgets('the real navigation tool moves the real phone shell over the '
      'fixture', (t) async {
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final world = (await t.runAsync(
      () => OrbEvalWorld.create(scenario('A1').data()),
    ))!;
    final w = world.workspace;
    final key = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        theme: raftTheme(RaftFamily.brutal),
        home: withAppServices(
          WorkspaceView(
            controller: w,
            appearance: RaftAppearance(light: RaftFamily.brutal),
            onAppearance: (_) async {},
            onLogout: () async {},
          ),
        ),
      ),
    );
    await t.pump(const Duration(seconds: 1));
    final ctx = OrbToolContext(
      workspace: w,
      navigatorContext: key.currentState!.overlay!.context,
      operating: ValueNotifier(false),
    );
    addTearDown(ctx.operating.dispose);
    final navigate = orbNavigationTools().firstWhere(
      (e) => e.name == 'navigate',
    );
    Map<String, Object?>? out;
    navigate
        .handler({'channel_id': evalId('raft-flutter')}, ctx)
        .then((v) => out = v);
    for (var i = 0; i < 40 && out == null; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(out!['title'], '#raft-flutter');
    expect(
      w.location.toString(),
      '/s/fixture/channel/${evalId('raft-flutter')}',
    );
    final messages = ((out!['page'] as Map)['messages'] as List).cast<Map>();
    expect(messages.map((m) => m['text']), contains('@Sam 第 10 步可以合入吗？'));
    expect(
      world.writes.where((x) => !orbEvalIsBenignWrite(x)),
      isEmpty,
      reason: 'reading a channel writes nothing but its read receipt',
    );
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(world.dispose);
  });

  test('the catalog is scenarios-v1: ids in order, every writing scenario runs, unbuilt '
      'features expected to fail', () {
    final ids = orbEvalScenarios.map((s) => s.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids, [
      for (final g in 'ABCDEFG'.split(''))
        for (
          var n = 1;
          n <=
              const {
                'A': 7,
                'B': 9,
                'C': 5,
                'D': 9,
                'E': 5,
                'F': 2,
                'G': 4,
              }[g]!;
          n++
        )
          '$g$n',
    ]);
    List<String> withStatus(OrbEvalStatus st) => [
      for (final s in orbEvalScenarios)
        if (s.status == st) s.id,
    ];
    // The ✍️ scenarios run now that the orb has actions.
    expect(withStatus(OrbEvalStatus.skipped), isEmpty);
    expect(withStatus(OrbEvalStatus.expectedFail), [
      'D5',
      'D6',
      'D7',
      'E1',
      'E5',
    ]);
    for (final s in orbEvalScenarios) {
      if (s.status == OrbEvalStatus.skipped) {
        expect(s.note, 'needs actions', reason: s.id);
      } else {
        expect(s.checks, isNotEmpty, reason: s.id);
        expect(s.say.isNotEmpty || s.events.isNotEmpty, isTrue, reason: s.id);
      }
      if (s.status == OrbEvalStatus.expectedFail) {
        expect(s.note, startsWith('not built'), reason: s.id);
      }
    }
    expect(orbEvalSelect(['b2', 'C']).map((s) => s.id), [
      'B2',
      'C1',
      'C2',
      'C3',
      'C4',
      'C5',
    ]);
    expect(orbEvalSelect(const []), hasLength(41));
  });
}
