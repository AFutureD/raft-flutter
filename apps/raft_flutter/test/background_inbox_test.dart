import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/platform/background_inbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends RaftClient {
  _Client()
    : super(
        origin: 'https://fixture.example',
        sessionStore: MemorySessionStore(),
      ) {
    user = RaftRecord({'id': 'alice'});
    selectServer('s');
  }
  @override
  bool get signedIn => user != null;
  bool muted = false;
  String mode = 'all';
  Completer<dynamic>? page;
  List<Map<String, dynamic>> rows = [];
  final reads = <String>[];
  @override
  Future<List<RaftRecord>> servers() async => [
    RaftRecord({'id': 's', 'serverPushMuted': muted}),
  ];
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    reads.add(path);
    if (path.endsWith('/notification-settings')) {
      return {'serverPushMode': mode};
    }
    return page?.future ?? {'items': rows};
  }
}

Map<String, dynamic> row(String id, {String? at, int unread = 1}) => {
  'kind': 'channel',
  'channelId': 'c',
  'channelName': 'general',
  'lastMessageId': id,
  'lastMessageAt': at ?? '2026-10-08T01:00:01Z',
  'lastMessagePreview': 'New message',
  'unreadCount': unread,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late BackgroundInboxStore store;
  late String scope;
  late List<String> sent;
  late BackgroundInboxPoller poller;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = _Client();
    store = BackgroundInboxStore();
    scope = notificationScope(client);
    sent = [];
    await store.select(scope);
    await (await SharedPreferences.getInstance()).setBool(
      notificationPreferenceKey(scope),
      true,
    );
    await store.save(scope, {
      'since': '2026-10-08T01:00:00Z',
      'seen': <String>[],
    });
    poller = BackgroundInboxPoller(
      client: client,
      store: store,
      authorize: (target, valid) async {
        expect(valid(), true);
      },
      deliver: (alert, selected) async {
        sent.add(alert.target.messageId!);
        return true;
      },
    );
  });
  tearDown(() => client.dispose());
  test('new unread activity delivers once across subsequent headless instances; old backlog and read rows do not', () async {
    client.rows = [
      row('old', at: '2026-10-07T00:00:00Z'),
      row('read', unread: 0),
      row('new'),
    ];
    await poller.run();
    await poller.run();
    expect(sent, ['new']);
    expect(await BackgroundInboxStore().seen(scope, 'new'), true);
    expect(
      client.reads.every(
        (p) => p == '/channels/inbox' || p.endsWith('/notification-settings'),
      ),
      true,
    );
  });
  test('server mentions-only alerts on hasMention with unread, not on firstMentionMessageId equality', () async {
    client.mode = 'mentions';
    client.rows = [
      row('ordinary'),
      {...row('later'), 'hasMention': true, 'firstMentionMessageId': 'earlier'},
      {
        ...row('personal'),
        'hasMention': true,
        'firstMentionMessageId': 'personal',
      },
    ];
    await poller.run();
    // `later`: firstMentionMessageId is the OLDEST unread mention, so it
    // legitimately differs from the latest message id.
    expect(sent, unorderedEquals(['later', 'personal']));
  });
  test('workspace change during fetch cannot alert', () async {
    client.page = Completer();
    final pending = poller.run();
    while (!client.reads.contains('/channels/inbox')) {
      await Future<void>.delayed(Duration.zero);
    }
    client.selectServer('other');
    client.page!.complete({
      'items': [row('new')],
    });
    await pending;
    expect(sent, isEmpty);
  });
  test(
    'disable during fetch prevents alerts without altering read state',
    () async {
      client.page = Completer();
      final pending = poller.run();
      while (!client.reads.contains('/channels/inbox')) {
        await Future<void>.delayed(Duration.zero);
      }
      await (await SharedPreferences.getInstance()).setBool(
        notificationPreferenceKey(scope),
        false,
      );
      client.page!.complete({
        'items': [row('new')],
      });
      await pending;
      expect(sent, isEmpty);
    },
  );
  test(
    'server mute and mismatched account do not fetch private inbox',
    () async {
      client.muted = true;
      await poller.run();
      expect(client.reads, isEmpty);
      client.muted = false;
      client.user = RaftRecord({'id': 'bob'});
      await poller.run();
      expect(client.reads, isEmpty);
    },
  );
  test(
    'Done after initial fetch suppresses alert after fresh projection',
    () async {
      client.rows = [row('new')];
      poller = BackgroundInboxPoller(
        client: client,
        store: store,
        authorize: (target, valid) async {
          client.rows = [];
        },
        deliver: (alert, selected) async {
          sent.add(alert.target.messageId!);
          return true;
        },
      );
      await poller.run();
      expect(sent, isEmpty);
    },
  );
  test(
    'unauthorized context fails closed and delivery failure remains retryable',
    () async {
      client.rows = [row('new')];
      poller = BackgroundInboxPoller(
        client: client,
        store: store,
        authorize: (target, valid) async {
          throw const RaftApiException('Forbidden');
        },
        deliver: (alert, selected) async {
          sent.add('invalid');
          return true;
        },
      );
      await expectLater(poller.run(), throwsA(isA<RaftApiException>()));
      expect(sent, isEmpty);
      poller = BackgroundInboxPoller(
        client: client,
        store: store,
        authorize: (target, valid) async {},
        deliver: (alert, scope) async => false,
      );
      await poller.run();
      expect(await store.seen(scope, 'new'), false);
    },
  );
  test('thread payload respects independent follow and personal mention; notification ID stable across processes and scopes', () {
    final r = {
      'kind': 'thread',
      'threadChannelId': 't',
      'parentChannelId': 'c',
      'parentMessageId': 'p',
      'latestActivityMessageId': 'm',
      'lastActivityAt': '2026-10-08T01:00:01Z',
      'unreadCount': 1,
      'isFollowing': false,
    };
    expect(
      BackgroundInboxAlert.fromRow(r, 's', DateTime.utc(2026, 10, 8, 1)),
      isNull,
    );
    final alert = BackgroundInboxAlert.fromRow(
      {...r, 'hasMention': true},
      's',
      DateTime.utc(2026, 10, 8, 1),
    )!;
    expect(alert.target.nativeUri('s').queryParameters['parentMessageId'], 'p');
    expect(
      messageNotificationId(scope, 'm'),
      messageNotificationId(scope, 'm'),
    );
    expect(
      messageNotificationId(scope, 'm'),
      isNot(messageNotificationId('$scope-other', 'm')),
    );
  });
  test('notification copy identifies channel, DM sender and thread without exposing IDs', () {
    final since = DateTime.utc(2026, 10, 8, 1);
    final channel = BackgroundInboxAlert.fromRow(
      {...row('m'), 'lastMessageSenderName': 'Alice'},
      's',
      since,
    )!;
    expect(channel.title, '#general');
    expect(channel.body, 'Alice: New message');
    final dm = BackgroundInboxAlert.fromRow(
      {
        ...row('m'),
        'kind': 'dm',
        'channelName': 'Internal conversation label',
        'lastMessageSenderName': '陈小明',
      },
      's',
      since,
    )!;
    expect(dm.title, '陈小明');
    expect(dm.body, 'New message');
    final thread = BackgroundInboxAlert.fromRow(
      {
        'kind': 'thread',
        'threadChannelId': 't',
        'parentChannelId': 'c',
        'parentChannelName': 'general',
        'parentMessageId': 'p',
        'latestActivityMessageId': 'm',
        'latestActivityPreview': 'A reply',
        'latestActivitySenderName': 'Bob',
        'lastActivityAt': '2026-10-08T01:00:01Z',
        'unreadCount': 1,
        'isFollowing': true,
      },
      's',
      since,
    )!;
    expect(thread.title, '#general · Thread');
    expect(thread.body, 'Bob: A reply');
    expect(thread.target.threadId, 't');
    final unnamed = BackgroundInboxAlert.fromRow(
      {...row('m'), 'kind': 'dm', 'channelName': '  '},
      's',
      since,
    )!;
    expect(unnamed.title, 'Direct message');
    final unicode = BackgroundInboxAlert.fromRow(
      {...row('m'), 'kind': 'dm', 'lastMessageSenderName': '😀' * 161},
      's',
      since,
    )!;
    expect(unicode.title, '😀' * 160);
  });
}
