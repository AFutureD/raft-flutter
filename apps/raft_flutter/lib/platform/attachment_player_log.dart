/// Classification and redaction of libmpv log lines for [NativeAttachmentPlayer].
///
/// libmpv logs many `error` lines that are not playback failures: it tries
/// hardware decoder wrappers (CUDA, V4L2, VDPAU, VAAPI ...) one by one and
/// reports each miss, and it reports a missing sound card while the video
/// plays fine. Only lines that mean the input cannot be played end playback.
library;

bool _isAudio(String prefix) =>
    prefix == 'ao' ||
    prefix.startsWith('ao/') ||
    prefix == 'ad' ||
    prefix.startsWith('ad/');

/// True when an mpv log line means the attachment cannot be played.
bool isPlaybackFailure(
  String level,
  String prefix,
  String text, {
  bool video = true,
}) {
  // Audio output and audio decoder problems (no sound card, JACK or PipeWire
  // absent: JACK even logs `fatal`) never stop the picture; mpv plays muted.
  // An audio-only attachment has nothing to play without an output device.
  if (!video &&
      prefix == 'cplayer' &&
      text.toLowerCase().contains('could not open/initialize audio device')) {
    return true;
  }
  if (_isAudio(prefix)) return false;
  if (level == 'fatal') return true;
  if (level != 'error') return false;
  // Video output failed to initialise or render.
  if (prefix == 'vo' || prefix.startsWith('vo/')) return true;
  // The input cannot be opened or recognised.
  if (prefix == 'file' || prefix == 'stream' || prefix == 'demux') return true;
  final lower = text.toLowerCase();
  if (prefix == 'cplayer') {
    return lower.contains('failed to recognize file format') ||
        lower.contains('errors when loading file') ||
        lower.contains('opening failed') ||
        lower.contains('error opening/initializing the selected video_out');
  }
  // `Could not open codec.` only means one decoder was skipped; mpv falls back
  // to the next. No decoder at all is a failure.
  if (prefix == 'vd') {
    return lower.contains('failed to initialize a decoder') ||
        lower.contains('no decoder');
  }
  return false;
}

final _url = RegExp(
  r'(https?|ftp|rtsp|rtmp|file)://[^\s"<>]+',
  caseSensitive: false,
);
final _unixHome = RegExp(r'/(home|Users)/[^/\s"]+');
final _windowsHome = RegExp(r'([A-Za-z]:\\Users\\)[^\\\s"]+');
final _appData = RegExp(r'(/data/(?:user/\d+|data)/)[^/\s"]+');

/// Removes what must not reach a log: URL credentials, paths, queries and
/// fragments, and user names in local paths. Keeps scheme and host so a
/// network failure is still recognisable.
String sanitizeMediaLog(String text, {int maxLength = 300}) {
  var out = text.replaceAllMapped(_url, (match) {
    final uri = Uri.tryParse(match.group(0)!);
    if (uri == null || uri.scheme.isEmpty) return '[url]';
    if (uri.scheme.toLowerCase() == 'file') return '[local file]';
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/[path]';
  });
  out = out.replaceAllMapped(_unixHome, (m) => '/${m.group(1)}/~');
  out = out.replaceAllMapped(_windowsHome, (m) => '${m.group(1)}~');
  out = out.replaceAllMapped(_appData, (m) => '${m.group(1)}~');
  if (out.length > maxLength) {
    out = '${out.substring(0, maxLength)}...';
  }
  return out;
}

/// Formats one line for stderr / the user journal.
String formatMediaLog(String level, String prefix, String text) =>
    'raft.media: [$level] $prefix: ${sanitizeMediaLog(text)}';

/// Collapses runs of identical lines and caps the number written.
class MediaLogLimiter {
  MediaLogLimiter({this.limit = 120});
  final int limit;
  int _written = 0;
  String? _last;
  int _suppressed = 0;

  /// The line to write for [line], or null to drop it.
  String? admit(String line) {
    if (line == _last) {
      _suppressed++;
      return null;
    }
    _last = line;
    if (_written >= limit) return null;
    _written++;
    if (_written == limit) {
      return '$line\nraft.media: further log lines suppressed';
    }
    return line;
  }

  int get suppressed => _suppressed;
}
