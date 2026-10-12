import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/inline_attachment_media.dart';
import 'package:raft_flutter/platform/attachment_player.dart';
import 'package:raft_flutter/platform/attachment_preview_files.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'message_presentation_test.dart' show MessageAdapter, fixture;

class _Files extends AttachmentPreviewFiles {
  _Files(this.lease, {this.refuse = false});
  final SharedFileLease lease;

  /// The download is refused (too large / cancelled): no private copy.
  final bool refuse;
  @override
  Future<SharedFileLease?> load(
    String url,
    String filename, {
    required CancelToken cancel,
    required bool Function() authorized,
    void Function(int, int)? onProgress,
  }) async => refuse ? null : lease;
}

class _Player implements AttachmentPlayer {
  final events = StreamController<AttachmentPlayback>.broadcast();
  final calls = <String>[];
  bool disposed = false;
  @override
  Stream<AttachmentPlayback> get changes => events.stream;
  @override
  Widget video() =>
      const ColoredBox(key: Key('fake-video-surface'), color: Colors.red);
  @override
  Future<void> open(File file) async {
    calls.add('open');
    events.add(const AttachmentPlayback(duration: Duration(seconds: 125)));
  }

  @override
  Future<void> toggle() async => calls.add('toggle');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration value) async =>
      calls.add('seek:${value.inSeconds}');
  @override
  Future<void> volume(double value) async =>
      calls.add('volume:${value.round()}');
  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(events.close());
  }
}

/// A player that keeps play state like the native one: `toggle` flips it and
/// publishes the new playback.
class _VideoPlayer extends _Player {
  _VideoPlayer({this.frame = true});

  /// The surface has drawn its first frame.
  bool frame;
  bool playing = false;
  Duration position = Duration.zero;
  AttachmentPlayback get state => AttachmentPlayback(
    playing: playing,
    position: position,
    duration: const Duration(seconds: 125),
    hasFrame: frame,
  );
  @override
  Future<void> open(File file) async {
    calls.add('open');
    events.add(state);
  }

  @override
  Future<void> toggle() async {
    calls.add('toggle');
    playing = !playing;
    events.add(state);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing = false;
    events.add(state);
  }

  @override
  Future<void> seek(Duration value) async {
    calls.add('seek:${value.inSeconds}');
    position = value;
    events.add(state);
  }

  @override
  Future<void> volume(double value) async {
    calls.add('volume:${value.round()}');
  }
}

