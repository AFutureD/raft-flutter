import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';

import 'support/agent_action_harness.dart';
import 'support/agent_capability_world.dart';

/// "昨天到今天": the digest across tasks, conversations and mentions, the
/// file filters of search, and switching workspace.
void main() {
  late ActionHarness h;

  setUp(() {
    h = ActionHarness();
  });
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> query(
    String capability, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await h.tools.run('query', {
      'capability': capability,
      'args': args,
    });
    return r!;
  }

  group('digest.since', () {
    setUp(() {
      h.w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'done')
            taskRow('t1', 1, 'done', title: '登录修复', updated: 2, claimedById: 'a-cody', claimedByName: 'Cody'),
          if (q?['status'] == 'in_review')
            taskRow('t2', 2, 'in_review', title: '导出报表', updated: 5, claimedById: 'a-cody', claimedByName: 'Cody'),
          if (q?['status'] == 'in_progress')
            taskRow('t3', 3, 'in_progress', title: '旧任务', updated: 60),
          if (q?['status'] == 'todo')
            taskRow('t4', 4, 'todo', title: '新建的', updated: 1),
        ],
      };
      h.w.routes['/channels/inbox'] = (_) => {
        'items': [
          {
            'kind': 'channel',
            'channelId': 'ch-general',
            'channelName': 'general',
            'lastMessageAt': hoursAgo(1),
            'lastMessagePreview': '周五上线',
            'lastMessageSenderName': 'Ada',
            'unreadCount': 3,
            'hasMention': false,
          },
          {
            'kind': 'channel',
            'channelId': 'ch-design',
            'channelName': 'design',
            'lastMessageAt': hoursAgo(4),
            'lastMessagePreview': '@Kevin 看下这版',
            'lastMessageSenderName': 'Cindy',
            'unreadCount': 1,
            'hasMention': true,
          },
          {
            'kind': 'channel',
            'channelId': 'ch-old',
            'channelName': 'old',
            'lastMessageAt': hoursAgo(90),
            'lastMessagePreview': '很久以前',
            'unreadCount': 0,
          },
        ],
      };
    });

    test('since yesterday, across tasks, conversations and mentions', () async {
      final r = (await query('digest.since'))['result'] as Map;
      expect(r['label'], '昨天 0 点起');
      final tasks = r['tasks'] as Map;
      expect(tasks['updated'], 3, reason: 'the 60-hour-old one is out');
      expect(tasks['byStatus'], {'done': 1, 'in_review': 1, 'todo': 1});
      final recent = (tasks['recent'] as List).cast<Map>();
      expect(recent.first['title'], '新建的', reason: 'newest first');
      expect(recent.map((t) => t['number']), [4, 1, 2]);
      final channels = r['channels'] as Map;
      expect(channels['active'], 2);
      expect((channels['rows'] as List).cast<Map>().map((c) => c['name']), [
        'general',
        'design',
      ]);
      final mentions = r['mentions'] as Map;
      expect(mentions['count'], 1);
      expect(((mentions['rows'] as List).single as Map)['name'], 'design');
      expect(r['unreadTotal'], 6);
    });

    test('a range or an exact start narrows it', () async {
      var r = (await query('digest.since', {'range': '24h'}))['result'] as Map;
      expect(r['label'], '最近 24 小时');
      expect((r['tasks'] as Map)['updated'], 3);
      r = (await query('digest.since', {
        'after': worldNow.subtract(const Duration(hours: 3)).toIso8601String(),
      }))['result'] as Map;
      expect((r['tasks'] as Map)['updated'], 2, reason: 'only 1h and 2h old');
      expect((r['channels'] as Map)['active'], 1);
      expect((r['mentions'] as Map)['count'], 0);
    });

    test('bad time and a start in the future are said', () async {
      expect('${(await query('digest.since', {'after': 'when'}))['error']}', contains('看不懂'));
      expect(
        '${(await query('digest.since', {'after': '2027-01-01T00:00:00Z'}))['error']}',
        contains('未来'),
      );
      expect('${(await query('digest.since', {'range': 'year'}))['error']}', contains('之一'));
    });

    test('a source that cannot be read does not hide the others', () async {
      h.w.routes['/channels/inbox'] = (_) => throw const RaftApiException('x');
      final r = (await query('digest.since'))['result'] as Map;
      expect((r['channels'] as Map)['problem'], contains('读不到'));
      expect((r['tasks'] as Map)['updated'], 3);
    });

    test('find answers the question', () async {
      for (final said in ['昨天到今天整体进展汇总一下', '我错过了什么', '给我一个日报']) {
        final r = await h.tools.run('find', {'intent': said});
        final ids = [for (final m in r!['matches'] as List) (m as Map)['id']];
        expect(ids.take(3), contains('digest.since'), reason: said);
      }
    });
  });

  group('search by file type and sender', () {
    Map<String, dynamic> hit(String id, String from, List<Map<String, dynamic>>? files) => {
      'id': id,
      'channelId': 'ch-design',
      'channelName': 'design',
      'senderId': from,
      'senderName': from == 'kevin' ? 'Kevin' : 'Ada',
      'content': '设计稿 $id',
      'createdAt': hoursAgo(3),
      'attachments': ?files,
    };
    final png = {'id': 'a1', 'filename': 'v2.png', 'mimeType': 'image/png'};
    final pdf = {'id': 'a2', 'filename': 'spec.pdf', 'mimeType': 'application/pdf'};

    test('messages.search keeps the ones with the kind of file asked', () async {
      h.w.routes['/messages/search'] = (_) => {
        'results': [
          hit('m1', 'kevin', [png]),
          hit('m2', 'kevin', [pdf]),
          hit('m3', 'kevin', const []),
          hit('m4', 'kevin', [png, pdf]),
        ],
      };
      var r = (await query('messages.search', {
        'q': '设计稿',
        'sender': 'Kevin',
        'attachment': 'image',
      }))['result'] as Map;
      expect((r['messages'] as List).cast<Map>().map((m) => m['id']), ['m1', 'm4']);
      expect(r['filteredBy'], contains('图片'));
      expect(h.w.queries['/messages/search']!['limit'], 20, reason: 'reads a full page to filter');
      expect(h.w.queries['/messages/search']!['senderId'], 'kevin');
      r = (await query('messages.search', {
        'q': '设计稿',
        'attachment': 'file',
      }))['result'] as Map;
      expect((r['messages'] as List).cast<Map>().map((m) => m['id']), ['m2', 'm4']);
    });

    test('a search that carries no file information cannot be filtered', () async {
      h.w.routes['/messages/search'] = (_) => {
        'results': [hit('m1', 'kevin', null)],
      };
      final r = await query('messages.search', {'q': '设计稿', 'attachment': 'image'});
      expect('${r['error']}', contains('没有附件信息'));
    });

    group('channels.files', () {
      setUp(() {
        h.w.routes['/channels/ch-design/files'] = (q) => {
          'files': [
            {'id': 'f1', 'filename': 'v2.png', 'mimeType': 'image/png', 'sizeBytes': 10, 'messageId': 'm1', 'createdAt': hoursAgo(3)},
            {'id': 'f2', 'filename': 'spec.pdf', 'mimeType': 'application/pdf', 'sizeBytes': 20, 'messageId': 'm2', 'createdAt': hoursAgo(4)},
            {'id': 'f3', 'filename': 'v1.png', 'mimeType': 'image/png', 'sizeBytes': 30, 'messageId': 'm3', 'createdAt': hoursAgo(5)},
          ],
        };
        h.w.ledger.ingest([
          hit('m1', 'kevin', [png]),
          hit('m2', 'ada', [pdf]),
          hit('m3', 'ada', [png]),
        ], expectedGeneration: h.w.ledger.generation);
      });

      test('by kind', () async {
        final r = (await query('channels.files', {'channel': 'design', 'kind': 'image'}))['result'] as Map;
        expect((r['files'] as List).cast<Map>().map((f) => f['id']), ['f1', 'f3']);
        expect(r['filteredBy'], '图片');
        final docs = (await query('channels.files', {'channel': 'design', 'kind': 'document'}))['result'] as Map;
        expect((docs['files'] as List).cast<Map>().map((f) => f['id']), ['f2']);
      });

      test('by who sent it: "Kevin 发的那个设计图"', () async {
        final r = (await query('channels.files', {
          'channel': 'design',
          'kind': 'image',
          'sender': 'Kevin',
        }))['result'] as Map;
        final files = (r['files'] as List).cast<Map>();
        expect(files.map((f) => f['id']), ['f1']);
        expect(files.single['from'], 'Kevin');
        expect(r['filteredBy'], contains('Kevin 发的'));
      });

      test('no filter reads as before', () async {
        final r = (await query('channels.files', {'channel': 'design'}))['result'] as Map;
        expect(r['count'], 3);
        expect(r.containsKey('filteredBy'), isFalse);
        expect(h.w.queries['/channels/ch-design/files'], {'limit': 10});
      });
    });
  });

  group('servers.switch', () {
    setUp(() {
      h.w.servers = [
        RaftRecord({'id': 's1', 'name': 'Fixture HQ', 'slug': 'hq', 'role': 'owner'}),
        RaftRecord({'id': 's2', 'name': 'Myoland', 'slug': 'myoland', 'role': 'member'}),
        RaftRecord({'id': 's3', 'name': 'Myoland Labs', 'slug': 'labs', 'role': 'member'}),
      ];
    });

    test('previews, switches with the server menu\'s call, tells the screen', () async {
      var told = 0;
      h.tools = h.rebuild(
        env: AgentCapabilityEnv(onServerSwitched: () => told++),
      );
      final r = await h.act('servers.switch', {'server': 'labs'});
      expect(h.summary(r), '从“Fixture HQ”切换到工作区“Myoland Labs”');
      expect(h.changes(r).single, '当前工作区: Fixture HQ → Myoland Labs');
      expect(h.w.switched, isEmpty);
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.w.switched, ['s3']);
      expect(h.w.server?.id, 's3');
      expect(told, 1);
      expect((done['result'] as Map)['serverId'], 's3');
      expect((done['undo'] as Map)['label'], '切回 Fixture HQ');
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone', reason: '$undone');
      expect(h.w.switched, ['s3', 's1']);
      expect(told, 2);
    });

    test('by name, an exact name beats a longer one', () async {
      final r = await h.act('servers.switch', {'server': 'Myoland'});
      expect(h.summary(r), contains('“Myoland”'));
      expect(r['status'], 'needs_confirmation');
    });

    test('refused: where you are, an unknown one, a vague one', () async {
      var r = await h.act('servers.switch', {'server': 'hq'});
      expect('${r['error']}', contains('已经在'));
      r = await h.act('servers.switch', {'server': 'nowhere'});
      expect('${r['error']}', contains('你加入的有'));
      r = await h.act('servers.switch', {'server': 'o'});
      expect('${r['error']}', contains('多个工作区'));
      expect(r['candidates'], isNotEmpty);
      expect(h.w.switched, isEmpty);
    });

    test('a switch the app did not take is a failure', () async {
      h.w.switchAccepted = false;
      final done = await h.run('servers.switch', {'server': 'labs'});
      expect(done['status'], 'failed', reason: '$done');
      expect('${done['error']}', contains('没有切换成功'));
    });
  });
}
