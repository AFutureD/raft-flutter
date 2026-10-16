import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Fictional workspace: no real names, servers or data.
final _now = DateTime.utc(2026, 10, 15, 12);

String _ago(int hours) =>
    _now.subtract(Duration(hours: hours)).toIso8601String();

Map<String, dynamic> _task(
  String id,
  String status,
  int hoursAgo, {
  String title = 'Task',
  String? description,
  String? createdById,
  String createdByName = 'Zed',
  String? claimedById,
  String? claimedByName,
  String claimedByType = 'agent',
  String channel = 'Seed',
  String? threadChannelId,
  int number = 1,
}) => {
  'id': id,
  'taskNumber': number,
  'title': title,
  'description': description,
  'status': status,
  'channelId': 'ch-$channel',
  'channelName': channel,
  'threadChannelId': threadChannelId,
  'createdById': createdById ?? 'zed',
  'createdByType': 'user',
  'createdByName': createdByName,
  'claimedById': claimedById,
  'claimedByType': claimedById == null ? null : claimedByType,
  'claimedByName': claimedByName,
  'updatedAt': _ago(hoursAgo),
};

class _Server extends WorkspaceController {
  _Server(super.client);
  final tasks = <String, List<Map<String, dynamic>>>{};
  List<Map<String, dynamic>> inbox = [];
  final threads = <String, List<Map<String, dynamic>>>{};
  final failing = <String>{};
  final reads = <String>[];

  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) async {
    reads.add(path);
    if (failing.contains(path)) throw StateError('offline');
    if (path == '/tasks/server') {
      return {'tasks': tasks[query?['status']] ?? const []};
    }
    if (path.startsWith('/messages/channel/')) {
      return {'messages': threads[path.split('/').last] ?? const []};
    }
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> sharedQuery(String path, {Map<String, dynamic>? query}) async {
    if (path == '/channels/inbox') return {'items': inbox};
    return this.query(path, query: query);
  }
}

Map<String, dynamic> _msg(int seq, String who, String text, int hoursAgo) => {
  'id': 'm$seq',
  'seq': '$seq',
  'senderName': who,
  'content': text,
  'createdAt': _ago(hoursAgo),
};

