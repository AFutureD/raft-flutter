// The image viewer (Web ImageLightbox): the message's images with arrows,
// keys and swipe; Download in the header on wide layouts, the long-press menu
// (save to the photo library, share) on phones; downloads reuse the cached
// original; neighbours preload one image each side.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/attachment_image_repository.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/attachment_image_viewer.dart';
import 'package:raft_flutter/features/attachment_view.dart';
import 'package:raft_flutter/platform/attachment_files.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_ui/raft_ui.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGP8V7uCgRTARJLqUQ2jGoaUBgC7qgJDBU0aZAAAAABJRU5ErkJggg==',
);

/// A valid PNG whose bytes differ per [tag] (data after IEND is ignored by
/// decoders), so a test can tell which rendition was saved.
Uint8List pngFor(String tag) =>
    Uint8List.fromList([..._png, ...utf8.encode('|$tag')]);

class _Client extends RaftClient {
  _Client()
    : super(
        origin: 'https://example.invalid',
        sessionStore: MemorySessionStore(),
      );
  final inlineSigned = <String>[];
  final attachmentSigned = <String>[];
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final id = path.split('/')[2];
    (query?['disposition'] == 'attachment' ? attachmentSigned : inlineSigned)
        .add(id);
    return {'url': 'https://storage.example.invalid/original/$id'};
  }

  @override
  Future<dynamic> post(String path, {dynamic data}) async => {'urls': []};
}

class _Files extends AttachmentFiles {
  _Files(this.out, {required bool gallery})
    : super(
        gallerySupported: gallery,
        temporaryDirectory: () async => Directory(out.path).parent,
        pickDestination: (name, mime) async => '${out.path}/$name',
        writeToGallery: null,
      );
  final Directory out;
  final reads = <String>[];
  final networkSaves = <String>[];
  final gallerySaves = <({String name, String mime, Uint8List bytes})>[];
  bool failSaves = false;

  @override
  Future<Uint8List> image(
    String url, {
    required CancelToken cancel,
    void Function(int received, int total)? onProgress,
  }) async {
    reads.add(url);
    return pngFor(url.split('/').last);
  }

  @override
  Future<String?> save({
    required String url,
    required String filename,
    required String mimeType,
    required CancelToken cancel,
    required bool Function() authorized,
    required void Function(int, int) onProgress,
  }) async {
    networkSaves.add(url);
    File('${out.path}/$filename').writeAsBytesSync(pngFor('net'));
    return '${out.path}/$filename';
  }

  @override
  Future<String?> saveBytes({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
    required bool Function() authorized,
  }) async {
    if (failSaves) throw const FileSystemException('disk full /secret/path');
    final destination = '${out.path}/$filename';
    File(destination).writeAsBytesSync(bytes);
    return destination;
  }

  @override
  Future<String?> saveToGallery({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
    required bool Function() authorized,
  }) async {
    if (failSaves) throw const FileSystemException('disk full /secret/path');
    gallerySaves.add((name: filename, mime: mimeType, bytes: bytes));
    return 'gallery://$filename';
  }
}

class _Sharing extends NativeSharing {
  _Sharing(bool supported) : super(supported: supported);
  final shared = <String>[];
  @override
  Future<SharedFileLease?> prepareBytes(
    Uint8List bytes, {
    required String filename,
    required bool Function() authorized,
  }) async {
    shared.add('bytes:$filename:${utf8.decode(bytes.sublist(_png.length))}');
    return null;
  }

  @override
  Future<SharedFileLease?> prepareFile(
    File file, {
    required String filename,
    required bool Function() authorized,
  }) async => null;

  @override
  Future<SharedFileLease?> prepareAttachment({
    required String url,
    required String filename,
    required CancelToken cancel,
    required bool Function() authorized,
    required void Function(int, int) onProgress,
  }) async {
    shared.add('url:$filename');
    return null;
  }
}

class _Rig {
  _Rig(this.client, this.w, this.files, this.sharing, this.root, this.toasts);
  final _Client client;
  final WorkspaceController w;
  final _Files files;
  final _Sharing sharing;
  final Directory root;
  final RaftToastController toasts;
  Directory get out => files.out;
}

List<Map<String, dynamic>> _images(int count, {bool thumbnails = false}) => [
  for (var i = 0; i < count; i++)
    {
      'id': 'img$i',
      'channelId': 'channel',
      'filename': 'photo-$i.png',
      'mimeType': 'image/png',
      'width': 16,
      'height': 16,
      'sizeBytes': 100,
      if (thumbnails)
        'thumbnailUrl': 'https://storage.example.invalid/thumb/img$i',
    },
];

