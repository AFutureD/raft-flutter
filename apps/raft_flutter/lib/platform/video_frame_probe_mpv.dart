import 'dart:async';

import 'video_frame_probe.dart';

/// Windows and Linux: the first picture of a video through a one-off, muted,
/// paused libmpv player (media_kit), the engine that plays video there.
/// Placeholder until the libmpv probe lands.
class MpvVideoFrameProbe implements VideoFrameProbe {
  @override
  Future<VideoFrameInfo> probe({
    required String id,
    required Uri url,
    Map<String, String> headers = const {},
    int maxEdge = 640,
    Duration timeout = const Duration(seconds: 20),
    int maxBytes = 16 * 1024 * 1024,
  }) async => throw const VideoFrameException(VideoFrameFailure.failed, 'not implemented');

  @override
  Future<void> cancel(String id) async {}
}
