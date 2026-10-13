import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/attachment_image_repository.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/attachment_preview_dialog.dart';
import 'package:raft_flutter/platform/attachment_preview_files.dart';
import 'package:raft_ui/raft_ui.dart';

import 'fixtures/preview_samples.dart';

/// A storage host that counts every request per path.
class _Storage {
  _Storage._(this.server);
  final HttpServer server;
  final hits = <String, int>{};
  Uint8List body = previewPdf();
  Duration delay = Duration.zero;
  int status = 200;

  static Future<_Storage> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final storage = _Storage._(server);
    server.listen((request) async {
      storage.hits[request.uri.path] =
          (storage.hits[request.uri.path] ?? 0) + 1;
      await Future<void>.delayed(storage.delay);
      request.response.statusCode = storage.status;
      request.response.add(storage.body);
      await request.response.close();
    });
    return storage;
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  int get total => hits.values.fold(0, (a, b) => a + b);
  Future<void> close() => server.close(force: true);
}

class _Client extends RaftClient {
  _Client(this.storage)
    : super(
        origin: 'https://example.invalid',
        sessionStore: MemorySessionStore(),
      );
  final _Storage storage;
  final paths = <String>[];
  int urlRequests = 0;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    paths.add(path);
    if (path.endsWith('/url')) {
      urlRequests++;
      // A new signature every time, like the real server.
      return {'url': storage.url('/blob/doc.pdf?sig=$urlRequests')};
    }
    return {
      'status': 'ok',
      'data': {'kind': 'text', 'text': 'private document'},
    };
  }
}

AttachmentImageStoreKey _key(String id) => AttachmentImageStoreKey(
  identity: AttachmentImageKey.identityOf('https://x.invalid', 'u', 's'),
  channelId: 'c1',
  entry: '["$id","rev","file"]',
);

