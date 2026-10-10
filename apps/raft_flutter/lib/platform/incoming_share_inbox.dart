import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../data/shared_draft_attachment.dart';
import 'native_sharing.dart';

/// Files live outside Android backups. Only opaque references enter the draft
/// cache; paths and ownership are checked here before opening a file.
class IncomingShareInbox {
  IncomingShareInbox(this.directory, this.readContent, {this.copyContent});
  final Future<int> Function(Uri uri, File destination, int limit)? copyContent;
  final Future<Directory> Function() directory;
  final Stream<List<int>> Function(Uri) readContent;
  Future<void> _writes = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _writes.then((_) => work());
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static const maxItemBytes = 25 * 1024 * 1024;
  static const maxTotalBytes = 100 * 1024 * 1024;
  static final _tokenPattern = RegExp(r'^[a-f0-9]{32}$');
  Future<Directory> _folder(String token) async {
    if (!_tokenPattern.hasMatch(token)) {
      throw const FormatException('Share token');
    }
    final root = await directory();
    await root.create(recursive: true);
    final folder = Directory(p.join(root.path, token));
    if (await FileSystemEntity.type(folder.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Invalid inbox folder');
    }
    return folder;
  }

  Future<Map<String, dynamic>?> _record(String token) async {
    final file = File(p.join((await _folder(token)).path, 'envelope.json'));
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<void> _write(String token, Map<String, dynamic> record) async {
    final folder = await _folder(token);
    final tmp = File(p.join(folder.path, 'envelope.tmp'));
    await tmp.writeAsString(jsonEncode(record), flush: true);
    await tmp.rename(p.join(folder.path, 'envelope.json'));
  }

  Future<IncomingShare> stage(
    IncomingShare share, {
    bool Function()? current,
  }) => _serial(() async {
    if (share.token != null) return share;
    if (share.files.length > 9) throw const FormatException('Too many files');
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final folder = await _folder(token);
    await folder.create();
    final files = <Map<String, dynamic>>[];
    var total = 0;
    try {
      for (final source in share.files) {
        if (current?.call() == false) throw const FormatException('Cancelled');
        if ((source.sizeBytes ?? 0) > maxItemBytes) {
          throw const FormatException('File too large');
        }
        final name = 'item-${files.length}';
        var size = 0;
        if (copyContent != null) {
          size = await copyContent!(
            Uri.parse(source.uri),
            File(p.join(folder.path, name)),
            min(maxItemBytes, maxTotalBytes - total),
          );
          total += size;
          if (size <= 0 ||
              size > maxItemBytes ||
              total > maxTotalBytes ||
              current?.call() == false) {
            throw const FormatException('Invalid or cancelled shared file');
          }
        } else {
          final file = await File(p.join(folder.path, name))
              .open(mode: FileMode.write);
          final reader = StreamIterator(readContent(Uri.parse(source.uri)));
          try {
            while (await reader.moveNext()) {
              if (current?.call() == false) {
                throw const FormatException('Cancelled');
              }
              size += reader.current.length;
              total += reader.current.length;
              if (size > maxItemBytes || total > maxTotalBytes) {
                throw const FormatException('File too large');
              }
              // Await each write: provider chunks cannot accumulate in memory.
              await file.writeFrom(reader.current);
            }
            if (size == 0) throw const FormatException('Empty file');
          } finally {
            await reader.cancel();
            await file.close();
          }
        }
        files.add({
          'file': name,
          'filename': source.filename,
          'mimeType': source.mimeType,
          'sizeBytes': size,
        });
      }
      if (current?.call() == false) throw const FormatException('Cancelled');
      final record = <String, dynamic>{
        'token': token,
        'created': DateTime.now().millisecondsSinceEpoch,
        'pending': true,
        'text': share.text,
        'files': files,
      };
      await _write(token, record);
      return _share(record);
    } catch (_) {
      await folder.delete(recursive: true);
      rethrow;
    }
  });

  IncomingShare _share(Map<String, dynamic> record) => IncomingShare(
    token: record['token'] as String,
    text: record['text'] as String?,
    files: [
      for (final file in (record['files'] as List).cast<Map>())
        IncomingSharedFile(
          file['file'] as String,
          file['filename'] as String,
          file['mimeType'] as String,
          file['sizeBytes'] as int,
        ),
    ],
  );

  Future<List<IncomingShare>> pending() => _serial(() async {
    final root = await directory();
    if (!await root.exists()) return [];
    final records = <Map<String, dynamic>>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !_tokenPattern.hasMatch(p.basename(entry.path))) {
        continue;
      }
      try {
        final record = await _record(p.basename(entry.path));
        if (record == null ||
            record['created'] is! int ||
            record['pending'] == true &&
                DateTime.now().millisecondsSinceEpoch -
                        (record['created'] as int) >
                    const Duration(days: 1).inMilliseconds) {
          await entry.delete(recursive: true);
        } else if (record['pending'] == true) {
          records.add(record);
        }
      } catch (_) {
        await entry.delete(recursive: true);
      }
    }
    records.sort(
      (a, b) => (a['created'] as int).compareTo(b['created'] as int),
    );
    return records.map(_share).toList();
  });