/// Unmount and let the asynchronous player / lease disposal finish (the lease
/// cancels its expiry timer).
dynamic _mounted;

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // The session cache owns the copy; its lease timer ends with the test.
  _mounted?.inlineMedia.clear();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('audio timestamps read m:ss and bound unknown values', () {
    expect(raftAudioTimestamp(Duration.zero), '0:00');
    expect(raftAudioTimestamp(const Duration(seconds: 65)), '1:05');
    expect(raftAudioTimestamp(const Duration(milliseconds: 9999)), '0:09');
    expect(raftAudioTimestamp(const Duration(seconds: -3)), '0:00');
  });

  Future<(MessageAdapter, _Player, SharedFileLease)> mount(
    WidgetTester tester, {
    required Widget Function(dynamic w, _Files files, _Player player) build,
    bool failUrl = false,
  }) async {
    tester.view.physicalSize = const Size(600, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (w, api) = (await tester.runAsync(() => fixture('owner')))!;
    addTearDown(w.dispose);
    _mounted = w;
    api.routes['GET /attachments/a1/url'] = (_) => failUrl
        ? throw StateError('no url')
        : {'url': 'https://media.invalid/a1'};
    // Synchronous IO: the test body runs in a fake-async zone.
    final dir = Directory.systemTemp.createTempSync('inline-media-test');
    final file = File('${dir.path}/clip.bin')..writeAsBytesSync([1, 2, 3]);
    final lease = SharedFileLease(file, lifetime: const Duration(hours: 1));
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final player = _Player();
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: Scaffold(body: build(w, _Files(lease), player)),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return (api, player, lease);
  }

  testWidgets('audio: loads, plays, seeks and sets the volume', (tester) async {
    var downloads = 0;
    final (_, player, _) = await mount(
      tester,
      build: (w, files, player) => InlineAudioAttachment(
        controller: w,
        metadata: const {
          'id': 'a1',
          'filename': 'standup.mp3',
          'mimeType': 'audio/mpeg',
        },
        authorized: () => true,
        pending: false,
        onDownload: () => downloads++,
        files: files,
        playerFactory: () => player,
      ),
    );
    expect(find.text('standup.mp3'), findsOneWidget);
    expect(find.text('Audio file'), findsOneWidget);
    expect(player.calls, ['open']);
    // Metadata known: 0:00 / 2:05.
    expect(find.text('0:00 / 2:05'), findsOneWidget);
    await tester.tap(find.byKey(const Key('audio-play-toggle')));
    await tester.pump();
    expect(player.calls.last, 'toggle');
    player.events.add(
      const AttachmentPlayback(
        playing: true,
        position: Duration(seconds: 61),
        duration: Duration(seconds: 125),
        volume: 100,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('1:01 / 2:05'), findsOneWidget);
    // Pressing the middle of the seek rail seeks to about half.
    final rail = tester.getRect(find.byKey(const Key('audio-seek')));
    await tester.tapAt(Offset(rail.left + rail.width / 2, rail.center.dy));
    await tester.pump();
    final seek = player.calls.where((c) => c.startsWith('seek:')).last;
    expect(int.parse(seek.substring(5)), inInclusiveRange(61, 64));
    final volume = tester.getRect(find.byKey(const Key('audio-volume')));
    await tester.tapAt(
      Offset(volume.left + volume.width * .25, volume.center.dy),
    );
    await tester.pump();
    expect(player.calls.last, 'volume:25');
    await tester.tap(find.byKey(const Key('audio-download')));
    expect(downloads, 1);
    await unmount(tester);
    expect(player.disposed, isTrue);
  });

  testWidgets('audio: a failed URL read offers Download to view', (
    tester,
  ) async {
    var downloads = 0;
    final (_, _, lease) = await mount(
      tester,
      failUrl: true,
      build: (w, files, player) => InlineAudioAttachment(
        controller: w,
        metadata: const {'id': 'a1', 'filename': 'standup.mp3'},
        authorized: () => true,
        pending: false,
        onDownload: () => downloads++,
        files: files,
        playerFactory: () => player,
      ),
    );
    expect(find.text('Download to view'), findsOneWidget);
    // The header download action is hidden once the load failed; the
    // placeholder itself downloads.
    expect(find.byKey(const Key('audio-download')), findsNothing);
    await tester.tap(find.byKey(const Key('audio-placeholder')));
    expect(downloads, 1);
    unawaited(lease.dispose());
    await unmount(tester);
  });

  testWidgets(
    'video: the player fills the 16:9 box; the corner opens the preview',
    (tester) async {
      var opened = 0;
      final (_, player, _) = await mount(
        tester,
        build: (w, files, player) => InlineVideoAttachment(
          controller: w,
          metadata: const {
            'id': 'a1',
            'filename': 'walkthrough.mp4',
            'mimeType': 'video/mp4',
          },
          authorized: () => true,
          pending: false,
          onOpenPreview: () => opened++,
          files: files,
          playerFactory: () => player,
        ),
      );
      expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);
      final box = tester.getRect(find.byKey(const Key('inline-video')));
      expect(box.width / box.height, closeTo(16 / 9, .02));
      expect(box.width, lessThanOrEqualTo(448));
      await tester.tap(find.byKey(const Key('inline-video-expand')));
      expect(opened, 1);
      await unmount(tester);
      expect(player.disposed, isTrue);
    },
  );

  testWidgets('video: a failed load shows the codec warning and a download', (
    tester,
  ) async {
    var downloads = 0;
    final (_, _, lease) = await mount(
      tester,
      failUrl: true,
      build: (w, files, player) => InlineVideoAttachment(
        controller: w,
        metadata: const {'id': 'a1', 'filename': 'walkthrough.mp4'},
        authorized: () => true,
        pending: false,
        onDownload: () => downloads++,
        files: files,
        playerFactory: () => player,
      ),
    );
    expect(
      find.text('This video may use a codec this browser cannot preview.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Download to view'));
    expect(downloads, 1);
    unawaited(lease.dispose());
    await unmount(tester);
  });

  testWidgets('an optimistic attachment never reads its URL', (tester) async {
    final (api, player, lease) = await mount(
      tester,
      build: (w, files, player) => InlineAudioAttachment(
        controller: w,
        metadata: const {'id': 'a1', 'filename': 'standup.mp3'},
        authorized: () => true,
        pending: true,
        files: files,
        playerFactory: () => player,
      ),
    );
    expect(api.calls.where((c) => c.path.contains('/attachments/')), isEmpty);
    expect(find.text('Loading standup.mp3'), findsOneWidget);
    expect(find.byKey(const Key('audio-download')), findsNothing);
    expect(player.calls, isEmpty);
    unawaited(lease.dispose());
    await unmount(tester);
  });

  group('video card controls', () {
    const meta = {
      'id': 'a1',
      'filename': 'walkthrough.mp4',
      'mimeType': 'video/mp4',
      'sizeBytes': 1000000,
    };

    final linux = TargetPlatformVariant.only(TargetPlatform.linux);

    Future<(_VideoPlayer, SharedFileLease)> mountVideo(
      WidgetTester tester, {
      Map<String, dynamic> metadata = meta,
      VoidCallback? onOpenPreview,
      bool refuse = false,
      bool frame = true,
    }) async {
      tester.view.physicalSize = const Size(600, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (w, api) = (await tester.runAsync(() => fixture('owner')))!;
      addTearDown(w.dispose);
      api.routes['GET /attachments/a1/url'] = (_) => {
        'url': 'https://media.invalid/a1',
      };
      final dir = Directory.systemTemp.createTempSync('inline-video-test');
      final file = File('${dir.path}/clip.bin')..writeAsBytesSync([1, 2, 3]);
      final lease = SharedFileLease(file, lifetime: const Duration(hours: 1));
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final player = _VideoPlayer(frame: frame);
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: Scaffold(
            body: InlineVideoAttachment(
              controller: w,
              metadata: metadata,
              authorized: () => true,
              pending: false,
              onOpenPreview: onOpenPreview,
              files: _Files(lease, refuse: refuse),
              playerFactory: () => player,
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return (player, lease);
    }

    testWidgets(
      'idle poster: the first frame, the bar, a Play button on hover',
      (tester) async {
        final (player, _) = await mountVideo(tester);
        expect(player.calls, ['open']);
        expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);
        // Paused: the browser's control panel is showing, the big Play is not.
        expect(find.byKey(const Key('inline-video-bar')), findsOneWidget);
        expect(find.byKey(const Key('inline-video-play')), findsNothing);
        expect(find.text('0:00 / 2:05'), findsOneWidget);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('inline-video'))),
        );
        await tester.pump();
        expect(find.byKey(const Key('inline-video-play')), findsOneWidget);
        await mouse.moveTo(const Offset(590, 490));
        await tester.pump();
        expect(find.byKey(const Key('inline-video-play')), findsNothing);
        await unmount(tester);
      },
      variant: linux,
    );

    testWidgets('a click plays, hides the bar off hover and pauses again', (
      tester,
    ) async {
      final (player, _) = await mountVideo(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('inline-video'))),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.calls, ['open', 'toggle']);
      expect(player.playing, isTrue);
      // Playing under the pointer keeps the controls; leaving hides them.
      expect(find.byKey(const Key('inline-video-bar')), findsOneWidget);
      expect(find.byKey(const Key('inline-video-play')), findsNothing);
      await mouse.moveTo(const Offset(590, 490));
      await tester.pump();
      expect(find.byKey(const Key('inline-video-bar')), findsNothing);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('inline-video'))),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('inline-video-toggle')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.playing, isFalse);
      // Seek, mute and the open-in-viewer control.
      final rail = tester.getRect(find.byKey(const Key('inline-video-seek')));
      await tester.tapAt(Offset(rail.left + rail.width / 2, rail.center.dy));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        int.parse(
          player.calls.where((c) => c.startsWith('seek:')).last.substring(5),
        ),
        inInclusiveRange(61, 64),
      );
      await tester.tap(find.byKey(const Key('inline-video-mute')));
      await tester.pump();
      expect(player.calls.last, 'volume:0');
      await unmount(tester);
    }, variant: linux);

    testWidgets('playing under a resting mouse hides the bar after 3 s; a move '
        'shows it again', (tester) async {
      final (player, _) = await mountVideo(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      final card = tester.getCenter(find.byKey(const Key('inline-video')));
      await mouse.moveTo(card);
      await tester.pump();
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.playing, isTrue);
      expect(find.byKey(const Key('inline-video-bar')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const Key('inline-video-bar')), findsNothing);
      await mouse.moveTo(card + const Offset(5, 0));
      await tester.pump();
      expect(find.byKey(const Key('inline-video-bar')), findsOneWidget);
      // Paused: the bar stays however long the pointer rests.
      await tester.tap(find.byKey(const Key('inline-video-toggle')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.playing, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(find.byKey(const Key('inline-video-bar')), findsOneWidget);
      await unmount(tester);
    }, variant: linux);

    testWidgets('touch: Play stays visible; a tap on playback shows the bar '
        'for a few seconds', (tester) async {
      final (player, _) = await mountVideo(tester);
      expect(find.byKey(const Key('inline-video-play')), findsOneWidget);
      expect(find.byKey(const Key('inline-video-bar')), findsOneWidget);
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.playing, isTrue);
      expect(find.byKey(const Key('inline-video-bar')), findsNothing);
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('inline-video-bar')), findsOneWidget);
      expect(player.playing, isTrue);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const Key('inline-video-bar')), findsNothing);
      await unmount(tester);
    });

    testWidgets('a failed decode shows the warning and downloads', (
      tester,
    ) async {
      final (_, lease) = await mountVideo(tester, refuse: true);
      expect(find.byKey(const Key('inline-video-surface')), findsNothing);
      expect(
        find.text('This video may use a codec this browser cannot preview.'),
        findsOneWidget,
      );
      unawaited(lease.dispose());
      await unmount(tester);
    });

    testWidgets('a large video loads on the first play, then plays', (
      tester,
    ) async {
      final (player, _) = await mountVideo(
        tester,
        metadata: {...meta, 'sizeBytes': 60 * 1024 * 1024},
      );
      expect(player.calls, isEmpty);
      expect(find.byKey(const Key('inline-video-play')), findsNothing);
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(player.calls, ['open', 'toggle']);
      await unmount(tester);
    });

    testWidgets('the server thumbnail is the poster until the first frame', (
      tester,
    ) async {
      final (player, _) = await mountVideo(
        tester,
        frame: false,
        metadata: {...meta, 'thumbnailUrl': 'https://cdn.invalid/t.webp'},
      );
      // Decoded at display size (RaftSizedImage) under the transparent video.
      expect(find.byType(RaftSizedImage), findsOneWidget);
      player.frame = true;
      player.events.add(player.state);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(RaftSizedImage), findsNothing);
      await unmount(tester);
    });

    testWidgets('opening the viewer pauses the inline video', (tester) async {
      var opened = 0;
      final (player, _) = await mountVideo(
        tester,
        onOpenPreview: () => opened++,
      );
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.playing, isTrue);
      await tester.tap(find.byKey(const Key('inline-video-expand')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(opened, 1);
      expect(player.playing, isFalse);
      await unmount(tester);
    });

    testWidgets('one video plays at a time; scrolling one away pauses it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(600, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (w, api) = (await tester.runAsync(() => fixture('owner')))!;
      addTearDown(w.dispose);
      for (final id in const ['v1', 'v2']) {
        api.routes['GET /attachments/$id/url'] = (_) => {
          'url': 'https://media.invalid/$id',
        };
      }
      final dir = Directory.systemTemp.createTempSync('inline-video-two');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final players = {'v1': _VideoPlayer(), 'v2': _VideoPlayer()};
      final leases = <SharedFileLease>[];
      Widget card(String id) {
        final file = File('${dir.path}/$id.bin')..writeAsBytesSync([1]);
        final lease = SharedFileLease(file, lifetime: const Duration(hours: 1));
        leases.add(lease);
        return InlineVideoAttachment(
          key: ValueKey(id),
          controller: w,
          metadata: {...meta, 'id': id},
          authorized: () => true,
          pending: false,
          files: _Files(lease),
          playerFactory: () => players[id]!,
        );
      }

      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: Scaffold(
            body: ListView(
              controller: scroll,
              // Both cards stay built while far apart.
              scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
              children: [card('v1'), const SizedBox(height: 900), card('v2')],
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byKey(const Key('inline-video-surface')).first);
      await tester.pump(const Duration(milliseconds: 50));
      expect(players['v1']!.playing, isTrue);
      // Scrolled past the 160 px margin: pauses by itself.
      scroll.jumpTo(700);
      await tester.pump(const Duration(milliseconds: 50));
      expect(players['v1']!.playing, isFalse);
      // The second one plays; scrolling back pauses it, and starting the first
      // again leaves only one playing.
      scroll.jumpTo(904);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('inline-video-surface')).last);
      await tester.pump(const Duration(milliseconds: 50));
      expect(players['v2']!.playing, isTrue);
      scroll.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 50));
      expect(players['v2']!.playing, isFalse);
      await tester.tap(find.byKey(const Key('inline-video-surface')).first);
      await tester.pump(const Duration(milliseconds: 50));
      expect(players['v1']!.playing, isTrue);
      await unmount(tester);
    });
  });
}
