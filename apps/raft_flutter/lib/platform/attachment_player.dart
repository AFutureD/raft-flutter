import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:raft_client/system_proxy.dart';

import 'attachment_player_log.dart';

class AttachmentPlayback {
  const AttachmentPlayback({
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 100,
    this.error = false,
    this.hasFrame = false,
    this.buffering = false,
    this.videoSize,
  });

  /// [hasFrame]: the video surface has drawn its first decoded frame (the
  /// poster), so a thumbnail beneath it can go.
  /// [buffering]: the player waits for data (the stream is behind the
  /// position, or a seek is being served).
  final bool playing, error, hasFrame, buffering;

  /// The video's own pixel size once mpv knows it.
  final Size? videoSize;
  final Duration position, duration;
  final double volume;
}

/// What a player opens: a private local file, or the attachment's own URL
/// (streamed: the player reads the byte ranges it needs, nothing is saved).
class AttachmentSource {
  const AttachmentSource.file(File this.file)
    : url = null,
      headers = const {},
      refresh = null,
      start = Duration.zero;

  /// [url] is the signed attachment URL (it is the only credential: [headers]
  /// stays empty for storage hosts). [refresh] returns a freshly signed URL;
  /// the player calls it once when the host answers 401/403/410 (the
  /// signature expired) and continues from where it was. [start] is where
  /// playback begins (the viewer taking over from a card).
  const AttachmentSource.network(
    Uri this.url, {
    this.headers = const {},
    this.refresh,
    this.start = Duration.zero,
  }) : file = null;

  final File? file;
  final Uri? url;
  final Map<String, String> headers;
  final Future<Uri> Function()? refresh;
  final Duration start;
  bool get isNetwork => url != null;
}

abstract interface class AttachmentPlayer {
  Stream<AttachmentPlayback> get changes;

  /// The last published state (a late listener starts from it).
  AttachmentPlayback get playback;

  /// The picture is a native view (`SurfaceView`, `AVPlayerLayer`) that does
  /// not move, clip or animate with Flutter content.
  bool get usesPlatformView;
  Widget video();
  Future<void> open(AttachmentSource source);
  Future<void> toggle();
  Future<void> pause();
  Future<void> seek(Duration value);
  Future<void> volume(double value);
  Future<void> dispose();
}

