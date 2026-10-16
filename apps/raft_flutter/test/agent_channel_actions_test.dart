import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_action_board.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/channel_action_capabilities.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_action_harness.dart';

/// A client whose named requests (`PATCH /path`) fail.
class _Flaky extends ActivityClient {
  final failing = <String>{};
  @override
  Future<dynamic> request(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    bool authorized = true,
    bool retried = false,
    UploadCancellation? cancellation,
    void Function(int, int)? onSendProgress,
    Map<String, dynamic>? headers,
    bool acceptServerExit = false,
    Duration? receiveTimeout,
  }) {
    if (failing.contains('$method $path')) {
      throw const RaftApiException('offline');
    }
    return super.request(
      method,
      path,
      data: data,
      query: query,
      authorized: authorized,
      retried: retried,
      cancellation: cancellation,
      onSendProgress: onSendProgress,
      headers: headers,
      acceptServerExit: acceptServerExit,
      receiveTimeout: receiveTimeout,
    );
  }
}

/// Mute, pin, create a channel, add members.
void main() {
  late ActionHarness h;
  late _Flaky client;

  setUp(() {
    client = _Flaky();
    h = ActionHarness(withClient: client);
    h.w.channels = [
      ...h.w.channels,
      RaftChannel({'id': 'ch-random', 'name': 'random'}),
      RaftChannel({
        'id': 'ch-old',
        'name': 'old',
        'joined': true,
        'archivedAt': '2026-10-01T00:00:00Z',
      }),
    ];
    h.w.sidebarOrder = {
      'pinned': [
        {'kind': 'channel', 'id': 'ch-design'},
      ],
      'pinnedVersion': 2,
      'sectionPlacements': [
        {'kind': 'channel', 'id': 'ch-general', 'sectionId': 's1', 'position': 0},
        {'kind': 'channel', 'id': 'ch-design2', 'sectionId': 's1', 'position': 1},
      ],
    };
  });
  tearDown(() => h.dispose());

  group('channels.set_muted', () {
    test('previews, patches like the sidebar menu, shows it at once', () async {
      h.w.commandRoutes['PATCH /channels/ch-general/notification-settings'] = (_) => {
        'activityMuted': true,
        'muteFromSeq': '77',
        'prefsVersion': 5,
      };
      final r = await h.act('channels.set_muted', {'channel': 'general'});
      expect(h.summary(r), contains('静音#general'));
      expect(h.changes(r).single, '#general 静音: 否 → 是');
      expect(h.w.commands, isEmpty);
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.w.commands.single.$1, 'PATCH');
      expect(h.w.commands.single.$3, {'activityMuted': true});
      final held = h.w.channelById('ch-general')!;
      expect(held.flag('activityMuted'), isTrue);
      expect(held.json['muteFromSeq'], '77');
      expect((done['result'] as Map)['entity'], 'channel');
    });

    test('undo unmutes', () async {
      await h.run('channels.set_muted', {'channel': 'general'});
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone', reason: '$undone');
      expect(h.w.commands.last.$3, {'activityMuted': false});
    });

    test('unmute, and "already" is said', () async {
      h.w.channels = [
        for (final c in h.w.channels)
          c.id == 'ch-design' ? RaftChannel({...c.json, 'activityMuted': true}) : c,
      ];
      var r = await h.act('channels.set_muted', {'channel': 'design'});
      expect('${r['error']}', contains('已经静音'));
      r = await h.act('channels.set_muted', {'channel': 'design', 'muted': false});
      expect(h.changes(r).single, '#design 静音: 是 → 否');
      r = await h.act('channels.set_muted', {'channel': 'general', 'muted': false});
      expect('${r['error']}', contains('没有静音'));
    });

    test('DMs, unjoined and archived channels are refused', () async {
      for (final (ref, message) in [
        ('Ada', '私信不能静音'),
        ('random', '加入之后才能静音'),
        ('old', '已归档'),
        ('nowhere', '没有叫'),
      ]) {
        final r = await h.act('channels.set_muted', {'channel': ref});
        expect('${r['error']}', contains(message), reason: ref);
      }
      expect(h.w.commands, isEmpty);
    });

    test('a failure puts the row back and the card can retry', () async {
      h.w.commandError = const RaftApiException('offline');
      final done = await h.run('channels.set_muted', {'channel': 'general'});
      expect(done['status'], 'failed');
      expect(h.w.channelById('ch-general')!.flag('activityMuted'), isFalse);
      expect(h.board.records.single.phase, AgentActionPhase.failed);
    });
  });

  group('channels.set_pinned', () {
    test('pin: appends the ref and drops the row\'s section placement', () async {
      final r = await h.act('channels.set_pinned', {'channel': 'general'});
      expect(h.changes(r).single, '#general 置顶: 否 → 是');
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(client.posts, ['PATCH /servers/s1/sidebar-order']);
      final body = client.bodies.single as Map;
      expect(body['pinned'], [
        {'kind': 'channel', 'id': 'ch-design'},
        {'kind': 'channel', 'id': 'ch-general'},
      ]);
      expect((body['sectionPlacements'] as List).map((p) => (p as Map)['id']), [
        'ch-design2',
      ]);
      expect((done['undo'] as Map)['label'], '取消置顶');
    });

    test('unpin, and undo pins again', () async {
      final done = await h.run('channels.set_pinned', {
        'channel': 'design',
        'pinned': false,
      });
      expect(done['status'], 'done', reason: '$done');
      expect((client.bodies.single as Map)['pinned'], isEmpty);
      expect((client.bodies.single as Map).containsKey('sectionPlacements'), isFalse);
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone', reason: '$undone');
      expect((client.bodies.last as Map)['pinned'], [
        {'kind': 'channel', 'id': 'ch-design'},
      ]);
    });

    test('a DM pins as the person or agent it is with', () async {
      h.w.dms = [
        RaftChannel({
          'id': 'dm-1',
          'type': 'dm',
          'name': 'dm',
          'peerName': 'Ada',
          'peerId': 'ada',
          'peerType': 'user',
        }),
        RaftChannel({
          'id': 'dm-cody',
          'type': 'dm',
          'name': 'dm',
          'peerName': 'Cody',
          'peerId': 'a-cody',
          'peerType': 'agent',
        }),
      ];
      await h.run('channels.set_pinned', {'channel': 'Ada'});
      expect(((client.bodies.last as Map)['pinned'] as List).last, {
        'kind': 'human',
        'id': 'ada',
      });
      await h.run('channels.set_pinned', {'channel': 'Cody'});
      expect(((client.bodies.last as Map)['pinned'] as List).last, {
        'kind': 'agent',
        'id': 'a-cody',
      });
    });

    test('already as asked, archived, and an unreadable sidebar', () async {
      var r = await h.act('channels.set_pinned', {'channel': 'design'});
      expect('${r['error']}', contains('已经置顶'));
      r = await h.act('channels.set_pinned', {'channel': 'general', 'pinned': false});
      expect('${r['error']}', contains('没有置顶'));
      r = await h.act('channels.set_pinned', {'channel': 'old'});
      expect('${r['error']}', contains('已归档'));
      h.w.sidebarOrder = {};
      r = await h.act('channels.set_pinned', {'channel': 'general'});
      expect('${r['error']}', contains('读不到侧栏'));
      expect(client.posts.where((p) => p.startsWith('PATCH')), isEmpty);
    });

    test('a server that refuses is an error, not a silent success', () async {
      client.failing.add('PATCH /servers/s1/sidebar-order');
      final done = await h.run('channels.set_pinned', {'channel': 'general'});
      expect(done['status'], 'failed', reason: '$done');
      expect('${done['error']}', contains('服务器没有接受'));
      expect(h.w.sidebarOrder['pinned'], [
        {'kind': 'channel', 'id': 'ch-design'},
      ]);
    });
  });

  group('channels.create', () {
    test('creates with the dialog\'s payload and pulls people in', () async {
      h.w.commandRoutes['POST /channels'] = (_) => {'id': 'ch-launch', 'name': 'launch'};
      final r = await h.act('channels.create', {
        'name': '#launch',
        'description': '发布协调',
        'visibility': 'private',
        'members': ['Cody', 'Ada'],
      });
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect(h.summary(r), '新建私有频道 #launch，拉进 Cody、Ada');
      expect(h.changes(r), [
        '频道:  → #launch',
        '可见性:  → 私有',
        '简介:  → 发布协调',
        '成员:  → Cody、Ada',
      ]);
      expect(h.w.commands, isEmpty);
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.w.commands.single.$2, '/channels');
      expect(h.w.commands.single.$3, {
        'name': 'launch',
        'description': '发布协调',
        'visibility': 'private',
        'type': 'channel',
        'userIds': ['ada'],
        'agentIds': ['a-cody'],
      });
      expect(h.w.channelRefreshes, 1);
      expect((done['result'] as Map)['entity'], 'channel');
      expect((done['result'] as Map)['id'], 'ch-launch');
      expect(done.containsKey('undo'), isFalse);
    });

    test('a bare channel is public', () async {
      final r = await h.act('channels.create', {'name': 'ops'});
      expect(h.summary(r), '新建公开频道 #ops');
      await h.approve(r);
      expect((h.w.commands.single.$3 as Map)['visibility'], 'public');
      expect((h.w.commands.single.$3 as Map)['userIds'], isEmpty);
    });

    test('names follow the dialog\'s rule', () {
      expect(channelNameProblem('launch'), isNull);
      expect(channelNameProblem('发布_2'), isNull);
      expect(channelNameProblem('a-b_c'), isNull);
      expect(channelNameProblem(''), isNotNull);
      expect(channelNameProblem('1abc'), isNotNull);
      expect(channelNameProblem('has space'), isNotNull);
      expect(channelNameProblem('x' * 33), isNotNull);
    });

    test('refused at the preview', () async {
      for (final (args, message) in [
        ({'name': 'has space'}, '字母开头'),
        ({'name': '9lives'}, '字母开头'),
        ({'name': 'general'}, '已经有叫 #general'),
        ({'name': 'old'}, '归档的 #old'),
        ({'name': 'new', 'members': ['nobody-like-this']}, '没有叫'),
        ({'name': 'new', 'visibility': 'secret'}, 'public / private'),
        (<String, Object?>{}, '缺少参数 name'),
      ]) {
        final r = await h.act('channels.create', args);
        expect('${r['error']}', contains(message), reason: '$args');
      }
      expect(h.w.commands, isEmpty);
    });

    test('a server that refuses the name is a failed card', () async {
      h.w.commandError = const RaftApiException('Name taken');
      final done = await h.run('channels.create', {'name': 'launch'});
      expect(done['status'], 'failed');
    });
  });

  group('channels.add_members', () {
    setUp(() {
      h.w.routes['/channels/ch-general/members'] = (_) => {
        'humans': [
          {'userId': 'kevin', 'name': 'kevin'},
        ],
        'agents': <Object>[],
      };
    });

    test('adds the ones who are not in yet, and undo removes them', () async {
      final r = await h.act('channels.add_members', {
        'channel': 'general',
        'members': ['Ada', 'Cody', 'Kevin'],
      });
      expect(h.summary(r), '把 Ada、Cody 加进 #general');
      expect(h.changes(r).single, '#general 成员:  → 加入 Ada、Cody');
      expect((r['preview'] as Map)['reversible'], isTrue);
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.w.commands.single.$2, '/channels/ch-general/members/batch');
      expect(h.w.commands.single.$3, {
        'userIds': ['ada'],
        'agentIds': ['a-cody'],
      });
      expect(h.w.channelRefreshes, 1);
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone', reason: '$undone');
      expect(h.w.commands.skip(1).map((c) => '${c.$1} ${c.$2}'), [
        'DELETE /channels/ch-general/members/user/ada',
        'DELETE /channels/ch-general/members/agent/a-cody',
      ]);
    });

    test('refused at the preview', () async {
      for (final (args, message) in [
        ({'channel': 'general', 'members': ['Kevin']}, '已经在 #general 里'),
        ({'channel': 'general', 'members': <String>[]}, '需要 members'),
        ({'channel': 'general', 'members': ['nobody-like-this']}, '没有叫'),
        ({'channel': 'Ada', 'members': ['Cody']}, '私信里不能'),
        ({'channel': 'old', 'members': ['Cody']}, '已归档'),
        ({'channel': 'general'}, '缺少参数 members'),
      ]) {
        final r = await h.act('channels.add_members', args);
        expect('${r['error']}', contains(message), reason: '$args');
      }
      h.w.server = RaftRecord({'id': 's1', 'role': 'guest'});
      final r = await h.act('channels.add_members', {
        'channel': 'general',
        'members': ['Cody'],
      });
      expect('${r['error']}', contains('权限'));
      expect(h.w.commands, isEmpty);
    });
  });

  test('find answers what people say', () async {
    for (final (said, id) in [
      ('静音这个频道', 'channels.set_muted'),
      ('把 design 置顶', 'channels.set_pinned'),
      ('建个频道 launch 把 Cody 拉进来', 'channels.create'),
      ('把 Ada 加到 general 频道', 'channels.add_members'),
    ]) {
      final r = await h.tools.run('find', {'intent': said});
      final ids = [for (final m in r!['matches'] as List) (m as Map)['id']];
      expect(ids.take(3), contains(id), reason: said);
    }
  });
}
