import 'dart:async';
import 'dart:collection';
import 'dart:io' show HttpClient, HttpClientResponse, HttpHeaders, HttpStatus;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Avatar and icon pictures (people, agents, servers, apps) are small, shown
/// everywhere and reused constantly, so they get a cache of their own instead
/// of sharing the 100 MB decoded-bitmap LRU with message attachments.
///
/// Layers, outermost first:
///
/// 1. decoded bitmap, held by [RaftHotImages] (an LRU of keep-alive handles
///    that the shared `ImageCache` cannot evict) so a remount paints in the
///    same frame;
/// 2. encoded bytes in memory, keyed by [raftStableImageKey] (not by display
///    size, so 20 / 36 / 64 dp surfaces share one download);
/// 3. encoded bytes in a persistent [RaftImageByteStore] when the host
///    installs one (the app does; survives restarts and background trims);
/// 4. the network, once per key at a time, with failures remembered briefly so
///    a 404 avatar is not requested again by every row that shows it.
///
/// Query parameters that only sign or time-limit a URL never take part in the
/// key; the request still uses the full URL it was given.

/// Query parameters (case-insensitive) that change per request without
/// changing the picture: URL signatures, expiry and tokens.
bool _volatileParameter(String name) {
  final n = name.toLowerCase();
  return n.startsWith('x-amz-') ||
      n.startsWith('x-goog-') ||
      n.startsWith('x-ms-') ||
      const {
        'signature',
        'sig',
        'expires',
        'expiry',
        'exp',
        'token',
        'access_token',
        'policy',
        'key-pair-id',
        'se',
        'sp',
        'sv',
        'sr',
        'skoid',
        'sktid',
        'st',
        'ske',
        'sks',
        'skv',
      }.contains(n);
}

/// The cache identity of [url]: lower-cased scheme and host, no fragment, no
/// signing or expiry parameters, remaining parameters sorted. Content
/// identifying parameters (`v`, `s`, `size`, ...) stay.
String raftStableImageKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  final kept =
      [
        for (final e in uri.queryParametersAll.entries)
          if (!_volatileParameter(e.key))
            for (final v in e.value) MapEntry(e.key, v),
      ]..sort(
        (a, b) => a.key == b.key
            ? a.value.compareTo(b.value)
            : a.key.compareTo(b.key),
      );
  final query = kept.map(
    (e) =>
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
  );
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    userInfo: uri.userInfo,
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    query: query.isEmpty ? null : query.join('&'),
  ).toString();
}

/// The decode extent (physical px) for an avatar box of [extent] px: rounded
/// up to a multiple of 12 (48 above 144). The exact common sizes (36 dp at
/// 1x / 2x / 3x = 36 / 72 / 108, 20 dp at 3x = 60) are unchanged, while the
/// fractional-ratio sizes that differ by a few pixels (2.5x and 2.625x phones)
/// share one decoded bitmap instead of one each.
int raftBucketExtent(int extent) {
  final step = extent <= 144 ? 12 : 48;
  return (extent + step - 1) ~/ step * step;
}

/// Persistent encoded-bytes storage behind [RaftImageBytes] (disk in the app).
/// Implementations must be safe to call concurrently and may throw; a failing
/// store only costs a network request.
abstract interface class RaftImageByteStore {
  Future<Uint8List?> read(String key);

  /// Stores [bytes] for at most [maxAge] (the server's `Cache-Control`; null
  /// when it said nothing). A zero [maxAge] means "do not keep".
  Future<void> write(String key, Uint8List bytes, {Duration? maxAge});
}

/// What a fetch returned: the encoded picture and how long the server allows
/// keeping it ([raftCacheControlMaxAge]).
class RaftFetchedImage {
  const RaftFetchedImage(this.bytes, {this.maxAge});
  final Uint8List bytes;
  final Duration? maxAge;
}

typedef RaftImageFetcher = Future<RaftFetchedImage> Function(String url);

/// The freshness a `Cache-Control` header grants: `immutable` is unbounded
/// ([Duration] of 10 years), `max-age=N` is N seconds, `no-store` / `no-cache`
/// / `max-age=0` is zero, no usable directive is null. `s-maxage` is ignored.
Duration? raftCacheControlMaxAge(String? header) {
  if (header == null) return null;
  Duration? result;
  var immutable = false;
  for (final raw in header.split(',')) {
    final directive = raw.trim().toLowerCase();
    if (directive == 'no-store' || directive == 'no-cache') {
      return Duration.zero;
    }
    if (directive == 'immutable') immutable = true;
    if (directive.startsWith('max-age=')) {
      final seconds = int.tryParse(directive.substring(8).replaceAll('"', ''));
      if (seconds != null && seconds >= 0) result = Duration(seconds: seconds);
    }
  }
  if (result != null) return result;
  return immutable ? const Duration(days: 3650) : null;
}

class RaftImageHttpError implements Exception {
  const RaftImageHttpError(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'RaftImageHttpError($statusCode)';
}

/// Bytes of avatar pictures: memory, then [store], then [fetcher].
class RaftImageBytes {
  /// Encoded avatar bytes kept in memory (the app's memory budget table,
  /// `RaftMemoryBudgets`, lists it).
  static const defaultMemoryBudgetBytes = 8 * 1024 * 1024;