/// The media_kit/libmpv player, for Windows and Linux only (see
/// `createAttachmentPlayer`); the other platforms use their system player.
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
    hwdecRequested =
        parseLinuxHwdec(Platform.environment[linuxHwdecVariable]) ?? 'no';
    player = Player(
      configuration: const PlayerConfiguration(
        // The attachment's own http(s) URL is streamed (mpv does its own
        // networking, through the proxy of `applyProxy`); nothing else.
        protocolWhitelist: ['file', 'http', 'https', 'tcp', 'tls', 'crypto'],
        libass: false,
        // warn+ so the next failure carries its reason (see raft.media: lines).
        logLevel: MPVLogLevel.warn,
      ),
    );
    controller = video
        ? VideoController(
            player,
            // Linux keeps the CPU renderer (no dependency on the host's GL
            // stack, proven by the release evidence). Windows uses media_kit's
            // default GPU texture, as miraa-app does; forcing software there
            // made 30 fps swscale the desktop default. Android, iOS and macOS
            // never get here (see createAttachmentPlayer).
            configuration: Platform.isLinux
                ? VideoControllerConfiguration(
                    enableHardwareAcceleration: false,
                    // The texture path copies frames in software anyway. mpv's
                    // default `auto` probes CUDA, VDPAU, V4L2 and VAAPI from a
                    // bundled userland against the host's drivers, which only
                    // adds failures and start-up delay on Linux. Copy-back
                    // decoding is opt-in through RAFT_LINUX_HWDEC.
                    hwdec: hwdecRequested,
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
      player.stream.buffering,
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
          if (Platform.isLinux) unawaited(logDecoder());
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
          // mpv's default log level does not carry the HTTP status ("Failed to
          // open <url>"), so like video_player the first failure of a streamed
          // source signs again once before it is reported.
          if (source?.refresh != null && !refreshed && !failed) {
            unawaited(
              refreshExpired().then((done) {
                if (!done) publish(error: true);
              }),
            );
          } else {
            publish(error: true);
          }
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

  /// The mpv `hwdec` option in effect on Linux (`no` unless opted in).
  late final String hwdecRequested;

  /// Writes one `raft.media: hwdec ...` line naming the decoder mpv really
  /// uses once the first frame is out; best effort, never throws.
  Future<void> logDecoder() async {
    final native = player.platform;
    if (closed || native is! NativePlayer) return;
    try {
      // The first rendered frame can arrive before mpv has set up the decoder;
      // the video size is only published once a frame has been decoded, and
      // hwdec-current is valid from then on.
      if ((player.state.width ?? 0) <= 0) {
        await player.stream.width
            .firstWhere((w) => (w ?? 0) > 0)
            .timeout(const Duration(seconds: 20));
      }
      Future<String?> read(String name) async {
        try {
          return await native.getProperty(name, waitForInitialization: false);
        } on Object {
          return null;
        }
      }

      final current = await read('hwdec-current');
      final codec = await read('video-format');
      if (closed) return;
      _writeLog(
        formatHwdecLog(
          requested: hwdecRequested,
          current: current,
          codec: codec,
          width: player.state.width,
          height: player.state.height,
        ),
      );
    } on Object {
      // Diagnostics only.
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
        buffering: player.state.buffering,
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
  AttachmentPlayback get playback => AttachmentPlayback(
    playing: player.state.playing,
    position: player.state.position,
    duration: player.state.duration,
    volume: player.state.volume,
    error: failed,
    hasFrame: hasFrame,
    buffering: player.state.buffering,
    videoSize: _videoSize(),
  );
  @override
  bool get usesPlatformView => false;
  @override
  Widget video() => Video(
    controller: controller!,
    // ds-allow: native video surface backdrop, not themed UI
    fill: transparentVideo ? const Color(0x00000000) : const Color(0xFF000000),
    controls: NoVideoControls,
    pauseUponEnteringBackgroundMode: true,
    resumeUponEnteringForegroundMode: false,
  );
  AttachmentSource? source;
  bool refreshed = false;

  @override
  Future<void> open(AttachmentSource source) async {
    this.source = source;
    refreshed = false;
    final native = player.platform;
    final target = source.isNetwork ? source.url!.toString() : source.file!.path;
    if (native is NativePlayer) {
      for (final property in const [
        'cache-on-disk',
        'access-references',
        'load-scripts',
        'ytdl',
        'sub-auto',
        'audio-file-auto',
        'autoload-files',
      ]) {
        await native.setProperty(property, 'no');
      }
      // A file is read directly; a stream keeps a bounded read-ahead in
      // memory (never on disk: only the Download action saves a file).
      await native.setProperty('cache', source.isNetwork ? 'yes' : 'no');
      if (source.isNetwork) {
        await native.setProperty('demuxer-max-bytes', '${maxVideoSize.width > 1000 ? 64 : 32}MiB');
        await native.setProperty('demuxer-max-back-bytes', '8MiB');
        await native.setProperty('http-proxy', httpProxyFor(source.url!));
        await native.setProperty(
          'http-header-fields',
          source.headers.entries.map((e) => '${e.key}: ${e.value}').join(','),
        );
      }
      await native.setProperty(
        'start',
        source.start > Duration.zero ? '${source.start.inMilliseconds / 1000}' : 'none',
      );
      // media_kit.open uses an intermediate playlist. Keep external references
      // disabled and load the already-authorized input directly instead.
      await native.setProperty('pause', 'yes');
      await native.command(['loadfile', target, 'replace']);
      return;
    }
    await player.open(
      Media(
        source.isNetwork ? target : source.file!.uri.toString(),
        httpHeaders: source.headers.isEmpty ? null : source.headers,
        start: source.start > Duration.zero ? source.start : null,
      ),
      play: false,
    );
  }

  /// mpv's `http-proxy` value for [url]: the app's proxy decision (Settings,
  /// environment, OS), `` for DIRECT. Only host and port leave the decision;
  /// credentials of a manual proxy are part of it and are set as a runtime
  /// property, never through argv or logs.
  @visibleForTesting
  static String httpProxyFor(Uri url) {
    final decision = SystemProxy.instance.findProxyForClient(url);
    for (final part in decision.split(';')) {
      final entry = part.trim();
      if (entry.toUpperCase().startsWith('PROXY ')) {
        return 'http://${entry.substring(6).trim()}';
      }
      if (entry.toUpperCase() == 'DIRECT') return '';
    }
    return '';
  }

  /// A streamed source that failed to open or play (typically a host that
  /// answered 401/403/410 for an expired signature): sign again once and
  /// continue from the current position.
  Future<bool> refreshExpired() async {
    final current = source;
    final refresh = current?.refresh;
    if (closed || current == null || !current.isNetwork || refresh == null || refreshed) {
      return false;
    }
    refreshed = true;
    try {
      final url = await refresh();
      if (closed) return false;
      final at = player.state.position;
      failed = false;
      await open(
        AttachmentSource.network(url, headers: current.headers, start: at),
      );
      refreshed = true;
      return true;
    } on Object {
      return false;
    }
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
