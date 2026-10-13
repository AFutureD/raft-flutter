import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/inline_attachment_media.dart';
import 'package:raft_flutter/platform/attachment_player.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'message_presentation_test.dart' show MessageAdapter, fixture;

class _Player implements AttachmentPlayer {
  final events = StreamController<AttachmentPlayback>.broadcast();
  final calls = <String>[];
  final sources = <AttachmentSource>[];
  bool disposed = false;
  @override
  Stream<AttachmentPlayback> get changes => events.stream;
  AttachmentPlayback last = const AttachmentPlayback();
  @override
  AttachmentPlayback get playback => last;
  @override
  bool get usesPlatformView => false;
  @override
  Widget video() =>
      const ColoredBox(key: Key('fake-video-surface'), color: Colors.red);
  @override
  Future<void> open(AttachmentSource source) async {
    sources.add(source);
    calls.add('open');
    last = const AttachmentPlayback(duration: Duration(seconds: 125));
    events.add(last);
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
  @override
  AttachmentPlayback get playback => state;
  AttachmentPlayback get state => AttachmentPlayback(
    playing: playing,
    position: position,
    duration: const Duration(seconds: 125),
    hasFrame: frame,
  );
  @override
  Future<void> open(AttachmentSource source) async {
    sources.add(source);
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

/// Unmount and let the asynchronous player disposal finish.
dynamic _mounted;

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // The sessions own the players; clearing them ends every player.
  _mounted?.playerSessions.clear();
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

  Future<(MessageAdapter, _Player)> mount(
    WidgetTester tester, {
    required Widget Function(dynamic w, Object? files, _Player player) build,
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
    final player = _Player();
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: Scaffold(body: build(w, null, player)),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return (api, player);
  }

  testWidgets('audio: loads, plays, seeks and sets the volume', (tester) async {
    var downloads = 0;
    final (_, player) = await mount(
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
    await mount(
      tester,
      failUrl: true,
      build: (w, files, player) => InlineAudioAttachment(
        controller: w,
        metadata: const {'id': 'a1', 'filename': 'standup.mp3'},
        authorized: () => true,
        pending: false,
        onDownload: () => downloads++,
        playerFactory: () => player,
      ),
    );
    expect(find.text('Download to view'), findsOneWidget);
    // The header download action is hidden once the load failed; the
    // placeholder itself downloads.
    expect(find.byKey(const Key('audio-download')), findsNothing);
    await tester.tap(find.byKey(const Key('audio-placeholder')));
    expect(downloads, 1);
    await unmount(tester);
  });

  testWidgets(
    'video: the player fills the 16:9 box; the corner opens the preview',
    (tester) async {
      var opened = 0;
      final (_, player) = await mount(
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

  testWidgets('video: an unclassified failure says so, with Retry and Download', (
    tester,
  ) async {
    var downloads = 0;
    await mount(
      tester,
      failUrl: true,
      build: (w, files, player) => InlineVideoAttachment(
        controller: w,
        metadata: const {'id': 'a1', 'filename': 'walkthrough.mp4'},
        authorized: () => true,
        pending: false,
        onDownload: () => downloads++,
        playerFactory: () => player,
      ),
    );
    // Not a codec problem: the signed URL could not even be read.
    expect(find.text('The media could not be played.'), findsOneWidget);
    expect(
      find.text('This video may use a codec this browser cannot preview.'),
      findsNothing,
    );
    expect(find.byKey(const Key('inline-video-retry')), findsOneWidget);
    expect(find.byKey(const Key('inline-video-network-settings')), findsNothing);
    await tester.tap(find.text('Download to view'));
    expect(downloads, 1);
    await unmount(tester);
  });

  testWidgets('an optimistic attachment never reads its URL', (tester) async {
    final (api, player) = await mount(
      tester,
      build: (w, files, player) => InlineAudioAttachment(
        controller: w,
        metadata: const {'id': 'a1', 'filename': 'standup.mp3'},
        authorized: () => true,
        pending: true,
        playerFactory: () => player,
      ),
    );
    expect(api.calls.where((c) => c.path.contains('/attachments/')), isEmpty);
    expect(find.text('Loading standup.mp3'), findsOneWidget);
    expect(find.byKey(const Key('audio-download')), findsNothing);
    expect(player.calls, isEmpty);
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

    Future<_VideoPlayer> mountVideo(
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
      api.routes['GET /attachments/a1/url'] = (_) => refuse
          ? throw StateError('no url')
          : {'url': 'https://media.invalid/a1'};
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
              playerFactory: () => player,
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return player;
    }

    testWidgets(
      'idle poster: the first frame, the bar, a Play button on hover',
      (tester) async {
        final player = await mountVideo(tester);
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
      final player = await mountVideo(tester);
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
      final player = await mountVideo(tester);
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
      final player = await mountVideo(tester);
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

    testWidgets('a failed load shows the cause, not a codec warning', (
      tester,
    ) async {
      await mountVideo(tester, refuse: true);
      expect(find.byKey(const Key('inline-video-surface')), findsNothing);
      expect(find.text('The media could not be played.'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a large video loads on the first play, then plays', (
      tester,
    ) async {
      final player = await mountVideo(
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
      final player = await mountVideo(
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

    testWidgets('opening the viewer leaves the shared player playing', (
      tester,
    ) async {
      var opened = 0;
      final player = await mountVideo(
        tester,
        onOpenPreview: () => opened++,
      );
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.playing, isTrue);
      await tester.tap(find.byKey(const Key('inline-video-expand')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(opened, 1);
      // The viewer takes the same player over; nothing pauses it.
      expect(player.playing, isTrue);
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
      final players = {'v1': _VideoPlayer(), 'v2': _VideoPlayer()};
      Widget card(String id) {
        return InlineVideoAttachment(
          key: ValueKey(id),
          controller: w,
          metadata: {...meta, 'id': id},
          authorized: () => true,
          pending: false,
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

  group('player lifetime (memory)', () {
    const meta = {
      'id': 'a1',
      'filename': 'walkthrough.mp4',
      'mimeType': 'video/mp4',
      'sizeBytes': 1000000,
    };

    /// A card whose players are made one per request, so a release and a
    /// replay can be told apart.
    Future<(List<_VideoPlayer>, ValueNotifier<bool>)> mountCard(
      WidgetTester tester, {
      Map<String, dynamic> metadata = meta,
      VoidCallback? onOpenPreview,
    }) async {
      tester.view.physicalSize = const Size(600, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (w, api) = (await tester.runAsync(() => fixture('owner')))!;
      addTearDown(w.dispose);
      _mounted = w;
      api.routes['GET /attachments/a1/url'] = (_) => {
        'url': 'https://media.invalid/a1',
      };
      final made = <_VideoPlayer>[];
      final shown = ValueNotifier(true);
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (context, visible, _) => TickerMode(
                enabled: visible,
                child: InlineVideoAttachment(
                  controller: w,
                  metadata: metadata,
                  authorized: () => true,
                  pending: false,
                  onOpenPreview: onOpenPreview,
                  playerFactory: () {
                    final player = _VideoPlayer();
                    made.add(player);
                    return player;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return (made, shown);
    }

    Future<void> settle(WidgetTester tester, [int ms = 200]) async {
      await tester.pump(Duration(milliseconds: ms));
      await tester.pump(Duration(milliseconds: ms));
    }

    testWidgets('playback that ends frees the player; a tap replays from the start', (
      tester,
    ) async {
      final (made, _) = await mountCard(tester);
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(made.single.playing, isTrue);
      // The clip reaches its end and stops.
      made.single.playing = false;
      made.single.position = const Duration(seconds: 125);
      made.single.events.add(made.single.state);
      await settle(tester);
      expect(made.single.disposed, isTrue, reason: 'the decoder stayed after the end');
      // The card is idle again, with a play affordance; no player, no bar.
      expect(find.byKey(const Key('inline-video-bar')), findsNothing);
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(made, hasLength(2));
      expect(made.last.playing, isTrue);
      expect(made.last.calls, ['open', 'toggle']);
      await unmount(tester);
    });

    testWidgets('a card whose page is hidden frees its player after a grace period', (
      tester,
    ) async {
      final (made, shown) = await mountCard(tester);
      expect(made.single.disposed, isFalse);
      shown.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(made.single.disposed, isFalse, reason: 'inside the grace period');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(made.single.disposed, isTrue);
      // Visible again: the card waits for a tap (a new stream per scroll-back
      // would spend requests), then prepares at the position it stopped at.
      shown.value = true;
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(made, hasLength(1), reason: 'prepared again without a tap');
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(made, hasLength(2));
      expect(made.last.calls, ['open', 'toggle']);
      await unmount(tester);
    });

    testWidgets('a card built again for a prepared clip waits for a tap and '
        'resumes where it stopped', (tester) async {
      final (made, _) = await mountCard(tester);
      final w = _mounted;
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 50));
      made.single.position = const Duration(seconds: 40);
      made.single.events.add(made.single.state);
      await tester.pump(const Duration(milliseconds: 50));
      // The list drops the row far from the viewport, then builds it again.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: Scaffold(
            body: InlineVideoAttachment(
              controller: w,
              metadata: meta,
              authorized: () => true,
              pending: false,
              playerFactory: () {
                final player = _VideoPlayer();
                made.add(player);
                return player;
              },
            ),
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(made, hasLength(1), reason: 'a new stream every time a clip scrolls back');
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(made, hasLength(2));
      expect((made.last.sources.single.start), const Duration(seconds: 40));
      expect(made.last.playing, isTrue);
      await unmount(tester);
    });

    testWidgets('coming back inside the grace period keeps the player', (
      tester,
    ) async {
      final (made, shown) = await mountCard(tester);
      shown.value = false;
      await tester.pump(const Duration(seconds: 2));
      shown.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      expect(made, hasLength(1));
      expect(made.single.disposed, isFalse);
      await unmount(tester);
    });

    testWidgets('a hidden page does not free a player the viewer holds', (
      tester,
    ) async {
      final (made, shown) = await mountCard(tester, onOpenPreview: () {});
      // The viewer takes a hold on the shared player.
      final w = _mounted;
      final viewer = w.playerSessions.acquire(
        'a1|',
        viewer: true,
        scope: w.attachmentImageScope,
        create: () => throw StateError('shares the card player'),
        source: () async => throw StateError('already open'),
      );
      shown.value = false;
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(made.single.disposed, isFalse);
      viewer.release();
      await unmount(tester);
    });

    testWidgets('a tap while released and preparing is kept (never dropped)', (
      tester,
    ) async {
      final (made, shown) = await mountCard(tester);
      shown.value = false;
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);
      shown.value = true;
      await tester.pump(const Duration(milliseconds: 20));
      // Card is idle or preparing: tap twice quickly.
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.tap(find.byKey(const Key('inline-video-surface')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(made.last.playing, isTrue, reason: 'the tap during preparation was lost');
      await unmount(tester);
    });
  });
}