void main() {
  late Directory root;
  late _Storage storage;
  late AttachmentDiskCache cache;
  setUpAll(() => HttpOverrides.global = null);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('raft-preview-cache');
    storage = await _Storage.start();
    cache = AttachmentDiskCache(() async => root);
  });
  tearDown(() async {
    await storage.close();
    await root.delete(recursive: true);
  });

  group('AttachmentPreviewFiles.loadCached', () {
    test('the second open, also after a restart, makes no request', () async {
      final files = AttachmentPreviewFiles();
      var signed = 0;
      Future<String> sign() async {
        signed++;
        return storage.url('/blob/a.pdf?sig=$signed');
      }

      final first = await files.loadCached(
        cache: cache,
        key: _key('a'),
        resolveUrl: sign,
        filename: 'a.pdf',
        expectedBytes: storage.body.length,
        cancel: CancelToken(),
        authorized: () => true,
      );
      expect(first, isNotNull);
      expect(await first!.file.readAsBytes(), storage.body);
      await first.dispose();
      expect((signed, storage.total), (1, 1));

      final second = await files.loadCached(
        cache: cache,
        key: _key('a'),
        resolveUrl: sign,
        filename: 'a.pdf',
        expectedBytes: storage.body.length,
        cancel: CancelToken(),
        authorized: () => true,
      );
      expect(await second!.file.readAsBytes(), storage.body);
      await second.dispose();
      expect(
        (signed, storage.total),
        (1, 1),
        reason: 'no URL signing and no storage request on a hit',
      );
      // Disposing the lease never deletes the cached file.
      expect(second.file.existsSync(), isTrue);

      final restarted = AttachmentDiskCache(() async => root);
      final third = await files.loadCached(
        cache: restarted,
        key: _key('a'),
        resolveUrl: sign,
        filename: 'a.pdf',
        expectedBytes: storage.body.length,
        cancel: CancelToken(),
        authorized: () => true,
      );
      expect(third, isNotNull);
      await third!.dispose();
      expect((signed, storage.total), (1, 1));
    });

    test('two simultaneous opens of one attachment download once', () async {
      storage.delay = const Duration(milliseconds: 80);
      final files = AttachmentPreviewFiles();
      var signed = 0;
      Future<String> sign() async {
        signed++;
        return storage.url('/blob/a.pdf');
      }

      final leases = await Future.wait([
        for (var i = 0; i < 3; i++)
          files.loadCached(
            cache: cache,
            key: _key('a'),
            resolveUrl: sign,
            filename: 'a.pdf',
            cancel: CancelToken(),
            authorized: () => true,
          ),
      ]);
      expect(leases.every((l) => l != null), isTrue);
      expect((signed, storage.total), (1, 1));
      for (final l in leases) {
        await l!.dispose();
      }
    });

    test('a failed download leaves nothing and the retry fetches', () async {
      final files = AttachmentPreviewFiles();
      storage.status = 500;
      await expectLater(
        files.loadCached(
          cache: cache,
          key: _key('a'),
          resolveUrl: () async => storage.url('/blob/a.pdf'),
          filename: 'a.pdf',
          cancel: CancelToken(),
          authorized: () => true,
        ),
        throwsA(isA<DioException>()),
      );
      expect(await cache.sizeBytes(), 0);
      storage.status = 200;
      final ok = await files.loadCached(
        cache: cache,
        key: _key('a'),
        resolveUrl: () async => storage.url('/blob/a.pdf'),
        filename: 'a.pdf',
        cancel: CancelToken(),
        authorized: () => true,
      );
      expect(ok, isNotNull);
      await ok!.dispose();
      expect(await cache.sizeBytes(), storage.body.length);
    });

    test('a revoked caller gets nothing', () async {
      final files = AttachmentPreviewFiles();
      expect(
        await files.loadCached(
          cache: cache,
          key: _key('a'),
          resolveUrl: () async => storage.url('/x'),
          filename: 'a.pdf',
          cancel: CancelToken(),
          authorized: () => false,
        ),
        isNull,
      );
      expect(storage.total, 0);
    });

    test('without a cache it behaves like load', () async {
      final folder = await Directory.systemTemp.createTemp('raft-nocache');
      addTearDown(() => folder.delete(recursive: true));
      final files = AttachmentPreviewFiles(
        temporaryDirectory: () async => folder,
      );
      final lease = await files.loadCached(
        cache: null,
        key: _key('a'),
        resolveUrl: () async => storage.url('/blob/a.pdf'),
        filename: 'a.pdf',
        cancel: CancelToken(),
        authorized: () => true,
      );
      expect(lease!.file.path.startsWith(folder.path), isTrue);
      await lease.dispose();
      expect(lease.file.existsSync(), isFalse);
    });
  });

  group('the preview dialog', () {
    /// Pumps, giving real file I/O turns to finish, until [done].
    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 80 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump();
      }
    }

    testWidgets('a PDF held on the device opens with no request', (
      tester,
    ) async {
      final client = _Client(storage);
      final w = WorkspaceController(client, attachmentImageStore: cache);
      final metadata = {
        'id': 'a',
        'channelId': 'c1',
        'filename': 'a.pdf',
        'mimeType': 'application/pdf',
        'sizeBytes': storage.body.length,
      };
      // An earlier open stored it.
      final stored = await tester.runAsync(
        () => cache.fetchFile(
          w.attachmentCacheKey(metadata, 'file', channelId: 'c1'),
          filename: 'a.pdf',
          expectedBytes: storage.body.length,
          download: (file, cancel, progress) => file.writeAsBytes(storage.body),
        ),
      );
      stored!.release();
      final pages = <String>[];
      for (var open = 1; open <= 2; open++) {
        await tester.pumpWidget(
          MaterialApp(
            home: AttachmentPreviewDialog(
              controller: w,
              metadata: metadata,
              channelId: 'c1',
              authorized: () => true,
              onClose: () {},
              onDownload: () async {},
              pdf: _Pdf(pages),
            ),
          ),
        );
        await settle(tester, () => pages.length == open);
        expect(pages, hasLength(open), reason: 'open $open rendered');
        await tester.pumpWidget(const SizedBox());
      }
      expect(client.urlRequests, 0, reason: 'no signed-URL request');
      expect(storage.total, 0, reason: 'no storage request');
      expect(pages.toSet(), hasLength(1), reason: 'the cached file twice');
      // Closing the dialog released the hold, not the file.
      await settle(tester, () => false);
      expect(File(pages.first).existsSync(), isTrue);
      w.dispose();
      await client.dispose();
    });

    testWidgets('a document preview opens from the cache and is stored', (
      tester,
    ) async {
      final client = _Client(storage);
      final w = WorkspaceController(client, attachmentImageStore: cache);
      const metadata = {'id': 'n', 'channelId': 'c1', 'filename': 'note.txt'};
      Future<void> open() async {
        await tester.pumpWidget(
          MaterialApp(
            home: AttachmentPreviewDialog(
              controller: w,
              metadata: metadata,
              channelId: 'c1',
              authorized: () => true,
              onClose: () {},
              onDownload: () async {},
            ),
          ),
        );
        await settle(
          tester,
          () => find.text('private document').evaluate().isNotEmpty,
        );
        expect(find.text('private document'), findsOneWidget);
      }

      int previews() =>
          client.paths.where((p) => p.endsWith('/preview')).length;
      await open();
      expect(previews(), 1);
      // The store finishes in the background.
      int? stored = 0;
      for (var i = 0; i < 80 && stored == 0; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump();
        stored = await tester.runAsync(cache.entryCount);
      }
      expect(stored, 1);
      await tester.pumpWidget(const SizedBox());
      await open();
      expect(previews(), 1, reason: 'the second open reads the stored copy');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
      w.dispose();
      await client.dispose();
    });
  });
}

/// Records the path of each rendered file.
class _Pdf extends NativePdfRenderer {
  _Pdf(this.pages);
  final List<String> pages;
  @override
  Future<NativePdfPage> render(
    File file,
    int page, {
    required CancelToken cancel,
    required bool Function() authorized,
  }) async {
    pages.add(file.path);
    return NativePdfPage(
      Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      1,
    );
  }
}
