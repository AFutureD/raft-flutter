import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'attachment_player_log.dart';

class AttachmentPlayback {
  const AttachmentPlayback({
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 100,
    this.error = false,
    this.hasFrame = false,
    this.videoSize,
  });

  /// [hasFrame]: the video surface has drawn its first decoded frame (the
  /// poster), so a thumbnail beneath it can go.
  final bool playing, error, hasFrame;

  /// The video's own pixel size once mpv knows it.
  final Size? videoSize;
  final Duration position, duration;
  final double volume;
}

abstract interface class AttachmentPlayer {
  Stream<AttachmentPlayback> get changes;
  Widget video();
  Future<void> open(File file);
  Future<void> toggle();
  Future<void> pause();
  Future<void> seek(Duration value);
  Future<void> volume(double value);
  Future<void> dispose();
}

class NativeAttachmentPlayer implements AttachmentPlayer {
  /// [maxVideoSize] bounds the decoded picture on desktop (the surface is
  /// resized to the video's aspect inside it): an inline card never needs a
  /// 1080p software frame.
  NativeAttachmentPlayer({
    bool video = true,
    this.maxVideoSize = const Size(1920, 1080),
    this.transparentVideo = false,
  }) {
    MediaKit.ensureInitialized();
    player = Player(
      configuration: const PlayerConfiguration(
        protocolWhitelist: ['file'],
        libass: false,
        // warn+ so the next failure carries its reason (see raft.media: lines).
        logLevel: MPVLogLevel.warn,
      ),
    );
    controller = video
        ? VideoController(
            player,
            configuration: Platform.isAndroid
                ? const VideoControllerConfiguration(
                    vo: 'mediacodec_embed',
                    hwdec: 'mediacodec',
                  )
                // Linux keeps the CPU renderer (no dependency on the host's
                // GL stack, proven by the release evidence). macOS, iOS and
                // Windows use media_kit's default GPU texture, as miraa-app
                // does; forcing software there made 30 fps swscale the
                // desktop default.
                : Platform.isLinux
                ? const VideoControllerConfiguration(
                    enableHardwareAcceleration: false,
                    // The texture path copies frames in software anyway. mpv's
                    // default `auto` probes CUDA, VDPAU, V4L2 and VAAPI from a
                    // bundled userland against the host's drivers, which only
                    // adds failures and start-up delay on Linux.
                    hwdec: 'no',
                  )
                : const VideoControllerConfiguration(),
          )
        : null;
    for (final stream in <Stream<dynamic>>[
      player.stream.playing,
      player.stream.position,
      player.stream.duration,
      player.stream.volume,
      player.stream.width,
      player.stream.height,
    ]) {
      subscriptions.add(stream.listen((_) => publish()));
    }
    if (controller != null) {
      if (Platform.isLinux) {
        // media_kit_video's Linux software renderer derives the frame size
        // with an integer division (`width / height * 1080`) once a video is
        // taller than 1080 px, so a 720x1280 clip rendered into a 720x1080
        // texture and stayed black. Give the surface the video's own aspect
        // explicitly instead; the bound also keeps the CPU frame small.
        for (final stream in <Stream<int?>>[
          player.stream.width,
          player.stream.height,
        ]) {
          subscriptions.add(stream.listen((_) => fitSurface()));
        }
      }
      unawaited(
        controller!.waitUntilFirstFrameRendered.then((_) {
          hasFrame = true;
          publish();
        }, onError: (_) {}),
      );
    }
    // media_kit's error stream also fires for harmless libmpv errors (a
    // hardware decoder that is absent, no sound card) while the video plays.
    // Failure comes from classified log lines only; every warn+ line is kept
    // in the journal, redacted, so a failure can be diagnosed afterwards.
    subscriptions.add(
      player.stream.log.listen((event) {
        final line = limiter.admit(
          formatMediaLog(event.level, event.prefix, event.text),
        );
        if (line != null) _writeLog(line);
        if (isPlaybackFailure(
          event.level,
          event.prefix,
          event.text,
          video: controller != null,
        )) {
          publish(error: true);
        }
      }),
    );
  }
  final limiter = MediaLogLimiter();
  static void _writeLog(String line) {
    try {
      stderr.writeln(line);
    } on Object {
      // stderr may be closed (detached GUI session); logging is best effort.
    }
  }

