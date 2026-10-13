import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'attachment_image_store.dart';

/// The size cap of the attachment cache (all accounts and servers on this
/// device). The one place the number is defined; eviction trims to 90 % of it.
const int attachmentCacheMaxBytes = 1024 * 1024 * 1024;

/// A cached file handed to a caller. While it is open the cache never evicts
/// or clears the file; [release] ends that. Never delete [file] yourself.
class AttachmentCachedFile {
  AttachmentCachedFile._(this._owner, this.file);
  final AttachmentDiskCache _owner;
  final File file;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _owner._unpin(file.path);
  }
}

/// Downloads into [destination] (a private temporary path inside the cache).
/// [cancel] is shared by every caller joined to the download; [progress] is
/// dio's `onReceiveProgress` shape. Throws on any failure.
typedef AttachmentFileDownload =
    Future<void> Function(
      File destination,
      CancelToken cancel,
      void Function(int received, int total) progress,
    );

/// The cache directory is unusable (no platform cache dir, read-only disk).
/// Callers fall back to their uncached path.
class AttachmentCacheUnavailable implements Exception {
  const AttachmentCacheUnavailable();
}

/// Persistent, bounded, concurrency-safe on-disk cache of attachment content,
/// keyed by account/server/channel and the attachment id plus its content
/// identity (never by a signed URL, so URL expiry cannot invalidate or
/// duplicate an entry).
///
/// Two kinds of entry share the budget and the LRU order:
/// * bytes (inline image sources, preview JSON/HTML): [read] / [write];
/// * files (PDF, audio and other preview inputs that native decoders open by
///   path): [openFile] / [fetchFile].
///
/// Layout `<root>/v2/<account>/<server>/<channel>/<entry>[.f/<name>]`, every
/// segment a hash except the file name. Writes go to a `.raft-part` sibling
/// and are renamed into place, so a crash leaves only an ignorable partial
/// that the next start deletes. Access order persists in file modification
/// times. Reads are only issued by callers that already hold authority; the
/// cache never grants access.
class AttachmentDiskCache implements AttachmentImageByteStore {
  AttachmentDiskCache(
    this._root, {
    this.maxBytes = attachmentCacheMaxBytes,
    this.maxEntryBytes = 64 * 1024 * 1024,
  });

  /// The process-wide cache installed by the app entry point. Controllers use
  /// it unless they are given another store; tests leave it unset.
  static AttachmentDiskCache? installed;

  static const _partSuffix = '.raft-part';
  static const _layout = 'v2';

