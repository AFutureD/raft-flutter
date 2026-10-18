import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/video_cache_proxy.dart';

/// A storage host that counts what it really sent. Serves deterministic bytes
/// (`byteAt`) so a body can be checked without keeping a copy.
class FakeUpstream {
  FakeUpstream();

  late HttpServer server;
  final sizes = <String, int>{};
  final requests = <({String path, String? range, int status})>[];
  int bytesSent = 0;

  /// Per-path behaviour.
  final ignoreRange = <String>{};
  final unsized = <String>{};
  final failing = <String, int>{};

  /// Paths that fail only for requests starting at or after this byte.
  final failFrom = <String, int>{};
  final etags = <String, String>{};
  Duration pause = Duration.zero;

  /// Cut the connection after this many body bytes (per path).
  final cutAfter = <String, int>{};

  static int byteAt(int i) => (i * 31 + 7) & 0xff;
  static Uint8List bytes(int from, int to) =>
      Uint8List.fromList([for (var i = from; i <= to; i++) byteAt(i)]);

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
  Future<void> stop() => server.close(force: true);

  int requestsFor(String path) => requests.where((r) => r.path == path).length;

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final size = sizes[path];
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0, end = (size ?? 1) - 1, status = 200;
    if (size == null) {
      requests.add((path: path, range: range, status: 404));
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    if (size == 0 && range != null) {
      requests.add((path: path, range: range, status: 416));
      request.response
        ..statusCode = 416
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */0')
        ..contentLength = 0;
      await request.response.close();
      return;
    }
    if (range != null && !ignoreRange.contains(path)) {
      final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range)!;
      if (m[1]!.isNotEmpty) start = int.parse(m[1]!);
      if (m[2]!.isNotEmpty) end = int.parse(m[2]!).clamp(0, size - 1);
      if (m[1]!.isEmpty) {
        start = size - int.parse(m[2]!);
        end = size - 1;
      }
      status = 206;
    }
    final failStatus = failing[path];
    if (failStatus != null && start >= (failFrom[path] ?? 0)) {
      requests.add((path: path, range: range, status: failStatus));
      request.response.statusCode = failStatus;
      await request.response.close();
      return;
    }
    requests.add((path: path, range: range, status: status));
    final response = request.response..statusCode = status;
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    final etag = etags[path];
    if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag);
    if (status == 206) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$size',
      );
    }
    if (!unsized.contains(path)) {
      response.contentLength = end - start + 1;
    } else {
      response.headers.chunkedTransferEncoding = true;
    }
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    var sent = 0;
    try {
      for (var at = start; at <= end; at += 16 * 1024) {
        final to = at + 16 * 1024 - 1 > end ? end : at + 16 * 1024 - 1;
        response.add(bytes(at, to));
        bytesSent += to - at + 1;
        sent += to - at + 1;
        await response.flush();
        final cut = cutAfter[path];
        if (cut != null && sent >= cut) {
          (await response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        if (pause > Duration.zero) await Future<void>.delayed(pause);
      }
      await response.close();
    } on Object {
      // The proxy hung up.
    }
  }
}

class Answer {
  Answer(this.status, this.headers, this.body, {this.error});
  final int status;
  final HttpHeaders? headers;
  final Uint8List body;
  final Object? error;
  String? header(String name) => headers?.value(name);
}

Future<Answer> fetch(
  Uri url, {
  String? range,
  String method = 'GET',
  int? stopAfter,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, url);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final out = BytesBuilder(copy: false);
    try {
      await for (final data in response) {
        out.add(data);
        if (stopAfter != null && out.length >= stopAfter) break;
      }
    } on Object catch (error) {
      return Answer(
        response.statusCode,
        response.headers,
        out.takeBytes(),
        error: error,
      );
    }
    return Answer(response.statusCode, response.headers, out.takeBytes());
  } finally {
    client.close(force: true);
  }
}

