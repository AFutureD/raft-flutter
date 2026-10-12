import 'dart:async';
import 'dart:collection';

/// Memory-only cache of signed attachment URLs.
///
/// A signed URL is a short-lived capability: it is held here only in memory,
/// is never logged or written to disk, and is dropped when its lifetime ends,
/// when its identity scope changes (account, server, role, sign-out), when its
/// channel is revoked, or when a transfer proves it stale. Callers keep their
/// own authority checks; a cache hit never replaces them.
///
/// Concurrent requests for the same attachment share one fetch (like Web's
/// `inlineAttachmentUrlCache`): a shared request outlives any single caller,
/// and each caller drops the result itself when it is gone.
class AttachmentUrlCache {
  AttachmentUrlCache({
    DateTime Function()? now,
    this.maxEntries = 256,
    this.maxLifetime = const Duration(minutes: 4),
    this.safetyMargin = const Duration(seconds: 45),
    this.unknownExpiryLifetime = const Duration(seconds: 60),
    this.prefetchBatch = 20,
    this.prefetchQueue = 40,
    this.prefetchDelay = const Duration(milliseconds: 120),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final int maxEntries;

  /// Never trust a URL for longer than this, whatever the server says. The
  /// server signs for 300 s; staying under that bounds clock skew.
  final Duration maxLifetime;

  /// A URL with less validity left than this is not reused: a transfer that
  /// starts now must outlive request latency and a redirect.
  final Duration safetyMargin;

  /// Lifetime when neither the response nor the URL states an expiry.
  final Duration unknownExpiryLifetime;
  final int prefetchBatch, prefetchQueue;
  final Duration prefetchDelay;

  final LinkedHashMap<_Key, _Entry> _entries = LinkedHashMap();
  final Map<_Key, Future<String>> _inFlight = {};
  final Set<_Key> _batched = {};
  final Map<_Key, _Prefetch> _queued = {};
  Object? _scope;
  int _epoch = 0;
  bool _batchRunning = false;
  Timer? _flushTimer;

  /// Number of cached URLs (diagnostics and tests; never their values).
  int get length => _entries.length;
  int get inFlightCount => _inFlight.length;
  int get queuedPrefetchCount => _queued.length;

  /// The unexpired URL for [id], or null. Never starts a request.
  String? peek(String id, {String disposition = 'inline', Object? scope}) {
    _enter(scope);
    final key = _Key(id, disposition);
    final entry = _entries[key];
    if (entry == null) return null;
    if (!entry.usable(_now(), safetyMargin)) {
      _entries.remove(key);
      return null;
    }
    return entry.url;
  }

  /// Resolves [id]: a fresh cached URL, a request already in flight, or a new
  /// [fetch]. [fetch] returns the decoded `GET /attachments/<id>/url` body.
  /// [scope] is the caller's identity; a different scope drops everything held.
  Future<String> resolve(
    String id, {
    String disposition = 'inline',
    Object? scope,
    String? channelId,
    required Future<dynamic> Function() fetch,
  }) {
    final hit = peek(id, disposition: disposition, scope: scope);
    if (hit != null) return Future<String>.value(hit);
    final key = _Key(id, disposition);
    final pending = _inFlight[key];
    if (pending != null) {
      if (!_batched.contains(key)) return pending;
      // A batch may omit an id it was not allowed to resolve; ask singly.
      return pending.catchError(
        (Object _) => resolve(
          id,
          disposition: disposition,
          scope: scope,
          channelId: channelId,
          fetch: fetch,
        ),
      );
    }
    final epoch = _epoch;
    late final Future<String> request;
    request = () async {
      final body = await fetch();
      final url = body is Map ? body['url'] : null;
      if (url is! String || url.isEmpty) {
        throw const FormatException('Invalid attachment response.');
      }
      // A revocation or scope change while the request was out means this
      // answer is not stored; the awaiting caller still applies its own check.
      if (epoch == _epoch) {
        _store(key, url, body['expiresAt'], channelId);
      }
      return url;
    }();
    _inFlight[key] = request;
    unawaited(
      request
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() {
            if (identical(_inFlight[key], request)) _inFlight.remove(key);
          }),
    );
    return request;
  }

  /// Queues a background resolve of [ids] (one batch request per flush) so a
  /// later open finds the URL cached. Bounded: at most [prefetchQueue] ids wait
  /// and [prefetchBatch] go in one request; one batch is in flight at a time.
  /// The returned handle removes the id again if it has not been sent.
  ///
  /// [fetchMany] returns the decoded `POST /attachments/urls` body
  /// (`{urls: [{id, url, expiresAt}]}`).
  PrefetchHandle prefetch(
    String id, {
    Object? scope,
    String? channelId,
    required Future<dynamic> Function(List<String> ids) fetchMany,
  }) {
    // The batch route signs for inline use only.
    const disposition = 'inline';
    final key = _Key(id, disposition);
    if (peek(id, disposition: disposition, scope: scope) != null ||
        _inFlight.containsKey(key)) {
      return PrefetchHandle._(() {});
    }
    var item = _queued[key];
    if (item == null) {
      while (_queued.length >= prefetchQueue) {
        _queued.remove(_queued.keys.first);
      }
      item = _queued[key] = _Prefetch(key, channelId, fetchMany, _epoch);
    }
    item.holders++;
    _schedule();
    final queued = item;
    return PrefetchHandle._(() {
      if (--queued.holders <= 0 && identical(_queued[key], queued)) {
        _queued.remove(key);
      }
    });
  }

  void _schedule() {
    if (_flushTimer != null || _batchRunning || _queued.isEmpty) return;
    _flushTimer = Timer(prefetchDelay, () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    if (_batchRunning || _queued.isEmpty) return;
    _batchRunning = true;
    final batch = <_Prefetch>[];
    for (final item in _queued.values) {
      if (batch.length >= prefetchBatch) break;
      batch.add(item);
    }
    for (final item in batch) {
      _queued.remove(item.key);
    }
    final completers = <_Key, Completer<String>>{};
    for (final item in batch) {
      final completer = Completer<String>();
      completers[item.key] = completer;
      _inFlight[item.key] = completer.future;
      _batched.add(item.key);
      // Nobody may be waiting; the error must not become unhandled.
      unawaited(completer.future.then<void>((_) {}, onError: (Object _) {}));
    }
    try {
      final body = await batch.first.fetchMany([
        for (final item in batch) item.key.id,
      ]);
      final urls = body is Map ? body['urls'] : null;
      final byId = <String, Map>{
        if (urls is List)
          for (final entry in urls)
            if (entry is Map && entry['id'] is String && entry['url'] is String)
              entry['id'] as String: entry,
      };
      for (final item in batch) {
        final entry = byId[item.key.id];
        if (entry != null && item.epoch == _epoch) {
          _store(
            item.key,
            entry['url'] as String,
            entry['expiresAt'],
            item.channelId,
          );
          completers[item.key]!.complete(entry['url'] as String);
        } else {
          completers[item.key]!.completeError(
            const FormatException('No attachment url.'),
          );
        }
      }
    } catch (error) {
      for (final completer in completers.values) {
        if (!completer.isCompleted) completer.completeError(error);
      }
    } finally {
      for (final item in batch) {
        _inFlight.remove(item.key);
        _batched.remove(item.key);
      }
      _batchRunning = false;
      _schedule();
    }
  }

  /// Drops a URL a transfer rejected (expired or revoked).
  void invalidate(String id, {String? disposition}) {
    _entries.removeWhere(
      (key, _) => key.id == id && (disposition == null || key.disposition == disposition),
    );
    _epoch++;
  }

  /// Revocation: nothing resolved for [channelId] survives, in flight included.
  void invalidateChannel(String channelId) {
    _entries.removeWhere((_, entry) => entry.channelId == channelId);
    _queued.removeWhere((_, item) => item.channelId == channelId);
    _epoch++;
  }

  void clear() {
    _entries.clear();
    _queued.clear();
    _epoch++;
  }

  void dispose() {
    clear();
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// Drops everything held for another identity (account, server, role,
  /// sign-out). Called with the owner's current scope on every state change.
  void synchronize(Object? scope) => _enter(scope);

  void _enter(Object? scope) {
    if (scope != _scope) {
      _scope = scope;
      clear();
    }
  }

  void _store(_Key key, String url, Object? expiresAt, String? channelId) {
    final now = _now();
    var lifetime = _lifetime(url, expiresAt, now);
    if (lifetime <= safetyMargin) return;
    if (lifetime > maxLifetime) lifetime = maxLifetime;
    _entries.remove(key);
    _entries[key] = _Entry(url, now.add(lifetime), channelId);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Remaining validity from the response, else from the URL's own signature
  /// (`X-Amz-Date` + `X-Amz-Expires`), else [unknownExpiryLifetime]. A URL that
  /// embeds a bearer token in its query (server-streamed storage) is short
  /// lived by the same default.
  Duration _lifetime(String url, Object? expiresAt, DateTime now) {
    if (expiresAt is String) {
      final at = DateTime.tryParse(expiresAt);
      if (at != null) return at.difference(now);
    }
    final query = Uri.tryParse(url)?.queryParameters ?? const {};
    String? param(String name) {
      for (final entry in query.entries) {
        if (entry.key.toLowerCase() == name) return entry.value;
      }
      return null;
    }

    final signedAt = param('x-amz-date'), seconds = param('x-amz-expires');
    final span = int.tryParse(seconds ?? '');
    if (signedAt != null && span != null && signedAt.length == 16) {
      final start = DateTime.tryParse(
        '${signedAt.substring(0, 4)}-${signedAt.substring(4, 6)}-'
        '${signedAt.substring(6, 8)}T${signedAt.substring(9, 11)}:'
        '${signedAt.substring(11, 13)}:${signedAt.substring(13, 15)}Z',
      );
      if (start != null) {
        return start.add(Duration(seconds: span)).difference(now);
      }
    }
    return unknownExpiryLifetime;
  }
}

class PrefetchHandle {
  PrefetchHandle._(this._cancel);
  PrefetchHandle.none() : _cancel = (() {});
  final void Function() _cancel;
  bool _cancelled = false;

  /// Withdraws the request if it has not been sent yet. A request already in
  /// flight completes into the cache (and serves any later open).
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancel();
  }
}

class _Key {
  const _Key(this.id, this.disposition);
  final String id, disposition;
  @override
  bool operator ==(Object other) =>
      other is _Key && other.id == id && other.disposition == disposition;
  @override
  int get hashCode => Object.hash(id, disposition);
}

class _Entry {
  _Entry(this.url, this.expires, this.channelId);
  final String url;
  final DateTime expires;
  final String? channelId;
  bool usable(DateTime now, Duration margin) =>
      expires.difference(now) > margin;
}

class _Prefetch {
  _Prefetch(this.key, this.channelId, this.fetchMany, this.epoch);
  final _Key key;
  final String? channelId;
  final Future<dynamic> Function(List<String>) fetchMany;
  final int epoch;
  int holders = 0;
}
