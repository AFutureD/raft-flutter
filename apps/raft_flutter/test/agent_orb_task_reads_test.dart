import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_tool_output.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_task_tools.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// The orb's task reads: lists by status, by assignee and "waiting on me /
/// stale", and one task by its number. The model gets titles, numbers, names
/// and how long a task has been still, never an id; the answer fits the tool
/// output limit.
void main() {
  late CapabilityWorld w;
  late ActivityClient client;

  setUp(() {
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.ledger.switchServer('s1');
    final rows = [
      // Cody has had it for four days.
      taskRow(
        't-141',
        141,
        'in_progress',
        title: '整理发布说明',
        claimedById: 'a-cody',
        claimedByName: 'Cody',
        updated: 100,
      ),
      // Kevin made it and Cody finished it: it waits for Kevin.
      taskRow(
        't-142',
        142,
        'in_review',
        title: '迁移旧的缓存',
        channel: 'design',
        claimedById: 'a-cody',
        claimedByName: 'Cody',
        updated: 5,
      ),
      // Ada made it: it waits for Ada, not for Kevin.
      taskRow(
        't-143',
        143,
        'in_review',
        title: '补充评审记录',
        claimedById: 'a-cody',
        claimedByName: 'Cody',
        createdById: 'ada',
        createdByName: 'Ada',
        updated: 80,
      ),
      taskRow('t-150', 150, 'todo', title: '写发布公告', updated: 2),
      taskRow('t-100', 100, 'done', title: '旧的任务', updated: 400),
    ];
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        for (final r in rows)
          if (q?['status'] == null || r['status'] == q?['status']) r,
      ],
    };
    w.routes['/tasks/channel/ch-general/number/141'] = (_) => {
      'task': {...rows[0], 'description': '卡在等设计稿。', 'revision': 2},
    };
    w.routes['/tasks/channel/ch-design/number/142'] = (_) => {
      'task': {...rows[1], 'description': '改动已完成。', 'revision': 1},
    };
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<Map<String, Object?>> list([Map<String, Object?> args = const {}]) =>
      orbListTasks(w, args, now: () => worldNow);

  List<Map<String, Object?>> tasksOf(Map<String, Object?> r) =>
      (r['tasks'] as List).cast<Map<String, Object?>>();

  test('the default list is what is open, the newest change first', () async {
    final r = await list();
    expect(r['total'], 4);
    expect(tasksOf(r).map((t) => t['number']), [150, 142, 143, 141]);
    expect(r['counts'], {'in_progress': 1, 'in_review': 2, 'todo': 1});
  });

  test('each row has the title, number, status, who, where, how long it has '
      'been still and what it waits for', () async {
    final r = await list({'status': 'in_review'});
    final mine = tasksOf(r).firstWhere((t) => t['number'] == 142);
    expect(mine, {
      'number': 142,
      'title': '迁移旧的缓存',
      'status': 'in_review',
      'statusText': '等验收',
      'assignee': 'Cody',
      'creator': 'Kevin',
      'channel': 'design',
      'idle': '5 小时',
      'idleHours': 5,
      'waitsFor': '等你验收',
      'waitingOnMe': true,
    });
  });

  test(
    'a task made by someone else waits for them, not for the person',
    () async {
      final r = await list({'status': 'in_review'});
      final other = tasksOf(r).firstWhere((t) => t['number'] == 143);
      expect(other['waitsFor'], '等 Ada 验收');
      expect(other['waitingOnMe'], isNot(true));
      expect(other['idle'], '3 天');
    },
  );

  test('by assignee: a name, me, and nobody', () async {
    final cody = await list({'assignee': 'cody'});
    expect(tasksOf(cody).map((t) => t['number']).toSet(), {141, 142, 143});
    final nobody = await list({'assignee': 'unassigned'});
    expect(tasksOf(nobody).map((t) => t['number']), [150]);
    expect(tasksOf(nobody).single['waitsFor'], '没人认领');
    final me = await list({'assignee': 'me'});
    expect(tasksOf(me), isEmpty);
  });

  test('waiting on me keeps what the person has to decide', () async {
    final r = await list({'waiting_on_me': true});
    expect(tasksOf(r).map((t) => t['number']), [142]);
    expect(r['waitingOnMe'], 1);
  });

  test(
    'stale keeps what nobody touched for three days, oldest first',
    () async {
      final r = await list({'stale': true});
      expect(tasksOf(r).map((t) => t['number']), [141, 143]);
      expect(tasksOf(r).every((t) => t['stale'] == true), isTrue);
      expect(r['stale'], 2);
    },
  );

  test(
    'a status that is not one is an error that says the valid ones',
    () async {
      final r = await list({'status': 'blocked'});
      expect(r['error'], contains('in_review'));
    },
  );

  test('done tasks can be listed on their own', () async {
    final r = await list({'status': 'done'});
    expect(tasksOf(r).single['number'], 100);
    expect(tasksOf(r).single['waitsFor'], isNull);
  });

  test(
    'a summary line counts by status in words, for "what state are they"',
    () async {
      final r = await list();
      expect(r['summary'], contains('进行中 1'));
      expect(r['summary'], contains('等验收 2'));
      expect(r['summary'], contains('待办 1'));
    },
  );

  test('no id leaves a read: not the task, the channel, the owner or the '
      'thread', () async {
    final list1 = jsonEncode(await list());
    for (final id in [
      't-141',
      't-142',
      'ch-general',
      'ch-design',
      'a-cody',
      'kevin',
    ]) {
      expect(list1, isNot(contains(id)), reason: id);
    }
    final detail = jsonEncode(await orbTaskDetail(w, {'number': 141}));
    for (final id in ['t-141', 'ch-general', 'a-cody']) {
      expect(detail, isNot(contains(id)), reason: id);
    }
  });

  test('a read stays inside the tool output limit', () async {
    final many = [
      for (var i = 0; i < 300; i++)
        taskRow(
          't-$i',
          1000 + i,
          'in_progress',
          title: '很长的任务标题 ${'字' * 100} $i',
          claimedById: 'a-cody',
          claimedByName: 'Cody',
          updated: i,
        ),
    ];
    w.routes['/tasks/server'] = (q) => {
      'tasks': q?['status'] == 'in_progress' ? many : [],
    };
    final r = await list({'limit': 30});
    final guarded = guardToolOutput(r);
    expect(guarded.truncated, isFalse);
    expect(guarded.bytes, lessThanOrEqualTo(agentToolOutputLimit));
    expect(tasksOf(r).length, inInclusiveRange(1, 30));
    expect(r['total'], 300);
  });

  group('one task by its number', () {
    test('title, status, who, where, how long, what it waits for and the '
        'thread', () async {
      final r = await orbTaskDetail(w, {'number': 141});
      final t = r['task'] as Map<String, Object?>;
      expect(t['number'], 141);
      expect(t['title'], '整理发布说明');
      expect(t['statusText'], '进行中');
      expect(t['assignee'], 'Cody');
      expect(t['creator'], 'Kevin');
      expect(t['channel'], 'general');
      expect(t['description'], '卡在等设计稿。');
      expect(t['idle'], isNotNull);
      expect(t['waitsFor'], 'Cody 在做');
      expect(t.containsKey('id'), isFalse);
      expect(t.containsKey('channelId'), isFalse);
    });

    test('a review the person owes says so', () async {
      final r = await orbTaskDetail(w, {'number': 142});
      expect((r['task'] as Map)['waitsFor'], '等你验收');
    });

    test('a number nobody has is an error, not a guess', () async {
      final r = await orbTaskDetail(w, {'number': 999});
      expect(r['error'], contains('999'));
    });

    test('no number asks for one', () async {
      final r = await orbTaskDetail(w, {});
      expect(r['error'], isNotNull);
    });
  });
}