void main() {
  const chunk = 1000;
  late FakeUpstream upstream;
  late Directory dir;
  late VideoCacheProxy proxy;

  VideoCacheProxy build({
    int maxBytes = 1 << 30,
    int window = 4,
    int size = chunk,
  }) => VideoCacheProxy(
    directory: dir,
    clientFactory: HttpClient.new,
    chunkSize: size,
    maxBytes: maxBytes,
    windowChunks: window,
    stallTimeout: const Duration(seconds: 5),
  );

  // flutter_test answers every HttpClient request with 400; these tests talk
  // to real loopback sockets.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    upstream = FakeUpstream();
    await upstream.start();
    upstream.sizes['/a.mp4'] = 10500; // 10 full chunks and a 500 byte tail
    dir = await Directory.systemTemp.createTemp('vcp');
    proxy = build();
    await proxy.start();
  });

  tearDown(() async {
    await proxy.close();
    await upstream.stop();
    await dir.delete(recursive: true);
  });

  Uri open([String key = 'att-1', String path = '/a.mp4']) =>
      proxy.register(key, upstream.url('$path?sig=1'));

  List<int> expected(int from, int to) => FakeUpstream.bytes(from, to);

  group('parseRangeHeader', () {
    SliceRange slice(int a, int b) => SliceRange(a, b);
    test('forms', () {
      expect(parseRangeHeader(null, 100), isA<FullRange>());
      expect(parseRangeHeader('bytes=0-9', 100), slice(0, 9));
      expect(parseRangeHeader('bytes=10-', 100), slice(10, 99));
      expect(parseRangeHeader('bytes=-10', 100), slice(90, 99));
      expect(parseRangeHeader('bytes=-500', 100), slice(0, 99));
      expect(parseRangeHeader('bytes=99-99', 100), slice(99, 99));
      expect(parseRangeHeader('bytes=90-500', 100), slice(90, 99));
      expect(parseRangeHeader(' BYTES = 5 - 6 ', 100), slice(5, 6));
      expect(
        parseRangeHeader('bytes=0-99999999999999999999999', 100),
        slice(0, 99),
      );
    });
    test('unsatisfiable', () {
      expect(parseRangeHeader('bytes=100-', 100), isA<UnsatisfiableRange>());
      expect(parseRangeHeader('bytes=100-200', 100), isA<UnsatisfiableRange>());
      expect(parseRangeHeader('bytes=-0', 100), isA<UnsatisfiableRange>());
      expect(parseRangeHeader('bytes=0-', 0), isA<UnsatisfiableRange>());
      expect(parseRangeHeader('bytes=-5', 0), isA<UnsatisfiableRange>());
      expect(
        parseRangeHeader('bytes=99999999999999999999999-', 100),
        isA<UnsatisfiableRange>(),
      );
    });
    test('ignored (answered with the whole file)', () {
      expect(parseRangeHeader('bytes=5-2', 100), isA<FullRange>());
      expect(parseRangeHeader('bytes=0-1,5-6', 100), isA<FullRange>());
      expect(parseRangeHeader('bytes=-', 100), isA<FullRange>());
      expect(parseRangeHeader('items=0-1', 100), isA<FullRange>());
      expect(parseRangeHeader('bytes=a-b', 100), isA<FullRange>());
      expect(parseRangeHeader('garbage', 100), isA<FullRange>());
    });
  });

  group('serving', () {
    test(
      'no Range: 200 with the whole file and the upstream headers',
      () async {
        final answer = await fetch(open());
        expect(answer.status, 200);
        expect(answer.body, expected(0, 10499));
        expect(answer.header('content-length'), '10500');
        expect(answer.header('accept-ranges'), 'bytes');
        expect(answer.header('content-type'), 'video/mp4');
        expect(answer.header('content-range'), isNull);
      },
    );

    test('closed, open-ended and suffix ranges, with Content-Range', () async {
      final url = open();
      var a = await fetch(url, range: 'bytes=0-1');
      expect(a.status, 206);
      expect(a.body, expected(0, 1));
      expect(a.header('content-range'), 'bytes 0-1/10500');
      expect(a.header('content-length'), '2');

      a = await fetch(url, range: 'bytes=9500-');
      expect(a.status, 206);
      expect(a.body, expected(9500, 10499));
      expect(a.header('content-range'), 'bytes 9500-10499/10500');

      a = await fetch(url, range: 'bytes=-300');
      expect(a.body, expected(10200, 10499));
      expect(a.header('content-range'), 'bytes 10200-10499/10500');

      a = await fetch(url, range: 'bytes=10000-99999');
      expect(a.body, expected(10000, 10499));
      expect(a.header('content-range'), 'bytes 10000-10499/10500');
    });

    test('chunk boundaries: last byte, first byte, straddling', () async {
      final url = open();
      for (final (from, to) in [
        (999, 999),
        (1000, 1000),
        (999, 1000),
        (1999, 2000),
        (500, 2500),
        (10499, 10499),
        (10000, 10499),
        (0, 999),
        (1000, 1999),
      ]) {
        final a = await fetch(url, range: 'bytes=$from-$to');
        expect(a.status, 206, reason: '$from-$to');
        expect(a.body, expected(from, to), reason: '$from-$to');
        expect(a.header('content-range'), 'bytes $from-$to/10500');
      }
    });

    test('unsatisfiable: 416 with the length', () async {
      final url = open();
      final a = await fetch(url, range: 'bytes=10500-');
      expect(a.status, 416);
      expect(a.header('content-range'), 'bytes */10500');
      expect((await fetch(url, range: 'bytes=-0')).status, 416);
    });

    test(
      'malformed and multiple ranges are answered with the whole file',
      () async {
        final url = open();
        for (final range in ['bytes=5-2', 'bytes=0-1,5-6', 'bytes=x']) {
          final a = await fetch(url, range: range);
          expect(a.status, 200, reason: range);
          expect(a.body, expected(0, 10499));
        }
      },
    );

    test('HEAD answers the headers without a body', () async {
      final a = await fetch(open(), method: 'HEAD', range: 'bytes=10-19');
      expect(a.status, 206);
      expect(a.header('content-length'), '10');
      expect(a.body, isEmpty);
    });

    test('a file smaller than one chunk, and an empty one', () async {
      upstream.sizes['/small.mp4'] = 40;
      upstream.sizes['/empty.mp4'] = 0;
      final small = await fetch(open('s', '/small.mp4'), range: 'bytes=10-');
      expect(small.body, expected(10, 39));
      expect(small.header('content-range'), 'bytes 10-39/40');
      final empty = await fetch(open('e', '/empty.mp4'));
      expect(empty.status, 200);
      expect(empty.body, isEmpty);
      expect(
        (await fetch(open('e', '/empty.mp4'), range: 'bytes=0-')).status,
        416,
      );
    });

    test('the proxy URL keeps the file extension and carries no signature', () {
      final url = open();
      expect(url.host, '127.0.0.1');
      expect(url.path, endsWith('.mp4'));
      expect(url.path, isNot(contains('att-1')));
      expect(url.toString(), isNot(contains('sig=1')));
      expect(url.pathSegments.first, proxy.token);
    });
  });

  group('caching', () {
    test('a second read of the same bytes costs zero upstream bytes', () async {
      final url = open();
      await fetch(url);
      await proxy.flushWrites();
      final sent = upstream.bytesSent, count = upstream.requests.length;
      expect(sent, greaterThanOrEqualTo(10500));
      final again = await fetch(url, range: 'bytes=0-');
      expect(again.body, expected(0, 10499));
      await fetch(url, range: 'bytes=3000-4999');
      expect(upstream.bytesSent, sent);
      expect(upstream.requests.length, count);
      expect(proxy.totalBytes, 10500);
    });

    test('a signed URL that is refreshed keeps the cache', () async {
      await fetch(open());
      await proxy.flushWrites();
      final sent = upstream.bytesSent;
      final next = proxy.register('att-1', upstream.url('/a.mp4?sig=2'));
      expect(next, open());
      await fetch(next);
      expect(upstream.bytesSent, sent);
      expect(upstream.requests.last.path, '/a.mp4');
    });

    test('a new proxy over the same folder serves from disk', () async {
      await fetch(open());
      await proxy.flushWrites();
      final sent = upstream.bytesSent;
      await proxy.close();
      proxy = build();
      await proxy.start();
      expect(proxy.totalBytes, 10500);
      // The upstream is not even reachable.
      upstream.failing['/a.mp4'] = 500;
      final a = await fetch(open(), range: 'bytes=2500-7499');
      expect(a.status, 206);
      expect(a.body, expected(2500, 7499));
      expect(upstream.bytesSent, sent);
    });

    test(
      'only the asked chunks and a bounded window come from upstream',
      () async {
        upstream.sizes['/big.mp4'] = 100 * chunk;
        final a = await fetch(
          open('big', '/big.mp4'),
          range: 'bytes=50000-50009',
        );
        expect(a.body, expected(50000, 50009));
        // The probe takes chunk 0; the answer needs chunk 50 only.
        expect(upstream.bytesSent, 2 * chunk);
        expect(upstream.requests.map((r) => r.range), [
          'bytes=0-${chunk - 1}',
          'bytes=50000-50999',
        ]);
      },
    );

    test('concurrent requests for one chunk fetch it once', () async {
      upstream.pause = const Duration(milliseconds: 20);
      final url = open();
      await fetch(url, range: 'bytes=0-9');
      final before = upstream.requests.length;
      final answers = await Future.wait([
        for (var i = 0; i < 6; i++) fetch(url, range: 'bytes=3000-3999'),
      ]);
      for (final a in answers) {
        expect(a.body, expected(3000, 3999));
      }
      final ranged = upstream.requests.skip(before).toList();
      expect(ranged, hasLength(1));
      expect(ranged.single.range, 'bytes=3000-3999');
    });

    test('overlapping readers share the chunks in flight', () async {
      upstream.pause = const Duration(milliseconds: 10);
      final url = open();
      final results = await Future.wait([
        fetch(url, range: 'bytes=2000-4999'),
        fetch(url, range: 'bytes=3000-5999'),
        fetch(url, range: 'bytes=2500-3500'),
      ]);
      expect(results[0].body, expected(2000, 4999));
      expect(results[1].body, expected(3000, 5999));
      expect(results[2].body, expected(2500, 3500));
      // Chunks 2..5 plus the probe's chunk 0: no byte twice.
      expect(upstream.bytesSent, 5 * chunk);
    });

    test('a content change under the same key drops the old chunks', () async {
      upstream.etags['/a.mp4'] = '"v1"';
      final url = open();
      await fetch(url, range: 'bytes=0-999');
      await fetch(url, range: 'bytes=2000-2999');
      await proxy.flushWrites();
      expect(proxy.totalBytes, 2000);
      upstream.etags['/a.mp4'] = '"v2"';
      // The first request after the change fails (the player retries) and the
      // old chunks are gone; the next one starts over.
      final failed = await fetch(url, range: 'bytes=5000-5999');
      expect(failed.status, 502);
      final ok = await fetch(url, range: 'bytes=5000-5999');
      expect(ok.status, 206);
      expect(ok.body, expected(5000, 5999));
    });
  });

  group('eviction', () {
    test(
      'stays under the cap and drops the least recently used chunk',
      () async {
        await proxy.close();
        proxy = build(maxBytes: 3 * chunk);
        await proxy.start();
        final url = open();
        for (var i = 0; i < 10; i++) {
          await fetch(url, range: 'bytes=${i * chunk}-${i * chunk + 9}');
          // Writing is asynchronous; let it settle before looking.
          await proxy.flushWrites();
          expect(proxy.totalBytes, lessThanOrEqualTo(3 * chunk));
        }
        final files = dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.chunk'))
            .length;
        expect(files, lessThanOrEqualTo(3));
        // Chunk 9 (the newest) is still here; chunk 1 is not.
        var before = upstream.bytesSent;
        await fetch(url, range: 'bytes=9000-9009');
        expect(upstream.bytesSent, before);
        before = upstream.bytesSent;
        await fetch(url, range: 'bytes=1000-1009');
        expect(upstream.bytesSent, before + chunk);
      },
    );

    test('a chunk that is read again outlives older ones', () async {
      await proxy.close();
      proxy = build(maxBytes: 3 * chunk);
      await proxy.start();
      final url = open();
      Future<void> read(int i) async {
        await fetch(url, range: 'bytes=${i * chunk}-${i * chunk + 9}');
        await proxy.flushWrites();
      }

      await read(1);
      await read(2);
      await read(3);
      await read(1); // touch 1: now 2 is the oldest
      await read(4); // evicts 2 (or whatever is oldest), not 1
      final before = upstream.bytesSent;
      await read(1);
      expect(upstream.bytesSent, before, reason: 'chunk 1 stayed');
      await read(2);
      expect(upstream.bytesSent, before + chunk, reason: 'chunk 2 went');
    });

    test('the start-up scan applies a smaller cap', () async {
      await fetch(open());
      await proxy.flushWrites();
      await proxy.close();
      proxy = build(maxBytes: 4 * chunk);
      await proxy.start();
      expect(proxy.totalBytes, lessThanOrEqualTo(4 * chunk));
    });
  });

  group('access control', () {
    test('requests without the token learn nothing and cost nothing', () async {
      final url = open();
      final base = 'http://127.0.0.1:${proxy.port}';
      for (final path in [
        '/${url.pathSegments.last}',
        '/${'0' * 32}/${url.pathSegments.last}',
        '/${proxy.token}x/${url.pathSegments.last}',
        '/${proxy.token.substring(1)}/${url.pathSegments.last}',
        '/${proxy.token}/nope.mp4',
        '/${proxy.token}',
        '/',
      ]) {
        final a = await fetch(Uri.parse('$base$path'));
        expect(a.status, 404, reason: path);
        expect(a.body, isEmpty);
      }
      expect(upstream.requests, isEmpty);
    });

    test('only GET and HEAD', () async {
      final a = await fetch(open(), method: 'POST');
      expect(a.status, 405);
      expect(upstream.requests, isEmpty);
    });

    test('binds the loopback interface only', () {
      expect(proxy.running, isTrue);
      expect(
        // The server is private; the URL is what players get.
        open().host,
        '127.0.0.1',
      );
    });
  });

  group('upstream failures', () {
    test('403 on the first request reaches the player as 403', () async {
      upstream.failing['/a.mp4'] = 403;
      final a = await fetch(open(), range: 'bytes=0-');
      expect(a.status, 403);
      expect(a.body, isEmpty);
      // A fresh signature works afterwards, nothing is stuck.
      upstream.failing.remove('/a.mp4');
      final b = await fetch(
        proxy.register('att-1', upstream.url('/a.mp4?sig=2')),
      );
      expect(b.status, 200);
      expect(b.body, expected(0, 10499));
    });

    test('404, 410 propagate; 500 becomes 502', () async {
      for (final (status, shown) in [(404, 404), (410, 410), (500, 502)]) {
        upstream.failing['/a.mp4'] = status;
        final a = await fetch(open('k$status'));
        expect(a.status, shown);
      }
    });

    test(
      '403 on a later chunk before any byte is out reaches the player',
      () async {
        final url = open();
        await fetch(url, range: 'bytes=0-9');
        upstream.failing['/a.mp4'] = 403;
        final a = await fetch(url, range: 'bytes=5000-');
        expect(a.status, 403);
      },
    );

    test('a failure after bytes went out cuts the connection', () async {
      final url = open();
      await fetch(url, range: 'bytes=0-9');
      upstream.failing['/a.mp4'] = 403;
      upstream.failFrom['/a.mp4'] = 3000;
      final a = await fetch(url, range: 'bytes=0-');
      expect(a.status, 206);
      expect(a.error, isNotNull, reason: 'the body must not look complete');
      expect(a.body.length, lessThan(10500));
    });

    test('an upstream that dies mid-chunk fails the request and caches nothing partial', () async {
      final url = open();
      await fetch(url, range: 'bytes=0-9');
      upstream.cutAfter['/a.mp4'] = 500;
      final a = await fetch(url, range: 'bytes=4000-4999');
      expect(a.error != null || a.status >= 500, isTrue);
      upstream.cutAfter.clear();
      final b = await fetch(url, range: 'bytes=4000-4999');
      expect(b.body, expected(4000, 4999));
    });

    test('an unreachable upstream is a 502', () async {
      final port = upstream.server.port;
      await upstream.stop();
      final a = await fetch(
        proxy.register('x', Uri.parse('http://127.0.0.1:$port/a.mp4')),
      );
      expect(a.status, 502);
      upstream = FakeUpstream();
      await upstream.start();
    });
  });

  group('upstreams that do not behave', () {
    test('ignoring Range still serves ranges and caches', () async {
      upstream.ignoreRange.add('/a.mp4');
      final url = open();
      final a = await fetch(url, range: 'bytes=3500-4499');
      expect(a.status, 206);
      expect(a.body, expected(3500, 4499));
      await proxy.flushWrites();
      final sent = upstream.bytesSent;
      final b = await fetch(url, range: 'bytes=3500-4499');
      expect(b.body, expected(3500, 4499));
      expect(upstream.bytesSent, sent, reason: 'cached');
      expect(upstream.requests.every((r) => r.status == 200), isTrue);
    });

    test('ignoring Range does not read past what was needed', () async {
      const big = 64 * 1024;
      await proxy.close();
      proxy = build(size: big);
      await proxy.start();
      upstream.sizes['/big.mp4'] = 100 * big;
      upstream.ignoreRange.add('/big.mp4');
      // Paced, so the proxy sees the body in small blocks like a real link.
      upstream.pause = const Duration(milliseconds: 1);
      final a = await fetch(
        open('big', '/big.mp4'),
        range: 'bytes=${2 * big}-${2 * big + 9}',
      );
      expect(a.body, expected(2 * big, 2 * big + 9));
      // The body is read from byte 0 up to the chunk that was needed (after
      // the probe's own chunk), not to the end of the 6.4 MB file.
      expect(proxy.upstreamBytes, lessThanOrEqualTo(5 * big));
    });

    test('a body without a length is passed through', () async {
      upstream.unsized.add('/a.mp4');
      upstream.ignoreRange.add('/a.mp4');
      final a = await fetch(open());
      expect(a.status, 200);
      expect(a.body, expected(0, 10499));
      expect(proxy.totalBytes, 0);
    });
  });

  group('player behaviour', () {
    const big = 64 * 1024;
    setUp(() async {
      await proxy.close();
      proxy = build(size: big);
      await proxy.start();
      upstream.sizes['/big.mp4'] = 400 * big;
      upstream.pause = const Duration(milliseconds: 3);
    });

    test('a player that disconnects stops the upstream', () async {
      final url = open('big', '/big.mp4');
      final a = await fetch(url, range: 'bytes=0-', stopAfter: big ~/ 2);
      expect(a.body.length, greaterThanOrEqualTo(big ~/ 2));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final settled = proxy.upstreamBytes;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(proxy.upstreamBytes, settled, reason: 'no more is taken');
      // The probe's chunk, the 4 chunk window of the request and a window
      // started for the read-ahead at most; the file is 400 chunks.
      expect(settled, lessThanOrEqualTo(10 * big));
    });

    test('an open-ended request is paced by the player', () async {
      final url = open('big', '/big.mp4');
      final a = await fetch(url, range: 'bytes=0-', stopAfter: 3 * big);
      expect(a.status, 206);
      expect(a.body.sublist(0, 3 * big), expected(0, 3 * big - 1));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(proxy.upstreamBytes, lessThanOrEqualTo(14 * big));
    });

    test('seeking back after the end plays from disk', () async {
      final url = open();
      await fetch(url, range: 'bytes=0-');
      await proxy.flushWrites();
      final sent = upstream.bytesSent;
      for (final r in ['bytes=0-1', 'bytes=0-', 'bytes=5000-', 'bytes=-1024']) {
        await fetch(url, range: r);
      }
      expect(upstream.bytesSent, sent);
    });
  });

  group('clear', () {
    test('removes every chunk and the next read starts over', () async {
      final url = open();
      await fetch(url);
      await proxy.flushWrites();
      expect(proxy.totalBytes, 10500);
      await proxy.clear();
      expect(proxy.totalBytes, 0);
      expect(dir.listSync(), isEmpty);
      final sent = upstream.bytesSent;
      final a = await fetch(url, range: 'bytes=0-999');
      expect(a.body, expected(0, 999));
      expect(upstream.bytesSent, greaterThan(sent));
    });

    test('stops what is in flight', () async {
      const big = 64 * 1024;
      await proxy.close();
      proxy = build(size: big);
      await proxy.start();
      upstream.sizes['/big.mp4'] = 200 * big;
      upstream.pause = const Duration(milliseconds: 5);
      final url = open('big', '/big.mp4');
      final pending = fetch(url, range: 'bytes=0-');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await proxy.clear();
      final a = await pending;
      expect(a.body.length, lessThan(200 * big));
      expect(a.error, isNotNull);
      expect(proxy.totalBytes, 0);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        dir.listSync().whereType<Directory>().expand((d) => d.listSync()),
        isEmpty,
      );
    });
  });
}
