import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/attachment_player.dart';
import 'package:raft_flutter/platform/attachment_player_factory.dart';
import 'package:raft_flutter/platform/video_player_attachment_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Platform extends VideoPlayerPlatform {
  final calls = <String>[];
  final streams = <int, StreamController<VideoEvent>>{};
  final volumes = <double>[];
  final seeks = <Duration>[];
  final sources = <DataSource>[];
  bool failOpen = false;
  Size size = const Size(1280, 720);
  Duration duration = const Duration(seconds: 10);

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('create');
    sources.add(options.dataSource);
    final stream = StreamController<VideoEvent>();
    streams[0] = stream;
    if (failOpen) {
      stream.addError(PlatformException(code: 'VideoError', message: 'bad'));
    } else {
      stream.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: size,
          duration: duration,
        ),
      );
    }
    return 0;
  }

  @override
  Future<void> dispose(int playerId) async => calls.add('dispose');
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> play(int playerId) async => calls.add('play');
  @override
  Future<void> pause(int playerId) async => calls.add('pause');
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {
    calls.add('volume');
    volumes.add(volume);
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool prevents,
  ) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seek');
    seeks.add(position);
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildView(int playerId) => const SizedBox(key: Key('texture'));
}

void main() {
  late _Platform fake;
  late VideoPlayerPlatform previous;
  setUp(() {
    previous = VideoPlayerPlatform.instance;
    fake = _Platform();
    VideoPlayerPlatform.instance = fake;
  });
  tearDown(() => VideoPlayerPlatform.instance = previous);

  group('backend selection', () {
    test('system player on Android, iOS and macOS; media_kit elsewhere', () {
      for (final p in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        expect(attachmentBackendFor(p), AttachmentBackend.system, reason: '$p');
      }
      for (final p in [TargetPlatform.windows, TargetPlatform.linux]) {
        expect(attachmentBackendFor(p), AttachmentBackend.mediaKit);
      }
    });

    test('the factory builds the right class and never touches media_kit '
        'on system platforms', () {
      var mediaKit = 0;
      final stub = _Stub();
      for (final p in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        final player = createAttachmentPlayer(
          platform: p,
          debugMediaKit: () {
            mediaKit++;
            return stub;
          },
        );
        expect(player, isA<VideoPlayerAttachmentPlayer>());
        unawaited(player.dispose());
      }
      expect(mediaKit, 0);
      for (final p in [TargetPlatform.windows, TargetPlatform.linux]) {
        expect(
          createAttachmentPlayer(platform: p, debugMediaKit: () => stub),
          same(stub),
        );
      }
    });
  });

  group('VideoPlayerAttachmentPlayer', () {
    test('opens paused and maps state', () async {
      final player = VideoPlayerAttachmentPlayer();
      final seen = <AttachmentPlayback>[];
      player.changes.listen(seen.add);
      await player.open(File('/tmp/raft-test/clip one.mp4'));
      await Future<void>.delayed(Duration.zero);
      expect(fake.sources.single.sourceType, DataSourceType.file);
      expect(fake.sources.single.uri, startsWith('file:///'));
      expect(fake.calls, isNot(contains('play')));
      final first = seen.last;
      expect(first.playing, false);
      expect(first.error, false);
      expect(first.duration, const Duration(seconds: 10));
      expect(first.videoSize, const Size(1280, 720));
      expect(first.volume, 100);
      expect(first.hasFrame, false);

      await player.toggle();
      await Future<void>.delayed(Duration.zero);
      expect(fake.calls, contains('play'));
      expect(seen.last.playing, true);
      await player.toggle();
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.playing, false);

      await player.volume(0);
      await player.volume(50);
      await player.volume(250);
      expect(fake.volumes, containsAllInOrder([0.0, 0.5, 1.0]));
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.volume, 100);

      await player.seek(const Duration(seconds: 4));
      await player.seek(const Duration(seconds: 99));
      await player.seek(const Duration(seconds: -3));
      expect(fake.seeks, [
        const Duration(seconds: 4),
        const Duration(seconds: 10),
        Duration.zero,
      ]);
      await player.dispose();
    });

    test('an audio file has no picture size and plays', () async {
      fake.size = Size.zero;
      final player = VideoPlayerAttachmentPlayer();
      final seen = <AttachmentPlayback>[];
      player.changes.listen(seen.add);
      await player.open(File('/tmp/raft-test/a.wav'));
      await player.toggle();
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.videoSize, isNull);
      expect(seen.last.playing, true);
      expect(seen.last.error, false);
      await player.dispose();
    });

    test('no frame is reported before the picture was built', () async {
      final player = VideoPlayerAttachmentPlayer(transparentVideo: true);
      final seen = <AttachmentPlayback>[];
      player.changes.listen(seen.add);
      await player.open(File('/tmp/raft-test/c.mp4'));
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.hasFrame, false);
    });

    testWidgets('video() is empty until sized, then contains the picture', (
      tester,
    ) async {
      final player = VideoPlayerAttachmentPlayer(transparentVideo: true);
      final seen = <AttachmentPlayback>[];
      player.changes.listen(seen.add);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(width: 400, height: 400, child: player.video()),
          ),
        ),
      );
      expect(find.byKey(const Key('texture')), findsNothing);
      await tester.runAsync(() => player.open(File('/tmp/raft-test/c.mp4')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('texture')), findsOneWidget);
      expect(tester.getSize(find.byType(AspectRatio)), const Size(400, 225));
      expect(seen.last.hasFrame, true);
      final colored = tester.widget<ColoredBox>(find.byType(ColoredBox).first);
      expect(colored.color, const Color(0x00000000));
      await tester.runAsync(player.dispose);
    });

    test('a failed open publishes the failure and throws', () async {
      fake.failOpen = true;
      final player = VideoPlayerAttachmentPlayer();
      final seen = <AttachmentPlayback>[];
      player.changes.listen(seen.add);
      await expectLater(
        player.open(File('/tmp/raft-test/bad.mp4')),
        throwsA(anything),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.any((e) => e.error), true);
      await player.dispose();
    });

    test('a playback error is a failure; buffering is not', () async {
      final player = VideoPlayerAttachmentPlayer();
      final seen = <AttachmentPlayback>[];
      player.changes.listen(seen.add);
      await player.open(File('/tmp/raft-test/c.mp4'));
      fake.streams[0]!.add(
        VideoEvent(eventType: VideoEventType.bufferingStart),
      );
      fake.streams[0]!.add(VideoEvent(eventType: VideoEventType.bufferingEnd));
      await Future<void>.delayed(Duration.zero);
      expect(seen.any((e) => e.error), false);
      fake.streams[0]!.addError(
        PlatformException(code: 'VideoError', message: 'decoder'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.error, true);
      // The failure is sticky and the known length is kept.
      expect(seen.last.duration, const Duration(seconds: 10));
      await player.dispose();
    });

    test('toggle after the end restarts from the beginning', () async {
      final player = VideoPlayerAttachmentPlayer();
      await player.open(File('/tmp/raft-test/c.mp4'));
      fake.streams[0]!.add(VideoEvent(eventType: VideoEventType.completed));
      await Future<void>.delayed(Duration.zero);
      fake.calls.clear();
      await player.toggle();
      expect(fake.calls, containsAllInOrder(['seek', 'play']));
      expect(fake.seeks.last, Duration.zero);
      await player.dispose();
    });

    test(
      'dispose releases the native player once and closes the stream',
      () async {
        final player = VideoPlayerAttachmentPlayer();
        var done = false;
        player.changes.listen((_) {}, onDone: () => done = true);
        await player.open(File('/tmp/raft-test/c.mp4'));
        await player.dispose();
        await player.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(fake.calls.where((c) => c == 'dispose'), hasLength(1));
        expect(done, true);
        // Late calls are ignored, not forwarded to a released player.
        fake.calls.clear();
        await player.toggle();
        await player.pause();
        await player.seek(Duration.zero);
        await player.volume(10);
        expect(fake.calls, isEmpty);
      },
    );

    test('leaving the app pauses and returning does not resume', () async {
      final player = VideoPlayerAttachmentPlayer();
      await player.open(File('/tmp/raft-test/c.mp4'));
      await player.toggle();
      fake.calls.clear();
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(fake.calls, ['pause']);
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(fake.calls, ['pause']);
      await player.dispose();
    });
  });
}

class _Stub implements AttachmentPlayer {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