Future<void> _settle(WidgetTester tester, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<_Rig> _mount(
  WidgetTester tester, {
  required Size size,
  int count = 3,
  bool thumbnails = false,
  bool gallery = false,
  bool share = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final root = Directory.systemTemp.createTempSync('raft-image-viewer');
  final out = Directory('${root.path}/out')..createSync();
  final cacheDir = Directory('${root.path}/cache')..createSync();
  final client = _Client()..user = RaftRecord({'id': 'alice'});
  client.selectServer('server');
  final w =
      WorkspaceController(
          client,
          attachmentImageStore: AttachmentDiskCache(() async => cacheDir),
        )
        ..server = RaftRecord({'id': 'server', 'role': 'owner'})
        ..channel = RaftChannel({'id': 'channel', 'joined': true});
  w.channels = [w.channel!];
  w.ledger.switchServer('server');
  final items = _images(count, thumbnails: thumbnails);
  w.ledger.ingest([
    {
      'id': 'm1',
      'channelId': 'channel',
      'seq': '1',
      'content': 'photos',
      'attachments': items,
    },
  ], expectedGeneration: w.ledger.generation);
  w.visibleIds['channel'] = {'m1'};
  final files = _Files(out, gallery: gallery);
  final sharing = _Sharing(share);
  final toasts = RaftToastController();
  addTearDown(() async {
    toasts.clear();
    await tester.pumpWidget(const SizedBox());
    w.dispose();
    await client.dispose();
    toasts.dispose();
    root.deleteSync(recursive: true);
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: raftTheme(RaftFamily.elegant),
      builder: (context, child) =>
          RaftToastHost(controller: toasts, child: child!),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              for (final item in items)
                SizedBox(
                  width: 240,
                  child: AttachmentView(
                    key: ValueKey('attachment-${item['id']}'),
                    controller: w,
                    files: files,
                    metadata: item,
                    messageId: 'm1',
                    galleryItems: items,
                    sharing: sharing,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return _Rig(client, w, files, sharing, root, toasts);
}

/// Ends a test that raised a toast: its 5 s timer must not outlive the tree.
Future<void> _finish(WidgetTester tester, _Rig rig) async {
  rig.toasts.clear();
  // The download flow disposes its progress notifier one second after it ends.
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpWidget(const SizedBox());
}

Future<void> _open(WidgetTester tester, int index) async {
  await tester.tap(find.byTooltip('Preview photo-$index.png'));
  await _settle(tester);
}

AttachmentImageViewerState _viewer(WidgetTester tester) =>
    tester.state(find.byType(AttachmentImageViewer));

String _counter(WidgetTester tester) {
  final counter = find.byType(RaftLightboxCounter);
  if (counter.evaluate().isEmpty) return 'none';
  final c = tester.widget<RaftLightboxCounter>(counter);
  return '${c.index + 1} / ${c.count}';
}

const _wide = Size(1280, 800);
const _phone = Size(390, 844);

void main() {
  group('header actions per layout', () {
    testWidgets('wide: Download only (Web header), no Share, no menu', (
      tester,
    ) async {
      await _mount(tester, size: _wide, gallery: true);
      await _open(tester, 0);
      expect(find.byKey(const ValueKey('attachment-download')), findsOneWidget);
      final viewer = find.byType(RaftAttachmentLightbox);
      expect(
        find.descendant(of: viewer, matching: find.textContaining('Share')),
        findsNothing,
      );
      expect(
        find.descendant(of: viewer, matching: find.byTooltip('Share')),
        findsNothing,
      );
      await tester.longPressAt(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
      );
      await _settle(tester, 4);
      expect(find.byKey(const ValueKey('viewer-menu-save')), findsNothing);
    });

    testWidgets('phone: no Share or Download in the header or on the tile', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _phone, gallery: true);
      // Tile overlay: Share / Download are gone on phones.
      expect(find.byTooltip('Share photo-0.png'), findsNothing);
      expect(find.byTooltip('Download photo-0.png'), findsNothing);
      expect(rig.files.gallerySupported, isTrue);
      await _open(tester, 0);
      expect(find.byKey(const ValueKey('attachment-download')), findsNothing);
      expect(find.byTooltip('Download'), findsNothing);
      expect(find.byTooltip('Share'), findsNothing);
    });

    testWidgets('a compact window on a desktop keeps Download in the header', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: false, share: false);
      await _open(tester, 0);
      expect(find.byKey(const ValueKey('attachment-download')), findsOneWidget);
    });
  });

  group('phone long-press menu', () {
    testWidgets(
      'offers Save and Share; Save writes the original to the gallery',
      (tester) async {
        final rig = await _mount(tester, size: _phone, gallery: true, count: 1);
        await _open(tester, 0);
        await tester.longPressAt(
          tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
        );
        await _settle(tester, 4);
        expect(find.byKey(const ValueKey('viewer-menu-save')), findsOneWidget);
        expect(find.byKey(const ValueKey('viewer-menu-share')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('viewer-menu-save')));
        await _settle(tester);
        expect(rig.files.gallerySaves, hasLength(1));
        final saved = rig.files.gallerySaves.single;
        expect(saved.name, 'photo-0.png');
        expect(saved.mime, 'image/png');
        expect(utf8.decode(saved.bytes.sublist(_png.length)), '|img0');
        expect(rig.toasts.title, isNotNull);
        await _finish(tester, rig);
      },
    );

    testWidgets('Share hands the same original to the system sheet', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _phone, gallery: true, count: 1);
      await _open(tester, 0);
      await tester.longPressAt(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
      );
      await _settle(tester, 4);
      await tester.tap(find.byKey(const ValueKey('viewer-menu-share')));
      await _settle(tester);
      // Not signed again for the attachment: the stored copy is shared.
      expect(rig.client.attachmentSigned, isEmpty);
      expect(rig.sharing.shared, ['bytes:photo-0.png:|img0']);
      expect(rig.files.gallerySaves, isEmpty);
      await _finish(tester, rig);
    });

    testWidgets('a failed save reports the fallback copy, never raw text', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _phone, gallery: true, count: 1);
      await _open(tester, 0);
      rig.files.failSaves = true;
      await tester.longPressAt(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
      );
      await _settle(tester, 4);
      await tester.tap(find.byKey(const ValueKey('viewer-menu-save')));
      await _settle(tester);
      expect(rig.toasts.title, 'The image could not be saved.');
      expect(rig.toasts.title, isNot(contains('secret')));
      await _finish(tester, rig);
    });
  });

  group('download', () {
    testWidgets('saves the cached original under its name, no new request', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _wide, count: 1);
      await _open(tester, 0);
      await tester.tap(find.byKey(const ValueKey('attachment-download')));
      await _settle(tester);
      final file = File('${rig.out.path}/photo-0.png');
      expect(file.existsSync(), isTrue);
      expect(utf8.decode(file.readAsBytesSync().sublist(_png.length)), '|img0');
      // Reused: nothing signed for the attachment disposition, no network save.
      expect(rig.client.attachmentSigned, isEmpty);
      expect(rig.files.networkSaves, isEmpty);
      expect(rig.toasts.title, 'Saved photo-0.png');
      await _finish(tester, rig);
    });

    testWidgets('without a stored copy it signs on demand and downloads', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _wide, count: 1, thumbnails: true);
      await _open(tester, 0);
      // The stored original is gone (evicted): the files, not the index.
      for (final entity in Directory(
        '${rig.root.path}/cache',
      ).listSync(recursive: true).whereType<File>()) {
        entity.deleteSync();
      }
      await tester.tap(find.byKey(const ValueKey('attachment-download')));
      await _settle(tester);
      expect(rig.client.attachmentSigned, ['img0']);
      expect(rig.files.networkSaves, hasLength(1));
      expect(File('${rig.out.path}/photo-0.png').existsSync(), isTrue);
      await _finish(tester, rig);
      await _finish(tester, rig);
    });

    testWidgets('a failed download shows the fallback, not the exception', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _wide, count: 1);
      await _open(tester, 0);
      rig.files.failSaves = true;
      await tester.tap(find.byKey(const ValueKey('attachment-download')));
      await _settle(tester);
      expect(rig.toasts.title, 'Download failed. Try again.');
      await _finish(tester, rig);
    });
  });

  group('multi-image navigation', () {
    testWidgets('counter and thumbnail strip, no arrows, no wrap', (
      tester,
    ) async {
      await _mount(tester, size: _wide);
      await _open(tester, 0);
      expect(_counter(tester), '1 / 3');
      expect(find.byKey(const ValueKey('lightbox-previous')), findsNothing);
      expect(find.byKey(const ValueKey('lightbox-next')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('lightbox-thumbnail-1')));
      await _settle(tester, 3);
      expect(_counter(tester), '2 / 3');
      expect(find.text('photo-1.png'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('lightbox-thumbnail-2')));
      await _settle(tester, 3);
      expect(_counter(tester), '3 / 3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester, 3);
      expect(_counter(tester), '3 / 3', reason: 'no wrap');
      await tester.tap(find.byKey(const ValueKey('lightbox-thumbnail-1')));
      await _settle(tester, 3);
      expect(_counter(tester), '2 / 3');
    });

    testWidgets('opens on the tapped image', (tester) async {
      await _mount(tester, size: _wide);
      await _open(tester, 1);
      expect(_counter(tester), '2 / 3');
    });

    testWidgets('ArrowLeft / ArrowRight switch; zoomed they do not', (
      tester,
    ) async {
      await _mount(tester, size: _wide);
      await _open(tester, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await _settle(tester, 3);
      expect(_counter(tester), '1 / 3', reason: 'no wrap at the first image');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester, 3);
      expect(_counter(tester), '2 / 3');
      // Web: while zoomed the arrows do not navigate.
      final viewer = _viewer(tester);
      viewer.zoomFor(1).value = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
      await tester.pump();
      expect(viewer.zoomed, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester, 3);
      expect(_counter(tester), '2 / 3');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pump();
      expect(viewer.zoomed, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester, 3);
      expect(_counter(tester), '3 / 3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester, 3);
      expect(_counter(tester), '3 / 3', reason: 'no wrap at the last image');
    });

    testWidgets('zoom resets when the image changes', (tester) async {
      await _mount(tester, size: _wide);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      viewer.zoomFor(0).value = Matrix4.identity()..scaleByDouble(3, 3, 1, 1);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lightbox-thumbnail-1')));
      await _settle(tester, 3);
      expect(viewer.zoomed, isFalse);
      expect(viewer.zoomFor(0).value, Matrix4.identity());
      expect(viewer.zoomFor(1).value, Matrix4.identity());
    });

    testWidgets('a single image has no counter or strip', (tester) async {
      await _mount(tester, size: _wide, count: 1);
      await _open(tester, 0);
      expect(find.byType(RaftLightboxCounter), findsNothing);
      expect(find.byKey(const ValueKey('lightbox-thumbnail-0')), findsNothing);
    });
  });

  group('swipe on phones', () {
    testWidgets('a horizontal swipe switches images; first and last stop', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      final stage = tester.getCenter(
        find.byKey(const ValueKey('viewer-stage')),
      );
      // Swipe right at the first image: nowhere to go.
      await tester.dragFrom(stage, const Offset(300, 0));
      await _settle(tester, 6);
      expect(_counter(tester), '1 / 3');
      await tester.dragFrom(stage, const Offset(-300, 0));
      await _settle(tester, 8);
      expect(_counter(tester), '2 / 3');
      await tester.dragFrom(stage, const Offset(-300, 0));
      await _settle(tester, 8);
      expect(_counter(tester), '3 / 3');
      await tester.dragFrom(stage, const Offset(-300, 0));
      await _settle(tester, 8);
      expect(_counter(tester), '3 / 3', reason: 'no wrap');
      await tester.dragFrom(stage, const Offset(300, 0));
      await _settle(tester, 8);
      expect(_counter(tester), '2 / 3');
    });

    testWidgets('zoomed, a horizontal drag pans instead of switching', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 1);
      final viewer = _viewer(tester);
      viewer.zoomFor(1).value = Matrix4.identity()..scaleByDouble(3, 3, 1, 1);
      await tester.pump();
      final stage = tester.getCenter(
        find.byKey(const ValueKey('viewer-stage')),
      );
      await tester.dragFrom(stage, const Offset(-250, 0));
      await _settle(tester, 8);
      expect(_counter(tester), '2 / 3');
      expect(viewer.zoomed, isTrue);
    });

    testWidgets(
      'a two-finger pinch zooms at fit scale without switching images',
      (tester) async {
        await _mount(tester, size: _phone, gallery: true);
        await _open(tester, 0);
        final viewer = _viewer(tester);
        final center = tester.getCenter(
          find.byKey(const ValueKey('viewer-stage')),
        );
        final a = await tester.startGesture(
          center - const Offset(20, 0),
          pointer: 1,
        );
        final b = await tester.startGesture(
          center + const Offset(20, 0),
          pointer: 2,
        );
        await a.moveBy(const Offset(-60, 0));
        await b.moveBy(const Offset(60, 0));
        await tester.pump();
        await a.up();
        await b.up();
        await _settle(tester, 4);
        expect(viewer.zoomed, isTrue);
        expect(_counter(tester), '1 / 3');
      },
    );
  });

  group('preloading', () {
    testWidgets('signs only the shown image and one neighbour per side', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _wide, count: 5, thumbnails: true);
      // Tiles use the server thumbnails: nothing is signed for the list.
      expect(rig.client.inlineSigned, isEmpty);
      await _open(tester, 0);
      await _settle(tester, 12);
      // Image 0 plus its one neighbour, not the other three.
      expect(rig.client.inlineSigned.toSet(), {'img0', 'img1'});
      await tester.tap(find.byKey(const ValueKey('lightbox-thumbnail-1')));
      await _settle(tester, 12);
      expect(rig.client.inlineSigned.toSet(), {'img0', 'img1', 'img2'});
      expect(rig.client.attachmentSigned, isEmpty);
    });
  });
}
