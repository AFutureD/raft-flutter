import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:raft_client/raft_client.dart';

import '../data/attachment_disk_cache.dart';
import 'cache_staging.dart';
import 'session_store.dart';

/// Deletes the cached attachments of accounts that have no saved session: what
/// a sign-out or a removed session left behind while the app was not running.
///
/// [savedSessions] must list every saved session. When it throws, or a session
/// does not say which user it belongs to (so its folder cannot be named), this
/// deletes nothing: an incomplete list must never cost an account its cache.
/// Returns the number of account folders removed.
Future<int> removeOrphanAttachmentAccounts(
  AttachmentDiskCache cache,
  Future<Map<String, Session>> Function() savedSessions,
) async {
  final Map<String, Session> sessions;
  try {
    sessions = await savedSessions();
  } catch (_) {
    return 0;
  }
  final keep = <(String, String)>[];
  for (final MapEntry(:key, :value) in sessions.entries) {
    final principal = value.cachedUser?['id'];
    if (principal is! String || principal.isEmpty) return 0;
    // The client strips a trailing slash from its origin before it reads or
    // writes a session and before it names a cache folder.
    keep.add((key.replaceFirst(RegExp(r'/$'), ''), principal));
  }
  return cache.removeOrphanAccounts(keep);
}

/// The one-time housekeeping at app start; no timers, every step best effort:
/// leftover staging older than an hour, orphan account folders. (The cache's
/// own start-up scan removes entries unopened for 30 days.)
Future<void> runStartupCacheHygiene({
  required AttachmentDiskCache cache,
  Future<Map<String, Session>> Function()? savedSessions,
}) async {
  try {
    await sweepStaging(
      staging: await cacheStagingDirectory(),
      legacyTemporary: await getTemporaryDirectory(),
    );
  } on Object {
    // Housekeeping never blocks or breaks the app.
  }
  try {
    await removeOrphanAttachmentAccounts(
      cache,
      savedSessions ?? SecureSessionStore().readAll,
    );
  } on Object {
    // Same.
  }
}
