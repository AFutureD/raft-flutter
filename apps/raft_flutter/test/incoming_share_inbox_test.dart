import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/incoming_share_inbox.dart';
import 'package:raft_flutter/platform/native_sharing.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('raft-share-inbox-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  const raw = IncomingShare(
    text: 'caption',
    files: [
      IncomingSharedFile(
        'content://fixture/file',
        'photo.jpg',
        'image/jpeg',
        3,
      ),
    ],
  );
  test(
    'durable admission, account ownership, destination revocation and cleanup',
    () async {
      final inbox = IncomingShareInbox(
        () async => directory,
        (_) => Stream.fromIterable([
          [1],
          [2, 3],
        ]),
      );
      final share = await inbox.stage(raw);
      final recovered = IncomingShareInbox(
        () async => directory,
        (_) => throw StateError('Must use private file'),
      );
      expect((await recovered.pending()).single.token, share.token);
      expect(
        await recovered.claim(share.token!, 'https://example.test', 'alice'),
        true,
      );
      expect(
        await recovered.claim(share.token!, 'https://example.test', 'bob'),
        false,
      );
      final ref = {'token': share.token, 'file': share.files.single.uri};
      expect(
        await recovered.restore(ref, 'https://example.test', 'bob'),
        isNull,
      );
      final file = (await recovered.restore(
        ref,
        'https://example.test',
        'alice',
      ))!;
      expect(await file.openRead().expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
      ]);
      await recovered.bindDestination(share.token!, 's', 'c');
      await recovered.complete(share.token!);
      expect(await recovered.pending(), isEmpty);
      expect(
        await recovered.restore(ref, 'https://example.test', 'alice'),
        isNotNull,
      );
      await recovered.clearScope(
        'https://example.test',
        'alice',
        'other',
        null,
      );
      expect(
        await recovered.restore(ref, 'https://example.test', 'alice'),
        isNotNull,
      );
      await recovered.clearScope('https://example.test', 'alice', 's', 'c');
      expect(
        await recovered.restore(ref, 'https://example.test', 'alice'),
        isNull,
      );
    },
  );
  test('copy backpressure, cancellation and empty/oversized intake remove partial files', () async {
    var allowed = true, reads = 0;
    final inbox = IncomingShareInbox(() async => directory, (_) async* {
      reads++;
      yield [1, 2];
      allowed = false;
      reads++;
      yield [3];
    });
    await expectLater(
      inbox.stage(raw, current: () => allowed),
      throwsFormatException,
    );
    expect(reads, 2);
    expect(await directory.list().toList(), isEmpty);
    await expectLater(
      inbox.stage(
        const IncomingShare(
          files: [
            IncomingSharedFile(
              'content://fixture/file',
              'huge',
              'application/octet-stream',
              IncomingShareInbox.maxItemBytes + 1,
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
    expect(await directory.list().toList(), isEmpty);
    final empty = IncomingShareInbox(
      () async => directory,
      (_) => const Stream.empty(),
    );
    await expectLater(empty.stage(raw), throwsFormatException);
    expect(await directory.list().toList(), isEmpty);
  });
  test('references cannot open a path outside the private inbox', () async {
    final inbox = IncomingShareInbox(
      () async => directory,
      (_) => Stream.value([1, 2, 3]),
    );
    final share = await inbox.stage(raw);
    await inbox.claim(share.token!, 'o', 'p');
    expect(
      await inbox.restore({'token': '../outside', 'file': 'item-0'}, 'o', 'p'),
      isNull,
    );
    expect(
      await inbox.restore(
        {'token': share.token, 'file': '../envelope.json'},
        'o',
        'p',
      ),
      isNull,
    );
    await File('${directory.path}/${share.token}/item-0').delete();
    await Link('${directory.path}/${share.token}/item-0').create('/etc/hosts');
    expect(
      await inbox.restore({'token': share.token, 'file': 'item-0'}, 'o', 'p'),
      isNull,
    );
    await inbox.clearAccount('o', 'p');
    expect(await directory.list().toList(), isEmpty);
  });
}
