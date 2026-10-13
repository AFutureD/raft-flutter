import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'attachment_player.dart';
import 'attachment_player_log.dart';

/// The platform's own player behind [AttachmentPlayer]: ExoPlayer (Media3) on
/// Android, AVPlayer on iOS and macOS, through the official `video_player`
/// plugin. Colour (HDR to SDR tone mapping), hardware decoding and codec
/// support are the system's; Windows and Linux keep [NativeAttachmentPlayer]
/// because their system codecs are optional or absent.
///
/// The media is always a private local file (see `InlineMediaFiles`), so no
/// network source, header or credential ever reaches the player.
class VideoPlayerAttachmentPlayer
    with WidgetsBindingObserver
    implements AttachmentPlayer {
  /// An audio-only attachment is opened the same way; it never builds
  /// [video], so no picture surface exists for it.
  VideoPlayerAttachmentPlayer({
    this.transparentVideo = false,
    this.platformView = false,
  });

  /// Render into the plugin's native view ([VideoViewType.platformView]:
  /// `SurfaceView` on Android, `AVPlayerLayer` on iOS and macOS) instead of a
  /// Flutter texture. The texture path tone-maps HDR to SDR on every
  /// platform; the native view hands HDR to the compositor untouched, so an
  /// HDR clip stays HDR on an HDR screen. A platform view does not clip,
  /// scroll or animate like Flutter content, so only the full-screen viewer
  /// asks for it, never a card in a list.
  final bool platformView;

  /// Nothing behind the picture, so a poster beneath it shows until the first
  /// frame; otherwise a black backdrop.
  final bool transparentVideo;

  final _controller = ValueNotifier<VideoPlayerController?>(null);
  final _output = StreamController<AttachmentPlayback>.broadcast();
  final _limiter = MediaLogLimiter(limit: 20);
  bool _closed = false, _failed = false, _observing = false;
  bool _hasFrame = false;
  AttachmentPlayback? _last;

  VideoPlayerController? get _active => _controller.value;

  @override
  Stream<AttachmentPlayback> get changes => _output.stream;

  @override
  Widget video() => _VideoSurface(
    player: this,
    // ds-allow: native video surface backdrop, not themed UI
    fill: transparentVideo ? const Color(0x00000000) : const Color(0xFF000000),
  );

  @override
  Future<void> open(File file) async {
    if (_closed) return;
    await _release();
    _failed = false;
    _hasFrame = false;
    _last = null;
    final controller = VideoPlayerController.file(
      file,
      viewType: platformView
          ? VideoViewType.platformView
          : VideoViewType.textureView,
      videoPlayerOptions: VideoPlayerOptions(
        // The lifecycle observer of video_player resumes playback when the app
        // returns; a video that was paused by leaving must stay paused (see
        // didChangeAppLifecycleState).
        allowBackgroundPlayback: true,
      ),
    );
    controller.addListener(_publish);
    _controller.value = controller;
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
    try {
      // Opens paused at the first frame.
      await controller.initialize();
    } on Object catch (error) {
      _log('open failed: ${_describe(error)}');
      _publish(error: true);
      rethrow;
    }
    _publish();
  }

  /// Called by the video surface once the picture was built after the player
  /// reported a size: the poster beneath can go.
  void _firstFrame() {
    if (_closed || _hasFrame) return;
    _hasFrame = true;
    _publish();
  }

  void _publish({bool error = false}) {
    if (_closed) return;
    final controller = _active;
    if (controller == null) return;
    final value = controller.value;
    if (value.hasError) {
      if (!_failed) _log('playback error: ${value.errorDescription}');
      error = true;
    }
    _failed = _failed || error;
    final size = value.size;
    final next = AttachmentPlayback(
      playing: value.isPlaying,
      position: value.position,
      // An erroneous value forgets the length; keep what the card knew.
      duration: value.hasError
          ? (_last?.duration ?? value.duration)
          : value.duration,
      volume: (value.volume * 100).clamp(0.0, 100.0),
      error: _failed,
      hasFrame: _hasFrame,
      videoSize: size.isEmpty ? null : size,
    );
    final last = _last;
    if (last != null &&
        last.playing == next.playing &&
        last.position == next.position &&
        last.duration == next.duration &&
        last.volume == next.volume &&
        last.error == next.error &&
        last.hasFrame == next.hasFrame &&
        last.videoSize == next.videoSize) {
      return;
    }
    _last = next;
    _output.add(next);
  }

  static String _describe(Object error) => error.toString();

  void _log(String text) {
    final line = _limiter.admit(formatMediaLog('error', 'video_player', text));
    if (line == null) return;
    // logcat on Android, the unified log on iOS and macOS.
    debugPrint(line);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app pauses; coming back does not resume on its own.
    if (state == AppLifecycleState.paused) {
      final controller = _active;
      if (controller != null && controller.value.isPlaying) {
        unawaited(controller.pause().catchError((_) {}));
      }
    }
  }

  @override
  Future<void> toggle() async {
    final controller = _active;
    if (controller == null || _closed) return;
    final value = controller.value;
    if (value.isPlaying) return controller.pause();
    final end =
        value.isCompleted ||
        (value.duration > Duration.zero && value.position >= value.duration);
    if (end) await controller.seekTo(Duration.zero);
    await controller.play();
  }

  @override
  Future<void> pause() async {
    if (_closed) return;
    await _active?.pause();
  }

  @override
  Future<void> seek(Duration value) async {
    final controller = _active;
    if (controller == null || _closed) return;
    final length = controller.value.duration;
    var target = value < Duration.zero ? Duration.zero : value;
    if (length > Duration.zero && target > length) target = length;
    await controller.seekTo(target);
  }

  @override
  Future<void> volume(double value) async {
    if (_closed) return;
    await _active?.setVolume((value / 100).clamp(0.0, 1.0));
  }

  Future<void> _release() async {
    final controller = _active;
    _controller.value = null;
    if (controller == null) return;
    controller.removeListener(_publish);
    try {
      await controller.dispose();
    } on Object {
      // A failing native player must not keep its file.
    }
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    if (_observing) {
      _observing = false;
      WidgetsBinding.instance.removeObserver(this);
    }
    await _release();
    _controller.dispose();
    await _output.close();
  }
}

/// The picture: contained inside the box it is given, nothing until the player
/// knows its size. Reports the first built frame back to the player.
class _VideoSurface extends StatelessWidget {
  const _VideoSurface({required this.player, required this.fill});
  final VideoPlayerAttachmentPlayer player;
  final Color fill;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: fill,
    child: ValueListenableBuilder<VideoPlayerController?>(
      valueListenable: player._controller,
      builder: (context, controller, _) {
        if (controller == null) return const SizedBox.expand();
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            if (!value.isInitialized || value.size.isEmpty) {
              return const SizedBox.expand();
            }
            if (!player._hasFrame) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => player._firstFrame(),
              );
            }
            return Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            );
          },
        );
      },
    ),
  );
}
