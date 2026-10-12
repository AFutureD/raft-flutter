import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/inline_media_files.dart';
import 'package:raft_flutter/platform/native_sharing.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('inline-media-files'));
  tearDown(() async {
    // Lease disposal is asynchronous; let it finish before the folder goes.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  SharedFileLease lease(String name, {int size = 10}) {
    final folder = Directory('${dir.path}/$name')..createSync();
    final file = File('${folder.path}/clip.bin')
      ..writeAsBytesSync(List.filled(size, 1));
    return SharedFileLease(file, lifetime: const Duration(hours: 1));
  }

  test('a clip scrolled out and back is downloaded once', () async {
    final cache = InlineMediaFiles();
    var downloads = 0;
    Future<SharedFileLease?> load(CancelToken c, bool Function() ok) async {
      downloads++;
      return lease('a');
    }

    final first = await cache.acquire('a', scope: 's', load: load);
    expect(first, isNotNull);
    first!.release(); // the card scrolls away
    final again = await cache.acquire('a', scope: 's', load: load);
    expect(again, isNotNull);
    expect(downloads, 1);
    expect(again!.file.existsSync(), isTrue);
    again.release();
    cache.dispose();
  });

  test('cards wanting the same clip at once share one download', () async {
    final cache = InlineMediaFiles();
    var downloads = 0;
    final gate = Completer<void>();
    Future<SharedFileLease?> load(CancelToken c, bool Function() ok) async {
      downloads++;
      await gate.future;
      return lease('a');
    }

    final both = Future.wait([
      cache.acquire('a', scope: 's', load: load),
      cache.acquire('a', scope: 's', load: load),
    ]);
    gate.complete();
    final holds = await both;
    expect(downloads, 1);
    holds[0]!.release();
    expect(holds[1]!.file.existsSync(), isTrue, reason: 'still held by the other');
    holds[1]!.release();
    cache.dispose();
  });

  test('a clip scrolled past while downloading is cancelled and not kept', () async {
    final cache = InlineMediaFiles();
    late CancelToken seen;
    var stillWanted = true;
    final gate = Completer<void>();
    final pending = cache.acquire(
      'a',
      scope: 's',
      load: (c, ok) async {
        seen = c;
        await gate.future;
        stillWanted = ok();
        return stillWanted ? lease('a') : null;
      },
    );
    await Future<void>.delayed(Duration.zero);
    // The card is disposed: its hold is not available yet, but the entry's
    // only claim goes away through the failed acquire.
    // Simulate by releasing via a second acquire that is dropped right away.
    cache.clear();
    gate.complete();
    expect(await pending, isNull);
    expect(seen.isCancelled, isTrue);
    expect(stillWanted, isFalse);
    expect(cache.length, 0);
  });

  test('the cache is bounded; least recently released goes first', () async {
    final cache = InlineMediaFiles(maxEntries: 2);
    Future<InlineMediaHold> take(String key) async => (await cache.acquire(
      key,
      scope: 's',
      load: (c, ok) async => lease(key),
    ))!;
    final a = await take('a'), b = await take('b'), c = await take('c');
    a.release();
    b.release();
    c.release();
    expect(cache.length, 2);
    final again = await cache.acquire(
      'a',
      scope: 's',
      load: (c, ok) async => lease('a2'),
    );
    expect(cache.downloads, 4, reason: 'a was evicted, b and c were not');
    again!.release();
    cache.dispose();
  });

  test('identity scope change and channel revocation drop the copies', () async {
    final cache = InlineMediaFiles();
    final a = await cache.acquire(
      'a',
      scope: 'alice',
      channelId: 'c1',
      load: (c, ok) async => lease('a'),
    );
    final file = a!.file;
    a.release();
    expect(file.existsSync(), isTrue);
    cache.invalidateChannel('c1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(file.existsSync(), isFalse);
    final b = await cache.acquire(
      'b',
      scope: 'alice',
      load: (c, ok) async => lease('b'),
    );
    final bFile = b!.file;
    b.release();
    cache.synchronize('bob');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(bFile.existsSync(), isFalse);
    expect(cache.length, 0);
  });

  test('a copy deleted behind the cache is downloaded again', () async {
    final cache = InlineMediaFiles();
    var downloads = 0;
    Future<SharedFileLease?> load(CancelToken c, bool Function() ok) async {
      downloads++;
      return lease('a$downloads');
    }

    final a = await cache.acquire('a', scope: 's', load: load);
    a!.file.parent.deleteSync(recursive: true);
    a.release();
    final b = await cache.acquire('a', scope: 's', load: load);
    expect(downloads, 2);
    b!.release();
    cache.dispose();
  });
}
