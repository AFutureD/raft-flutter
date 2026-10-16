import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';

class _Transport implements HttpClientAdapter {
  final writes = <Map<String, dynamic>>[];
  final reads = <String>[];
  bool fail = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    dynamic body;
    var status = 200;
    if (o.path == '/auth/login') {
      body = {
        'accessToken': 'fixture',
        'refreshToken': 'fixture',
        'user': {'id': 'alice'},
      };
    } else if (o.path == '/v2/messages') {
      writes.add(Map<String, dynamic>.from(jsonDecode(jsonEncode(o.data))));
      status = fail ? 503 : 200;
      body = fail
          ? {'error': 'Offline'}
          : {
              'message': {
                'id': 'receipt-${writes.length}',
                'channelId': o.data['channelId'],
                'content': o.data['content'],
                'seq': '5',
              },
            };
    } else if (o.path == '/channels/c1/threads/m1') {
      reads.add('${o.method} ${o.path}');
      body = {'threadChannelId': 'th1'};
    } else {
      reads.add('${o.method} ${o.path}');
      body = {'channels': [], 'messages': []};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<WorkspaceController> _fixture(_Transport transport) async {
  final c = RaftClient(
    origin: 'https://example.invalid',
    sessionStore: MemorySessionStore(),
    transport: Dio()..httpClientAdapter = transport,
  );
  await c.login('fixture', 'fixture');
  c.selectServer('s1');
  final w = WorkspaceController(c)
    ..server = RaftRecord({'id': 's1', 'role': 'owner'})
    ..channels = [
      RaftChannel({'id': 'c1', 'name': 'general', 'joined': true}),
      RaftChannel({'id': 'c2', 'name': 'design', 'joined': true}),
    ]
    ..channel = RaftChannel({'id': 'c1', 'name': 'general', 'joined': true});
  w.ledger.switchServer('s1');
  return w;
}

/// Sending for the person (agent mode) names its destination: what they have
/// open, their drafts and their selection are not touched, not even briefly.
void main() {
  test(
    'sendToChannel goes to the channel it names and nothing moves',
    () async {
      final t = _Transport();
      final w = await _fixture(t);
      addTearDown(w.dispose);
      w.drafts['c1'] = 'half-written';
      final target = w.channels.last;

      final ok = await w.sendToChannel(target, '你好', randomId: 'r-1');
      expect(ok, isTrue);
      expect(t.writes.single['channelId'], 'c2');
      expect(t.writes.single['content'], '你好');
      expect(t.writes.single['randomId'], 'r-1');
      expect(w.channel?.id, 'c1', reason: 'the selection is the person\'s');
      expect(w.threadParent, isNull);
      expect(w.drafts['c1'], 'half-written');
      // No window was opened for the channel it sent to.
      expect(t.reads.where((r) => r.contains('/messages/channel/')), isEmpty);
    },
  );

  test('a failed send keeps the words in that channel\'s draft only', () async {
    final t = _Transport()..fail = true;
    final w = await _fixture(t);
    addTearDown(w.dispose);
    w.drafts['c1'] = 'half-written';
    expect(await w.sendToChannel(w.channels.last, '你好'), isFalse);
    expect(w.error, isNotNull);
    expect(w.drafts['c1'], 'half-written');
    expect(w.channel?.id, 'c1');
  });

  test(
    'a channel in conversion is not sent to; the open one is not asked',
    () async {
      final t = _Transport();
      final w = await _fixture(t);
      addTearDown(w.dispose);
      final paused = RaftChannel({
        'id': 'c2',
        'name': 'design',
        'joined': true,
        'conversionJob': {'id': 'job', 'status': 'running', 'phase': 'prepare'},
      });
      expect(await w.sendToChannel(paused, 'x'), isFalse);
      expect(t.writes, isEmpty);
      // The reverse: the open channel is paused, another one is still fine.
      w.channel = RaftChannel({
        ...w.channels.first.json,
        'conversionJob': {'id': 'job', 'status': 'running', 'phase': 'prepare'},
      });
      expect(w.conversationPaused, isTrue);
      expect(await w.sendToChannel(w.channels.last, 'y'), isTrue);
      expect(t.writes.single['channelId'], 'c2');
    },
  );

  test('sendThreadReply goes into the thread without opening it', () async {
    final t = _Transport();
    final w = await _fixture(t);
    addTearDown(w.dispose);
    final parent = RaftMessage({
      'id': 'm1',
      'channelId': 'c1',
      'content': '周五上线？',
      'senderName': 'Cody',
    });
    String? thread;
    final ok = await w.sendThreadReply(
      parent,
      '可以',
      randomId: 'r-2',
      resolved: (id) => thread = id,
    );
    expect(ok, isTrue);
    expect(thread, 'th1');
    expect(t.writes.single['channelId'], 'th1');
    expect(t.writes.single['content'], '可以');
    expect(w.threadParent, isNull, reason: 'no thread was opened');
    expect(w.threadChannelId, isNull);
    expect(w.channel?.id, 'c1');
  });
}
