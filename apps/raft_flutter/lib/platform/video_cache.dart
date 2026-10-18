import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:raft_client/system_proxy.dart';

import 'attachment_player.dart';
import 'video_cache_proxy.dart';

/// Videos at most this long loop (the player's own repeat mode); longer ones
/// stop at the end as before.
const Duration kLoopingVideoMaxDuration = Duration(seconds: 60);

/// The prototype's switch for the on-disk video cache and short-video looping:
/// `--dart-define=RAFT_VIDEO_CACHE=1`. Off, nothing changes.
class VideoCache {
  VideoCache._();

  static const _defined = bool.fromEnvironment('RAFT_VIDEO_CACHE');

  /// Lets the evidence harness compare the cache against the direct URL in
  /// one process.
  @visibleForTesting
  static bool? debugEnabled;

  static bool get enabled => debugEnabled ?? _defined;

  /// Where the chunks live (tests and tools point it elsewhere); by default
  /// `<app cache>/video_cache`.
  @visibleForTesting
  static Directory? debugDirectory;

  /// The cap in bytes (`--dart-define=RAFT_VIDEO_CACHE_MB=n`, default 500).
  static const _megabytes = int.fromEnvironment(
    'RAFT_VIDEO_CACHE_MB',
    defaultValue: 500,
  );

  /// `--dart-define=RAFT_VIDEO_CACHE_HOST=localhost` hands players
  /// `localhost` instead of the IP literal (see the ATS notes).
  static const _host = String.fromEnvironment(
    'RAFT_VIDEO_CACHE_HOST',
    defaultValue: '127.0.0.1',
  );

  /// A timeline sink for the evidence harness.
  @visibleForTesting
  static void Function(String line)? debugTrace;

  static Future<VideoCacheProxy>? _proxy;

  /// The running proxy, started on first use.
  static Future<VideoCacheProxy> proxy() => _proxy ??= _start();

  static Future<VideoCacheProxy> _start() async {
    final folder =
        debugDirectory ??
        Directory(
          p.join((await getApplicationCacheDirectory()).path, 'video_cache'),
        );
    final proxy = VideoCacheProxy(
      directory: folder,
      maxBytes: _megabytes * 1024 * 1024,
      urlHost: _host,
      clientFactory: () => SystemProxy.instance.createHttpClient(),
    );
    proxy.trace = debugTrace;
    await proxy.start();
    return proxy;
  }

  /// [source] as the player is to open it: through the cache when it is
  /// enabled and the source is a streamed attachment, otherwise unchanged.
  /// A failure to start the cache falls back to the direct URL.
  static Future<AttachmentSource> route(AttachmentSource source) async {
    final url = source.url;
    if (!enabled || url == null || !url.scheme.startsWith('http')) {
      return source;
    }
    try {
      final proxy = await VideoCache.proxy();
      await SystemProxy.instance.ready(url);
      final local = proxy.register(
        source.cacheKey ?? _derivedKey(url),
        url,
        headers: source.headers,
      );
      return AttachmentSource.network(local, start: source.start);
    } on Object catch (error) {
      debugPrint('raft.media: video cache unavailable ($error)');
      return source;
    }
  }

  /// A key for a source nobody named: its URL without the query (the
  /// signature), which is stable across re-signing for path-style hosts.
  static String _derivedKey(Uri url) => '${url.host}${url.path}';

  /// Whether a loopback URL is one of ours (players must not send it through
  /// a configured HTTP proxy).
  static bool isLocal(Uri url) =>
      (url.host == '127.0.0.1' || url.host == 'localhost') &&
      url.scheme == 'http';

  /// Total bytes on disk (Settings > Storage).
  static Future<int> sizeBytes() async => (await proxy()).totalBytes;

  /// Deletes every cached video (the Settings button, sign-out, account
  /// switch).
  static Future<void> clear() async => (await proxy()).clear();
}