  final Future<Directory> Function() _root;
  final int maxBytes, maxEntryBytes;
  Future<_DiskIndex?>? _index;
  Future<void> _tail = Future.value();
  final Map<String, int> _pins = {};
  final Map<String, _Download> _downloads = {};
  int _sequence = 0;

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 40);

  /// Account and server segments of an identity. The identity string is
  /// `[origin, principal, server]` as JSON (see `AttachmentImageKey`); the
  /// split lets sign-out remove an account without knowing its servers.
  static (String, String) _segments(String identity) {
    try {
      final parts = jsonDecode(identity);
      if (parts is List && parts.length == 3) {
        return (
          _hash(jsonEncode([parts[0], parts[1]])),
          _hash(jsonEncode(parts[2])),
        );
      }
    } catch (_) {
      // Not structured: a single flat bucket.
    }
    return (_hash(identity), '-');
  }

  static String _accountSegment(String origin, String principal) =>
      _hash(jsonEncode([origin, principal]));

  /// Opens the index (once): creates the directory, deletes partial files and
  /// the pre-v2 layout, and sizes what is there. Null when no directory.
  Future<_DiskIndex?> _open() => _index ??= () async {
    try {
      final base = await _root();
      final directory = Directory(
        p.join(base.path, 'raft-attachments', _layout),
      );
      await directory.create(recursive: true);
      // The first image-only layout: its entries were never reachable again.
      unawaited(
        _quietly(
          () => Directory(
            p.join(base.path, 'raft-attachment-images'),
          ).delete(recursive: true),
        ),
      );
      final index = _DiskIndex(directory);
      await for (final entity in directory.list(recursive: true)) {
        if (entity is! File) continue;
        if (entity.path.endsWith(_partSuffix)) {
          await _quietly(entity.delete);
          continue;
        }
        try {
          final stat = await entity.stat();
          index.files[entity.path] = (stat.size, stat.modified);
          index.total += stat.size;
        } on FileSystemException {
          // Raced with another eviction; nothing to index.
        }
      }
      return index;
    } catch (_) {
      return null; // No platform cache directory: run memory-only.
    }
  }();

  /// Starts indexing now (app start), so the first lookups do not wait for it.
  Future<void> warm() => _open().then<void>((_) {}, onError: (Object _) {});

  /// Serializes mutations so concurrent writes/evictions see one index.
  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  String _dir(_DiskIndex index, AttachmentImageStoreKey key) {
    final (account, server) = _segments(key.identity);
    return p.join(index.directory.path, account, server, _hash(key.channelId));
  }

  String _path(_DiskIndex index, AttachmentImageStoreKey key) =>
      p.join(_dir(index, key), _hash(key.entry));

  static String _safeName(String name) {
    var cleaned = p.posix
        .basename(p.windows.basename(name))
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      cleaned = 'attachment';
    }
    if (cleaned.length > 96) {
      final extension = p.extension(cleaned);
      final keep = extension.length <= 16 ? extension : '';
      cleaned = cleaned.substring(0, 96 - keep.length) + keep;
    }
    return cleaned;
  }

  String _filePath(
    _DiskIndex index,
    AttachmentImageStoreKey key,
    String filename,
  ) => p.join('${_path(index, key)}.f', _safeName(filename));

  // ---- Bytes entries -------------------------------------------------------

  @override
  Future<Uint8List?> read(AttachmentImageStoreKey key) async {
    final index = await _open();
    if (index == null) return null;
    final path = _path(index, key);
    if (!index.files.containsKey(path)) return null;
    try {
      final bytes = await File(path).readAsBytes();
      final now = DateTime.now();
      index.files[path] = (bytes.length, now);
      unawaited(_quietly(() => File(path).setLastModified(now)));
      return bytes;
    } on FileSystemException {
      await _serial(() => _delete(index, path));
      return null;
    }
  }

  @override
  Future<void> write(AttachmentImageStoreKey key, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxEntryBytes) return;
    final index = await _open();
    if (index == null) return;
    await _serial(() async {
      final path = _path(index, key);
      final part = '$path.${_sequence++}$_partSuffix';
      try {
        await Directory(p.dirname(path)).create(recursive: true);
        await File(part).writeAsBytes(bytes, flush: true);
        await File(part).rename(path);
      } on FileSystemException {
        await _quietly(() => File(part).delete());
        return;
      }
      _register(index, path, bytes.length);
      await _trim(index, keep: path);
    });
  }

  /// True when the bytes entry is stored; no read and no LRU touch.
  Future<bool> contains(AttachmentImageStoreKey key) async {
    final index = await _open();
    return index != null && index.files.containsKey(_path(index, key));
  }

  @override
  Future<void> remove(AttachmentImageStoreKey key) async {
    final index = await _open();
    if (index == null) return;
    await _serial(() => _delete(index, _path(index, key)));
  }

  // ---- File entries --------------------------------------------------------

  /// True when the file entry is stored; no LRU touch.
  Future<bool> containsFile(
    AttachmentImageStoreKey key, {
    required String filename,
  }) async {
    final index = await _open();
    return index != null &&
        index.files.containsKey(_filePath(index, key, filename));
  }

  /// The stored file for [key], pinned, or null on a miss. A file whose size
  /// differs from [expectedBytes] (or from what was stored) is corrupt: it is
  /// deleted and reported as a miss.
  Future<AttachmentCachedFile?> openFile(
    AttachmentImageStoreKey key, {
    required String filename,
    int? expectedBytes,
  }) async {
    expectedBytes = _knownSize(expectedBytes);
    final index = await _open();
    if (index == null) return null;
    return _openPath(index, _filePath(index, key, filename), expectedBytes);
  }

  /// Attachment metadata without a size (0, negative) promises nothing: it must
  /// not make every download look incomplete.
  static int? _knownSize(int? bytes) =>
      bytes != null && bytes > 0 ? bytes : null;

  Future<AttachmentCachedFile?> _openPath(
    _DiskIndex index,
    String path,
    int? expectedBytes,
  ) async {
    final entry = index.files[path];
    if (entry == null) return null;
    _pin(path); // Before touching the disk: eviction must not win the race.
    try {
      if (expectedBytes != null && entry.$1 != expectedBytes) {
        throw const FileSystemException('size differs from the metadata');
      }
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file || stat.size != entry.$1) {
        throw const FileSystemException('stored file changed');
      }
      final now = DateTime.now();
      index.files[path] = (stat.size, now);
      unawaited(_quietly(() => File(path).setLastModified(now)));
      return AttachmentCachedFile._(this, File(path));
    } on FileSystemException {
      _unpin(path);
      await _serial(() => _delete(index, path));
      return null;
    }
  }

  /// The file for [key]: the stored copy, or one download shared by every
  /// caller asking for the same entry at the same time. [download] runs once;
  /// its result is checked (non-empty, [expectedBytes]) and renamed into
  /// place atomically before any caller sees it. Returns a pinned handle, or
  /// null if this caller's [cancel] fired first (the download is cancelled
  /// when no caller is left). Throws the download's error otherwise, and
  /// [AttachmentCacheUnavailable] when there is no cache directory.
  Future<AttachmentCachedFile?> fetchFile(
    AttachmentImageStoreKey key, {
    required String filename,
    required AttachmentFileDownload download,
    int? expectedBytes,
    CancelToken? cancel,
    void Function(int received, int total)? onProgress,
  }) async {
    expectedBytes = _knownSize(expectedBytes);
    final index = await _open();
    if (index == null) throw const AttachmentCacheUnavailable();
    final path = _filePath(index, key, filename);
    final stored = await _openPath(index, path, expectedBytes);
    if (stored != null) return stored;
    if (cancel?.isCancelled == true) return null;
    final job = _downloads[path] ??= _startDownload(
      index,
      path,
      download,
      expectedBytes,
    );
    final waiter = _Waiter(onProgress);
    job.waiters.add(waiter);
    final detached = Completer<void>();
    unawaited(
      cancel?.whenCancel.then<void>((_) {
        // After the download finished the waiter already owns its pin.
        if (job.finished || !job.waiters.remove(waiter)) return;
        if (job.waiters.isEmpty) job.shared.cancel();
        detached.complete();
      }),
    );
    await Future.any([job.done.future, detached.future]);
    if (!job.waiters.contains(waiter)) return null;
    return AttachmentCachedFile._(this, File(path));
  }

  _Download _startDownload(
    _DiskIndex index,
    String path,
    AttachmentFileDownload download,
    int? expectedBytes,
  ) {
    final job = _Download();
    // An abandoned download may fail after every waiter left.
    unawaited(job.done.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(() async {
      final part = File('$path.${_sequence++}$_partSuffix');
      try {
        await part.parent.create(recursive: true);
        await download(part, job.shared, (received, total) {
          for (final waiter in job.waiters.toList()) {
            waiter.progress?.call(received, total);
          }
        });
        if (job.shared.isCancelled) {
          throw const FileSystemException('download cancelled');
        }
        final length = await part.length();
        if (length == 0 ||
            length > maxBytes ||
            (expectedBytes != null && length != expectedBytes)) {
          throw const FileSystemException('incomplete download');
        }
        await _serial(() async {
          await part.rename(path);
          _register(index, path, length);
          // From this instant the entry is findable, every caller still
          // attached owns one pin, and later callers open the stored file:
          // nothing below (eviction included) can lose it.
          _pins[path] = (_pins[path] ?? 0) + job.waiters.length;
          job.finished = true;
          if (identical(_downloads[path], job)) _downloads.remove(path);
          await _trim(index, keep: path);
        });
        job.done.complete();
      } catch (error, trace) {
        await _quietly(part.delete);
        job.finished = true;
        if (identical(_downloads[path], job)) _downloads.remove(path);
        job.done.completeError(error, trace);
      }
    }());
    return job;
  }

  void _pin(String path) => _pins[path] = (_pins[path] ?? 0) + 1;

  void _unpin(String path) {
    final count = (_pins[path] ?? 0) - 1;
    if (count > 0) {
      _pins[path] = count;
    } else {
      _pins.remove(path);
    }
  }

  // ---- Index, eviction, removal -------------------------------------------

  void _register(_DiskIndex index, String path, int length) {
    index.total -= index.files[path]?.$1 ?? 0;
    index.files[path] = (length, DateTime.now());
    index.total += length;
  }

  /// Trims the least recently used unpinned entries (never [keep]) down to
  /// 90 % of [maxBytes] when over it. Inside [_serial].
  Future<void> _trim(_DiskIndex index, {required String keep}) async {
    if (index.total <= maxBytes) return;
    final oldest = index.files.entries.toList()
      ..sort((a, b) => a.value.$2.compareTo(b.value.$2));
    for (final entry in oldest) {
      if (index.total <= maxBytes * 9 ~/ 10) break;
      if (entry.key == keep || _pins.containsKey(entry.key)) continue;
      await _delete(index, entry.key);
    }
  }

  /// Bytes stored (what Settings shows).
  Future<int> sizeBytes() async => (await _open())?.total ?? 0;

  /// Number of stored entries.
  Future<int> entryCount() async => (await _open())?.files.length ?? 0;

  /// Removes every entry of every account and server on this device except
  /// files an open preview still holds. Never touches anything outside the
  /// cache directory (sessions, drafts, settings, files the user saved).
  Future<void> clear() async {
    final index = await _open();
    if (index == null) return;
    await _serial(() async {
      for (final path in index.files.keys.toList()) {
        if (_pins.containsKey(path)) continue;
        await _delete(index, path);
      }
      await _pruneEmpty(index.directory);
    });
  }

  Future<void> _pruneEmpty(Directory root) async {
    final directories = <Directory>[];
    try {
      await for (final entity in root.list(recursive: true)) {
        if (entity is Directory) directories.add(entity);
      }
    } on FileSystemException {
      return;
    }
    directories.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in directories) {
      await _quietly(directory.delete); // Non-recursive: only when empty.
    }
  }

  @override
  Future<void> purgeChannel(String identity, String channelId) {
    final (account, server) = _segments(identity);
    return _purge(p.join(account, server, _hash(channelId)));
  }

  @override
  Future<void> purgeIdentity(String identity) {
    final (account, server) = _segments(identity);
    return _purge(p.join(account, server));
  }

  /// Removes everything cached for one account on this device (sign-out,
  /// rejected session, account switch), whatever servers it used.
  Future<void> purgeAccount(String origin, String principal) =>
      _purge(_accountSegment(origin, principal));

  /// [purgeAccount] on the installed cache.
  static Future<void> purgeInstalledAccount(
    String origin,
    String principal,
  ) async => installed?.purgeAccount(origin, principal);

  Future<void> _purge(String relative) async {
    final index = await _open();
    if (index == null) return;
    await _serial(() async {
      final directory = p.join(index.directory.path, relative);
      // Revoked data goes even if a preview still holds it; that preview's
      // own authority check closes it.
      for (final path in index.files.keys.toList()) {
        if (p.isWithin(directory, path)) {
          index.total -= index.files.remove(path)!.$1;
        }
      }
      await _quietly(() => Directory(directory).delete(recursive: true));
    });
  }

  Future<void> _delete(_DiskIndex index, String path) async {
    final removed = index.files.remove(path);
    if (removed != null) index.total -= removed.$1;
    await _quietly(() => File(path).delete());
    if (path.contains('.f${p.separator}')) {
      // A file entry lives in its own directory.
      await _quietly(() => Directory(p.dirname(path)).delete());
    }
  }

  static Future<void> _quietly(Future<Object?> Function() task) async {
    try {
      await task();
    } on FileSystemException {
      // Best effort: a missing file is already the desired state.
    }
  }
}

class _DiskIndex {
  _DiskIndex(this.directory);
  final Directory directory;
  final Map<String, (int, DateTime)> files = {};
  int total = 0;
}

class _Waiter {
  _Waiter(this.progress);
  final void Function(int received, int total)? progress;
}

class _Download {
  final CancelToken shared = CancelToken();
  final Set<_Waiter> waiters = {};
  final Completer<void> done = Completer<void>();
  bool finished = false;
}
