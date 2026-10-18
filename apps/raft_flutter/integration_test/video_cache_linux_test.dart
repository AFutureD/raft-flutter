// The video cache through the real desktop player
// (mpv via media_kit, Linux and Windows): a range server that counts what it
// sends, real clips, the production proxy. Needs a clip named portrait.mp4 in
// --dart-define=VC_MEDIA=<dir>:
//
//   xvfb-run -a tool/flutter test integration_test/video_cache_linux_test.dart -d linux \
//     --dart-define=VC_MEDIA=/path/to/media
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:raft_flutter/platform/attachment_player.dart'
    show AttachmentSource, NativeAttachmentPlayer;
import 'package:raft_flutter/platform/video_cache.dart';

const _media = String.fromEnvironment('VC_MEDIA');

/// A static file server with ranges that counts bytes and requests per file
/// and remembers who asked.
class RangeServer {
  RangeServer(this.root);
  final Directory root;
  late final HttpServer server;
  final bytes = <String, int>{};
  final requests = <String, int>{};
  final agents = <String>{};

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      final file = File('${root.path}/$name');
      final response = request.response;
      if (!file.existsSync()) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      agents.add(request.headers.value('user-agent') ?? '');
      final size = file.lengthSync();
      var start = 0, end = size - 1;
      final m = RegExp(r'bytes=(\d*)-(\d*)')
          .firstMatch(request.headers.value('range') ?? '');
      response.headers
        ..set('accept-ranges', 'bytes')
        ..set('content-type', 'video/mp4');
      if (m != null) {
        if (m[1]!.isNotEmpty) start = int.parse(m[1]!);
        if (m[2]!.isNotEmpty) end = int.parse(m[2]!).clamp(0, size - 1);
        response.statusCode = 206;
        response.headers.set('content-range', 'bytes $start-$end/$size');
      }
      response.contentLength = end - start + 1;
      requests[name] = (requests[name] ?? 0) + 1;
      try {
        await response.addStream(
          file.openRead(start, end + 1).map((chunk) {
            bytes[name] = (bytes[name] ?? 0) + chunk.length;
            return chunk;
          }),
        );
        await response.close();
      } on Object {
        // The proxy or the player hung up.
      }
    });
  }

  Uri url(String name, {int sig = 1}) =>
      Uri.parse('http://127.0.0.1:${server.port}/$name?sig=$sig');
  Future<void> stop() => server.close(force: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final account = VideoCacheAccount('https://raft.example', 'alice');
  late RangeServer server;
  late Directory cacheRoot;

  setUp(() async {
    server = RangeServer(Directory(_media));
    await server.start();
    cacheRoot = await Directory.systemTemp.createTemp('vc-linux');
    VideoCache.debugRoot = cacheRoot;
    VideoCache.debugEnabled = true;
  });

  tearDown(() async {
    await VideoCache.debugReset();
    VideoCache.debugRoot = null;
    VideoCache.debugEnabled = null;
    await server.stop();
    await cacheRoot.delete(recursive: true);
  });

  AttachmentSource sourceOf(String name, {int sig = 1}) =>
      AttachmentSource.network(
        server.url(name, sig: sig),
        cacheKey: name,
        cacheAccount: account,
      );

  Future<NativeAttachmentPlayer> open(
    WidgetTester tester,
    AttachmentSource source,
  ) async {
    final player = NativeAttachmentPlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(width: 270, height: 480, child: player.video()),
        ),
      ),
    );
    await player.open(source);
    for (
      var i = 0;
      i < 200 && player.player.state.duration == Duration.zero;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      player.player.state.duration,
      greaterThan(Duration.zero),
      reason: 'the clip opened',
    );
    return player;
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() done,
    String what, {
    int seconds = 40,
  }) async {
    for (var i = 0; i < seconds * 10 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(done(), isTrue, reason: 'timed out waiting for $what');
  }

  Future<void> close(WidgetTester tester, NativeAttachmentPlayer player) async {
    await player.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets(
    'a clip seen once plays again with no upstream bytes (play, seek, close, reopen)',
    (tester) async {
      var player = await open(tester, sourceOf('portrait.mp4'));
      await player.toggle();
      await until(
        tester,
        () => player.player.state.position > const Duration(milliseconds: 1500),
        'playback',
      );
      await player.seek(const Duration(seconds: 12));
      await until(
        tester,
        () => player.player.state.position >= const Duration(seconds: 12),
        'the seek',
      );
      // The proxy reads ahead of the player: wait for the whole file to have come once.
      final size = File('$_media/portrait.mp4').lengthSync();
      await until(
        tester,
        () => (server.bytes['portrait.mp4'] ?? 0) >= size,
        'the whole clip through the proxy',
      );
      final first = (
        bytes: server.bytes['portrait.mp4']!,
        requests: server.requests['portrait.mp4']!,
      );
      expect(server.agents, {
        'RaftVideoCache/1',
      }, reason: 'mpv read the loopback proxy, the proxy read the server');
      await close(tester, player);

      for (var i = 1; i <= 2; i++) {
        // A new player and a newly signed URL, as a reopened viewer has.
        player = await open(tester, sourceOf('portrait.mp4', sig: 1 + i));
        await player.toggle();
        await until(
          tester,
          () =>
              player.player.state.position > const Duration(milliseconds: 1500),
          'playback again',
        );
        await player.seek(Duration(seconds: 4 * i));
        await tester.pump(const Duration(seconds: 1));
        expect(
          server.bytes['portrait.mp4'],
          first.bytes,
          reason: 'reopen $i fetched bytes again',
        );
        expect(
          server.requests['portrait.mp4'],
          first.requests,
          reason: 'reopen $i made a request',
        );
        await close(tester, player);
      }
      debugPrint(
        'video-cache-linux: upstream bytes ${first.bytes} in ${first.requests} requests, unchanged by 2 reopens',
      );
    },
  );

  testWidgets('purging the account deletes its cached videos', (tester) async {
    final player = await open(tester, sourceOf('portrait.mp4'));
    await player.toggle();
    final size = File('$_media/portrait.mp4').lengthSync();
    await until(
      tester,
      () => (server.bytes['portrait.mp4'] ?? 0) >= size,
      'the clip through the proxy',
    );
    await close(tester, player);
    final folder = await VideoCache.directoryOf(account);
    expect(folder.existsSync(), isTrue);
    expect(await VideoCache.sizeBytes(account), greaterThanOrEqualTo(size));
    await VideoCache.purgeAccount('https://raft.example', 'alice');
    expect(folder.existsSync(), isFalse);
  });
}
