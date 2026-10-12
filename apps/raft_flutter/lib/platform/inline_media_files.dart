import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'native_sharing.dart';

/// Session cache of the private local copies that inline video and audio
/// cards play.
///
/// A card used to download its attachment (up to 50 MB) every time it was
/// built and delete the copy when it was disposed, so scrolling a clip out of
/// view and back downloaded it again, once per pass, and a fast scroll past a
/// column of clips started a download for each. Here the copy outlives the
/// card:
///
/// * one download per attachment, shared by every card that wants it;
/// * a card that leaves while the download is still running and has no other
///   holder cancels it (nothing is cached for what scrolled by);
/// * finished copies stay, within [maxBytes] / [maxEntries], least recently
///   released first out, until the identity scope changes (account, server,
///   role, sign-out) or the owner is disposed.
///
/// A hit makes no request at all (not even for the signed URL). Callers keep
/// their own authority checks; a hit never replaces them.
class InlineMediaFiles {
  InlineMediaFiles({
    this.maxBytes = 192 * 1024 * 1024,
    this.maxEntries = 32,
    this.maxIdle = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxBytes, maxEntries;
  final Duration maxIdle;
  final DateTime Function() _now;
  final Map<String, _Entry> _entries = {};
  Object? _scope;
  int downloads = 0;

  int get length => _entries.length;
  int get heldBytes =>
      _entries.values.fold(0, (sum, entry) => sum + entry.bytes);

  /// The copy for [key], downloading it with [load] when none is held or on
  /// its way. [load] receives the shared cancel token and an `authorized`
  /// check that turns false once nobody wants the file any more.
  Future<InlineMediaHold?> acquire(
    String key, {
    Object? scope,
    String? channelId,
    required Future<SharedFileLease?> Function(
      CancelToken cancel,
      bool Function() authorized,
    )
    load,
  }) async {
    synchronize(scope);
    _expire();
    var entry = _entries[key];
    if (entry != null && entry.lease != null && !_exists(entry.lease!)) {
      _drop(key);
      entry = null;
    }
    if (entry == null) {
      downloads++;
      final created = entry = _Entry(_scope, channelId);
      _entries[key] = created;
      created.loading = () async {
        try {
          final lease = await load(
            created.cancel,
            () =>
                !created.cancel.isCancelled &&
                created.refs > 0 &&
                identical(_entries[key], created),
          );
          if (lease == null || !identical(_entries[key], created)) {
            await lease?.dispose();
            if (identical(_entries[key], created)) _entries.remove(key);
            return null;
          }
          // The cache owns the file's lifetime from here (age and size
          // bounds, scope change, dispose), not the lease's own timer.
          lease.cancelExpiry();
          created.lease = lease;
          created.bytes = _length(lease);
          return lease;
        } catch (_) {
          if (identical(_entries[key], created)) _entries.remove(key);
          rethrow;
        }
      }();
    }
    final held = entry;
    held.refs++;
    final hold = InlineMediaHold._(this, key, held);
    try {
      final lease = await held.loading;
      if (lease == null) {
        hold.release();
        return null;
      }
      return hold;
    } catch (_) {
      hold.release();
      rethrow;
    }
  }

  static bool _exists(SharedFileLease lease) {
    try {
      return lease.file.existsSync();
    } catch (_) {
      return false;
    }
  }

  static int _length(SharedFileLease lease) {
    try {
      return lease.file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  void _release(String key, _Entry entry) {
    if (entry.refs > 0) entry.refs--;
    entry.released = _now();
    if (entry.refs > 0) return;
    if (entry.lease == null) {
      // Still downloading and nobody wants it: stop, keep nothing.
      entry.cancel.cancel();
      if (identical(_entries[key], entry)) _entries.remove(key);
      return;
    }
    _evict();
  }

  /// Copies nobody holds for longer than [maxIdle] go (the lease's own
  /// 15-60 minute expiry, applied lazily).
  void _expire() {
    final t = _now();
    for (final e in _entries.entries.toList()) {
      final v = e.value;
      if (v.refs == 0 && v.lease != null && t.difference(v.released) > maxIdle) {
        _drop(e.key);
      }
    }
  }

  void _evict() {
    final idle = [
      for (final e in _entries.entries)
        if (e.value.refs == 0 && e.value.lease != null) e,
    ]..sort((a, b) => a.value.released.compareTo(b.value.released));
    var bytes = heldBytes;
    var count = _entries.length;
    for (final e in idle) {
      if (bytes <= maxBytes && count <= maxEntries) break;
      bytes -= e.value.bytes;
      count--;
      _drop(e.key);
    }
  }

  void _drop(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return;
    entry.cancel.cancel();
    final lease = entry.lease;
    if (lease != null) unawaited(lease.dispose());
  }

  /// Revocation: nothing held for [channelId] survives, downloads included.
  void invalidateChannel(String channelId) {
    for (final e in _entries.entries.toList()) {
      if (e.value.channelId == channelId) _drop(e.key);
    }
  }

  /// Drops everything held for another identity.
  void synchronize(Object? scope) {
    if (scope == _scope) return;
    _scope = scope;
    clear();
  }

  void clear() {
    for (final key in _entries.keys.toList()) {
      _drop(key);
    }
  }

  void dispose() => clear();
}

/// One card's claim on a cached copy. [release] gives it back (idempotent).
class InlineMediaHold {
  InlineMediaHold._(this._owner, this._key, this._entry);
  final InlineMediaFiles _owner;
  final String _key;
  final _Entry _entry;
  bool _released = false;

  File get file => _entry.lease!.file;

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(_key, _entry);
  }
}

class _Entry {
  _Entry(this.scope, this.channelId) : released = DateTime.fromMillisecondsSinceEpoch(0);
  final Object? scope;
  final String? channelId;
  final CancelToken cancel = CancelToken();
  Future<SharedFileLease?>? loading;
  SharedFileLease? lease;
  int refs = 0, bytes = 0;
  DateTime released;
}
