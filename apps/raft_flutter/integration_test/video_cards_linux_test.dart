// The real Linux build: a desktop video card without a thumbnail or a size
// shows the video's own first frame (read through libmpv by MpvVideoFrameProbe
// from a few ranged bytes) and the inline player still plays.
//
//   xvfb-run -a tool/flutter test integration_test/video_cards_linux_test.dart -d linux
//
// Makes its media with ffmpeg and serves it from a local byte-counting server.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/attachment_image_repository.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/inline_attachment_media.dart';
import 'package:raft_ui/raft_ui.dart';

class _Client extends RaftClient {
  _Client(this.base)
    : super(origin: 'https://example.invalid', sessionStore: MemorySessionStore());
  final String base;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final id = path.split('/')[2];
    return {'url': '$base/$id.mp4?X-Amz-Signature=fixture'};
  }

  @override
  Future<dynamic> post(String path, {dynamic data}) async => {'urls': []};
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('no thumbnail, no size: first frame from ranged reads; inline player plays', (tester) async {
    final dir = Directory.systemTemp.createTempSync('raft-video-cards-linux');
    addTearDown(() => dir.deleteSync(recursive: true));
    Future<void> make(String name, String size) async {
      final r = await Process.run('ffmpeg', [
        '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=$size:rate=24:duration=40',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=40', '-c:v', 'libx264', '-b:v', '3M',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', '${dir.path}/$name.mp4',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    await tester.runAsync(() async {
      await make('landscape', '1280x720');
      await make('portrait', '720x1280');
    });
    final sent = <String, int>{};
    final requests = <String, int>{};
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      final file = File('${dir.path}/$name');
      final size = file.lengthSync();
      var start = 0, end = size - 1, status = 200;
      final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(request.headers.value('range') ?? '');
      if (range != null) {
        if (range[1]!.isNotEmpty) start = int.parse(range[1]!);
        if (range[2]!.isNotEmpty) end = int.parse(range[2]!).clamp(0, size - 1);
        if (range[1]!.isEmpty && range[2]!.isNotEmpty) {
          start = size - int.parse(range[2]!);
          end = size - 1;
        }
        status = 206;
      }
      requests[name] = (requests[name] ?? 0) + 1;
      request.response
        ..statusCode = status
        ..headers.set('accept-ranges', 'bytes')
        ..headers.contentType = ContentType('video', 'mp4')
        ..contentLength = end - start + 1;
      if (status == 206) request.response.headers.set('content-range', 'bytes $start-$end/$size');
      try {
        await for (final chunk in file.openRead(start, end + 1)) {
          request.response.add(chunk);
          sent[name] = (sent[name] ?? 0) + chunk.length;
          await request.response.flush();
        }
        await request.response.close();
      } on Object {
        // the reader went away
      }
    });
    addTearDown(() => server.close(force: true));

    final client = _Client('http://127.0.0.1:${server.port}')..user = RaftRecord({'id': 'alice'});
    client.selectServer('server');
    final store = AttachmentDiskCache(() async => dir);
    final w = WorkspaceController(client, attachmentImageStore: store)
      ..server = RaftRecord({'id': 'server', 'role': 'owner'})
      ..channel = RaftChannel({'id': 'channel', 'joined': true});
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      w.dispose();
      await client.dispose();
    });
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Map<String, dynamic> clip(String name) => {
      'id': name,
      'channelId': 'channel',
      'filename': '$name.mp4',
      'mimeType': 'video/mp4',
      'sizeBytes': File('${dir.path}/$name.mp4').lengthSync(),
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final name in ['portrait', 'landscape'])
                InlineVideoAttachment(
                  key: ValueKey(name),
                  controller: w,
                  metadata: clip(name),
                  channelId: 'channel',
                  authorized: () => true,
                  pending: false,
                  onOpenPreview: () {},
                ),
            ],
          ),
        ),
      ),
    );
    Finder poster(String name) => find.descendant(
      of: find.byKey(ValueKey(name)),
      matching: find.byType(Image),
    );
    final clock = Stopwatch()..start();
    while ((poster('portrait').evaluate().isEmpty || poster('landscape').evaluate().isEmpty) &&
        clock.elapsed < const Duration(seconds: 60)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(poster('portrait'), findsOneWidget, reason: 'the first frame of the portrait clip');
    expect(poster('landscape'), findsOneWidget);
    final bytes = {for (final e in sent.entries) e.key: e.value};
    final sizes = {
      for (final name in ['portrait', 'landscape']) '$name.mp4': File('${dir.path}/$name.mp4').lengthSync(),
    };
    // ignore: avoid_print
    print('VIDEO-CARDS-LINUX posters after ${clock.elapsedMilliseconds} ms; bytes $bytes of $sizes; requests $requests');
    for (final name in sizes.keys) {
      expect(bytes[name] ?? 0, lessThan(sizes[name]! ~/ 4), reason: '$name: ranged reads, not the file');
    }
    // The inline player is still there and plays on a tap (desktop keeps Web's card).
    expect(find.byType(RaftInlineVideo), findsNWidgets(2));
    expect(find.byType(RaftVideoPosterCard), findsNothing);
    final play = find.descendant(
      of: find.byKey(const ValueKey('landscape')),
      matching: find.byKey(const Key('inline-video-play')),
    );
    expect(play, findsOneWidget);
    await tester.tap(play);
    final card = find.descendant(
      of: find.byKey(const ValueKey('landscape')),
      matching: find.byType(RaftInlineVideo),
    );
    final playClock = Stopwatch()..start();
    while (playClock.elapsed < const Duration(seconds: 40)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      final video = tester.widget<RaftInlineVideo>(card);
      if (video.playing && video.position > const Duration(seconds: 1)) break;
    }
    final video = tester.widget<RaftInlineVideo>(card);
    // ignore: avoid_print
    print('VIDEO-CARDS-LINUX inline playing=${video.playing} position=${video.position}');
    expect(video.playing, isTrue);
    expect(video.position, greaterThan(const Duration(seconds: 1)));
    await tester.pumpWidget(const SizedBox());
  });
}