  late final Player player;
  late final VideoController? controller;
  final Size maxVideoSize;

  /// Nothing behind the picture, so a poster beneath it shows until the first
  /// frame; otherwise media_kit's black backdrop.
  final bool transparentVideo;
  bool hasFrame = false;
  Size? surface;

  /// The decoded size bounded to [maxVideoSize], keeping the aspect ratio and
  /// never enlarging; null while the size is unknown.
  static Size? fitted(int? width, int? height, Size bound) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    final scale = [
      1.0,
      bound.width / width,
      bound.height / height,
    ].reduce((a, b) => a < b ? a : b);
    return Size(
      (width * scale).roundToDouble().clamp(2, double.infinity),
      (height * scale).roundToDouble().clamp(2, double.infinity),
    );
  }

  void fitSurface() {
    if (closed) return;
    final size = fitted(player.state.width, player.state.height, maxVideoSize);
    if (size == null || size == surface) return;
    surface = size;
    unawaited(() async {
      try {
        await controller!.setSize(
          width: size.width.round(),
          height: size.height.round(),
        );
        // The software renderer drew nothing (or the old size) before the
        // surface had its final size, and a paused video never redraws by
        // itself: seeking to the start paints the first frame again.
        if (!closed && !player.state.playing) await player.seek(Duration.zero);
      } catch (_) {}
    }());
  }

  final output = StreamController<AttachmentPlayback>.broadcast();
  final subscriptions = <StreamSubscription<dynamic>>[];
  bool closed = false, failed = false;
  void publish({bool error = false}) {
    if (closed) return;
    failed = failed || error;
    output.add(
      AttachmentPlayback(
        playing: player.state.playing,
        position: player.state.position,
        duration: player.state.duration,
        volume: player.state.volume,
        error: failed,
        hasFrame: hasFrame,
        videoSize: _videoSize(),
      ),
    );
  }

  Size? _videoSize() {
    final w = player.state.width, h = player.state.height;
    return w == null || h == null || w <= 0 || h <= 0
        ? null
        : Size(w.toDouble(), h.toDouble());
  }

  @override
  Stream<AttachmentPlayback> get changes => output.stream;
  @override
  Widget video() => Video(
    controller: controller!,
    // ds-allow: native video surface backdrop, not themed UI
    fill: transparentVideo ? const Color(0x00000000) : const Color(0xFF000000),
    controls: NoVideoControls,
    pauseUponEnteringBackgroundMode: true,
    resumeUponEnteringForegroundMode: false,
  );
  @override
  Future<void> open(File file) async {
    final native = player.platform;
    if (native is NativePlayer) {
      for (final property in const [
        'cache-on-disk',
        'cache',
        'access-references',
        'load-scripts',
        'ytdl',
        'sub-auto',
        'audio-file-auto',
        'autoload-files',
      ]) {
        await native.setProperty(property, 'no');
      }
      // media_kit.open uses an intermediate playlist. Keep external references
      // disabled and load the already-authorized local input directly instead.
      await native.setProperty('pause', 'yes');
      await native.command(['loadfile', file.path, 'replace']);
      return;
    }
    await player.open(Media(file.uri.toString()), play: false);
  }

  @override
  Future<void> toggle() => player.playOrPause();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> seek(Duration value) => player.seek(value);
  @override
  Future<void> volume(double value) => player.setVolume(value);
  @override
  Future<void> dispose() async {
    if (closed) return;
    closed = true;
    for (final s in subscriptions) {
      await s.cancel();
    }
    await player.dispose();
    await output.close();
  }
}
