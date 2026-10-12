import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/incoming_share_picker.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_ui/raft_ui.dart';

import 'app_global_server_selector_test.dart' show RootFixture;

void main() {
  for (final cold in [true, false]) {
    testWidgets(
      'iOS ${cold ? 'cold' : 'warm'} handoff opens the shared picker once without sending',
      (t) async {
        final directory = (await t.runAsync(
          () => Directory.systemTemp.createTemp('raft-ios-root-share-test-'),
        ))!;
        final token = 'a' * 32;
        Future<void> publish() async {
          final folder = await Directory('${directory.path}/$token').create();
          await File('${folder.path}/envelope.json').writeAsString(
            jsonEncode({
              'token': token,
              'created': DateTime.now().millisecondsSinceEpoch,
              'pending': true,
              'text': 'iOS shared text',
              'files': [],
            }),
          );
        }

        final sharing = NativeSharing(
          supported: true,
          ios: true,
          incomingDirectory: () async => directory,
        );
        final f = RootFixture(sharing: sharing);
        final wake = Uri.parse('raft://share/$token');
        if (cold) await t.runAsync(publish);
        await f.mount(t, 'elegant', 390, uri: cold ? wake : null);
        if (!cold) {
          await t.runAsync(publish);
          f.content.receiveLink(wake);
        }
        for (
          var i = 0;
          i < 6 && find.byType(IncomingSharePicker).evaluate().isEmpty;
          i++
        ) {
          await f.flush(t);
        }
        expect(find.byType(IncomingSharePicker), findsOneWidget);
        f.content.receiveLink(wake);
        f.content.receiveLink(wake);
        await f.flush(t);
        expect(find.byType(IncomingSharePicker), findsOneWidget);
        expect(
          f.adapter.calls.where(
            (call) =>
                call.path == '/v2/messages' ||
                call.path.contains('/attachments/upload'),
          ),
          isEmpty,
        );
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() => directory.delete(recursive: true));
      },
    );
  }
  testWidgets(
    'share admitted before restore selects another server and appends editable queued files without upload',
    (t) async {
      final directory = (await t.runAsync(
        () => Directory.systemTemp.createTemp('raft-share-handoff-test-'),
      ))!;
      final sharing = NativeSharing(
        supported: false,
        incomingDirectory: () async => directory,
        readContent: (_) => Stream.value(Uint8List.fromList([1, 2, 3])),
      );
      sharing.receive(
        const IncomingShare(
          text: 'Shared caption',
          files: [
            IncomingSharedFile(
              'content://fixture/photo',
              'photo.jpg',
              'image/jpeg',
              3,
            ),
          ],
        ),
      );
      final f = RootFixture(sharing: sharing);
      f.overrides['GET /channels/cb'] = (_) => {
        'id': 'cb',
        'name': 'general-b',
        'type': 'channel',
        'joined': true,
        'serverId': 'b',
      };
      await f.mount(t, 'elegant', 412);
      for (
        var i = 0;
        i < 4 && find.byType(IncomingSharePicker).evaluate().isEmpty;
        i++
      ) {
        await f.flush(t);
      }
      expect(find.byType(IncomingSharePicker), findsOneWidget);
      await t.tap(find.text('Beta').last);
      await f.flush(t);
      await t.tap(find.byKey(const ValueKey('incoming-target-cb')));
      await t.pump();
      await t.tap(find.byKey(const Key('incoming-share-continue')));
      for (
        var i = 0;
        i < 8 && find.byType(IncomingSharePicker).evaluate().isNotEmpty;
        i++
      ) {
        await f.flush(t);
      }
      expect(find.byType(IncomingSharePicker), findsNothing);
      final w = t.widget<WorkspaceView>(find.byType(WorkspaceView)).controller;
      expect(w.server?.id, 'b');
      expect(w.channel?.id, 'cb');
      expect(w.drafts['cb'], 'Shared caption');
      expect(w.uploads().single.queued, true);
      expect(w.uploads().single.bytes, isEmpty);
      expect(w.uploadsReady(), true);
      expect(find.text('photo.jpg'), findsOneWidget);
      final composer = find
          .descendant(
            of: find.byType(RaftComposer),
            matching: find.byType(TextField),
          )
          .first;
      expect(t.widget<TextField>(composer).controller!.text, 'Shared caption');
      await t.enterText(composer, 'Edited caption');
      await f.flush(t);
      expect(w.drafts['cb'], 'Edited caption');
      expect(
        f.adapter.calls.where(
          (c) =>
              c.path.contains('/attachments/upload') ||
              c.path == '/v2/messages' ||
              c.path.contains('/messages/forward'),
        ),
        isEmpty,
      );
      final persisted =
          f.cache.rows.entries
                  .where((e) => e.key.endsWith('|draft|cb'))
                  .single
                  .value
              as Map;
      expect(persisted['files'], hasLength(1));
      expect(persisted.toString(), isNot(contains(directory.path)));
      w.removeUpload(w.uploads().single);
      await f.flush(t);
      expect(w.uploads(), isEmpty);
      List<FileSystemEntity> remaining = [];
      for (var i = 0; i < 20; i++) {
        await f.flush(t);
        remaining = (await t.runAsync(() => directory.list().toList()))!;
        if (remaining.isEmpty) break;
      }
      expect(remaining, isEmpty);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => directory.delete(recursive: true));
    },
  );

  // Continue before the copy ended: the checks and the destination read run at
  // once, the hand-off completes when the copy does, and Cancel leaves nothing.
  for (final cancel in [false, true]) {
    testWidgets(
      cancel
          ? 'Continue then Cancel while the copy is slow: nothing is staged and the files are removed'
          : 'Continue while the copy is slow: no request is awaited and the hand-off finishes with the copy',
      (t) async {
        final directory = (await t.runAsync(
          () => Directory.systemTemp.createTemp('raft-share-slow-test-'),
        ))!;
        final gate = Completer<void>();
        final sharing = NativeSharing(
          supported: false,
          incomingDirectory: () async => directory,
          readContent: (_) => Stream.fromFuture(
            gate.future.then((_) => Uint8List.fromList([1, 2, 3])),
          ),
        );
        sharing.receive(
          const IncomingShare(
            files: [
              IncomingSharedFile(
                'content://fixture/photo',
                'photo.jpg',
                'image/jpeg',
                3,
              ),
            ],
          ),
        );
        final f = RootFixture(sharing: sharing);
        f.overrides['GET /channels/cb'] = (_) => {
          'id': 'cb',
          'name': 'general-b',
          'type': 'channel',
          'joined': true,
          'serverId': 'b',
        };
        await f.mount(t, 'elegant', 412);
        for (
          var i = 0;
          i < 4 && find.byType(IncomingSharePicker).evaluate().isEmpty;
          i++
        ) {
          await f.flush(t);
        }
        await t.tap(find.text('Beta').last);
        await f.flush(t);
        await t.tap(find.byKey(const ValueKey('incoming-target-cb')));
        await t.pump();
        final before = f.adapter.calls.length;
        await t.tap(find.byKey(const Key('incoming-share-continue')));
        for (var i = 0; i < 4; i++) {
          await f.flush(t);
        }
        // The copy is the only thing Continue waits for: no request is made
        // (or awaited) for the hand-off, and the page says what it waits for.
        final reads = f.adapter.calls.skip(before).map((c) => c.path).toList();
        expect(reads, isNot(contains('/channels/cb')));
        expect(reads, isNot(contains('/servers')));
        expect(find.byType(IncomingSharePicker), findsOneWidget);
        expect(find.text('Preparing files'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        // Nothing is applied before the copy ends: no server was selected.
        expect(find.byType(WorkspaceView, skipOffstage: false), findsNothing);
        if (cancel) {
          await t.tap(find.text('Cancel'));
          for (var i = 0; i < 6; i++) {
            await f.flush(t);
          }
          gate.complete();
          for (var i = 0; i < 6; i++) {
            await f.flush(t);
          }
          expect(find.byType(IncomingSharePicker), findsNothing);
          // Cancelled before the copy ended: the workspace never switched.
          expect(find.byType(WorkspaceView, skipOffstage: false), findsNothing);
          List<FileSystemEntity> remaining = [];
          for (var i = 0; i < 20; i++) {
            await f.flush(t);
            remaining = (await t.runAsync(() => directory.list().toList()))!;
            if (remaining.isEmpty) break;
          }
          expect(remaining, isEmpty);
        } else {
          gate.complete();
          for (
            var i = 0;
            i < 10 && find.byType(IncomingSharePicker).evaluate().isNotEmpty;
            i++
          ) {
            await f.flush(t);
          }
          expect(find.byType(IncomingSharePicker), findsNothing);
          final w = t
              .widget<WorkspaceView>(find.byType(WorkspaceView))
              .controller;
          expect(w.channel?.id, 'cb');
          expect(w.uploads().single.queued, true);
          expect(find.text('photo.jpg'), findsOneWidget);
        }
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() => directory.delete(recursive: true));
      },
    );
  }
}
