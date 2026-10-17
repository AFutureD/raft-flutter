import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/attachment_image_repository.dart';
import 'package:raft_flutter/data/workspace_controller.dart';

const _metadata = {
  'id': 'image',
  'filename': 'fixture.png',
  'mimeType': 'image/png',
  'width': 16,
  'height': 16,
};

class _Client extends RaftClient {
  _Client()
    : super(
        origin: 'https://example.invalid',
        sessionStore: MemorySessionStore(),
      );
  final bus = StreamController<RaftEvent>.broadcast(sync: true);
  @override
  Stream<RaftEvent> get events => bus.stream;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async => [];
  @override
  Future<void> dispose() async {
    await bus.close();
    await super.dispose();
  }
}

class _Fixture {
  _Fixture() {
    client.user = RaftRecord({'id': 'alice'});
    client.selectServer('server');
    w = WorkspaceController(client)
      ..server = RaftRecord({'id': 'server', 'role': 'owner'})
      ..channel = RaftChannel({'id': 'channel', 'joined': true});
    w.channels = [w.channel!];
    w.ledger.switchServer('server');
    ingest(_metadata, '1');
    imageKey = AttachmentImageKey.fromMetadata(
      scope: w.attachmentImageScope,
      channelId: 'channel',
      metadata: _metadata,
    );
    addTearDown(() async {
      w.dispose();
      await client.dispose();
    });
  }
  final client = _Client();
  late final WorkspaceController w;
  late final AttachmentImageKey imageKey;
  int loads = 0;
  void ingest(Map<String, dynamic> metadata, String seq) => w.ledger.ingest([
    {
      'id': 'host',
      'channelId': 'channel',
      'seq': seq,
      'content': 'fixture',
      'attachments': [metadata],
    },
  ], expectedGeneration: w.ledger.generation);

  Future<Object> retain() async {
    final lease = w.acquireAttachmentImage(
      imageKey,
      authorized: () => true,
      load: (_) async {
        ++loads;
        return base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGP8V7uCgRTARJLqUQ2jGoaUBgC7qgJDBU0aZAAAAABJRU5ErkJggg==',
        );
      },
    );
    final provider = await lease.lease.ready;
    lease.release();
    expect(w.retainedImageCount, 1);
    return provider;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'page notifications retain the image without rescanning message history',
    () async {
      final f = _Fixture();
      final image = await f.retain();
      final firstBuilds = f.w.debugRetainedAttachmentIndexBuilds;
      for (var i = 0; i < 20; i++) {
        f.w.section = i.isEven ? 'settings' : 'chat';
        f.w.notifyListeners();
        final ready = f.w.peekAttachmentImage(
          f.imageKey,
          authorized: () => true,
        );
        expect(ready, isNotNull);
        expect(ready!.lease.value, same(image));
        ready.release();
      }
      expect(f.loads, 1);
      expect(f.w.debugRetainedAttachmentIndexBuilds, firstBuilds);
    },
  );

  test(
    'plain arrivals keep the retained image without a complete history scan',
    () async {
      final f = _Fixture();
      final image = await f.retain();
      final builds = f.w.debugRetainedAttachmentIndexBuilds;
      for (var i = 0; i < 20; i++) {
        f.w.ledger.ingest([
          {
            'id': 'plain-$i',
            'channelId': 'channel',
            'seq': '${i + 2}',
            'content': 'An ordinary message without attachments.',
          },
        ], expectedGeneration: f.w.ledger.generation);
        f.w.notifyListeners();
        final lease = f.w.peekAttachmentImage(
          f.imageKey,
          authorized: () => true,
        );
        expect(lease, isNotNull);
        expect(lease!.lease.value, same(image));
        lease.release();
      }
      expect(f.loads, 1);
      expect(
        f.w.debugRetainedAttachmentIndexBuilds,
        builds,
        reason: 'no attachment or admission changed in these arrivals',
      );
    },
  );

  test(
    'replacing channel records with the same admission retains the index',
    () async {
      final f = _Fixture();
      await f.retain();
      final firstBuilds = f.w.debugRetainedAttachmentIndexBuilds;
      f.w.channels = [
        RaftChannel({'id': 'channel', 'name': 'renamed', 'joined': true}),
      ];
      f.w.notifyListeners();
      expect(f.w.retainedImageCount, 1);
      expect(f.w.debugRetainedAttachmentIndexBuilds, firstBuilds);
    },
  );

  test(
    'same-length in-place channel replacement drops the retired image',
    () async {
      final f = _Fixture();
      await f.retain();
      f.w.channels[0] = RaftChannel({'id': 'other', 'joined': true});
      f.w.notifyListeners();
      expect(f.w.retainedImageCount, 0);
      expect(
        f.w.peekAttachmentImage(f.imageKey, authorized: () => true),
        isNull,
      );
    },
  );

  test(
    'accepted same-ID metadata replacement drops the previous rendition',
    () async {
      final f = _Fixture();
      await f.retain();
      f.ingest({..._metadata, 'contentVersion': 'next'}, '2');
      f.w.notifyListeners();
      expect(f.w.retainedImageCount, 0);
      expect(
        f.w.peekAttachmentImage(f.imageKey, authorized: () => true),
        isNull,
      );
    },
  );

  test(
    'ledger updates recheck admission before another notification',
    () async {
      final f = _Fixture();
      await f.retain();
      f.w.channels[0] = RaftChannel({'id': 'other', 'joined': true});
      f.ingest({..._metadata, 'width': 32}, '2');
      // A ledger read can precede its owner's next notification. Its revision
      // must refresh admission as well as the cached attachment metadata.
      expect(
        f.w.peekAttachmentImage(f.imageKey, authorized: () => true),
        isNull,
      );
      expect(f.w.retainedImageCount, 0);
    },
  );

  test(
    'a real channel removal event clears the retained image immediately',
    () async {
      final f = _Fixture();
      await f.retain();
      f.client.bus.add(
        const RaftEvent('channel:removed', {'channelId': 'channel'}),
      );
      expect(f.w.retainedImageCount, 0);
      expect(
        f.w.peekAttachmentImage(f.imageKey, authorized: () => true),
        isNull,
      );
    },
  );

  test(
    'role and principal changes cannot retain a previous scope image',
    () async {
      for (final changeRole in [true, false]) {
        final f = _Fixture();
        await f.retain();
        if (changeRole) {
          f.w.server = RaftRecord({'id': 'server', 'role': 'guest'});
        } else {
          f.client.user = RaftRecord({'id': 'bob'});
        }
        f.w.notifyListeners();
        expect(f.w.retainedImageCount, 0);
        expect(
          f.w.peekAttachmentImage(f.imageKey, authorized: () => true),
          isNull,
        );
      }
    },
  );
}
