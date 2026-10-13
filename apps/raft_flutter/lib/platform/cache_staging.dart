import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where temporary staging copies (preview inputs, share-sheet copies, save
/// and export copies) live.
///
/// Desktop: `<app cache>/staging/`, because the system temporary directory is
/// not the cache there and on Linux `/tmp` is often a RAM disk.
///
/// Android and iOS: the platform temporary directory, which already is the app
/// cache directory (`Context.cacheDir`, `Library/Caches`). The native share
/// and PDF bridges allow-list `raft-share` and `raft-previews` directly under
/// it (FileProvider paths, `ShareInboxWriter.exportFile`,
/// `NativePdfPreviewBridge`), so these two names stay at the top of it.
Future<Directory> cacheStagingDirectory() async {
  if (Platform.isAndroid || Platform.isIOS) return getTemporaryDirectory();
  return Directory(
    p.join((await getApplicationCacheDirectory()).path, 'staging'),
  );
}

/// Leftover staging older than this is deleted at start.
const Duration stagingMaxAge = Duration(hours: 1);

bool _isStagingName(String name) =>
    name == 'raft-previews' ||
    name == 'raft-share' ||
    name.startsWith('raft-attachment-') ||
    name.startsWith('raft-export-') ||
    name.startsWith('raft-gallery-');

/// Deletes staging folders that nobody can still be using: those whose newest
/// change (the folder or a file directly in it) is older than [maxAge]. Run
/// once at start, never on a timer.
///
/// Looks in [staging] and, for what earlier versions left there, in
/// [legacyTemporary] (the system temporary directory). Only the known staging
/// names are touched, never anything else: on Android, iOS and macOS the
/// temporary and cache directories are the same directory, and received
/// shares (`raft-incoming`, user data) live beside them. Returns the number of
/// folders removed.
Future<int> sweepStaging({
  required Directory staging,
  Directory? legacyTemporary,
  Duration maxAge = stagingMaxAge,
  DateTime Function()? clock,
}) async {
  final now = (clock ?? DateTime.now)();
  var removed = 0;
  for (final root in {staging.path, ?legacyTemporary?.path}) {
    try {
      await for (final entity in Directory(root).list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (!_isStagingName(name)) continue;
        if (name == 'raft-previews' || name == 'raft-share') {
          // A shared parent: each lease folder ages on its own.
          await for (final child in entity.list(followLinks: false)) {
            if (child is Directory && await _removeIfOld(child, now, maxAge)) {
              removed++;
            }
          }
        } else if (await _removeIfOld(entity, now, maxAge)) {
          removed++;
        }
      }
    } on FileSystemException {
      // No such directory or unreadable: nothing to sweep.
    }
  }
  return removed;
}

Future<bool> _removeIfOld(
  Directory folder,
  DateTime now,
  Duration maxAge,
) async {
  try {
    var newest = (await folder.stat()).modified;
    await for (final entity in folder.list(followLinks: false)) {
      final modified = (await entity.stat()).modified;
      if (modified.isAfter(newest)) newest = modified;
    }
    if (now.difference(newest) < maxAge) return false;
    await folder.delete(recursive: true);
    return true;
  } on FileSystemException {
    return false;
  }
}