  Future<bool> claim(String token, String origin, String principal) =>
      _serial(() async {
        final record = await _record(token);
        if (record == null ||
            record['principal'] != null &&
                (record['principal'] != principal ||
                    record['origin'] != origin)) {
          return false;
        }
        record.addAll({'origin': origin, 'principal': principal});
        await _write(token, record);
        return true;
      });

  Future<SharedDraftAttachment?> restore(
    Map<String, dynamic> ref,
    String origin,
    String principal,
  ) async {
    final token = ref['token'], name = ref['file'];
    if (token is! String ||
        name is! String ||
        !RegExp(r'^item-[0-8]$').hasMatch(name)) {
      return null;
    }
    try {
      final record = await _record(token);
      if (record == null ||
          record['origin'] != origin ||
          record['principal'] != principal) {
        return null;
      }
      final metadata = (record['files'] as List)
          .cast<Map>()
          .where((f) => f['file'] == name)
          .firstOrNull;
      if (metadata == null) return null;
      final folder = await _folder(token);
      final file = File(p.join(folder.path, name));
      if (!await file.exists() ||
          await file.length() != metadata['sizeBytes']) {
        return null;
      }
      final root = await directory();
      if (!p.isWithin(
        await root.resolveSymbolicLinks(),
        await file.resolveSymbolicLinks(),
      )) {
        return null;
      }
      return SharedDraftAttachment(
        reference: {'token': token, 'file': name},
        filename: metadata['filename'] as String,
        mimeType: metadata['mimeType'] as String,
        sizeBytes: metadata['sizeBytes'] as int,
        previewPath: file.path,
        openRead: () async* {
          if (await restore(ref, origin, principal) == null) {
            throw const FormatException('Shared file unavailable');
          }
          yield* file.openRead();
        },
        release: () => release(token, name),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> bindDestination(String token, String server, String channel) =>
      _serial(() async {
        final record = await _record(token);
        if (record == null) {
          throw const FormatException('Shared content unavailable');
        }
        record.addAll({'server': server, 'channel': channel});
        await _write(token, record);
      });

  Future<void> clearScope(
    String origin,
    String principal,
    String server,
    String? channel,
  ) => _serial(() async {
    final root = await directory();
    if (!await root.exists()) return;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !_tokenPattern.hasMatch(p.basename(entry.path))) {
        continue;
      }
      final record = await _record(p.basename(entry.path));
      if (record?['origin'] == origin &&
          record?['principal'] == principal &&
          record?['server'] == server &&
          (channel == null || record?['channel'] == channel)) {
        await entry.delete(recursive: true);
      }
    }
  });

  Future<void> complete(String token) => _serial(() async {
    final record = await _record(token);
    if (record == null) return;
    record['pending'] = false;
    if ((record['files'] as List).isEmpty) {
      await _discard(token);
    } else {
      await _write(token, record);
    }
  });

  Future<void> release(String token, String name) => _serial(() async {
    final record = await _record(token);
    if (record == null) return;
    final files = (record['files'] as List)
      ..removeWhere((f) => f['file'] == name);
    final file = File(p.join((await _folder(token)).path, name));
    if (await file.exists()) await file.delete();
    if (files.isEmpty) {
      await _discard(token);
    } else {
      await _write(token, record);
    }
  });

  Future<void> discard(String token) => _serial(() => _discard(token));
  Future<void> _discard(String token) async {
    final folder = await _folder(token);
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<void> clearAccount(String origin, String principal) =>
      _serial(() async {
        final root = await directory();
        if (!await root.exists()) return;
        await for (final entry in root.list(followLinks: false)) {
          if (entry is! Directory ||
              !_tokenPattern.hasMatch(p.basename(entry.path))) {
            continue;
          }
          final record = await _record(p.basename(entry.path));
          if (record != null &&
              (record['principal'] == null ||
                  record['principal'] == principal &&
                      record['origin'] == origin)) {
            await entry.delete(recursive: true);
          }
        }
      });
}
