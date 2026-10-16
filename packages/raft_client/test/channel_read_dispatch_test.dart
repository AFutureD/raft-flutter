import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:raft_client/raft_client.dart';
import 'package:test/test.dart';

void main() {
  test('a channel read reaches the adapter before the caller yields', () async {
    final adapter = _Adapter();
    final client = _client(adapter);
    addTearDown(client.dispose);
    await client.login('ada@example.invalid', 'secret');
    client.selectServer('s1');
    final before = adapter.calls.length;

    final read = client.post('/channels/c1/read', data: {'seq': '901'});
    final readAll = client.post('/channels/c1/read-all');
    final sent = adapter.calls.sublist(before).map((c) => c.path).toList();

    expect(sent, ['/channels/c1/read']);
    final receipt = adapter.calls[before];
    expect(receipt.method, 'POST');
    expect(receipt.data, {'seq': '901'});
    expect(receipt.headers['X-Server-Id'], 's1');
    expect('${receipt.headers['Authorization']}', startsWith('Bearer '));
    for (var n = 0; n < 64; n++) {
      unawaited(Future<void>.delayed(Duration.zero));
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      adapter.calls.sublist(before).map((c) => c.path),
      contains('/channels/c1/read'),
    );
    expect(await read, {'maxReadSeq': '901', 'readStateVersion': 3});
    expect(adapter.bodies[before], '{"seq":"901"}');
    await readAll;
    expect(adapter.calls.map((c) => c.path), contains('/channels/c1/read-all'));
  });

  test('sync interceptors still see the read on that same turn', () async {
    final adapter = _Adapter();
    final client = _client(adapter);
    addTearDown(client.dispose);
    await client.login('ada@example.invalid', 'secret');
    final order = <String>[];
    client.http.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          order.add('request');
          options.extra['stamped'] = true;
          handler.next(options);
        },
        onResponse: (response, handler) {
          order.add('response');
          handler.next(response);
        },
      ),
    );
    adapter.onFetch = () => order.add('adapter');

    final pending = client.post('/channels/c1/read', data: {'seq': '1'});
    expect(order, ['request', 'adapter']);
    expect(adapter.calls.last.extra['stamped'], isTrue);
    expect(await pending, {'maxReadSeq': '901', 'readStateVersion': 3});
    expect(order, ['request', 'adapter', 'response']);
  });

  test('a 401 on the read still refreshes once and retries', () async {
    final adapter = _Adapter();
    final client = _client(adapter);
    addTearDown(client.dispose);
    await client.login('ada@example.invalid', 'secret');
    var reads = 0;
    adapter.handler = (options) {
      if (options.path == '/channels/c1/read') {
        reads++;
        if (reads == 1) return _json({'error': 'expired'}, 401);
        return _json({'maxReadSeq': '1', 'readStateVersion': 2});
      }
      if (options.path == '/auth/refresh') {
        return _json({'accessToken': 'access-2', 'refreshToken': 'refresh-2'});
      }
      return _json({'error': 'missing'}, 404);
    };

    expect(await client.post('/channels/c1/read', data: {'seq': '1'}), {
      'maxReadSeq': '1',
      'readStateVersion': 2,
    });
    final receipts = adapter.calls.where((c) => c.path == '/channels/c1/read');
    expect(receipts, hasLength(2));
    expect(receipts.last.headers['Authorization'], 'Bearer access-2');
    expect(adapter.calls.where((c) => c.path == '/auth/refresh'), hasLength(1));
  });
}

RaftClient _client(_Adapter adapter) => RaftClient(
  origin: 'https://example.invalid',
  sessionStore: MemorySessionStore(),
  transport: Dio()..httpClientAdapter = adapter,
);

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _Adapter implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  final bodies = <String>[];
  void Function()? onFetch;
  ResponseBody Function(RequestOptions options)? handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    onFetch?.call();
    if (requestStream == null) {
      bodies.add('');
    } else {
      final bytes = await requestStream.fold<List<int>>(<int>[], (all, chunk) {
        all.addAll(chunk);
        return all;
      });
      bodies.add(utf8.decode(bytes));
    }
    final answer = handler?.call(options);
    if (answer != null) return answer;
    if (options.path == '/auth/login') {
      return _json({
        'accessToken': 'access-1',
        'refreshToken': 'refresh-1',
        'user': {'id': 'ada'},
      });
    }
    if (options.path == '/channels/c1/read') {
      return _json({'maxReadSeq': '901', 'readStateVersion': 3});
    }
    return _json({'ok': true});
  }

  @override
  void close({bool force = false}) {}
}