  RaftImageBytes({
    RaftImageFetcher? fetcher,
    this.store,
    this.memoryBudgetBytes = defaultMemoryBudgetBytes,
    this.maxEntryBytes = 4 * 1024 * 1024,
    this.clientErrorMemory = const Duration(minutes: 10),
    this.transientErrorMemory = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : fetcher = fetcher ?? _fetchWithFlutterClient,
       _now = now ?? DateTime.now;

  /// The process-wide service used by [RaftAvatarImageProvider].
  static RaftImageBytes instance = RaftImageBytes();

  RaftImageFetcher fetcher;
  RaftImageByteStore? store;
  final int memoryBudgetBytes, maxEntryBytes;

  /// How long a 4xx answer (no such avatar) is remembered without asking
  /// again, and the same for a network failure or 5xx.
  final Duration clientErrorMemory, transientErrorMemory;
  final DateTime Function() _now;

  final _memory = LinkedHashMap<String, Uint8List>();
  var _memoryBytes = 0;
  final _inFlight = <String, Future<Uint8List>>{};
  final _failures = <String, ({DateTime until, Object error})>{};

  /// Requests that reached [fetcher] (tests and diagnostics).
  int fetchCount = 0;

  int get memoryEntries => _memory.length;
  int get memoryBytes => _memoryBytes;

  /// The encoded bytes for [url], which is requested as given while the cache
  /// identity is [raftStableImageKey] of it.
  Future<Uint8List> load(String url) {
    final key = raftStableImageKey(url);
    final hit = _memory.remove(key);
    if (hit != null) {
      _memory[key] = hit; // most recent last
      return SynchronousFuture(hit);
    }
    final failure = _failures[key];
    if (failure != null) {
      if (_now().isBefore(failure.until)) {
        return Future<Uint8List>.error(failure.error);
      }
      _failures.remove(key);
    }
    return _inFlight[key] ??= _fill(key, url).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<Uint8List> _fill(String key, String url) async {
    final persisted = store;
    if (persisted != null) {
      try {
        final bytes = await persisted.read(key);
        if (bytes != null && bytes.isNotEmpty) {
          _remember(key, bytes);
          return bytes;
        }
      } catch (_) {
        // A broken store is a miss.
      }
    }
    try {
      fetchCount++;
      final fetched = await fetcher(url);
      final bytes = fetched.bytes;
      _remember(key, bytes);
      if (persisted != null && fetched.maxAge != Duration.zero) {
        unawaited(
          persisted
              .write(key, bytes, maxAge: fetched.maxAge)
              .catchError((Object _) {}),
        );
      }
      return bytes;
    } catch (error) {
      final client =
          error is RaftImageHttpError &&
          error.statusCode >= 400 &&
          error.statusCode < 500 &&
          error.statusCode != HttpStatus.requestTimeout &&
          error.statusCode != HttpStatus.tooManyRequests;
      _failures[key] = (
        until: _now().add(client ? clientErrorMemory : transientErrorMemory),
        error: error,
      );
      rethrow;
    }
  }

  void _remember(String key, Uint8List bytes) {
    if (bytes.length > maxEntryBytes) return;
    final old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.length;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > memoryBudgetBytes && _memory.length > 1) {
      final oldest = _memory.keys.first;
      _memoryBytes -= _memory.remove(oldest)!.length;
    }
  }

  /// Forgets remembered failures (for example after the network changed).
  void forgetFailures() => _failures.clear();

  /// Drops the in-memory copies; the [store] and the network still serve.
  void clearMemory() => trimMemory(0);

  /// Drops the oldest in-memory copies until at most [maxBytes] remain.
  void trimMemory(int maxBytes) {
    while (_memoryBytes > maxBytes && _memory.isNotEmpty) {
      _memoryBytes -= _memory.remove(_memory.keys.first)!.length;
    }
  }

  // One client for every avatar so connections are reused, like the framework's
  // own NetworkImage client.
  static HttpClient? _client;

  /// Forgets the shared client (tests that change `HttpOverrides`).
  @visibleForTesting
  static void resetClient() {
    _client?.close(force: true);
    _client = null;
  }

  static Future<RaftFetchedImage> _fetchWithFlutterClient(String url) async {
    // Same client NetworkImage uses: it follows `HttpOverrides.global`, which
    // the app points at the shared proxy decision (docs/system-proxy.md); the
    // app also installs its own fetcher on [RaftImageBytes.instance].
    // ignore: raft_lints/avoid_unproxied_network_client -- Resolves through HttpOverrides.global (SystemProxy.installGlobally), exactly like Flutter's NetworkImage; the app replaces it with SystemProxy.createHttpClient.
    final client = _client ??= HttpClient();
    final request = await client.getUrl(Uri.parse(url));
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw RaftImageHttpError(response.statusCode);
    }
    return RaftFetchedImage(
      await consolidateHttpClientResponseBytes(response),
      maxAge: raftCacheControlMaxAge(
        response.headers.value(HttpHeaders.cacheControlHeader),
      ),
    );
  }
}

/// Keeps decoded avatar bitmaps alive across the shared `ImageCache`'s LRU.
///
/// A bitmap whose widget unmounts moves to the 100 MB LRU, where a few screens
/// of attachments push it out; the avatar then reloads and flickers on the
/// next visit. This is an LRU of owned completers (bounded by count and by the
/// estimated decoded size): while one is held, the sized provider hands it back
/// from `loadImage`, so a remount after an `ImageCache` eviction is answered
/// synchronously with the already decoded image and no new request or decode.
class RaftHotImages {
  RaftHotImages({
    this.maxEntries = defaultMaxEntries,
    this.maxBytes = defaultMaxBytes,
  });

