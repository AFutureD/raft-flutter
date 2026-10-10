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
      await t.tap(find.text('#general-b'));
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
}
