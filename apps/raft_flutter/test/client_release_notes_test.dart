import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/client_release_notes.dart';
import 'package:raft_ui/raft_ui.dart';

import 'support/memory_storage.dart';

Map<String, Object?> _item(
  String tag, {
  String state = 'published',
  String date = '2026-10-13',
  List<Object?>? entries,
}) => {
  'releaseId': tag,
  'tag': tag,
  'version': '0.1.0',
  'date': date,
  'state': state,
  'entries':
      entries ??
      [
        {'type': 'feature', 'text': 'Thing', 'emphasis': false},
      ],
};

String _page(List<Object?> items) =>
    jsonEncode({'items': items, 'nextCursor': null});

void main() {
  group('parseClientReleaseNotes', () {
    test('reads the Web page shape and marks the first published Current', () {
      final notes = parseClientReleaseNotes(
        _page([
          _item('v0.1.0+6', state: 'retracted'),
          _item('v0.1.0+5'),
          _item('v0.1.0+4'),
        ]),
      );
      expect(notes.map((n) => n.id), ['v0.1.0+6', 'v0.1.0+5', 'v0.1.0+4']);
      expect(notes.map((n) => n.current), [false, true, false]);
      expect(notes.first.retracted, isTrue);
      expect(notes[1].entries.single.kind, RaftReleaseNoteKind.feature);
      expect(notes[1].entries.single.text, 'Thing');
    });

    test('a malformed document fails as a whole', () {
      for (final body in [
        'nope',
        '[]',
        '{"items": 1}',
        _page([_item('v1.0.0'), 'x']),
        _page([_item('v1.0.0', date: 'yesterday')]),
        _page([_item('v1.0.0', state: 'draft')]),
        _page([
          _item(
            'v1.0.0',
            entries: [
              {'type': 'wish', 'text': 'x', 'emphasis': false},
            ],
          ),
        ]),
        _page([
          _item(
            'v1.0.0',
            entries: [
              {'type': 'fix', 'text': 'x'},
            ],
          ),
        ]),
      ]) {
        expect(
          () => parseClientReleaseNotes(body),
          throwsFormatException,
          reason: body,
        );
      }
    });

    test('an empty page is an empty list', () {
      expect(parseClientReleaseNotes(_page([])), isEmpty);
    });

    // RAFT_RELEASE_NOTES_JSON=<file written by tool/release_notes.py>
    test('the release tool output parses', () {
      final path = Platform.environment['RAFT_RELEASE_NOTES_JSON'];
      if (path == null) return;
      final notes = parseClientReleaseNotes(File(path).readAsStringSync());
      expect(notes, isNotEmpty);
      expect(notes.first.current, isTrue);
    });
  });

  group('ClientReleaseNotes', () {
    late MemoryStorage storage;
    late DateTime now;
    late List<Uri> requests;
    var body = _page([_item('v0.1.0+5')]);
    Future<String?> Function(Uri) respond = (_) async => body;

    ClientReleaseNotes make() => ClientReleaseNotes(
      storage: storage,
      clock: () => now,
      fetch: (url) {
        requests.add(url);
        return respond(url);
      },
    );

    setUp(() {
      storage = MemoryStorage();
      now = DateTime(2026, 10, 13, 9);
      requests = [];
      body = _page([_item('v0.1.0+5')]);
      respond = (_) async => body;
    });

    test('downloads the latest release asset and keeps a copy', () async {
      final notes = await make().load();
      expect(notes.single.id, 'v0.1.0+5');
      expect(
        requests.single.toString(),
        'https://github.com/kevinzhow/raft-flutter/releases/latest/download/'
        'release-notes.json',
      );
      expect(storage.values, contains(ClientReleaseNotes.storageKey));
    });

    test('a recent copy is served without a request', () async {
      await make().load();
      now = now.add(const Duration(hours: 5));
      expect((await make().load()).single.id, 'v0.1.0+5');
      expect(requests, hasLength(1));
      now = now.add(const Duration(hours: 2));
      body = _page([_item('v0.1.0+6'), _item('v0.1.0+5')]);
      expect(await make().load(), hasLength(2));
      expect(requests, hasLength(2));
    });

    test('offline falls back to the last copy, else rethrows', () async {
      respond = (_) async => throw StateError('offline');
      await expectLater(make().load(), throwsStateError);
      respond = (_) async => body;
      await make().load();
      now = now.add(const Duration(days: 2));
      respond = (_) async => throw StateError('offline');
      expect((await make().load()).single.id, 'v0.1.0+5');
    });

    test('an unusable download keeps the last copy', () async {
      await make().load();
      now = now.add(const Duration(days: 2));
      respond = (_) async => '<html>captive portal</html>';
      expect((await make().load()).single.id, 'v0.1.0+5');
    });

    test('a release without the asset is an empty list', () async {
      respond = (_) async => null;
      expect(await make().load(), isEmpty);
    });

    test('concurrent loads share one request', () async {
      final service = make();
      await Future.wait([service.load(), service.load()]);
      expect(requests, hasLength(1));
    });
  });
}
