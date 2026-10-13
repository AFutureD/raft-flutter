import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:raft_client/system_proxy.dart';
import 'package:raft_ui/raft_ui.dart';

import '../platform/memory_release.dart';
import 'attachment_disk_cache.dart';

/// Persistent encoded avatar / icon pictures (the layer under the decoded
/// bitmaps of `RaftHotImages`, see raft_ui `avatar_image_cache.dart`), kept in
/// the `public` namespace of the shared [AttachmentDiskCache] that Settings >
/// Storage shows and clears: one root, one size figure, one "Clear cache".
/// The namespace is shared by every account and is not purged on sign-out
/// (avatars are public pictures), has its own cap and recency order, and is
/// never evicted to make room for attachments; keys are the stable URL keys.
///
/// Each entry is `<8-byte big-endian expiry time in ms><bytes>`: the expiry is
/// the server's `Cache-Control` freshness (`/api/avatars/**` is
/// `public, max-age=31536000, immutable`; Gravatar is minutes;
/// `external-avatars` is `no-cache` and is not stored), capped at [ttl], and
/// [unknownTtl] when the server said nothing. An expired entry is a miss and
/// is removed.
class AvatarImageStore implements RaftImageByteStore {
  AvatarImageStore(
    this._cache, {
    this.ttl = const Duration(days: 14),
    this.unknownTtl = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AttachmentDiskCache _cache;
  final Duration ttl, unknownTtl;
  final DateTime Function() _now;

  @override
  Future<Uint8List?> read(String key) async {
    final data = await _cache.readPublic(key);
    if (data == null || data.length <= 8) return null;
    final expires = DateTime.fromMillisecondsSinceEpoch(
      ByteData.sublistView(data, 0, 8).getInt64(0),
    );
    if (!_now().isBefore(expires)) {
      unawaited(_cache.removePublic(key));
      return null;
    }
    return Uint8List.sublistView(data, 8);
  }

  @override
  Future<void> write(String key, Uint8List bytes, {Duration? maxAge}) async {
    final granted = maxAge ?? unknownTtl;
    if (granted <= Duration.zero) return;
    final lifetime = granted < ttl ? granted : ttl;
    final entry = Uint8List(8 + bytes.length);
    ByteData.sublistView(
      entry,
      0,
      8,
    ).setInt64(0, _now().add(lifetime).millisecondsSinceEpoch);
    entry.setRange(8, entry.length, bytes);
    await _cache.writePublic(key, entry);
  }
}

// One pooled client per proxy service (the app has one).
final _avatarClients = Expando<HttpClient>('avatar http client');

/// Fetches an avatar through the shared proxy decision (docs/system-proxy.md).
/// One pooled client; no credentials of any kind are attached.
Future<RaftFetchedImage> fetchAvatarImage(
  String url, {
  SystemProxy? proxy,
  Duration timeout = const Duration(seconds: 20),
  int maxBytes = 4 * 1024 * 1024,
}) async {
  final service = proxy ?? SystemProxy.instance;
  final uri = Uri.parse(url);
  await service.ready(uri);
  final client = _avatarClients[service] ??= service.createHttpClient()
    ..idleTimeout = const Duration(seconds: 60)
    ..maxConnectionsPerHost = 8
    ..autoUncompress = true;
  final request = await client.getUrl(uri).timeout(timeout);
  final response = await request.close().timeout(timeout);
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw RaftImageHttpError(response.statusCode);
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.timeout(timeout)) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) {
      throw const RaftImageHttpError(HttpStatus.requestEntityTooLarge);
    }
  }
  return RaftFetchedImage(
    bytes.takeBytes(),
    maxAge: raftCacheControlMaxAge(
      response.headers.value(HttpHeaders.cacheControlHeader),
    ),
  );
}

/// Points the avatar layer at the proxy-aware fetcher and the shared disk
/// cache, registers the memory-pressure shrink, and makes "Clear cache" in
/// Settings > Storage forget the in-memory avatars too (the next mount then
/// fetches once). Called once at start-up.
void installAvatarImageCache(
  AttachmentDiskCache cache, {
  RaftMemoryRelease? memoryRelease,
}) {
  RaftImageBytes.instance
    ..fetcher = fetchAvatarImage
    ..store = AvatarImageStore(cache);
  (memoryRelease ?? RaftMemoryRelease.instance).addTrimmer(trimAvatarImages);
  cache.addPublicClearListener(clearAvatarImages);
}

/// Forgets every avatar held in memory (decoded, encoded and remembered
/// failures); widgets that show one keep theirs until they unmount.
void clearAvatarImages() {
  RaftHotImages.instance.evictAll();
  RaftImageBytes.instance
    ..clearMemory()
    ..forgetFailures();
}

/// Memory pressure shrinks the avatar caches to a small floor (64 decoded
/// avatars / 4 MB, 1 MB of encoded bytes) instead of emptying them: Android
/// reports the app being hidden as pressure, and avatars are what makes the
/// app look populated when it comes back. A time-based background trim keeps
/// them whole (they are bounded: `RaftHotImages` 24 MB).
@visibleForTesting
void trimAvatarImages(RaftMemoryTrim reason) {
  if (reason != RaftMemoryTrim.pressure) return;
  RaftHotImages.instance.trimTo();
  RaftImageBytes.instance.trimMemory(1024 * 1024);
}