void main() {
  late ActivityClient client;
  late _Server w;
  late AgentModeData data;

  setUp(() {
    AgentModeData.clearSession();
    client = ActivityClient()
      ..user = RaftRecord({'id': 'kevin', 'displayName': 'Kevin'});
    client.selectServer('s1');
    w = _Server(client)..server = RaftRecord({'id': 's1', 'role': 'owner'});
    data = AgentModeData(w, now: () => _now);
    w.tasks['in_review'] = [
      // Mentioned in the description; full text only lives there.
      _task(
        'task1',
        'in_review',
        24,
        title: '@Cardinal',
        description: '@Cardinal\n\n记住以下内容：项目设定共 6 条，请逐条写入长期记忆。@Kevin 请确认。',
        createdById: 'huanan',
        createdByName: 'Huanan',
        claimedById: 'cardinal',
        claimedByName: 'Cardinal',
        threadChannelId: 'th1',
        number: 1,
      ),
      // Created by me.
      _task(
        'task2',
        'in_review',
        11,
        title: '改个名字，叫 Wilson-Cindy @Cindy',
        createdById: 'kevin',
        createdByName: 'Kevin',
        claimedById: 'cindy',
        claimedByName: 'Cindy',
        channel: 'KevinClub',
        number: 2,
      ),
      // Somebody else's review: team, not mine.
      _task(
        'task3',
        'in_review',
        30,
        title: '整理发布说明',
        claimedById: 'ming',
        claimedByName: 'Ming',
        number: 3,
      ),
      // Assigned to me.
      _task(
        'task4',
        'in_review',
        3,
        title: '重构运维 App',
        claimedById: 'kevin',
        claimedByName: 'Kevin',
        claimedByType: 'user',
        number: 4,
      ),
    ];
    w.tasks['in_progress'] = [
      _task(
        'task5',
        'in_progress',
        5,
        title: 'PR #127 等全量检查，卡住了合并',
        createdById: 'kevin',
        createdByName: 'Kevin',
        claimedById: 'grok',
        claimedByName: 'Grok',
        channel: 'raft-flutter',
        number: 5,
      ),
      _task(
        'task6',
        'in_progress',
        9,
        title: '别人的卡住任务',
        claimedById: 'ming',
        claimedByName: 'Ming',
        number: 6,
      ),
      _task(
        'task7',
        'in_progress',
        1,
        title: '刚开始',
        createdById: 'kevin',
        claimedById: 'grok',
        claimedByName: 'Grok',
        number: 7,
      ),
    ];
    w.inbox = [
      {
        'kind': 'thread',
        'threadChannelId': 'th-m7',
        'parentChannelId': 'ch-M7',
        'parentChannelName': 'M7',
        'parentMessagePreview': '检测首片',
        'latestActivitySenderName': 'Cody',
        'latestActivityPreview': '@Kevin 首片 12 张里 2 张误检，继续跑全量还是先调阈值？',
        'lastActivityAt': _ago(0),
        'unreadCount': 1,
        'hasMention': true,
      },
      // Not a mention: ignored.
      {
        'kind': 'channel',
        'channelId': 'ch-x',
        'channelName': 'x',
        'unreadCount': 3,
        'hasMention': false,
      },
    ];
  });

  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  group('headlines', () {
    test('leading mentions and markdown are stripped', () {
      expect(
        AgentHeadlines.clean('@Cardinal\n\n记住以下内容：项目设定共 6 条，请逐条写入。'),
        '记住以下内容',
      );
      expect(
        AgentHeadlines.clean('## **修复** [登录页](https://example.test/a) 的 `bug`。后续再说'),
        '修复 登录页 的 bug',
      );
      expect(AgentHeadlines.clean('@A @B'), isEmpty);
      expect(
        AgentHeadlines.clean('改个名字，叫 Wilson-Cindy @Cindy'),
        '改个名字，叫 Wilson-Cindy',
      );
    });

    test('a long first sentence is cut with an ellipsis', () {
      final long = '修复' * 40;
      final clean = AgentHeadlines.clean(long);
      expect(clean.length, lessThanOrEqualTo(41));
      expect(clean, endsWith('…'));
    });

    test('rule writer names who did what and what is asked', () {
      const writer = RuleHeadlineWriter();
      expect(
        writer.write(
          const AgentHeadlineInput(
            status: 'in_review',
            text: '@Cardinal\n\n记住以下内容：项目设定共 6 条',
            claimer: 'Cardinal',
          ),
        ),
        'Cardinal 完成了「记住以下内容」，等你验收',
      );
      expect(
        writer.write(
          const AgentHeadlineInput(
            status: 'in_review',
            text: '这样可以吗？',
            claimer: 'Cindy',
          ),
        ),
        'Cindy 完成了「这样可以吗？」，等你确认',
      );
      expect(
        writer.write(
          const AgentHeadlineInput(
            status: 'in_review',
            text: '@Someone',
            claimer: null,
            number: 9,
          ),
        ),
        '任务 #9 已提交，等你验收',
      );
      expect(
        writer.write(
          const AgentHeadlineInput(
            status: 'in_progress',
            text: 'PR #127 等全量检查',
            claimer: 'Grok',
            idleHours: 5,
          ),
        ),
        'Grok 的「PR #127 等全量检查」5 小时没动，卡住了',
      );
    });

    test('a custom writer replaces the rules', () async {
      final custom = AgentModeData(
        w,
        now: () => _now,
        headlines: const _Shouting(),
      );
      final got = await custom.attention();
      expect(got.items.first.headline, 'HEADLINE');
    });
  });

  group('ownership and counts', () {
    test('only my tasks wait for a decision; the rest is team progress', () async {
      final got = await data.attention();
      expect([for (final i in got.decisions) i.taskId], [
        'task1',
        'task2',
        'task4',
      ]);
      expect(got.team.map((t) => t.id), containsAll(['task3', 'task6']));
      expect(got.teamCount, 2);
      expect(got.teamLabel, '2');
      expect(got.capped, isFalse);
      expect(got.decisionCount, 3);
      expect(got.blockedCount, 1);
      expect(got.mentionCount, 1);
    });

    test('a capped query is not shown as an exact number', () async {
      w.tasks['in_review'] = [
        for (var i = 0; i < 50; i++)
          _task('other$i', 'in_review', 2, number: 100 + i),
        ...w.tasks['in_review']!,
      ];
      final got = await data.attention();
      expect(got.capped, isTrue);
      expect(got.teamLabel, endsWith('+'));
      expect(got.teamLabel, isNot('50'));
      expect(got.decisionCount, 3);
    });

    test('no user means nothing is mine', () async {
      client.user = null;
      final got = await data.attention();
      expect(got.decisions, isEmpty);
      expect(got.teamCount, greaterThan(0));
    });

    test('only stalled work of mine is blocked', () async {
      final got = await data.attention();
      expect(got.blocked.map((i) => i.taskId), ['task5']);
      expect(got.blocked.single.priority, AgentPriority.blocked);
      expect(got.blocked.single.ask, '解除阻塞');
      expect(got.blocked.single.reason, '卡住合并');
    });

    test('mentions come from the inbox and keep the sender', () async {
      final got = await data.attention();
      final m = got.mentions.single;
      expect(m.reason, '点名找你');
      expect(m.waiters, ['Cody']);
      expect(m.headline, contains('Cody'));
      expect(m.headline, contains('M7'));
      expect(m.askLine, '回答一个问题');
      expect(m.channelName, 'M7');
    });

    test('a task already in my decisions is not repeated as a mention', () async {
      w.inbox.add({
        'kind': 'thread',
        'threadChannelId': 'th1',
        'parentChannelId': 'ch-Seed',
        'parentChannelName': 'Seed',
        'taskNumber': 1,
        'taskStatus': 'in_review',
        'latestActivitySenderName': 'Cardinal',
        'latestActivityPreview': '@Kevin 已记住',
        'lastActivityAt': _ago(1),
        'unreadCount': 1,
        'hasMention': true,
      });
      final got = await data.attention();
      expect(got.mentionCount, 1);
    });
  });

  group('cards', () {
    test('content comes from the full task text, not the first line', () async {
      final got = await data.attention();
      final first = got.decisions.first;
      expect(first.headline, 'Cardinal 完成了「记住以下内容」，等你确认');
      expect(first.headline, isNot(contains('@')));
      expect(first.ask, '确认');
      expect(first.channelName, 'Seed');
      expect(first.threadTitle, '记住以下内容');
      expect(first.waiters, ['Huanan', 'Cardinal']);
      expect(first.canApprove, isTrue);
      expect(first.action, AgentAction.approve);
    });

    test('ranking: waiting time x ownership x people waiting', () async {
      final got = await data.attention();
      expect([for (final i in got.items) i.taskId ?? i.id], [
        'task1',
        'task2',
        'task4',
        'task5',
        isNot(anyOf('task1', 'task2', 'task4', 'task5')),
      ]);
      final ranks = got.decisions.map((i) => i.score).toList();
      expect(ranks, [...ranks]..sort((a, b) => b.compareTo(a)));
      expect(got.decisions[0].reason, '2 人在等');
      expect(got.decisions[1].reason, '你派的任务');
      expect(got.decisions[2].reason, '指给你的任务');
      expect(got.decisions[0].waitValue, 24);
      expect(got.decisions[0].waitUnit, '小时');
    });

    test('a mention outweighs an equally old created task', () async {
      w.tasks['in_review'] = [
        _task(
          'a',
          'in_review',
          5,
          title: '一',
          createdById: 'kevin',
          claimedById: 'cindy',
          claimedByName: 'Cindy',
        ),
        _task(
          'b',
          'in_review',
          5,
          title: '二 @Kevin 看一下',
          createdById: 'cindy',
          createdByName: 'Cindy',
          claimedById: 'cindy',
          claimedByName: 'Cindy',
          number: 2,
        ),
      ];
      final got = await data.attention();
      expect(got.decisions.map((i) => i.taskId), ['b', 'a']);
      expect(got.decisions.first.reason, '点名找你');
    });

    test('the last thread messages become progress; the last is the quote', () async {
      w.threads['th1'] = [
        _msg(3, 'Cardinal', '已记住 6 条', 1),
        _msg(1, 'Huanan', '@Cardinal 记住设定', 5),
        _msg(2, 'Cardinal', '正在写入 4 / 6', 3),
      ];
      final got = await data.attention();
      final p = got.decisions.first.progress;
      expect(p.map((l) => l.text), ['@Cardinal 记住设定', '正在写入 4 / 6', '已记住 6 条']);
      expect(got.decisions.first.quote!.who, 'Cardinal');
      expect(got.decisions.first.quote!.text, '已记住 6 条');
    });

    test('a failing thread read falls back to the task text', () async {
      w.failing.add('/messages/channel/th1');
      final got = await data.attention();
      final first = got.decisions.first;
      expect(first.progress, isNotEmpty);
      expect(first.quote!.text, contains('记住以下内容'));
    });

    test('header facts: urgent line names who waits and for how long', () async {
      final got = await data.attention();
      expect(got.urgent, 'Cardinal 的确认已经等了 24 小时，Huanan 也在等你');
      expect(AgentAttention.scopeNote, '只统计你创建、指派给你、或点名你确认的事项');
    });

    test('hiding items recounts without touching the rest', () async {
      final got = await data.attention();
      final less = got.without({got.decisions.first.id});
      expect(less.decisionCount, 2);
      expect(less.blockedCount, 1);
      expect(got.decisionCount, 3);
      expect(less.urgent, isNot(got.urgent));
    });

    test('the accepted result is kept for the next visit', () async {
      expect(AgentModeData.cached(w), isNull);
      final got = await data.attention();
      AgentModeData.remember(w, got);
      expect(AgentModeData.cached(w), same(got));
      AgentModeData.clearSession();
      expect(AgentModeData.cached(w), isNull);
    });
  });
}

class _Shouting implements AgentHeadlineWriter {
  const _Shouting();
  @override
  String write(AgentHeadlineInput input) => 'HEADLINE';
}
