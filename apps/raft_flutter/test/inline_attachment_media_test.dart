import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/inline_attachment_media.dart';
import 'package:raft_flutter/platform/attachment_player.dart';
import 'package:raft_flutter/platform/attachment_preview_files.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'message_presentation_test.dart' show MessageAdapter, fixture;

class _Files extends AttachmentPreviewFiles {
  _Files(this.lease);
  final SharedFileLease lease;
  @override
  Future<SharedFileLease?> load(
    String url,
    String filename, {
    required CancelToken cancel,
    required bool Function() authorized,
    void Function(int, int)? onProgress,
  }) async => lease;
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

/// Unmount and let the asynchronous player / lease disposal finish (the lease
/// cancels its expiry timer).
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
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
}
