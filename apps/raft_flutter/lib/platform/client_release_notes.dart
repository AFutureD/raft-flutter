import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/search_memory.dart';
import 'app_update.dart' show AppRelease, AppUpdateFetcher;

/// The client's own release notes: `release-notes.json`, an asset the release
/// CI attaches to every release (tool/release_notes.py). It has the shape of
/// one page of the Web `GET /release-notes` response (`{"items": [...],
/// "nextCursor": null}`), so the Settings > Release Notes view keeps its Web
/// parser and layout. The notes come from GitHub, not from the Raft server.
class ClientReleaseNotes {
  ClientReleaseNotes({
    required this.fetch,
    SearchMemoryStorage? storage,
    DateTime Function()? clock,
    this.maxAge = const Duration(hours: 6),
  }) : storage = storage ?? PreferencesSearchMemoryStorage(),
       _clock = clock ?? DateTime.now;

  static const url =
      '${AppRelease.repository}/releases/latest/download/release-notes.json';
  static const storageKey = 'raft:release-notes:v1';

  final AppUpdateFetcher fetch;
  final SearchMemoryStorage storage;
  final DateTime Function() _clock;
  final Duration maxAge;
  Future<List<RaftReleaseNote>>? _inflight;

  /// The notes: the stored copy while it is younger than [maxAge], otherwise
  /// a fresh download. Offline (or an unusable download) falls back to the
  /// last stored copy; with no copy the error is rethrown. A release without
  /// the asset yields an empty list.
  Future<List<RaftReleaseNote>> load({bool force = false}) =>
      _inflight ??= _load(force).whenComplete(() => _inflight = null);

  Future<List<RaftReleaseNote>> _load(bool force) async {
    String? body;
    DateTime? fetchedAt;
    try {
      final raw = await storage.read(storageKey);
      final stored = raw == null ? null : jsonDecode(raw);
      if (stored is Map && stored['body'] is String) {
        body = stored['body'] as String;
        final at = stored['fetchedAt'];
        if (at is int) fetchedAt = DateTime.fromMillisecondsSinceEpoch(at);
      }
    } catch (_) {
      // An unreadable copy is no copy.
    }
    List<RaftReleaseNote>? stored;
    if (body != null) {
      try {
        stored = parseClientReleaseNotes(body);
      } on FormatException {
        stored = null;
      }
    }
    final now = _clock();
    final fresh =
        fetchedAt != null &&
        !now.isBefore(fetchedAt) &&
        now.difference(fetchedAt) < maxAge;
    if (stored != null && fresh && !force) return stored;
    try {
      final downloaded = await fetch(Uri.parse(url));
      if (downloaded == null) return stored ?? const [];
      final parsed = parseClientReleaseNotes(downloaded);
      try {
        await storage.write(
          storageKey,
          jsonEncode({
            'fetchedAt': now.millisecondsSinceEpoch,
            'body': downloaded,
          }),
        );
      } catch (_) {
        // The notes are still shown this time.
      }
      return parsed;
    } catch (_) {
      if (stored != null) return stored;
      rethrow;
    }
  }
}

const _kinds = {
  'feature': RaftReleaseNoteKind.feature,
  'improvement': RaftReleaseNoteKind.improvement,
  'fix': RaftReleaseNoteKind.fix,
  'breaking': RaftReleaseNoteKind.breaking,
  'deprecated': RaftReleaseNoteKind.deprecated,
};

/// Web `parseRelease` / `parseReleaseNotesPage` for one page: a malformed
/// document fails as a whole (the Web view shows its unavailable banner
/// rather than a partial list). The first published release is Current.
@visibleForTesting
List<RaftReleaseNote> parseClientReleaseNotes(String body) {
  final Object? raw;
  try {
    raw = jsonDecode(body);
  } on FormatException {
    throw const FormatException('release notes');
  }
  if (raw is! Map || raw['items'] is! List) {
    throw const FormatException('release notes page');
  }
  final rows = [for (final item in raw['items'] as List) _parseRelease(item)];
  final current = rows.where((r) => r.published).firstOrNull?.id;
  return [
    for (final r in rows)
      r.id == current
          ? RaftReleaseNote(
              id: r.note.id,
              date: r.note.date,
              version: r.note.version,
              current: true,
              retracted: r.note.retracted,
              entries: r.note.entries,
            )
          : r.note,
  ];
}

({String id, RaftReleaseNote note, bool published}) _parseRelease(Object? raw) {
  if (raw is! Map) throw const FormatException('release');
  final id = raw['releaseId'], date = raw['date'], state = raw['state'];
  final version = raw['version'], entries = raw['entries'];
  if (id is! String ||
      id.isEmpty ||
      date is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
      (state != 'published' && state != 'retracted') ||
      (version != null && version is! String) ||
      entries is! List) {
    throw const FormatException('release');
  }
  final parsed = [
    for (final e in entries)
      if (e is Map &&
          _kinds[e['type']] != null &&
          e['text'] is String &&
          e['emphasis'] is bool)
        RaftReleaseNoteEntry(
          _kinds[e['type']]!,
          e['text'] as String,
          emphasis: e['emphasis'] as bool,
        )
      else
        throw const FormatException('release entry'),
  ];
  return (
    id: id,
    published: state == 'published',
    note: RaftReleaseNote(
      id: id,
      date: date,
      version: version as String?,
      retracted: state == 'retracted',
      entries: parsed,
    ),
  );
}
