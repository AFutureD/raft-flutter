import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:raft_client/raft_client.dart';
import 'package:test/test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.me, {this.status = 200});
  final Map<String, dynamic> me;
  final int status;
  final gate = Completer<void>();
  final paths = <String>[];
  final requests = <RequestOptions>[];
  bool rotated = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async {
    paths.add('${o.method} ${o.path}');
    requests.add(o);
    if (o.path == '/auth/me') await gate.future;
    final (body, code) = switch (o.path) {
      '/auth/me' => (me, status),
      '/auth/refresh' when rotated => (
        <String, dynamic>{
          'accessToken': 'refreshed-fixture',
          'refreshToken': 'refreshed-fixture',
        },
        200,
      ),
      '/auth/refresh' => (<String, dynamic>{'error': 'Revoked'}, 401),
      _ => (<String, dynamic>{'ok': true}, 200),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      code,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<(RaftClient, _Adapter, MemorySessionStore)> _restore(
  Map<String, dynamic> me, {
  int status = 200,
  Future<void>? credentialsReady,
}) async {
  final store = MemorySessionStore();
  await store.write(
    'https://example.invalid',
    Session(
      accessToken: 'fixture-only',
      refreshToken: 'fixture-only',
      cachedUser: {'id': 'alice', 'name': 'Alice'},
    ),
  );
  final adapter = _Adapter(me, status: status);
  final client = RaftClient(
    origin: 'https://example.invalid',
    sessionStore: store,
    transport: Dio()..httpClientAdapter = adapter,
  );
  // The account record is available before /auth/me answers.
  expect(
    await client.restore(cachedFirst: true, credentialsReady: credentialsReady),
    isTrue,
  );
  expect(client.user?.id, 'alice');
  return (client, adapter, store);
}

void main() {
  test(
    'cached-first restore revalidates and survives a server switch',
    () async {
      final (client, adapter, store) = await _restore({
        'id': 'alice',
        'name': 'Alice Renamed',
      });
      final events = <String>[];
      client.events.listen((e) => events.add(e.name));
      client.selectServer('server-a');
      adapter.gate.complete();
      await client.sessionValidated;
      await Future<void>.delayed(Duration.zero);
      expect(client.user?.string('name'), 'Alice Renamed');
      expect(events, contains('account:updated'));
      expect(
        (await store.read('https://example.invalid'))?.cachedUser?['name'],
        'Alice Renamed',
      );
      await client.dispose();
    },
  );

  test('cached-first restore ends a rejected session', () async {
    final (client, adapter, store) = await _restore({
      'error': 'Expired',
    }, status: 401);
    final events = <String>[];
    client.events.listen((e) => events.add(e.name));
    adapter.gate.complete();
    await client.sessionValidated;
    await Future<void>.delayed(Duration.zero);
    expect(client.user, isNull);
    expect(events, contains('session:ended'));
    expect(await store.read('https://example.invalid'), isNull);
    await client.dispose();
  });

  test('cached-first restore stays offline on an unreachable server', () async {
    final (client, adapter, _) = await _restore({
      'error': 'Unavailable',
    }, status: 503);
    adapter.gate.complete();
    await client.sessionValidated;
    expect(client.user?.id, 'alice');
    expect(client.restoredOffline, isTrue);
    await client.dispose();
  });

  test(
    'cached account paints while ownership, validation and requests wait',
    () async {
      final ownership = Completer<void>();
      final (client, adapter, store) = await _restore({
        'id': 'alice',
      }, credentialsReady: ownership.future);
      final read = client.get('/servers');
      await Future<void>.delayed(Duration.zero);
      expect(client.user?.id, 'alice');
      expect(adapter.requests, isEmpty);
      final rotated = Session(
        accessToken: 'worker-rotated-fixture',
        refreshToken: 'worker-rotated-fixture',
        cachedUser: {'id': 'alice', 'name': 'Alice'},
      );
      await store.write(client.origin, rotated);
      ownership.complete();
      await read;
      expect(
        adapter.requests
            .singleWhere((r) => r.path == '/servers')
            .headers['Authorization'],
        'Bearer worker-rotated-fixture',
      );
      adapter.gate.complete();
      await client.sessionValidated;
      expect(
        adapter.requests.every(
          (r) => r.headers['Authorization'] == 'Bearer worker-rotated-fixture',
        ),
        isTrue,
      );
      expect(
        (await store.read(client.origin))?.refreshToken,
        'worker-rotated-fixture',
      );
      await client.dispose();
    },
  );

  test(
    'refresh waits for handoff and retries the worker\'s persisted attempt',
    () async {
      final ownership = Completer<void>();
      final (client, adapter, store) = await _restore({
        'id': 'alice',
      }, credentialsReady: ownership.future);
      adapter.rotated = true;
      final refresh = client.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.requests, isEmpty);
      await store.write(
        client.origin,
        Session(
          accessToken: 'worker-fixture',
          refreshToken: 'worker-fixture',
          installationId: 'ari_fixture',
          refreshAttemptId: 'arf_worker_fixture',
          cachedUser: {'id': 'alice'},
        ),
      );
      ownership.complete();
      await refresh;
      final request = adapter.requests.singleWhere(
        (r) => r.path == '/auth/refresh',
      );
      expect(request.data['refreshToken'], 'worker-fixture');
      expect(
        request.headers['X-Slock-Auth-Refresh-Attempt-Id'],
        'arf_worker_fixture',
      );
      expect(request.headers['X-Slock-Auth-Installation-Id'], 'ari_fixture');
      adapter.gate.complete();
      await client.sessionValidated;
      expect(
        (await store.read(client.origin))?.refreshToken,
        'refreshed-fixture',
      );
      await client.dispose();
    },
  );

  for (final replaced in [false, true]) {
    test(
      'handoff ${replaced ? 'to another account' : 'after revocation'} retires cached identity before any request',
      () async {
        final ownership = Completer<void>();
        final (client, adapter, store) = await _restore({
          'id': 'alice',
        }, credentialsReady: ownership.future);
        final ended = client.events.firstWhere(
          (e) => e.name == 'session:ended',
        );
        final request = expectLater(
          client.get('/servers'),
          throwsA(isA<RaftApiException>()),
        );
        await store.write(
          client.origin,
          replaced
              ? Session(
                  accessToken: 'bob-fixture',
                  refreshToken: 'bob-fixture',
                  cachedUser: {'id': 'bob'},
                )
              : null,
        );
        ownership.complete();
        await client.sessionValidated;
        await ended;
        await request;
        expect(client.user, isNull);
        expect(adapter.requests, isEmpty);
        expect(
          (await store.read(client.origin))?.cachedUser?['id'],
          replaced ? 'bob' : null,
        );
        await client.dispose();
      },
    );
  }

  test(
    'logout while awaiting handoff never restores the cached identity',
    () async {
      final ownership = Completer<void>();
      final (client, adapter, store) = await _restore({
        'id': 'alice',
      }, credentialsReady: ownership.future);
      final request = expectLater(
        client.get('/servers'),
        throwsA(isA<RaftApiException>()),
      );
      final logout = client.logout();
      ownership.complete();
      await logout;
      await client.sessionValidated;
      await request;
      expect(adapter.paths, ['POST /auth/logout']);
      expect(await store.read(client.origin), isNull);
      expect(client.user, isNull);
      await client.dispose();
    },
  );

  test(
    'ownership failure preserves cached identity without sending credentials',
    () async {
      final ownership = Completer<void>();
      final (client, adapter, store) = await _restore({
        'id': 'alice',
      }, credentialsReady: ownership.future);
      ownership.completeError(
        const RaftApiException('Fixture owner unavailable'),
      );
      await client.sessionValidated;
      expect(client.restoredOffline, isTrue);
      expect(client.user?.id, 'alice');
      expect(adapter.requests, isEmpty);
      expect((await store.read(client.origin))?.cachedUser?['id'], 'alice');
      await client.dispose();
    },
  );

  test(
    'logout retires requests immediately and revokes the final handoff record',
    () async {
      final ownership = Completer<void>(), revocation = Completer<Session?>();
      final (client, adapter, _) = await _restore({
        'id': 'alice',
      }, credentialsReady: ownership.future);
      final request = expectLater(
        client.get('/servers'),
        throwsA(isA<RaftApiException>()),
      );
      final logout = client.logout(revocationSession: revocation.future);
      expect(client.signedIn, false);
      expect(client.user, isNull);
      ownership.complete();
      revocation.complete(
        Session(
          accessToken: 'worker-fixture',
          refreshToken: 'worker-fixture',
          cachedUser: {'id': 'alice'},
        ),
      );
      await logout;
      await request;
      expect(adapter.requests.single.path, '/auth/logout');
      expect(adapter.requests.single.data['refreshToken'], 'worker-fixture');
      await client.dispose();
    },
  );

  test('socket connection waits for ownership, then can start without waiting for auth/me', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    var connections = 0;
    final subscription = server.listen((request) async {
      connections++;
      if (!accepted.isCompleted) accepted.complete();
      request.response.statusCode = 503;
      await request.response.close();
    });
    final origin = 'http://127.0.0.1:${server.port}';
    final store = MemorySessionStore();
    await store.write(
      origin,
      Session(
        accessToken: 'fixture-only',
        refreshToken: 'fixture-only',
        cachedUser: {'id': 'alice'},
      ),
    );
    final adapter = _Adapter({'id': 'alice'});
    final client = RaftClient(
      origin: origin,
      sessionStore: store,
      transport: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(() async {
      await client.dispose();
      await server.close(force: true);
      await subscription.cancel();
    });
    final ownership = Completer<void>();
    expect(
      await client.restore(
        cachedFirst: true,
        credentialsReady: ownership.future,
      ),
      true,
    );
    client.selectServer('server-a');
    client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(connections, 0);
    expect(adapter.requests, isEmpty);
    ownership.complete();
    await accepted.future.timeout(const Duration(seconds: 2));
    expect(adapter.gate.isCompleted, false);
    adapter.gate.complete();
    await client.sessionValidated;
  });
}
