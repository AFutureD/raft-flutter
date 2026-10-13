import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart'
    show ImageInfo, OneFrameImageStreamCompleter;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/system_proxy.dart';
import 'package:raft_flutter/data/attachment_disk_cache.dart';
import 'package:raft_flutter/data/avatar_image_store.dart';
import 'package:raft_flutter/platform/memory_release.dart';
import 'package:raft_ui/raft_ui.dart';

Uint8List _bytes(int n, [int fill = 1]) =>
    Uint8List.fromList(List.filled(n, fill));

void main() {
  late Directory root;
  var clock = DateTime(2026, 10, 14);

  setUp(() async {
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('raft-avatars-test');
    clock = DateTime(2026, 10, 14);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  AttachmentDiskCache cacheOf({int maxBytes = 1 << 30}) =>
      AttachmentDiskCache(() async => root, maxBytes: maxBytes);
  AvatarImageStore store(AttachmentDiskCache cache) =>
      AvatarImageStore(cache, now: () => clock);

  group('AvatarImageStore in the public namespace of the shared cache', () {
    test('round-trips bytes by stable key, also in a new instance', () async {
      await store(cacheOf()).write(
        'https://x.test/a.webp',
        _bytes(20, 9),
        maxAge: const Duration(days: 365),
      );
      expect(
        await store(cacheOf()).read('https://x.test/a.webp'),
        _bytes(20, 9),
      );
      expect(await store(cacheOf()).read('https://x.test/other.webp'), isNull);
    });

    test(
      'is counted in the size Settings shows and removed by Clear',
      () async {
        final cache = cacheOf();
        final s = store(cache);
        expect(await cache.sizeBytes(), 0);
        await s.write('k1', _bytes(100), maxAge: const Duration(days: 1));
        await s.write('k2', _bytes(50), maxAge: const Duration(days: 1));
        expect(await cache.sizeBytes(), 100 + 8 + 50 + 8);
        expect(await cache.entryCount(), 2);
        await cache.clear();
        expect(await cache.sizeBytes(), 0);
        expect(await s.read('k1'), isNull);
        expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
      },
    );

    test('an entry is fresh for the granted time, capped at the TTL', () async {
      final s = store(cacheOf());
      await s.write('k', _bytes(5), maxAge: const Duration(days: 365));
      await s.write('short', _bytes(5), maxAge: const Duration(minutes: 5));
      await s.write('silent', _bytes(5));
      clock = clock.add(const Duration(minutes: 6));
      expect(await s.read('short'), isNull, reason: 'max-age=300 ran out');
      expect(await s.read('silent'), isNotNull, reason: 'unknown: one hour');
      clock = clock.add(const Duration(hours: 1));
      expect(await s.read('silent'), isNull);
      clock = clock.add(const Duration(days: 12));
      expect(await s.read('k'), isNotNull);
      clock = clock.add(const Duration(days: 2));
      expect(await s.read('k'), isNull, reason: 'capped at 14 days');
    });

    test('an expired entry is removed from the cache', () async {
      final cache = cacheOf();
      final s = store(cache);
      await s.write('k', _bytes(5), maxAge: const Duration(minutes: 1));
      clock = clock.add(const Duration(minutes: 2));
      expect(await s.read('k'), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await cache.entryCount(), 0);
    });

    test('no-cache / no-store answers are not kept at all', () async {
      final cache = cacheOf();
      await store(cache).write('k', _bytes(5), maxAge: Duration.zero);
      expect(await cache.entryCount(), 0);
    });

    test('sign-out purges the account but leaves the avatars', () async {
      final cache = cacheOf();
      await store(cache).write('k', _bytes(5), maxAge: const Duration(days: 1));
      await cache.purgeAccount('https://x.invalid', 'alice');
      expect(await store(cache).read('k'), isNotNull);
    });

    test('an unusable cache directory is a miss, never an error', () async {
      final cache = AttachmentDiskCache(
        () async => throw const FileSystemException(),
      );
      final s = store(cache);
      expect(await s.read('k'), isNull);
      await s.write('k', _bytes(3), maxAge: const Duration(days: 1));
    });
  });

  group('Clear cache in Settings > Storage', () {
    test(
      'forgets the in-memory avatars: the next load fetches exactly once',
      () async {
        final cache = cacheOf();
        var fetches = 0;
        RaftImageBytes.instance = RaftImageBytes();
        installAvatarImageCache(cache, memoryRelease: RaftMemoryRelease());
        RaftImageBytes.instance.fetcher = (_) async {
          fetches++;
          return RaftFetchedImage(
            _bytes(30),
            maxAge: const Duration(days: 365),
          );
        };
        final url =
            'http://127.0.0.1:1/api/avatars/users/ab.webp?X-Amz-Signature=1';
        await RaftImageBytes.instance.load(url);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // Still cached in every layer: no new request.
        await RaftImageBytes.instance.load(url);
        expect(fetches, 1);
        final hot = RaftHotImages.instance;
        hot.hold(
          'k',
          OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
          10,
        );

        await cache.clear();

        expect(hot.length, 0);
        expect(RaftImageBytes.instance.memoryEntries, 0);
        await RaftImageBytes.instance.load(url);
        await RaftImageBytes.instance.load(url);
        expect(fetches, 2, reason: 'one refetch, then served again');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(await cache.entryCount(), 1);
      },
    );
  });

  group('fetchAvatarImage', () {
    test(
      'follows the shared proxy decision and sends no credentials',
      () async {
        final seen = <String>[];
        final headers = <String>[];
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        proxy.listen((request) {
          seen.add(request.uri.toString());
          headers.addAll(
            request.headers.value('authorization') == null ? [] : ['auth'],
          );
          headers.addAll(
            request.headers.value('cookie') == null ? [] : ['cookie'],
          );
          request.response
            ..persistentConnection = false
            ..headers.set(
              'cache-control',
              'public, max-age=31536000, immutable',
            )
            ..add(_bytes(8))
            ..close();
        });
        final service = SystemProxy()
          ..configure(
            ProxySettings(
              mode: ProxyMode.manual,
              host: '127.0.0.1',
              port: proxy.port,
            ),
          );
        final bytes = await fetchAvatarImage(
          'http://avatars.invalid/api/avatars/users/ab.webp?X-Amz-Signature=s',
          proxy: service,
        );
        expect(bytes.bytes, _bytes(8));
        expect(bytes.maxAge, const Duration(days: 365));
        expect(seen.single, startsWith('http://avatars.invalid/api/avatars/'));
        expect(
          seen.single,
          contains('X-Amz-Signature=s'),
          reason: 'fetched as given',
        );
        expect(headers, isEmpty);
        await proxy.close(force: true);
      },
    );

    test('a non-200 answer is a typed error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) {
        r.response
          ..statusCode = 404
          ..persistentConnection = false
          ..close();
      });
      final service = SystemProxy()
        ..configure(const ProxySettings(mode: ProxyMode.direct));
      await expectLater(
        fetchAvatarImage(
          'http://127.0.0.1:${server.port}/x.webp',
          proxy: service,
        ),
        throwsA(
          isA<RaftImageHttpError>().having((e) => e.statusCode, 'status', 404),
        ),
      );
      await server.close(force: true);
    });
  });

  group('memory trim', () {
    test(
      'pressure keeps a small floor of avatars, a background trim keeps all',
      () async {
        final hot = RaftHotImages.instance;
        for (var i = 0; i < 70; i++) {
          hot.hold(
            'k$i',
            OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
            100,
          );
        }
        RaftImageBytes.instance = RaftImageBytes(
          fetcher: (_) async =>
              RaftFetchedImage(Uint8List(600 * 1024), maxAge: Duration.zero),
        );
        await RaftImageBytes.instance.load('https://x.test/a.webp');
        await RaftImageBytes.instance.load('https://x.test/b.webp');
        final release = RaftMemoryRelease();
        installAvatarImageCache(cacheOf(), memoryRelease: release);
        release.trim(RaftMemoryTrim.backgrounded);
        expect(hot.length, 70);
        expect(RaftImageBytes.instance.memoryEntries, 2);
        release.trim(RaftMemoryTrim.pressure);
        expect(hot.length, 64, reason: 'the 64 most recent stay');
        expect(hot.holds('k69'), isTrue);
        expect(hot.holds('k0'), isFalse);
        expect(RaftImageBytes.instance.memoryEntries, 1);
        expect(RaftImageBytes.instance.memoryBytes, lessThanOrEqualTo(1 << 20));
      },
    );
  });
}
