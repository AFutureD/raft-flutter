// Which video surface each place asks for on Android, iOS and macOS: the
// full-screen viewer takes the plugin's native view (SurfaceView, AVPlayerLayer;
// HDR stays HDR), a card in a list keeps the texture (tone-mapped to SDR,
// clips and scrolls like Flutter content).
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/attachment_preview_dialog.dart';
import 'package:raft_flutter/features/inline_attachment_media.dart';
import 'package:raft_flutter/platform/attachment_preview_files.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'message_presentation_test.dart' show fixture;

class _Platform extends VideoPlayerPlatform {
  final types = <VideoViewType>[];
  var disposed = 0;
  final _streams = <int, StreamController<VideoEvent>>{};
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    types.add(options.viewType);
    final id = types.length - 1;
    _streams[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(1920, 1080),
          duration: const Duration(seconds: 10),
        ),
      );
    return id;
  }

  @override
  Future<void> dispose(int playerId) async => disposed++;
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _streams[playerId]!.stream;
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
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
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildView(int playerId) => const SizedBox(key: Key('picture'));
}

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

class _Client extends RaftClient {
  _Client()
    : super(
        origin: 'https://example.invalid',
        sessionStore: MemorySessionStore(),
      );
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async => {
    'url': 'https://example.invalid/signed',
  };
}

void main() {
  late _Platform fake;
  late VideoPlayerPlatform previous;
  late SharedFileLease lease;
  setUp(() {
    previous = VideoPlayerPlatform.instance;
    fake = _Platform();
    VideoPlayerPlatform.instance = fake;
    final dir = Directory.systemTemp.createTempSync('android-surface-test');
    // The lease removes its own folder when the viewer or the cache lets go;
    // this only sweeps what a test left behind, after that had its turn.
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Already gone.
      }
    });
    lease = SharedFileLease(
      File('${dir.path}/clip.mp4')..writeAsBytesSync([1, 2, 3]),
      lifetime: const Duration(hours: 1),
    );
  });
  tearDown(() => VideoPlayerPlatform.instance = previous);
  final system = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  });

  Future<void> mountViewer(WidgetTester tester, String filename) async {
    final client = _Client();
    final w = WorkspaceController(client);
    addTearDown(() async {
      w.dispose();
      await client.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: AttachmentPreviewDialog(
          controller: w,
          metadata: {'id': 'a', 'filename': filename},
          authorized: () => true,
          onClose: () {},
          onDownload: () async {},
          files: _Files(lease),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the viewer plays video in a platform view', (tester) async {
    await mountViewer(tester, 'clip.mp4');
    expect(fake.types, [VideoViewType.platformView]);
    expect(find.byType(RaftVideoViewer), findsOneWidget);
    expect(find.byKey(const Key('picture')), findsOneWidget);
    // Closing the viewer releases the native player (and its platform view).
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10 && fake.disposed == 0; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(fake.disposed, 1);
  }, variant: system);

  testWidgets('an audio attachment in the viewer needs no picture surface', (
    tester,
  ) async {
    await mountViewer(tester, 'tone.wav');
    expect(fake.types, [VideoViewType.textureView]);
    await tester.pumpWidget(const SizedBox());
  }, variant: system);

  testWidgets('an inline card keeps the texture', (tester) async {
    tester.view.physicalSize = const Size(600, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (w, api) = (await tester.runAsync(() => fixture('owner')))!;
    addTearDown(w.dispose);
    api.routes['GET /attachments/a1/url'] = (_) => {
      'url': 'https://media.invalid/a1',
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: Scaffold(
          body: InlineVideoAttachment(
            controller: w,
            metadata: const {
              'id': 'a1',
              'filename': 'walkthrough.mp4',
              'mimeType': 'video/mp4',
              'sizeBytes': 1000000,
            },
            authorized: () => true,
            pending: false,
            files: _Files(lease),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(fake.types, [VideoViewType.textureView]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  }, variant: system);
}
