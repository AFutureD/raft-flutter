import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_resolver.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';

import 'app_global_server_selector_test.dart' show RootFixture;

// The navigation tools of the Agent orb, driven against the real phone shell
// (RaftApp, router, WorkspaceView) with an in-memory server. Fictional data
// only: Alice (me), Cody and Grok (agents), #raft-flutter, #design.

final _now = DateTime.now().toUtc();
String _ago(int minutes) =>
    _now.subtract(Duration(minutes: minutes)).toIso8601String();

Map<String, dynamic> _channel(String id, String name) => {
  'id': id,
  'name': name,
  'type': 'channel',
  'serverId': 'a',
  'joined': true,
  'latestSeq': '3',
};

Map<String, dynamic> _message(
  String channel,
  int seq,
  String text, {
  String id = '',
  String senderId = 'a-cody',
  String? senderName = 'Cody',
  String senderType = 'agent',
}) => {
  'id': id.isEmpty ? '$channel-m$seq' : id,
  'channelId': channel,
  'seq': '$seq',
  'senderId': senderId,
  'senderName': ?senderName,
  'senderType': senderType,
  'content': text,
  'createdAt': _ago(60 - seq),
};

Map<String, dynamic> _page(List<Map<String, dynamic>> messages) => {
  'messages': messages,
  'hasMore': false,
  'hasNewer': false,
};

final _task136 = <String, dynamic>{
  'id': 'tk136',
  'taskNumber': 136,
  'title': 'Ship the orb navigation',
  'status': 'in_progress',
  'channelId': 'ca',
  'channelName': 'raft-flutter',
  'messageId': 'ca-m1',
  'claimedByName': 'Cody',
  'claimedById': 'a-cody',
  'createdByName': 'Alice',
  'threadChannelId': 'tt136',
  'description': 'Navigate by voice and read the data layer.',
  'updatedAt': _ago(30),
};

class Fixture {
  Fixture() {
    f.overrides.addAll({
      'GET /channels': (_) => [
        _channel('ca', 'raft-flutter'),
        _channel('cb', 'design'),
        _channel('ce', 'empty-room'),
      ],
      'GET /channels/dm': (_) => [
        {
          'id': 'dc',
          'type': 'dm',
          'name': 'cody',
          'peerId': 'a-cody',
          'peerType': 'agent',
          'peerName': 'Cody',
          'serverId': 'a',
          'joined': true,
          'latestSeq': '1',
        },
      ],
      'GET /channels/unread': (_) => {
        'channels': {'cb': 2},
      },
      'GET /agents': (_) => [
        {
          'id': 'a-cody',
          'name': 'Cody',
          'displayName': 'Cody',
          'status': 'active',
          'runtime': 'codex',
          'model': 'gpt',
        },
      ],
      'GET /servers/a/members': (_) => [
        {
          'userId': 'alice',
          'name': 'Alice',
          'displayName': 'Alice',
          'role': 'owner',
        },
        {
          'userId': 'u-dana',
          'name': 'Dana',
          'displayName': 'Dana',
          'role': 'member',
        },
      ],
      'GET /messages/channel/ca': (_) async {
        await caPage?.future;
        return _page([
          _message('ca', 1, 'Task #136 is ready for review.', id: 'ca-m1'),
          _message(
            'ca',
            2,
            'Looks good, shipping it.',
            senderId: 'alice',
            senderName: 'Alice',
            senderType: 'user',
          ),
          _message(
            'ca',
            3,
            'Cody moved #136 to review',
            senderId: 'system',
            senderName: null,
            senderType: 'system',
          ),
        ]);
      },
      'GET /messages/channel/cb': (_) => _page([
        _message(
          'cb',
          1,
          'New tab bar icons are in Figma.',
          senderId: 'u-dana',
          senderName: 'Dana',
          senderType: 'user',
        ),
        _message(
          'cb',
          2,
          'I like the third one.',
          senderId: 'u-dana',
          senderName: 'Dana',
          senderType: 'user',
        ),
      ]),
      'GET /messages/channel/ce': (_) => _page([]),
      'GET /messages/channel/dc': (_) =>
          _page([_message('dc', 1, 'Review is ready.')]),
      'GET /channels/inbox': (_) async {
        await inboxPage?.future;
        return {
          'items': [
            {
              'kind': 'thread',
              'threadChannelId': 'tt136',
              'parentChannelId': 'ca',
              'parentChannelName': 'raft-flutter',
              'parentChannelType': 'channel',
              'parentMessageId': 'ca-m1',
              'parentMessagePreview': 'Task #136 is ready for review.',
              'parentMessageSenderId': 'alice',
              'latestActivityMessageId': 'tt136-m1',
              'latestActivityPreview': 'First slice passes the checks.',
              // The server names only the sender's id: the name comes from
              // the member and Agent directory.
              'latestActivitySenderId': 'a-cody',
              'latestActivitySenderType': 'agent',
              'lastActivityAt': _ago(5),
              'unreadCount': 2,
              'hasMention': false,
              'isFollowing': true,
              'taskNumber': 136,
              'taskStatus': 'in_progress',
            },
            {
              'kind': 'channel',
              'channelId': 'ca',
              'channelName': 'raft-flutter',
              'channelType': 'channel',
              'lastMessageId': 'ca-m3',
              'lastMessagePreview': 'Cody moved #136 to review',
              'lastMessageSenderType': 'system',
              'lastActivityAt': _ago(20),
              'unreadCount': 0,
            },
            {
              'kind': 'dm',
              'channelId': 'dc',
              'channelName': 'cody',
              'channelType': 'dm',
              'lastMessageId': 'dc-m1',
              'lastMessagePreview': 'Review is ready.',
              'lastMessageSenderId': 'a-cody',
              'lastMessageSenderType': 'agent',
              'lastActivityAt': _ago(40),
              'unreadCount': 1,
            },
          ],
          'hasMore': false,
          'totalUnreadCount': 3,
        };
      },
      'GET /tasks/server': (o) => {
        'tasks': o.queryParameters['status'] == 'in_progress'
            ? [_task136]
            : <Object?>[],
      },
      'GET /tasks/channel/ca': (_) => {
        'tasks': [_task136],
      },
      'GET /tasks/channel/ca/number/136': (_) => {'task': _task136},
      'GET /messages/channel/tt136': (_) => _page([
        _message('tt136', 1, 'Started on the resolver.', id: 'tt136-m1'),
        _message('tt136', 2, 'First slice passes the checks.', id: 'tt136-m2'),
      ]),
    });
  }

