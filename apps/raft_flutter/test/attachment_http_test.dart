import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/attachment_files.dart';
import 'package:raft_flutter/platform/attachment_html.dart';
import 'package:raft_flutter/platform/attachment_http.dart';
import 'package:raft_flutter/platform/attachment_preview_files.dart';
import 'package:raft_flutter/platform/native_sharing.dart';

void main() {
  setUpAll(() => HttpOverrides.global = null);
  late HttpServer server;
  late List<({String method, String uri, int port, Map<String, List<String>> headers})>
  seen;
  late String base;

  setUp(() async {
    AttachmentHttp.close();
    seen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final headers = <String, List<String>>{};
      request.headers.forEach((k, v) => headers[k] = v);
      seen.add((
        method: request.method,
        uri: request.uri.toString(),
        port: request.connectionInfo!.remotePort,
        headers: headers,
      ));
      request.response
        ..statusCode = 200
        ..add(List<int>.filled(1024, 1));
      await request.response.close();
    });
  });

  tearDown(() async {
    AttachmentHttp.close();
    await server.close(force: true);
  });

  test('every attachment loader defaults to the one shared client', () {
    final shared = AttachmentHttp.shared;
    expect(identical(AttachmentPreviewFiles().dio, shared), isTrue);
    expect(identical(AttachmentHtmlLoader().dio, shared), isTrue);
    expect(identical(AttachmentHttp.shared, shared), isTrue);
    NativeSharing(); // Builds with the shared client; no private pool.
  });

  test('separate loaders reuse one connection to the storage host', () async {
    final cancel = CancelToken();
    for (var i = 0; i < 4; i++) {
      // A new AttachmentFiles per card, as the attachment view builds them.
      final bytes = await AttachmentFiles().image(
        '$base/object/$i?sig=x',
        cancel: cancel,
      );
      expect(bytes.length, 1024);
    }
    expect(seen.length, 4);
    expect(seen.map((r) => r.port).toSet().length, 1);
  });

  test('the shared client carries no credentials of its own', () async {
    await AttachmentFiles().image('$base/o?sig=x', cancel: CancelToken());
    final headers = seen.single.headers;
    expect(headers.containsKey('authorization'), isFalse);
    expect(headers.containsKey('cookie'), isFalse);
    expect(AttachmentHttp.shared.interceptors.whereType<Interceptor>().length, 1,
        reason: 'only dio\'s own import interceptor');
    expect(AttachmentHttp.shared.options.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')));
  });

  test('warming a host sends no path or query and the transfer reuses it', () async {
    AttachmentHttp.warmHost('$base/private/path?X-Amz-Signature=secret');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(seen.single.method, 'HEAD');
    expect(seen.single.uri, '/');
    await AttachmentFiles().image('$base/o?sig=x', cancel: CancelToken());
    expect(seen.length, 2);
    expect(seen.map((r) => r.port).toSet().length, 1);
    // At most one warm-up per host in a short window.
    AttachmentHttp.warmHost('$base/other?sig=y');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(seen.length, 2);
  });

  test('warming ignores unusable addresses and server failure', () async {
    AttachmentHttp.warmHost('file:///etc/passwd');
    AttachmentHttp.warmHost('https://user:pw@example.invalid/x');
    AttachmentHttp.warmHost('not a url');
    AttachmentHttp.warmHost('http://127.0.0.1:1/'); // refused
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(seen, isEmpty);
  });

  test('cancel semantics are unchanged on the shared client', () async {
    final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => slow.close(force: true));
    slow.listen((request) async {
      await Future<void>.delayed(const Duration(seconds: 5));
      await request.response.close().catchError((Object _) => request.response);
    });
    final cancel = CancelToken();
    final future = AttachmentFiles().image(
      'http://127.0.0.1:${slow.port}/o',
      cancel: cancel,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cancel.cancel();
    await expectLater(
      future,
      throwsA(
        isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel),
      ),
    );
  });
}