  /// Decoded avatar bitmaps held: count and estimated size (the app's memory
  /// budget table, `RaftMemoryBudgets`, lists them).
  static const defaultMaxEntries = 384;
  static const defaultMaxBytes = 24 * 1024 * 1024;

  static final RaftHotImages instance = RaftHotImages();

  final int maxEntries, maxBytes;
  final _held =
      LinkedHashMap<
        Object,
        ({
          ImageStreamCompleter completer,
          ImageStreamCompleterHandle handle,
          int bytes,
        })
      >();
  var _bytes = 0;

  int get length => _held.length;
  int get estimatedBytes => _bytes;
  bool holds(Object key) => _held.containsKey(key);

  /// The held completer for [key], marked most recently used.
  ImageStreamCompleter? completerFor(Object key) {
    final entry = _held.remove(key);
    if (entry == null) return null;
    _held[key] = entry;
    return entry.completer;
  }

  /// Marks [key] most recently used when it is held.
  void touch(Object key) => completerFor(key);

  /// Holds [completer] under [key].
  void hold(Object key, ImageStreamCompleter completer, int estimatedBytes) {
    release(key);
    _held[key] = (
      completer: completer,
      handle: completer.keepAlive(),
      bytes: estimatedBytes,
    );
    _bytes += estimatedBytes;
    while (_held.length > maxEntries ||
        (_bytes > maxBytes && _held.length > 1)) {
      release(_held.keys.first);
    }
  }

  /// Lets go of [key] (evicted by the LRU, or its image failed to load).
  void release(Object key) {
    final entry = _held.remove(key);
    if (entry == null) return;
    _bytes -= entry.bytes;
    entry.handle.dispose();
  }

  /// Memory pressure: keep only the [maxEntries] most recently used avatars
  /// (and at most [maxBytes]); a handful of 36 dp bitmaps is a few hundred KB.
  /// Android reports the app going to the background as memory pressure, and
  /// dropping every avatar then is what makes them reload on return.
  void trimTo({int maxEntries = 64, int maxBytes = 4 * 1024 * 1024}) {
    while (_held.length > maxEntries ||
        (_bytes > maxBytes && _held.length > 1)) {
      release(_held.keys.first);
    }
  }

  /// "Clear cache": lets go of everything held and also evicts those images
  /// from the shared `ImageCache` (live entries too), so the next mount
  /// resolves again from [RaftImageBytes]. Avatars an on-screen widget shows
  /// stay until it unmounts.
  void evictAll() {
    final cache = PaintingBinding.instance.imageCache;
    for (final key in _held.keys.toList()) {
      cache.evict(key, includeLive: true);
    }
    releaseAll();
  }

  /// Lets go of everything; images that are on screen stay alive through
  /// their own listeners.
  void releaseAll() {
    for (final entry in _held.values) {
      entry.handle.dispose();
    }
    _held.clear();
    _bytes = 0;
  }
}

@immutable
class RaftAvatarImageKey {
  const RaftAvatarImageKey(this.stable);
  final String stable;
  @override
  bool operator ==(Object other) =>
      other is RaftAvatarImageKey && other.stable == stable;
  @override
  int get hashCode => stable.hashCode;
}

/// The one provider for avatar / icon URLs. Wrap it with [raftSizedImage]
/// (or use `RaftSizedImage.avatar`) so the decode is display-sized.
@immutable
class RaftAvatarImageProvider extends ImageProvider<RaftAvatarImageKey> {
  RaftAvatarImageProvider(this.url, {RaftImageBytes? bytes})
    : _bytes = bytes,
      _key = RaftAvatarImageKey(raftStableImageKey(url));

  /// Fetched exactly as given (it may be signed); not part of the identity.
  final String url;
  final RaftImageBytes? _bytes;
  final RaftAvatarImageKey _key;

  @override
  Future<RaftAvatarImageKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(_key);

  @override
  ImageStreamCompleter loadImage(
    RaftAvatarImageKey key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _codec(decode),
    scale: 1.0,
    debugLabel: 'avatar ${key.stable}',
  );

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async {
    final bytes = await (_bytes ?? RaftImageBytes.instance).load(url);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is RaftAvatarImageProvider && other._key == _key;
  @override
  int get hashCode => _key.hashCode;
  @override
  String toString() => 'RaftAvatarImageProvider(${_key.stable})';
}