  final f = RootFixture();

  /// While set, the first page of #raft-flutter (or the Activity window) is
  /// held until the test completes it.
  Completer<void>? caPage, inboxPage;

  late OrbToolContext ctx;
  late ValueNotifier<bool> operating;

  Future<void> mount(WidgetTester t, {String uri = '/s/alpha'}) async {
    t.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    t.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewPadding);
    await f.mount(t, 'brutal', 412, uri: Uri.parse(uri));
    t.view.physicalSize = const Size(412, 915);
    await f.flush(t);
    operating = ValueNotifier(false);
    addTearDown(operating.dispose);
    ctx = OrbToolContext(
      workspace: f.workspace(t),
      navigatorContext: f.router(t).navigatorKey.currentState!.overlay!.context,
      operating: operating,
    );
  }

  OrbTool tool(String name) =>
      orbNavigationTools().firstWhere((tool) => tool.name == name);

  /// Runs a tool and lets the app and the in-memory server work until it
  /// answers.
  Future<Map<String, Object?>> call(
    WidgetTester t,
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    Map<String, Object?>? out;
    Object? failure;
    unawaited(
      tool(name)
          .handler(args, ctx)
          .then((v) => out = v, onError: (Object e) => failure = e),
    );
    for (var i = 0; i < 40 && out == null && failure == null; i++) {
      await f.flush(t);
    }
    if (failure != null) throw failure!;
    expect(out, isNotNull, reason: '$name did not answer');
    return out!;
  }

  Future<void> back(WidgetTester t) async {
    expect(await t.binding.handlePopRoute(), isTrue);
    await f.flush(t);
    for (var i = 0; i < 24; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  String get path => ctx.workspace.location.toString();
}

Map<String, Object?> _map(Object? v) => (v as Map).cast<String, Object?>();
List<Map<String, Object?>> _list(Object? v) => [
  for (final e in v as List) _map(e),
];

void main() {
  testWidgets(
    'the tools are the seam: navigate, list_targets, describe_page, read_conversation',
    (t) async {
      final tools = orbNavigationTools();
      expect(tools.map((e) => e.name), [
        'navigate',
        'list_targets',
        'describe_page',
        'read_conversation',
      ]);
      for (final tool in tools) {
        expect(tool.declaration['description'], isA<String>());
      }
      final navigate = tools.first.declaration['parameters']! as Map;
      expect(navigate['required'], isNull);
    },
  );

  group('navigate', () {
    testWidgets('to Activity by its name, and Back returns', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final home = fx.path;
      expect(home, '/s/alpha');
      final r = await fx.call(t, 'navigate', {'target': '动态'});
      expect(r['error'], isNull, reason: '$r');
      expect(r['route'], '/s/alpha/activity');
      expect(r['title'], '动态');
      expect(r['loading'], false);
      expect(fx.path, '/s/alpha/activity');
      final page = _map(r['page']);
      expect(page['page'], 'activity');
      // The page the model is told about is the page on screen.
      expect(
        find.textContaining(
          'First slice passes the checks.',
          findRichText: true,
        ),
        findsWidgets,
      );
      expect(fx.operating.value, false);

      await fx.back(t);
      expect(fx.path, home);
      await fx.f.close(t);
    });

    testWidgets('to #raft-flutter by a misheard name; its messages come back', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {'target': 'Roughslutter'});
      expect(r['error'], isNull, reason: '$r');
      expect(r['route'], '/s/alpha/channel/ca');
      expect(r['title'], '#raft-flutter');
      expect(_map(r['matched'])['id'], 'ca');
      expect(r['loading'], false);
      final page = _map(r['page']);
      expect(page['page'], 'conversation');
      final texts = _list(page['messages']).map((m) => m['text']).toList();
      expect(texts, contains('Task #136 is ready for review.'));
      // The page on screen shows the same message.
      expect(
        find.textContaining('Looks good, shipping it.', findRichText: true),
        findsWidgets,
      );

      await fx.back(t);
      expect(fx.path, '/s/alpha');
      await fx.f.close(t);
    });

    testWidgets('"RA flutter" and a DM by name', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      var r = await fx.call(t, 'navigate', {'target': 'RA flutter'});
      expect(r['route'], '/s/alpha/channel/ca');
      await fx.back(t);
      r = await fx.call(t, 'navigate', {'target': 'Cody 的私信'});
      expect(r['error'], isNull, reason: '$r');
      expect(r['route'], '/s/alpha/dm/dc');
      expect(r['title'], 'Cody');
      expect(
        _list(_map(r['page'])['messages']).single['text'],
        'Review is ready.',
      );
      await fx.f.close(t);
    });

    testWidgets('to task 136; Back returns', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {'target': 'task 136'});
      expect(r['error'], isNull, reason: '$r');
      expect(r['loading'], false, reason: '$r');
      final page = _map(r['page']);
      expect(page['page'], 'task');
      final task = _map(page['task']);
      expect(task['number'], 136);
      expect(task['status'], 'in_progress');
      expect(task['assignee'], 'Cody');
      expect(task['title'], 'Ship the orb navigation');
      expect(
        _list(page['discussion']).map((m) => m['text']),
        contains('First slice passes the checks.'),
      );
      expect(fx.ctx.workspace.location.task?.itemId, 'ca-m1');
      expect(find.textContaining('Ship the orb navigation'), findsWidgets);

      await fx.back(t);
      expect(fx.ctx.workspace.location.task, isNull);
      expect(fx.path, '/s/alpha');
      await fx.f.close(t);
    });

    testWidgets('"任务136" and "#136" mean the same task', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      var r = await fx.call(t, 'navigate', {'target': '任务136'});
      expect(_map(_map(r['page'])['task'])['number'], 136);
      await fx.back(t);
      r = await fx.call(t, 'navigate', {'target': '#136'});
      expect(_map(_map(r['page'])['task'])['number'], 136);
      await fx.f.close(t);
    });

    testWidgets('a task that does not exist is an error', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {'target': 'task 9999'});
      expect(r['error'], contains('9999'));
      expect(fx.path, '/s/alpha');
      await fx.f.close(t);
    });

    testWidgets('waits for a delayed first page, then includes its messages', (
      t,
    ) async {
      final fx = Fixture()..caPage = Completer<void>();
      await fx.mount(t);
      Map<String, Object?>? result;
      unawaited(
        fx
            .tool('navigate')
            .handler({'target': 'raft-flutter'}, fx.ctx)
            .then((v) => result = v),
      );
      await fx.f.flush(t);
      await fx.f.flush(t);
      expect(result, isNull, reason: 'answered before the first page arrived');
      expect(fx.operating.value, true, reason: 'operating while moving');
      expect(fx.path, '/s/alpha/channel/ca');

      fx.caPage!.complete();
      for (var i = 0; i < 20 && result == null; i++) {
        await fx.f.flush(t);
      }
      final r = result!;
      expect(r['loading'], false);
      final texts = _list(_map(r['page'])['messages']).map((m) => m['text']);
      expect(texts, contains('Looks good, shipping it.'));
      expect(fx.operating.value, false, reason: 'operating ends when done');
      await fx.f.close(t);
    });

    testWidgets(
      'a page that is still loading after the cap reports loading, not empty',
      (t) async {
        final fx = Fixture()..caPage = Completer<void>();
        await fx.mount(t);
        Map<String, Object?>? result;
        unawaited(
          fx
              .tool('navigate')
              .handler({'target': 'raft-flutter'}, fx.ctx)
              .then((v) => result = v),
        );
        await fx.f.flush(t);
        expect(result, isNull);
        await t.pump(const Duration(seconds: 6));
        await fx.f.flush(t);
        final r = result!;
        expect(r['route'], '/s/alpha/channel/ca');
        expect(r['loading'], true);
        expect(r['note'], contains('不是空的'));
        final page = _map(r['page']);
        expect(page['loading'], true);
        expect(page['empty'], false);
        expect(page['messages'], isEmpty);
        expect(fx.operating.value, false);
        fx.caPage!.complete();
        await fx.f.flush(t);
        await fx.f.close(t);
      },
    );

    testWidgets('an empty channel reports empty, not loading', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {'target': 'empty room'});
      expect(r['route'], '/s/alpha/channel/ce');
      expect(r['loading'], false);
      final page = _map(r['page']);
      expect(page['empty'], true);
      expect(page['loading'], false);
      expect(page['messages'], isEmpty);
      await fx.f.close(t);
    });

    testWidgets('the user touching the screen ends the wait', (t) async {
      final fx = Fixture()..caPage = Completer<void>();
      await fx.mount(t);
      Map<String, Object?>? result;
      unawaited(
        fx
            .tool('navigate')
            .handler({'target': 'raft-flutter'}, fx.ctx)
            .then((v) => result = v),
      );
      await fx.f.flush(t);
      expect(result, isNull);
      fx.operating.value = false; // the shell: a pointer went down
      await fx.f.flush(t);
      expect(result, isNotNull);
      expect(result!['interrupted'], true);
      fx.caPage!.complete();
      await fx.f.flush(t);
      await fx.f.close(t);
    });

    testWidgets(
      'ambiguous words give candidates with reasons; unknown give an error',
      (t) async {
        final fx = Fixture();
        fx.f.overrides['GET /channels'] = (_) => [
          _channel('ca', 'raft-flutter'),
          _channel('cu', 'flutter-ui'),
        ];
        await fx.mount(t);
        final r = await fx.call(t, 'navigate', {'target': 'flutter'});
        final candidates = _list(r['candidates']);
        expect(candidates.map((c) => c['id']).toSet(), {'ca', 'cu'});
        expect(candidates.every((c) => '${c['reason']}'.isNotEmpty), isTrue);
        // Each candidate says which argument chooses it.
        expect(
          {for (final c in candidates) _map(c['use'])['channel_id']},
          {'ca', 'cu'},
        );
        expect(fx.path, '/s/alpha', reason: 'ambiguous words do not move');
        final none = await fx.call(t, 'navigate', {'target': 'xyzzy plugh'});
        expect(none['error'], isNotNull);
        expect(none.containsKey('route'), isFalse);
        await fx.f.close(t);
      },
    );

    testWidgets(
      'from Activity to a channel: Back returns to Activity, then Home',
      (t) async {
        final fx = Fixture();
        await fx.mount(t);
        await fx.call(t, 'navigate', {'target': '动态'});
        await fx.call(t, 'navigate', {'target': 'design 频道'});
        expect(fx.path, '/s/alpha/channel/cb');
        await fx.back(t);
        expect(fx.path, '/s/alpha/activity');
        await fx.back(t);
        expect(fx.path, '/s/alpha');
        await fx.f.close(t);
      },
    );

    testWidgets('where the user already is: no new history entry', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      await fx.call(t, 'navigate', {'target': 'design'});
      final again = await fx.call(t, 'navigate', {'target': 'design 频道'});
      expect(again['alreadyThere'], true);
      expect(_map(again['page'])['page'], 'conversation');
      await fx.back(t);
      expect(fx.path, '/s/alpha');
      await fx.f.close(t);
    });

    testWidgets('"文件" without a conversation open is an error', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final none = await fx.call(t, 'navigate', {'target': '文件'});
      expect(none['error'], contains('频道'));
      expect(fx.operating.value, false);
      expect(fx.path, '/s/alpha');
      await fx.f.close(t);
    });
    testWidgets(
      'settings pages and a member profile',
      (t) async {
        final fx = Fixture();
        await fx.mount(t);
        var r = await fx.call(t, 'navigate', {'target': '外观'});
        expect(r['error'], isNull, reason: '$r');
        expect(r['route'], '/s/alpha/settings/appearance');
        expect(_map(r['page'])['page'], 'other');
        expect(_map(r['page'])['semantics'], isA<List>());
        await fx.back(t);
        r = await fx.call(t, 'navigate', {'target': 'Dana 的资料'});
        expect(r['error'], isNull, reason: '$r');
        expect(fx.ctx.workspace.location.profile?.id, 'u-dana');
        expect(_map(r['page'])['page'], 'profile');
        await fx.f.close(t);
      },
      // Opening the Files tab starts the workspace's own files store, which
      // the app releases with the workspace, after this test's teardown.
      experimentalLeakTesting: LeakTesting.settings.withIgnored(
        classes: ['SourceChannelFilesStore'],
      ),
    );
  });

  group('navigate by id', () {
    final log = <String>[];
    setUp(() {
      log.clear();
      orbNavLog = log.add;
    });
    tearDown(() => orbNavLog = (_) {});

    testWidgets('page: activity goes to the Activity; Back returns', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {'page': 'activity'});
      expect(r['error'], isNull, reason: '$r');
      expect(r['route'], '/s/alpha/activity');
      expect(r['title'], '动态');
      expect(_map(r['page'])['page'], 'activity');
      expect(_map(r['matched'])['id'], 'activity');
      expect(fx.operating.value, false);
      await fx.back(t);
      expect(fx.path, '/s/alpha');
      await fx.f.close(t);
    });

    testWidgets('a settings page by id', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {'page': 'settings/appearance'});
      expect(r['error'], isNull, reason: '$r');
      expect(r['title'], '外观');
      expect(fx.path, contains('appearance'));
      await fx.f.close(t);
    });

    testWidgets('an invalid page id returns the nearest valid ids', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      var r = await fx.call(t, 'navigate', {'page': 'activty'});
      expect(r['error'], isA<String>());
      final valid = _list(r['valid']);
      expect(valid, hasLength(5));
      expect(valid.first, {'id': 'activity', 'name': '动态'});
      expect(r.containsKey('route'), isFalse);
      expect(fx.path, '/s/alpha', reason: 'a wrong id does not move');
      // A display name in the id field points at the right id.
      r = await fx.call(t, 'navigate', {'page': '动态'});
      expect(_list(r['valid']).first['id'], 'activity');
      await fx.f.close(t);
    });

    testWidgets('channel_id opens the channel with its messages', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {'channel_id': 'ca'});
      expect(r['error'], isNull, reason: '$r');
      expect(r['route'], contains('/channel/ca'));
      expect(r['title'], '#raft-flutter');
      expect(_map(r['matched'])['kind'], 'channel');
      expect(
        _list(_map(r['page'])['messages']).map((m) => m['text']),
        contains('Looks good, shipping it.'),
      );
      await fx.f.close(t);
    });

    testWidgets('an unknown channel_id returns the nearest channels', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      // A name where an id belongs: the right id comes back first.
      var r = await fx.call(t, 'navigate', {'channel_id': 'raft-flutter'});
      expect(r['error'], isA<String>());
      expect(_list(r['valid']).first, {'id': 'ca', 'name': 'raft-flutter'});
      r = await fx.call(t, 'navigate', {'channel_id': 'cx'});
      expect(r['error'], isA<String>());
      expect(
        _list(r['valid']).map((c) => c['id']).toSet(),
        containsAll({'ca', 'cb', 'ce'}),
      );
      expect(fx.path, '/s/alpha');
      await fx.f.close(t);
    });

    testWidgets('dm_id opens the private conversation', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {'dm_id': 'dc'});
      expect(r['error'], isNull, reason: '$r');
      expect(r['route'], contains('/dm/dc'));
      expect(_map(r['matched'])['kind'], 'dm');
      final bad = await fx.call(t, 'navigate', {'dm_id': 'ca'});
      expect(_list(bad['valid']).first['id'], 'dc');
      await fx.f.close(t);
    });

    testWidgets('person_id opens a profile; an Agent is an Agent', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      var r = await fx.call(t, 'navigate', {'person_id': 'u-dana'});
      expect(r['error'], isNull, reason: '$r');
      expect(_map(r['page'])['page'], 'profile');
      expect(fx.ctx.workspace.location.profile?.id, 'u-dana');
      r = await fx.call(t, 'navigate', {'person_id': 'u-danna'});
      expect(r['error'], isA<String>());
      expect(_list(r['valid']).first['id'], 'u-dana');
      await fx.f.close(t);
    });

    testWidgets('thread_id opens the discussion from the Activity rows', (
      t,
    ) async {
      final fx = Fixture();
      fx.f.overrides['GET /messages/context/ca-m1'] = (_) => {
        'messages': [
          _message('ca', 1, 'Task #136 is ready for review.', id: 'ca-m1'),
        ],
      };
      await fx.mount(t);
      await fx.call(t, 'navigate', {'page': 'activity'});
      await fx.back(t);
      final listed = await fx.call(t, 'list_targets', {'kind': 'threads'});
      expect(_list(listed['threads']).map((e) => e['id']), ['ca-m1']);
      final open = await fx.call(t, 'navigate', {'thread_id': 'ca-m1'});
      expect(open['error'], isNull, reason: '$open');
      expect(_map(open['page'])['page'], 'thread');
      expect(fx.ctx.workspace.location.thread?.itemId, 'ca-m1');
      final bad = await fx.call(t, 'navigate', {'thread_id': 'nope'});
      expect(_list(bad['valid']).first['id'], 'ca-m1');
      await fx.f.close(t);
    });

    testWidgets('task_number opens the task, with or without a channel', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      var r = await fx.call(t, 'navigate', {'task_number': 136});
      expect(r['error'], isNull, reason: '$r');
      expect(_map(_map(r['page'])['task'])['number'], 136);
      await fx.back(t);
      r = await fx.call(t, 'navigate', {
        'task_number': '#136',
        'channel_id': 'ca',
      });
      expect(r['error'], isNull, reason: '$r');
      expect(fx.ctx.workspace.location.task?.itemId, 'ca-m1');
      final none = await fx.call(t, 'navigate', {'task_number': 9999});
      expect(none['error'], isA<String>());
      final bad = await fx.call(t, 'navigate', {'task_number': 'abc'});
      expect(bad['error'], contains('task_number'));
      await fx.f.close(t);
    });

    testWidgets('two destinations at once is an error that moves nothing', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {
        'page': 'activity',
        'channel_id': 'ca',
      });
      expect(r['error'], isA<String>());
      expect(fx.path, '/s/alpha');
      final empty = await fx.call(t, 'navigate', {});
      expect(empty['error'], isA<String>());
      await fx.f.close(t);
    });

    testWidgets('an id beats the words; target is only the fallback', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'navigate', {
        'channel_id': 'cb',
        'target': 'Roughslutter',
      });
      expect(r['route'], contains('/channel/cb'));
      // A mis-heard name with no id still resolves through the matcher.
      final heard = await fx.call(t, 'navigate', {'target': 'Roughslutter'});
      expect(heard['route'], contains('/channel/ca'));
      await fx.f.close(t);
    });

    testWidgets('the choice is logged as ids, never content', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      await fx.call(t, 'navigate', {'page': 'activity'});
      await fx.back(t);
      await fx.call(t, 'navigate', {'channel_id': 'ca'});
      await fx.back(t);
      await fx.call(t, 'navigate', {'page': 'nope'});
      await fx.call(t, 'navigate', {'target': 'Roughslutter'});
      expect(log, [
        'choose page=activity kind=page',
        'choose channel_id=ca kind=channel',
        'invalid page',
        'fallback target=ca kind=channel',
      ]);
      expect(log.join(' '), isNot(contains('Roughslutter')));
      await fx.f.close(t);
    });
  });

  group('list_targets', () {
    testWidgets('channels, DMs, people with ids; unread and joined', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await fx.call(t, 'list_targets');
      final channels = _list(r['channels']);
      expect(channels.first, {
        'id': 'cb',
        'name': 'design',
        'joined': true,
        'unread': 2,
      }, reason: 'unread first');
      expect(channels.map((c) => c['id']), containsAll(['ca', 'cb', 'ce']));
      expect(_list(r['dms']).single, {
        'id': 'dc',
        'name': 'Cody',
        'person_id': 'a-cody',
      });
      expect(
        _list(r['people']).map((p) => '${p['id']}:${p['type']}'),
        containsAll(['u-dana:member', 'a-cody:agent']),
      );
      expect(_list(r['threads']), isEmpty);
      final only = await fx.call(t, 'list_targets', {'kind': 'dms'});
      expect(only.keys, ['dms']);
      expect(
        (await fx.call(t, 'list_targets', {'kind': 'x'}))['error'],
        isNotNull,
      );
      await fx.f.close(t);
    });

    test('each list is capped and says what it left out', () {
      final dir = OrbDirectory(
        channels: [
          for (var i = 0; i < 70; i++) OrbChannelRef(id: 'c$i', name: 'n$i'),
        ],
      );
      final r = orbTargetsJson(dir);
      expect((r['channels']! as List), hasLength(60));
      expect(r['channelsOmitted'], 10);
      expect(orbChannelsLine(dir), contains('n0 [c0]'));
    });
  });

  group('describe_page', () {
    testWidgets(
      'Activity: the Activity rows in order, with real names and flags',
      (t) async {
        final fx = Fixture();
        await fx.mount(t);
        await fx.call(t, 'navigate', {'target': '动态'});
        final d = await fx.call(t, 'describe_page');
        expect(d['page'], 'activity');
        expect(d['route'], '/s/alpha/activity');
        expect(d['title'], '动态');
        expect(d['loading'], false);
        expect(d['empty'], false);
        expect(d['unreadTotal'], 3);
        final items = _list(d['items']);
        expect(items.map((i) => i['id']), [
          'activity:thread:tt136',
          'activity:channel:ca',
          'activity:dm:dc',
        ]);
        expect(items.map((i) => i['n']), [1, 2, 3]);
        final thread = items[0];
        expect(thread['kind'], 'thread');
        // The row carries only the sender's id; the name is the real one.
        expect(thread['who'], 'Cody');
        expect(thread['where'], contains('raft-flutter'));
        expect(thread['unread'], 2);
        expect(thread['why'], '回复了你的消息');
        expect(thread['preview'], 'First slice passes the checks.');
        expect(thread['isPreview'], true);
        expect(thread['task'], 136);
        expect(thread['time'], isA<String>());
        // A system event names its actor in its text and has no "有人".
        final event = items[1];
        expect(event.containsKey('who'), isFalse);
        expect(event['preview'], 'Cody moved #136 to review');
        expect('$event', isNot(contains('有人')));
        expect(items[2]['who'], 'Cody');
        expect(items[2]['where'], '@Cody');
        await fx.f.close(t);
      },
    );

    testWidgets('Activity still loading says loading, then the rows', (
      t,
    ) async {
      final fx = Fixture()..inboxPage = Completer<void>();
      await fx.mount(t);
      Map<String, Object?>? result;
      unawaited(
        fx
            .tool('navigate')
            .handler({'target': '动态'}, fx.ctx)
            .then((v) => result = v),
      );
      await fx.f.flush(t);
      expect(result, isNull);
      await t.pump(const Duration(seconds: 6));
      await fx.f.flush(t);
      expect(result!['loading'], true);
      expect(_map(result!['page'])['empty'], isNot(true));
      fx.inboxPage!.complete();
      await fx.f.flush(t);
      await fx.f.close(t);
    });

    // Eval A5: Alice's message had 8 replies but no thread summary was
    // loaded; the page said nothing of them and the model answered "还没定".
    testWidgets('a message that says it has replies shows them and how to '
        'read its discussion, without a loaded summary', (t) async {
      final fx = Fixture();
      fx.f.overrides['GET /messages/channel/ca'] = (_) => {
        ..._page([
          {
            ..._message('ca', 1, '移动端的缓存策略怎么定？', id: 'ca-m1'),
            'replyCount': 8,
            'threadChannelId': 'th-cache',
          },
        ]),
      };
      await fx.mount(t);
      await fx.call(t, 'navigate', {'target': 'raft-flutter'});
      final d = await fx.call(t, 'describe_page');
      final m = _list(d['messages']).single;
      expect(m['replies'], 8);
      expect(m['thread'], 'thread:th-cache');
      expect('${d['repliesNote']}', contains('read_conversation'));
      await fx.f.close(t);
    });

    testWidgets(
      'a conversation: sender names, full text, time, replies, system rows',
      (t) async {
        final fx = Fixture();
        fx.f.overrides['GET /messages/channel/ca'] = (_) => {
          ..._page([
            _message('ca', 1, 'Short.', id: 'ca-m1'),
            _message(
              'ca',
              2,
              'L' * 2000,
              id: 'ca-m2',
              senderId: 'alice',
              senderName: 'Alice',
              senderType: 'user',
            ),
            _message(
              'ca',
              3,
              'Cody moved #136 to review',
              senderId: 'system',
              senderName: null,
              senderType: 'system',
            ),
          ]),
          'threadSummariesByParentMessageId': {
            'ca-m1': {'replyCount': 4},
          },
        };
        await fx.mount(t);
        await fx.call(t, 'navigate', {'target': 'raft-flutter'});
        final d = await fx.call(t, 'describe_page');
        expect(d['page'], 'conversation');
        expect(_map(d['conversation'])['name'], 'raft-flutter');
        expect(d['loading'], false);
        final messages = _list(d['messages']);
        expect(messages, hasLength(3));
        expect(messages[0]['from'], 'Cody');
        expect(messages[0]['text'], 'Short.');
        expect(messages[0]['replies'], 4);
        expect(messages[0]['time'], isA<String>());
        expect(messages[1]['from'], 'Alice');
        expect(messages[1]['fromMe'], true);
        expect(messages[1]['truncated'], true);
        expect(messages[1]['fullLength'], 2000);
        expect('${messages[1]['text']}'.length, lessThan(1600));
        expect(messages[2]['system'], true);
        expect(messages[2].containsKey('from'), isFalse);
        await fx.f.close(t);
      },
    );

    testWidgets(
      'a long conversation is bounded and says how much was left out',
      (t) async {
        final fx = Fixture();
        fx.f.overrides['GET /messages/channel/ca'] = (_) => _page([
          for (var i = 1; i <= 45; i++) _message('ca', i, 'Message number $i'),
        ]);
        await fx.mount(t);
        await fx.call(t, 'navigate', {'target': 'raft-flutter'});
        final d = await fx.call(t, 'describe_page');
        final messages = _list(d['messages']);
        expect(messages, hasLength(orbMaxMessagesForTest));
        expect(messages.last['text'], 'Message number 45');
        expect(d['omitted'], 45 - orbMaxMessagesForTest);
        await fx.f.close(t);
      },
    );

    testWidgets('a thread: the parent and the replies with names', (t) async {
      final fx = Fixture();
      fx.f.overrides['GET /messages/context/ca-m1'] = (_) => {
        'messages': [
          _message('ca', 1, 'Task #136 is ready for review.', id: 'ca-m1'),
        ],
      };
      await fx.mount(t);
      // The discussion is known by the message it hangs under, from Activity.
      await fx.call(t, 'navigate', {'target': '动态'});
      await fx.back(t);
      final open = await fx.call(t, 'navigate', {
        'target': 'ready for review 讨论',
      });
      expect(open['error'], isNull, reason: '$open');
      expect(_map(open['page'])['page'], 'thread');
      expect(fx.ctx.workspace.location.thread?.itemId, 'ca-m1');
      final d = await fx.call(t, 'describe_page');
      expect(d['page'], 'thread');
      expect(d['title'], '#raft-flutter › 讨论');
      expect(
        _map(_map(d['thread'])['parent'])['text'],
        'Task #136 is ready for review.',
      );
      expect(_map(_map(d['thread'])['parent'])['from'], 'Cody');
      final replies = _list(d['replies']);
      expect(replies.map((m) => m['text']), [
        'Started on the resolver.',
        'First slice passes the checks.',
      ]);
      expect(replies.map((m) => m['from']), ['Cody', 'Cody']);

      await fx.back(t);
      expect(fx.path, '/s/alpha');
      await fx.f.close(t);
    });

    testWidgets('a task: status, assignee, title and the latest discussion', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      await fx.call(t, 'navigate', {'target': 'task 136'});
      final d = await fx.call(t, 'describe_page');
      expect(d['page'], 'task');
      expect(d['title'], '#136 Ship the orb navigation');
      final task = _map(d['task']);
      expect(task['status'], 'in_progress');
      expect(task['assignee'], 'Cody');
      expect(task['creator'], 'Alice');
      expect(task['channel'], 'raft-flutter');
      expect(task['description'], contains('Navigate by voice'));
      final lines = _list(d['discussion']);
      expect(lines.map((l) => l['from']), ['Cody', 'Cody']);
      expect(lines.last['text'], 'First slice passes the checks.');
      await fx.f.close(t);
    });

    testWidgets('another page: route, title and a Semantics summary', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      await fx.call(t, 'navigate', {'target': '设置'});
      final d = await fx.call(t, 'describe_page');
      expect(d['page'], 'other');
      expect(d['route'], '/s/alpha/settings');
      expect(d['title'], '设置');
      final lines = (d['semantics']! as List).cast<String>();
      expect(lines, isNotEmpty);
      expect(lines.length, lessThanOrEqualTo(40));
      await fx.f.close(t);
    });
  });

  group('read_conversation', () {
    testWidgets(
      'reads recent messages by a misheard name without opening or marking read',
      (t) async {
        final fx = Fixture();
        await fx.mount(t);
        final r = await fx.call(t, 'read_conversation', {
          'conversation': 'desine',
          'limit': 5,
        });
        expect(r['error'], isNull, reason: '$r');
        expect(_map(r['conversation'])['id'], 'cb');
        final messages = _list(r['messages']);
        expect(messages.map((m) => m['from']), ['Dana', 'Dana']);
        expect(messages.first['text'], 'New tab bar icons are in Figma.');
        expect(fx.path, '/s/alpha', reason: 'reading does not move the screen');
        expect(r['readStateChanged'], false);
        await fx.f.close(t);
      },
    );

    // On the G100 the model passed an Activity item's id from describe_page
    // ("thread:<id>") and read_conversation said it found nothing.
    testWidgets('takes the id of an Activity item as describe_page gives it', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      for (final id in [
        'channel:cb',
        'dm:cb',
        'thread:cb',
        'conversation:cb',
      ]) {
        final r = await fx.call(t, 'read_conversation', {'conversation': id});
        expect(r['error'], isNull, reason: '$id: $r');
        expect(_map(r['conversation'])['id'], 'cb', reason: id);
      }
      await fx.f.close(t);
    });

    testWidgets(
      'since last_read returns only the unread ones and sends no read receipt',
      (t) async {
        final fx = Fixture();
        await fx.mount(t);
        final w = fx.ctx.workspace;
        expect(w.unread['cb'], 2);
        final before = fx.f.adapter.calls.length;
        final r = await fx.call(t, 'read_conversation', {
          'conversation': 'design',
          'since': 'last_read',
        });
        expect(r['unread'], 2);
        expect(_list(r['messages']).map((m) => m['text']), [
          'New tab bar icons are in Figma.',
          'I like the third one.',
        ]);
        final calls = fx.f.adapter.calls.skip(before).toList();
        expect(
          calls.where((c) => c.method != 'GET'),
          isEmpty,
          reason: 'no write of any kind',
        );
        expect(calls.where((c) => c.path.endsWith('/read')), isEmpty);
        expect(w.unread['cb'], 2, reason: 'read state is untouched');
        await fx.f.close(t);
      },
    );

    testWidgets('with nothing unread, last_read says so and reads nothing', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      final before = fx.f.adapter.calls.length;
      final r = await fx.call(t, 'read_conversation', {
        'conversation': 'raft-flutter',
        'since': 'last_read',
      });
      expect(r['unread'], 0);
      expect(r['messages'], isEmpty);
      expect(
        fx.f.adapter.calls
            .skip(before)
            .where((c) => c.path.contains('/messages/')),
        isEmpty,
      );
      await fx.f.close(t);
    });

    testWidgets('by channel id, and the open conversation by default', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      var r = await fx.call(t, 'read_conversation', {
        'conversation': 'cb',
        'limit': 1,
      });
      expect(_list(r['messages']).single['text'], 'I like the third one.');
      expect(r['hasMoreAbove'], anyOf(isNull, isTrue));
      await fx.call(t, 'navigate', {'target': 'raft-flutter'});
      r = await fx.call(t, 'read_conversation');
      expect(_map(r['conversation'])['id'], 'ca');
      expect(_list(r['messages']), hasLength(3));
      // A thread's channel is not in the channel list: its id still reads.
      r = await fx.call(t, 'read_conversation', {'conversation': 'tt136'});
      expect(_list(r['messages']).map((m) => m['from']), ['Cody', 'Cody']);
      await fx.f.close(t);
    });

    testWidgets('an unknown name is an error; similar names are candidates', (
      t,
    ) async {
      final fx = Fixture();
      fx.f.overrides['GET /channels'] = (_) => [
        _channel('ca', 'raft-flutter'),
        _channel('cu', 'flutter-ui'),
      ];
      await fx.mount(t);
      final r = await fx.call(t, 'read_conversation', {
        'conversation': 'xyzzy plugh',
      });
      expect(r['error'], isNotNull);
      final c = await fx.call(t, 'read_conversation', {
        'conversation': 'flutter',
      });
      expect(_list(c['candidates']).map((m) => m['id']).toSet(), {'ca', 'cu'});
      expect(c.containsKey('messages'), isFalse);
      await fx.f.close(t);
    });
  });
}

const orbMaxMessagesForTest = 30;
