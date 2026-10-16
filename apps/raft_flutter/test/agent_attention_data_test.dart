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

  /// When set, /tasks/server answers like the server: [serverPage] rows per
  /// page and a `next_cursor` (an offset) while rows remain.
  int? serverPage;
  final taskQueries = <Map<String, dynamic>>[];
  int? failPageAfter;

  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) async {
    reads.add(path);
    if (failing.contains(path)) throw StateError('offline');
    if (path == '/tasks/server') {
      taskQueries.add({...?query});
      final all = tasks[query?['status']] ?? const [];
      final size = serverPage;
      if (size == null) return {'tasks': all};
      final from = int.tryParse('${query?['cursor'] ?? 0}') ?? 0;
      if (failPageAfter != null && from >= failPageAfter!) {
        throw StateError('page failed');
      }
      final to = (from + size).clamp(0, all.length);
      return {
        'tasks': all.sublist(from, to),
        'next_cursor': to < all.length ? '$to' : null,
      };
    }
    if (path.startsWith('/messages/channel/')) {
      return {'messages': threads[path.split('/').last] ?? const []};
    }
    return <String, dynamic>{};
  }

  @override
  Future<dynamic> sharedQuery(
    String path, {
    Map<String, dynamic>? query,
  }) async {
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
        AgentHeadlines.clean(
          '## **修复** [登录页](https://example.test/a) 的 `bug`。后续再说',
        ),
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
      expect(got.decisions.first.headline, 'HEADLINE');
    });
  });

  group('ownership and counts', () {
    test(
      'only my tasks wait for a decision; the rest is team progress',
      () async {
        final got = await data.attention();
        // By recency (3, 11 and 24 hours), not by how long they waited.
        expect(
          [for (final i in got.decisions) i.taskId],
          ['task4', 'task2', 'task1'],
        );
        expect(got.team.map((t) => t.id), containsAll(['task3', 'task6']));
        expect(got.teamCount, 2);
        expect(got.teamLabel, '2');
        expect(got.capped, isFalse);
        expect(got.decisionCount, 3);
        expect(got.blockedCount, 1);
        expect(got.mentionCount, 1);
      },
    );

    List<Map<String, dynamic>> others(int n) => [
      for (var i = 0; i < n; i++)
        _task('other$i', 'in_review', 2, number: 100 + i),
    ];

    test('pages past 50 rows, so the count after filtering is exact', () async {
      w.serverPage = 50;
      w.tasks['in_review'] = [...others(120), ...w.tasks['in_review']!];
      final got = await data.attention();
      // 120 + 6 rows read in three pages, then only mine are decisions.
      expect(w.taskQueries.where((q) => q['status'] == 'in_review').length, 3);
      expect(
        w.taskQueries
            .where((q) => q['status'] == 'in_review')
            .map((q) => q['cursor']),
        [null, '50', '100'],
      );
      expect(got.capped, isFalse);
      expect(got.decisionCount, 3);
      expect(got.teamLabel, isNot(endsWith('+')));
      expect(got.teamCount, 120 + 2);
    });

    test('a bound that was hit is shown as N+', () async {
      w.serverPage = 50;
      w.tasks['in_review'] = [
        ...others(AgentModeData.maxTaskRows + 100),
        ...w.tasks['in_review']!,
      ];
      final got = await data.attention();
      expect(got.capped, isTrue);
      expect(got.teamLabel, endsWith('+'));
      expect(
        w.taskQueries.where((q) => q['status'] == 'in_review').length,
        AgentModeData.maxTaskRows ~/ 50,
      );
    });

    test('exactly the bound with nothing more is not capped', () async {
      w.serverPage = 50;
      w.tasks['in_review'] = others(AgentModeData.maxTaskRows);
      final got = await data.attention();
      expect(got.capped, isFalse);
    });

    test('a later page that fails leaves the count open', () async {
      w.serverPage = 50;
      w.failPageAfter = 50;
      w.tasks['in_review'] = [...others(120), ...w.tasks['in_review']!];
      final got = await data.attention();
      expect(got.capped, isTrue);
    });

    test('a first page that fails is still a failed read', () async {
      w.failing.add('/tasks/server');
      expect(data.attention(), throwsStateError);
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
      expect(m.reason, '点名了你');
      expect(m.waiters, ['Cody']);
      expect(m.headline, startsWith('Cody：'));
      expect(m.excerpt, contains('继续跑全量还是先调阈值'));
      expect(m.place, '#M7 › 检测首片');
      expect(m.askLine, '回复 Cody');
      expect(m.channelName, 'M7');
    });

    test(
      'a task already in my decisions is not repeated as a mention',
      () async {
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
      },
    );
  });

  group('cards', () {
    test('content comes from the full task text, not the first line', () async {
      final got = await data.attention();
      final first = got.decisions.firstWhere((i) => i.taskId == 'task1');
      expect(first.headline, 'Cardinal 完成了「记住以下内容」，等你确认');
      expect(first.headline, isNot(contains('@')));
      expect(first.ask, '确认');
      expect(first.channelName, 'Seed');
      expect(first.threadTitle, '记住以下内容');
      expect(first.waiters, ['Huanan', 'Cardinal']);
      expect(first.canApprove, isTrue);
      expect(first.action, AgentAction.approve);
    });

    test('ranking: Activity first, decisions by recency, not by waiting', () async {
      final got = await data.attention();
      expect(
        [for (final i in got.items) i.taskId ?? i.id],
        [
          // The App's Activity rows, as the server orders them ...
          'activity:thread:th-m7',
          'activity:channel:ch-x',
          // ... and the tasks that wait for a decision after them, the most
          // recently touched first (3, 5, 11 and 24 hours ago).
          'task4',
          'task5',
          'task2',
          'task1',
        ],
      );
      final task1 = got.decisions.firstWhere((i) => i.taskId == 'task1');
      expect(task1.reason, '2 人在等');
      expect(
        got.decisions.firstWhere((i) => i.taskId == 'task2').reason,
        '你派的任务',
      );
      expect(
        got.decisions.firstWhere((i) => i.taskId == 'task4').reason,
        '指给你的任务',
      );
      expect(task1.waitValue, 24);
      expect(task1.waitUnit, '小时');
      expect(task1.kind, AgentItemKind.decision);
    });

    test('two equally recent tasks: the more direct one first', () async {
      w.inbox = [];
      w.tasks['in_review'] = [
        _task('c', 'in_review', 4, title: '三', createdById: 'kevin', number: 3),
        _task(
          'd',
          'in_review',
          4,
          title: '四 @Kevin',
          createdById: 'cindy',
          number: 4,
        ),
      ];
      w.tasks['in_progress'] = [];
      final got = await data.attention();
      expect([for (final i in got.items) i.taskId], ['d', 'c']);
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

    test(
      'the last thread messages become progress; the last is the quote',
      () async {
        w.threads['th1'] = [
          _msg(3, 'Cardinal', '已记住 6 条', 1),
          _msg(1, 'Huanan', '@Cardinal 记住设定', 5),
          _msg(2, 'Cardinal', '正在写入 4 / 6', 3),
        ];
        final got = await data.attention();
        final first = got.decisions.firstWhere((i) => i.taskId == 'task1');
        expect(first.progress.map((l) => l.text), [
          '@Cardinal 记住设定',
          '正在写入 4 / 6',
          '已记住 6 条',
        ]);
        expect(first.quote!.who, 'Cardinal');
        expect(first.quote!.text, '已记住 6 条');
      },
    );

    test('a failing thread read falls back to the task text', () async {
      w.failing.add('/messages/channel/th1');
      final got = await data.attention();
      final first = got.decisions.firstWhere((i) => i.taskId == 'task1');
      expect(first.progress, isNotEmpty);
      expect(first.quote!.text, contains('记住以下内容'));
    });

    test(
      'header facts: urgent line names who waits and for how long',
      () async {
        final got = await data.attention();
        // The top of the home is the newest Activity row.
        expect(
          got.urgent,
          'Cody在#M7 › 检测首片，点名了你：@Kevin 首片 12 张里 2 张误检，继续跑全量还是先调阈值？（1 分钟前）',
        );
        // A task that waits for a decision still says who waits and how long.
        expect(
          got.decisions.firstWhere((i) => i.taskId == 'task1').urgent,
          'Cardinal 的确认已经等了 24 小时，Huanan 也在等你',
        );
        expect(AgentAttention.scopeNote, contains('任务只统计你创建、指派给你、或点名你确认的事项'));
      },
    );

    test('hiding items recounts without touching the rest', () async {
      final got = await data.attention();
      final less = got.without({
        got.decisions.firstWhere((i) => i.taskId == 'task1').id,
      });
      expect(less.decisionCount, 2);
      expect(less.blockedCount, 1);
      expect(got.decisionCount, 3);
      expect(got.without({got.top!.id}).urgent, isNot(got.urgent));
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

  group('stale tasks', () {
    test('a task nobody touched for days is in the stale group, not the feed', () async {
      w.tasks['in_review'] = [
        _task(
          'old1',
          'in_review',
          24 * 6,
          title: '很久以前交的',
          createdById: 'kevin',
          number: 21,
        ),
        _task('new1', 'in_review', 2, title: '刚交的', createdById: 'kevin', number: 22),
      ];
      w.tasks['in_progress'] = [
        _task(
          'old2',
          'in_progress',
          24 * 4,
          title: '早就没动了',
          createdById: 'kevin',
          claimedById: 'grok',
          claimedByName: 'Grok',
          number: 23,
        ),
      ];
      final got = await data.attention();
      expect([for (final i in got.items) i.taskId ?? i.id], [
        'activity:thread:th-m7',
        'activity:channel:ch-x',
        'new1',
      ]);
      // The least stale first: what was touched last may still be alive.
      expect([for (final i in got.stale) i.taskId], ['old2', 'old1']);
      expect(got.stale.every((i) => i.kind == AgentItemKind.stale), isTrue);
      expect(got.stale.first.idle, isTrue);
      expect(got.stale.first.waitUnit, '天');
      // The stale group counts apart; it is never the top and is not a decision.
      expect(got.staleCount, 2);
      expect(got.decisionCount, 1);
      expect(got.top!.isActivity, isTrue);
      expect(got.listed(open: false), hasLength(3));
      expect(got.listed(open: true), hasLength(5));
      expect(got.summary, contains('2 件很久没动'));
    });
  });

  group('the feed', () {
    test('a decision is placed among the Activity rows by recency', () async {
      w.tasks['in_review'] = [
        _task('t-mid', 'in_review', 5, title: '中间的', createdById: 'kevin', number: 31),
      ];
      w.tasks['in_progress'] = [];
      w.inbox = [
        for (final (i, hours) in [1, 9].indexed)
          {
            'kind': 'channel',
            'channelId': 'ch$i',
            'channelName': 'c$i',
            'lastMessageAt': _ago(hours),
            'lastMessagePreview': 'm$i',
            'unreadCount': 1,
          },
      ];
      final got = await data.attention();
      expect([for (final i in got.items) i.taskId ?? i.id], [
        'activity:channel:ch0',
        't-mid',
        'activity:channel:ch1',
      ]);
    });

    test('the Activity row of a task I decide gains the decision', () async {
      w.tasks['in_review'] = [
        _task(
          't1',
          'in_review',
          6,
          title: '待验收的',
          createdById: 'kevin',
          number: 41,
          channel: 'Seed',
        ),
      ];
      w.tasks['in_progress'] = [];
      w.inbox = [
        {
          'kind': 'thread',
          'threadChannelId': 'th-41',
          'parentChannelId': 'ch-Seed',
          'parentChannelName': 'Seed',
          'parentMessagePreview': '待验收的',
          'taskNumber': 41,
          'taskStatus': 'in_review',
          'latestActivitySenderName': 'Grok',
          'latestActivityPreview': '做完了，请看',
          'lastActivityAt': _ago(1),
          'unreadCount': 2,
        },
      ];
      final got = await data.attention();
      final only = got.items.single;
      expect(only.id, 'activity:thread:th-41');
      expect(only.isActivity, isFalse);
      expect(only.kind, AgentItemKind.decision);
      expect(only.canApprove, isTrue);
      expect(only.taskId, 't1');
      // It keeps what the row said.
      expect(only.excerpt, '做完了，请看');
      expect(only.unread, 2);
    });

    test('the rows are the first page of the inbox, newest first', () async {
      final items = data.activityItems([
        for (var i = 0; i < 3; i++)
          {
            'kind': 'dm',
            'channelId': 'd$i',
            'channelName': 'p$i',
            'lastMessageAt': _ago(i + 1),
            'lastMessagePreview': 'hello $i',
            'lastMessageSenderName': 'P$i',
            'lastMessageSenderId': 'p$i',
            'unreadCount': i == 0 ? 2 : 0,
          },
      ]);
      expect([for (final i in items) i.id], [
        'activity:dm:d0',
        'activity:dm:d1',
        'activity:dm:d2',
      ]);
      expect(items.first.reason, '私信你');
      expect(items.first.unread, 2);
      expect(items.first.place, startsWith('@'));
      expect(items.last.unread, 0);
      expect(items.first.tone, HfTone.info);
    });
  });
}

class _Shouting implements AgentHeadlineWriter {
  const _Shouting();
  @override
  String write(AgentHeadlineInput input) => 'HEADLINE';
}
