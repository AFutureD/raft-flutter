// The image viewer (Web ImageLightbox): the message's images with arrows,
// keys and swipe; Download in the header on wide layouts, the long-press menu
// (save to the photo library, share) on phones; downloads reuse the cached
// original; neighbours preload one image each side.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/attachment_image_repository.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/attachment_image_loader.dart';
import 'package:raft_flutter/features/media_image_page.dart';
import 'package:raft_flutter/features/media_items.dart';
import 'package:raft_flutter/features/media_browser.dart';
import 'package:raft_flutter/features/attachment_image_zoom.dart';
import 'package:raft_flutter/features/attachment_view.dart';
import 'package:raft_flutter/platform/attachment_files.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_ui/raft_ui.dart';

import 'flutter_test_config.dart' show leakDebt;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGP8V7uCgRTARJLqUQ2jGoaUBgC7qgJDBU0aZAAAAABJRU5ErkJggg==',
);

/// A 400x1600 PNG (a phone screenshot's proportions): taller than any phone
/// stage, so it fits by height.
final _tallPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAZAAAAZACAAAAAByTUuxAAAF+ElEQVR42u3cMQEAAAjDMPybBg39OBILvbcZAAAAAAAAAAAAAAAAAAAACJZXBBEEQQRBEEEQRBAEEQRBEEQQBBEEQQRBEEEQBEEEQRBBEEQQBBEEQRBEEAQRBEEEQRBBEARBvgcBAAAAAAAAAAAAAAAAAACAwlTfkwOCCIIggiCIIAgiCIIgiCAIIgiCCIIggiAIggiCIIIgiCAIIgiCIIggCCIIggiCIIIgCIIIQgkCAAAAAAAAAAAAAAAAAAAAham+JwcEEQRBBEEQQRBEEARBEEEQRBAEEQRBBEEQBBEEQQRBEEEQRBAEQRBBEEQQBBEEQQRBEAQRhBIEAAAAAAAAAAAAAAAAAAAAClN9Tw4IIgiCCIIggiCIIAiCIIIgiCAIIgiCCIIgCCIIggiCIIIgiCAIgiCCIIggCCIIggiCIAgiCCUIAAAAAAAAAAAAAAAAAAAAFKb6nhwQRBAEEQRBBEEQQRAEQQRBEEEQRBAEEQRBEEQQBBEEQQRBEEEQBEEEQRBBEEQQBBEEQRBEEEoQAAAAAAAAAAAAAAAAAAAAKEz1PTkgiCAIIgiCCIIggiAIggiCIIIgiCAIIgiCIIggCCIIggiCIIIgCIIIgiCCIIggCCIIgiCIIJQgAAAAAAAAAAAAAAAAAAAAUJjqe3JAEEEQRBAEEQRBBEEQBBEEQQRBEEEQRBAEQRBBEEQQBBEEQQRBEAQRBEEEQRBBEEQQBEEQQShBAAAAAAAAAAAAAAAAAAAAoDDV9+SAIIIgiCAIIgiCCIIgCCIIggiCIIIgiCAIgiCCIIggCCIIggiCIAgiCIIIgiCCIIggCIIgglCCAAAAAAAAAAAAAAAAAAAAQGGq78kBQQRBEEEQRBAEEQRBEEQQBBEEQQRBEEEQBEEEQRBBEEQQBBEEQRBEEAQRBEEEQRBBEARBBKEEAQAAAAAAAAAAAAAAAAAAgMJU35MDggiCIIIgiCAIIgiCIIggCCIIggiCIIIgCIIIgiCCIIggCCIIgiCIIAgiCIIIgiCCIAiCCEIJAgAAAAAAAAAAAAAAAAAAAIWpvicHBBEEQQRBEEEQRBAEQRBBEEQQBBEEQQRBEAQRBEEEQRBBEEQQBEEQQRBEEAQRBEEEQRAEEYQSBAAAAAAAAAAAAAAAAAAAAApTfU8OCCIIggiCIIIgiCAIgiCCIIggCCIIggiCIAgiCIIIgiCCIIggCIIggiCIIAgiCIIIgiAIIgglCAAAAAAAAAAAAAAAAAAAABSm+p4cEEQQBBEEQQRBEEEQBEEEQRBBEEQQBBEEQRBEEAQRBEEEQRBBEARBBEEQQRBEEAQRBEEQRBBKEAAAAAAAAAAAAAAAAAAAAChM9T05IIggCCIIggiCIIIgCIIIgiCCIIggCCIIgiCIIAgiCIIIgiCCIAiCCIIggiCIIAgiCIIgiCCUIAAAAAAAAAAAAAAAAAAAAFCY6ntyQBBBEEQQBBEEQQRBEAQRBEEEQRBBEEQQBEEQQRBEEAQRBEEEQRAEEQRBBEEQQRBEEARBEEEoQQAAAAAAAAAAAAAAAAAAAKAw1ffkgCCCIIggCCIIggiCIAgiCIIIgiCCIIggCIIggiCIIAgiCIIIgiAIIgiCCIIggiCIIAiCIIJQggAAAAAAAAAAAAAAAAAAAEBhqu/JAUEEQRBBEEQQBBEEQRBEEAQRBEEEQRBBEARBBEEQQRBEEAQRBEEQRBAEEQRBBEEQQRAEQQShBAEAAAAAAAAAAAAAAAAAAIDCVN+TA4IIgiCCIIggCCIIgiCIIAgiCIIIgiCCIAiCCIIggiCIIAgiCIIgiCAIIgiCCIIggiAIgghCCQIAAAAAAAAAAAAAAAAAAACFqb4nBwQRBEEEQRBBEEQQBEEQQRBEEAQRBEEEQRAEEQRBBEEQQRBEEARBEEEQRBAEEQRBBEEQBBGEEgQAAAAAAAAAAAAAAAAAAAAKU31PDggiCIIIgiCCIIggCIIggiCIIAgiCIIIgiAIIgiCCIIggiCIIAiCIIIgiCAIIgiCCIIgCCIIwQGfN2b0IGi/xgAAAABJRU5ErkJggg==',
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
        stagingDirectory: () async => Directory(out.path).parent,
        pickDestination: (name, mime) async => '${out.path}/$name',
        writeToGallery: null,
      );
  final Directory out;
  final reads = <String>[];

  /// While set, originals and thumbnails report progress and wait for it.
  Completer<void>? hold;

  /// Serves the tall screenshot instead of the 16x16 picture.
  bool tall = false;

  /// Fails the full-size originals (not the thumbnails).
  bool failOriginals = false;
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
    if (failOriginals && !url.contains('/thumb/')) {
      throw const SocketException('offline');
    }
    final gate = hold;
    if (gate != null) {
      onProgress?.call(10, 100);
      await gate.future;
    }
    final tag = url.split('/').last;
    return tall
        ? Uint8List.fromList([..._tallPng, ...utf8.encode('|$tag')])
        : pngFor(tag);
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

List<Map<String, dynamic>> _images(
  int count, {
  bool thumbnails = false,
  Size size = const Size(16, 16),
}) => [
  for (var i = 0; i < count; i++)
    {
      'id': 'img$i',
      'channelId': 'channel',
      'filename': 'photo-$i.png',
      'mimeType': 'image/png',
      'width': size.width,
      'height': size.height,
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

/// Waits until image [index]'s original is on disk. The repository persists a
/// fetched original without being awaited, so a Share or Download tapped as
/// soon as the picture shows can run before the write lands and (correctly)
/// fall back to the URL path. Waits on the wall clock, not a frame count: the
/// write is real file I/O that a loaded machine delays.
Future<void> _stored(
  WidgetTester tester,
  _Rig rig,
  int index, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final key = attachmentOriginalKey(
    rig.w,
    _images(index + 1)[index],
    'channel',
  ).source.storeKey;
  final clock = Stopwatch()..start();
  while (true) {
    final bytes = await tester.runAsync(
      () => rig.w.attachmentDiskCache!.read(key),
    );
    if (bytes != null) return;
    if (clock.elapsed > timeout) {
      fail('Timed out after ${timeout.inSeconds}s waiting for original $index');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Pumps short frames until the Hero [shuttle] is in the tree, failing after
/// [timeout] of wall-clock time. The flight starts when the route is built,
/// which waits on real async work; fake time only advances by these frames, so
/// the flight (hundreds of milliseconds) cannot end while this waits.
Future<void> _untilInFlight(
  WidgetTester tester,
  Finder shuttle, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final clock = Stopwatch()..start();
  while (shuttle.evaluate().isEmpty) {
    if (clock.elapsed > timeout) {
      fail('Timed out after ${timeout.inSeconds}s waiting for the Hero flight');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<_Rig> _mount(
  WidgetTester tester, {
  required Size size,
  int count = 3,
  bool thumbnails = false,
  bool gallery = false,
  bool share = true,
  Size imageSize = const Size(16, 16),
  Completer<void>? hold,
  MediaMessageInfo? message,
  bool tall = false,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
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
  final items = _images(count, thumbnails: thumbnails, size: imageSize);
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
  final files = _Files(out, gallery: gallery)
    ..hold = hold
    ..tall = tall;
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
      builder: (context, child) => RaftToastHost(
        controller: toasts,
        child: textScale == 1 ? child! : RaftTextScaling(child: child!),
      ),
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
                    mediaMessage: message == null ? null : () => message,
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

MediaBrowserState _viewer(WidgetTester tester) =>
    tester.state(find.byType(MediaBrowser));

String _counter(WidgetTester tester) {
  final counter = find.byType(RaftLightboxCounter);
  if (counter.evaluate().isEmpty) return 'none';
  final c = tester.widget<RaftLightboxCounter>(counter);
  return '${c.index + 1} / ${c.count}';
}

const _alice = MediaMessageInfo(
  sender: 'Alice Chen',
  time: 'Oct 13, 2:02 PM',
  text: 'Hall walkthrough, second floor',
);

/// The chrome layers' opacity summed: 2 when top and bottom bars are shown.
double _chromeOpacity(WidgetTester tester) => tester
    .widgetList<AnimatedOpacity>(
      find.descendant(
        of: find.byType(RaftMediaImmersiveShell),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .map((o) => o.opacity)
    .reduce((a, b) => a + b);

const _wide = Size(1280, 800);
const _phone = Size(390, 844);

void main() {
  // Leak debt (other): see docs/development.md, Leak tracking.
  leakDebt(const ['Image', 'ImageInfo', 'ImageStreamCompleterHandle']);
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

    testWidgets('phone: Share and More in the top bar, none on the tile', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _phone, gallery: true);
      // Tile overlay: Share / Download are gone on phones.
      expect(find.byTooltip('Share photo-0.png'), findsNothing);
      expect(find.byTooltip('Download photo-0.png'), findsNothing);
      expect(rig.files.gallerySupported, isTrue);
      await _open(tester, 0);
      expect(find.byKey(const ValueKey('attachment-download')), findsNothing);
      expect(find.byKey(const ValueKey('viewer-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-more')), findsOneWidget);
      expect(find.bySemanticsLabel('Share'), findsOneWidget);
      expect(find.bySemanticsLabel('More'), findsOneWidget);
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
        await _stored(tester, rig, 0);
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
      await _stored(tester, rig, 0);
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
      await _stored(tester, rig, 0);
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
      await _stored(tester, rig, 0);
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
      await _stored(tester, rig, 0);
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

  group('loading and failure', () {
    Finder chip() => find.byType(RaftTransferBar);

    testWidgets('the progress chip waits 300 ms and is not shown for a page '
        'that was already loaded', (tester) async {
      final gate = Completer<void>();
      final rig = await _mount(
        tester,
        size: _phone,
        count: 3,
        gallery: true,
        hold: gate,
      );
      await tester.tap(find.byTooltip('Preview photo-0.png'));
      // Loading started: no chip for the first 300 ms, then it appears.
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 120));
      expect(chip(), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(chip(), findsOneWidget);
      gate.complete();
      await _settle(tester, 8);
      expect(chip(), findsNothing);
      final viewer = _viewer(tester);
      // Page away; forget the stored bytes; page back: the network is hit
      // again, but a page that was shown once never brings the chip back.
      viewer.goTo(2);
      await _settle(tester, 8);
      for (final entry in rig.root.listSync(recursive: true)) {
        if (entry is File && entry.path.contains('/cache/')) entry.deleteSync();
      }
      final again = Completer<void>();
      rig.files.hold = again;
      viewer.goTo(0);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      final page = tester.widget<AttachmentLightboxImage>(
        find.byType(AttachmentLightboxImage).first,
      );
      expect(page.settledBefore, isTrue);
      await tester.pump(const Duration(milliseconds: 600));
      expect(chip(), findsNothing);
      again.complete();
      await _settle(tester, 8);
    });

    testWidgets('a failed original keeps a visible Retry that loads again', (
      tester,
    ) async {
      final rig = await _mount(
        tester,
        size: _wide,
        count: 2,
        thumbnails: true,
        imageSize: const Size(3000, 2000),
      );
      rig.files.failOriginals = true;
      await _open(tester, 0);
      await _settle(tester, 12);
      final retry = find.byKey(const ValueKey('lightbox-retry'));
      expect(retry, findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      rig.files.failOriginals = false;
      await tester.tap(retry);
      await _settle(tester, 12);
      expect(retry, findsNothing);
    });
  });

  group('closing and page changes', () {
    testWidgets('desktop: closing fades out (reverse transition), then gone', (
      tester,
    ) async {
      await _mount(tester, size: _wide);
      await _open(tester, 0);
      await tester.tap(find.byTooltip('Close preview'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      // Mid-transition the viewer is still painted.
      expect(find.byType(MediaBrowser), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MediaBrowser), findsNothing);
    });

    testWidgets('desktop keeps Web\'s hard cut for arrows and thumbnails', (
      tester,
    ) async {
      await _mount(tester, size: _wide);
      await _open(tester, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
      expect(_viewer(tester).pages.page, 1.0);
      await tester.tap(find.byKey(const ValueKey('lightbox-thumbnail-2')));
      await tester.pump();
      await tester.pump();
      expect(_viewer(tester).pages.page, 2.0);
    });

    testWidgets('phone: stepping to the next image glides, a long jump cuts', (
      tester,
    ) async {
      await _mount(tester, size: _phone, count: 5, gallery: true);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      viewer.goTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(viewer.pages.page, inExclusiveRange(0.0, 1.0));
      await tester.pump(const Duration(milliseconds: 400));
      expect(viewer.pages.page, 1.0);
      viewer.goTo(4);
      await tester.pump();
      expect(viewer.pages.page, 4.0);
    });
  });

  group('thumbnail strip', () {
    Rect thumb(WidgetTester tester, int i) =>
        tester.getRect(find.byKey(ValueKey('lightbox-thumbnail-$i')));
    double offset(WidgetTester tester) => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('lightbox-thumbnail-scroll')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;

    testWidgets('opens with the active thumbnail in view, centred', (
      tester,
    ) async {
      await _mount(tester, size: _phone, count: 12, gallery: true);
      await _open(tester, 5);
      await _settle(tester, 6);
      final active = thumb(tester, 5);
      expect(active.left, greaterThanOrEqualTo(0));
      expect(active.right, lessThanOrEqualTo(_phone.width));
      expect(active.center.dx, closeTo(_phone.width / 2, 1));
    });

    testWidgets('follows the page: swiping to the last image scrolls it in', (
      tester,
    ) async {
      await _mount(tester, size: _phone, count: 12, gallery: true);
      await _open(tester, 0);
      _viewer(tester).goTo(11);
      await _settle(tester, 8);
      final active = thumb(tester, 11);
      expect(active.right, lessThanOrEqualTo(_phone.width));
      expect(active.left, greaterThanOrEqualTo(0));
      // The first ones scrolled away (thumbnails are built lazily).
      expect(offset(tester), greaterThan(100));
      expect(find.byKey(const ValueKey('lightbox-thumbnail-0')), findsNothing);
    });

    testWidgets('a few thumbnails stay centred as in Web', (tester) async {
      await _mount(tester, size: _wide, count: 3);
      await _open(tester, 0);
      final first = thumb(tester, 0), last = thumb(tester, 2);
      expect((first.left + last.right) / 2, closeTo(_wide.width / 2, 1));
      expect(first.width, 48);
      // `bottom-4`: the thumbnails end 16 px above the stage's bottom edge.
      expect(first.bottom, closeTo(_wide.height - 16, 1));
    });

    testWidgets('a drag scrolls the strip', (tester) async {
      await _mount(tester, size: _phone, count: 12, gallery: true);
      await _open(tester, 0);
      await _settle(tester, 6);
      expect(offset(tester), 0);
      await tester.drag(
        find.byKey(const ValueKey('lightbox-thumbnail-3')),
        const Offset(-150, 0),
      );
      await tester.pump();
      expect(offset(tester), greaterThan(100));
      expect(_counter(tester), '1 / 12', reason: 'the strip, not the pages');
    });

    testWidgets('the mouse wheel over the strip scrolls it, never zooms', (
      tester,
    ) async {
      await _mount(tester, size: _phone, count: 12);
      await _open(tester, 0);
      await _settle(tester, 6);
      final at = tester.getCenter(
        find.byKey(const ValueKey('lightbox-thumbnail-2')),
      );
      final mouse = TestPointer(9, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(at));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
      await tester.pump();
      expect(offset(tester), 120);
      // Even with the zoom modifier held the strip gets it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 60)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(offset(tester), 180);
      expect(_viewer(tester).zoomed, isFalse);
      expect(_viewer(tester).zoomFor(0).value, Matrix4.identity());
    });

    testWidgets('the strip band is reserved: stage content keeps clear of it', (
      tester,
    ) async {
      final gate = Completer<void>();
      await _mount(
        tester,
        size: _wide,
        count: 3,
        imageSize: const Size(3000, 4000),
        hold: gate,
      );
      await _open(tester, 0);
      // The loading stand-in (tall) ends above the strip band.
      final stand = tester.getRect(
        find
            .descendant(
              of: find.byType(AttachmentLightboxImage),
              matching: find.byType(RaftTransferPlaceholder),
            )
            .first,
      );
      expect(stand.bottom, lessThanOrEqualTo(thumb(tester, 0).top));
      gate.complete();
      await _settle(tester, 8);
      expect(
        tester
            .widget<ImageZoomSurface>(find.byType(ImageZoomSurface))
            .verticalInset,
        raftMediaDesktopStripBand,
      );
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

    testWidgets('a fast flick pages at fit scale (sparse move events)', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      final stage = tester.getCenter(
        find.byKey(const ValueKey('viewer-stage')),
      );
      // A real flick delivers few, large move events: the first one is far
      // beyond every slop at once. The image must not win it from the pages.
      for (final step in [90.0, 130.0, 200.0]) {
        final finger = await tester.createGesture();
        await finger.down(
          stage + const Offset(150, 0),
          timeStamp: Duration.zero,
        );
        await finger.moveBy(
          Offset(-step, 0),
          timeStamp: const Duration(milliseconds: 16),
        );
        await tester.pump(const Duration(milliseconds: 16));
        await finger.moveBy(
          Offset(-step, 0),
          timeStamp: const Duration(milliseconds: 32),
        );
        await tester.pump(const Duration(milliseconds: 16));
        await finger.up(timeStamp: const Duration(milliseconds: 40));
        await _settle(tester, 8);
        expect(_counter(tester), '2 / 3', reason: 'flick of $step px/event');
        // Back to the first image for the next flick.
        viewer.goTo(0);
        await _settle(tester, 8);
      }
      expect(viewer.zoomed, isFalse);
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

  group('phone chrome', () {
    testWidgets('top bar: back, title, sender · time, counter, Share, More', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true, message: _alice);
      await _open(tester, 0);
      expect(find.text('photo-0.png'), findsWidgets);
      // Phone sub-line: who and when, no sizes.
      expect(find.text('Alice Chen · Oct 13, 2:02 PM'), findsOneWidget);
      expect(_counter(tester), '1 / 3');
      for (final label in ['Back', 'Share', 'More']) {
        expect(
          tester.getSize(find.bySemanticsLabel(label).first).shortestSide,
          greaterThanOrEqualTo(44),
          reason: label,
        );
      }
      expect(
        tester.getRect(find.byKey(const ValueKey('viewer-pages'))),
        const Rect.fromLTWH(0, 0, 390, 844),
        reason: 'the stage runs edge to edge under the bars',
      );
      await tester.tap(find.bySemanticsLabel('Back'));
      await _settle(tester, 8);
      expect(find.byType(MediaBrowser), findsNothing);
    });

    testWidgets('a tap toggles the chrome once the double-tap window has '
        'passed; the picture re-centres in the room the chrome leaves', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true, message: _alice);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      final before = tester.getRect(
        find.byKey(const ValueKey('attachment-image-img0')),
      );
      final stage = tester.getCenter(
        find.byKey(const ValueKey('viewer-stage')),
      );
      // Away from the 16 px picture's centre: the tap is on the stage.
      final at = stage + const Offset(0, 250);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 100));
      expect(viewer.chrome.value, isTrue, reason: 'a second tap may follow');
      await tester.pump(const Duration(milliseconds: 300));
      expect(viewer.chrome.value, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_chromeOpacity(tester), 0);
      // Hidden: centred in the whole stage; shown: centred between the bars.
      final hidden = tester.getRect(
        find.byKey(const ValueKey('attachment-image-img0')),
      );
      expect(hidden.center.dy, closeTo(844 / 2, 1));
      expect(before.center.dy, lessThan(hidden.center.dy));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(viewer.chrome.value, isTrue);
      expect(_chromeOpacity(tester), 2);
      expect(
        tester.getRect(find.byKey(const ValueKey('attachment-image-img0'))),
        before,
      );
    });

    group('a tall image fits between the bars', () {
      const tall = Size(600, 2400);
      Rect picture(WidgetTester tester) =>
          tester.getRect(find.byKey(const ValueKey('attachment-image-img0')));

      Future<_Rig> open(
        WidgetTester tester, {
        Size size = _phone,
        MediaMessageInfo? message = _alice,
        int count = 3,
        double textScale = 1,
      }) async {
        final rig = await _mount(
          textScale: textScale,
          tester,
          size: size,
          gallery: true,
          count: count,
          imageSize: tall,
          message: message,
          tall: true,
        );
        await _open(tester, 0);
        await _settle(tester, 6);
        return rig;
      }

      testWidgets('chrome visible: above the caption and the strip, below '
          'the top bar; hidden: the whole stage', (tester) async {
        await open(tester);
        final viewer = _viewer(tester);
        final band = tester
            .getTopLeft(find.byKey(const ValueKey('media-caption')))
            .dy;
        final bar = tester
            .getBottomLeft(find.text('Alice Chen · Oct 13, 2:02 PM'))
            .dy;
        final shown = picture(tester);
        expect(
          shown.bottom,
          lessThanOrEqualTo(band),
          reason: 'under the caption',
        );
        expect(
          shown.top,
          greaterThanOrEqualTo(bar),
          reason: 'under the top bar',
        );
        expect(
          shown.height,
          greaterThan(500),
          reason: 'still as large as it can be',
        );
        viewer.chrome.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final hidden = picture(tester);
        expect(hidden.top, closeTo(0, 1));
        expect(hidden.bottom, closeTo(_phone.height, 1));
        // And back.
        viewer.chrome.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(picture(tester), shown);
      });

      testWidgets('the change between the two glides, never jumps', (
        tester,
      ) async {
        await open(tester);
        final viewer = _viewer(tester);
        final before = picture(tester);
        viewer.chrome.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final mid = picture(tester);
        expect(mid.height, greaterThan(before.height));
        expect(mid.height, lessThan(_phone.height));
        await tester.pump(const Duration(milliseconds: 400));
        expect(picture(tester).height, closeTo(_phone.height, 1));
      });

      testWidgets('no caption: the strip alone bounds it; one image: only '
          'the bars', (tester) async {
        await open(tester, message: const MediaMessageInfo(sender: 'A'));
        final strip = tester
            .getTopLeft(find.byKey(const ValueKey('lightbox-thumbnails')))
            .dy;
        expect(picture(tester).bottom, lessThanOrEqualTo(strip));
        await tester.pumpWidget(const SizedBox());
        await open(tester, count: 1);
        expect(find.byKey(const ValueKey('lightbox-thumbnails')), findsNothing);
        final caption = tester
            .getTopLeft(find.byKey(const ValueKey('media-caption')))
            .dy;
        expect(picture(tester).bottom, lessThanOrEqualTo(caption));
        expect(picture(tester).bottom, greaterThan(caption - 80));
      });

      testWidgets('landscape: between the top bar and the gesture bar, no '
          'strip', (tester) async {
        await open(tester, size: const Size(844, 390));
        expect(find.byKey(const ValueKey('lightbox-thumbnails')), findsNothing);
        final bar = tester
            .getBottomLeft(find.text('Alice Chen · Oct 13, 2:02 PM'))
            .dy;
        expect(picture(tester).top, greaterThanOrEqualTo(bar));
        expect(picture(tester).bottom, lessThanOrEqualTo(390));
      });

      testWidgets('a screen reader keeps the chrome on, so the picture stays '
          'between the bars', (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await open(tester);
        _viewer(tester).chrome.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final band = tester
            .getTopLeft(find.byKey(const ValueKey('media-caption')))
            .dy;
        expect(picture(tester).bottom, lessThanOrEqualTo(band));
      });

      testWidgets('zoomed 2x with the chrome shown, every edge pans fully into '
          'the room between the bars; hidden, into the whole stage', (
        tester,
      ) async {
        await open(tester);
        final viewer = _viewer(tester);
        final surface = find.byType(ImageZoomSurface);
        viewer.zoomStep(2);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        viewer.chrome.value = true; // the zoom hid it; a tap brings it back
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final band = tester
            .getTopLeft(find.byKey(const ValueKey('media-caption')))
            .dy;
        final bar =
            raftMediaTopBarRow; // the top bar's row (no status bar here)
        final centre = tester.getCenter(surface);
        expect(viewer.zoomed, isTrue);
        // Drag the picture up as far as it goes: its bottom edge meets the band.
        await tester.dragFrom(centre, const Offset(0, -3000));
        await tester.pump(const Duration(milliseconds: 100));
        expect(picture(tester).bottom, closeTo(band, 1), reason: 'bottom edge');
        // And down: its top edge meets the bar, none of it is stuck under it.
        await tester.dragFrom(centre, const Offset(0, 6000));
        await tester.pump(const Duration(milliseconds: 100));
        expect(picture(tester).top, closeTo(bar, 1), reason: 'top edge');
        // Chrome hidden: the whole stage.
        viewer.chrome.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.dragFrom(centre, const Offset(0, -3000));
        await tester.pump(const Duration(milliseconds: 100));
        expect(picture(tester).bottom, closeTo(_phone.height, 1));
        await tester.dragFrom(centre, const Offset(0, 6000));
        await tester.pump(const Duration(milliseconds: 100));
        expect(picture(tester).top, closeTo(0, 1));
      });

      testWidgets('large text (2.0x): the picture keeps clear of the grown top '
          'bar and the grown caption band, zoomed edges too', (tester) async {
        await open(tester, textScale: 2);
        final viewer = _viewer(tester);
        final caption = find.byKey(const ValueKey('media-caption'));
        final band = tester.getTopLeft(caption).dy;
        // The bar wraps its sender line: its rendered bottom, not 56 dp.
        final bar =
            tester.getRect(find.byType(RaftMediaImmersiveShell)).top +
            tester.getBottomLeft(find.byType(RaftLargeContentScope).first).dy;
        final shown = picture(tester);
        expect(band, lessThan(_phone.height - 100), reason: 'the band grew');
        expect(shown.bottom, lessThanOrEqualTo(band + .5));
        expect(shown.top, greaterThanOrEqualTo(bar - .5));
        // Zoomed, the edges meet the same lines.
        viewer.zoomStep(2);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        viewer.chrome.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final centre = tester.getCenter(find.byType(ImageZoomSurface));
        await tester.dragFrom(centre, const Offset(0, -3000));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          picture(tester).bottom,
          closeTo(band, 1.5),
          reason: 'bottom edge',
        );
        await tester.dragFrom(centre, const Offset(0, 6000));
        await tester.pump(const Duration(milliseconds: 100));
        expect(picture(tester).top, closeTo(bar, 1.5), reason: 'top edge');
      });

      testWidgets('a zoomed image keeps its zoom when the chrome returns', (
        tester,
      ) async {
        await open(tester);
        final viewer = _viewer(tester);
        viewer.zoomFor(0).value = Matrix4.identity()..scaleByDouble(2, 2, 1, 1);
        await tester.pump();
        viewer.chrome.value = false;
        await tester.pump(const Duration(milliseconds: 400));
        viewer.chrome.value = true;
        await tester.pump(const Duration(milliseconds: 400));
        expect(viewer.zoomed, isTrue);
        expect(viewer.zoomFor(0).value.getMaxScaleOnAxis(), closeTo(2, .01));
      });
    });

    testWidgets('a double tap zooms and hides the chrome; the next tap '
        'brings it back', (tester) async {
      await _mount(tester, size: _phone, gallery: true, message: _alice);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      final at = tester.getCenter(find.byKey(const ValueKey('viewer-stage')));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(at);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(viewer.zoomed, isTrue);
      expect(viewer.chrome.value, isFalse);
      await tester.tapAt(at + const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 500));
      expect(viewer.chrome.value, isTrue);
      expect(viewer.zoomed, isTrue, reason: 'a tap does not undo the zoom');
    });

    testWidgets('a pinch hides the chrome', (tester) async {
      await _mount(tester, size: _phone, gallery: true, message: _alice);
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
      expect(viewer.chrome.value, isFalse);
      await a.up();
      await b.up();
      await _settle(tester, 4);
    });

    testWidgets('a tap on the empty stage does not close on a phone', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true, count: 1);
      await _open(tester, 0);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))) +
            const Offset(0, 250),
      );
      await _settle(tester, 8);
      expect(find.byType(MediaBrowser), findsOneWidget);
    });

    testWidgets('desktop: a click on the empty stage still closes (Web)', (
      tester,
    ) async {
      await _mount(tester, size: _wide, count: 1);
      await _open(tester, 0);
      await tester.tapAt(const Offset(200, 400));
      await _settle(tester, 8);
      expect(find.byType(MediaBrowser), findsNothing);
    });

    testWidgets('a screen reader keeps the chrome on', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _mount(tester, size: _phone, gallery: true, message: _alice);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))) +
            const Offset(0, 250),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 300));
      expect(viewer.chrome.value, isFalse);
      expect(_chromeOpacity(tester), 2, reason: 'still on screen');
    });

    testWidgets('landscape drops the strip, keeps the top bar and the swipe', (
      tester,
    ) async {
      await _mount(tester, size: const Size(844, 390), gallery: true);
      await _open(tester, 0);
      expect(find.byKey(const ValueKey('lightbox-thumbnails')), findsNothing);
      expect(find.text('photo-0.png'), findsWidgets);
      expect(_counter(tester), '1 / 3');
      await tester.dragFrom(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
        const Offset(-600, 0),
      );
      await _settle(tester, 8);
      expect(_counter(tester), '2 / 3');
    });

    testWidgets('caption: the message text, two lines, only when there is '
        'text', (tester) async {
      await _mount(tester, size: _phone, gallery: true, message: _alice);
      await _open(tester, 0);
      final caption = find.byKey(const ValueKey('media-caption'));
      expect(caption, findsOneWidget);
      expect(
        find.descendant(of: caption, matching: find.text(_alice.text!)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(of: caption, matching: find.byType(Text)),
            )
            .maxLines,
        2,
      );
    });

    testWidgets('no caption when the message has no text', (tester) async {
      await _mount(
        tester,
        size: _phone,
        gallery: true,
        message: const MediaMessageInfo(sender: 'Alice Chen', text: '  '),
      );
      await _open(tester, 0);
      expect(find.byKey(const ValueKey('media-caption')), findsNothing);
    });

    testWidgets('the system bars: light icons over the black stage', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find
            .descendant(
              of: find.byType(RaftMediaImmersiveShell),
              matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
            )
            .first,
      );
      expect(region.value.statusBarIconBrightness, Brightness.light);
      expect(region.value.statusBarColor, Colors.transparent);
    });

    testWidgets('opened, the page below stops painting; dragging brings it '
        'back', (tester) async {
      await _mount(tester, size: _phone, gallery: true);
      expect(find.byType(AttachmentView), findsWidgets);
      await _open(tester, 0);
      expect(find.byType(AttachmentView), findsNothing);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
      );
      await gesture.moveBy(const Offset(0, 40));
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump();
      expect(find.byType(AttachmentView), findsWidgets);
      await gesture.up(timeStamp: const Duration(seconds: 3));
      await _settle(tester, 8);
      expect(find.byType(AttachmentView), findsNothing);
    });
  });

  group('desktop header', () {
    testWidgets('kind glyph, filename, sender · time · size, counter', (
      tester,
    ) async {
      await _mount(tester, size: _wide, message: _alice);
      await _open(tester, 1);
      final header = find.byType(RaftLightboxHeader);
      expect(
        find.descendant(
          of: header,
          matching: find.byWidgetPredicate(
            (w) => w is RaftIcon && w.glyph == RaftGlyph.image,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.text('photo-1.png')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: header,
          matching: find.text('Alice Chen · Oct 13, 2:02 PM · 16x16 · 100 B'),
        ),
        findsOneWidget,
      );
      expect(_counter(tester), '2 / 3');
      expect(find.byKey(const ValueKey('attachment-download')), findsOneWidget);
    });

    testWidgets('without message info the header is Web\'s: no sub-line, '
        'no glyph on a lone sender-less message', (tester) async {
      await _mount(tester, size: _wide, count: 1);
      await _open(tester, 0);
      final header = find.byType(RaftLightboxHeader);
      expect(
        find.descendant(of: header, matching: find.textContaining(' · ')),
        findsOneWidget,
        reason: 'size and dimensions only',
      );
    });

    testWidgets('the strip is a band under the stage, not drawn over it', (
      tester,
    ) async {
      await _mount(tester, size: _wide, message: _alice);
      await _open(tester, 0);
      final strip = tester.getRect(
        find.byKey(const ValueKey('lightbox-thumbnails')),
      );
      final page = tester.getRect(find.byType(ImageZoomSurface));
      expect(strip.bottom, lessThanOrEqualTo(_wide.height));
      expect(
        tester
            .widget<ImageZoomSurface>(find.byType(ImageZoomSurface))
            .verticalInset,
        raftMediaDesktopStripBand,
      );
      expect(page.height, greaterThan(strip.height));
    });

    testWidgets('dragging down does not dismiss a desktop viewer', (
      tester,
    ) async {
      await _mount(tester, size: _wide, message: _alice);
      await _open(tester, 0);
      await tester.flingFrom(
        const Offset(640, 300),
        const Offset(0, 400),
        3000,
      );
      await _settle(tester, 8);
      expect(find.byType(MediaBrowser), findsOneWidget);
    });
  });

  group('Share and More', () {
    testWidgets('Share hands the original to the system sheet', (tester) async {
      final rig = await _mount(tester, size: _phone, gallery: true, count: 1);
      await _open(tester, 0);
      await _stored(tester, rig, 0);
      await tester.tap(find.byKey(const ValueKey('viewer-share')));
      await _settle(tester);
      expect(rig.sharing.shared, ['bytes:photo-0.png:|img0']);
      await _finish(tester, rig);
    });

    testWidgets('More offers Save, Download file and Show in message', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _phone, gallery: true, count: 1);
      await _open(tester, 0);
      await _stored(tester, rig, 0);
      await tester.tap(find.byKey(const ValueKey('viewer-more')));
      await _settle(tester, 4);
      expect(find.byKey(const ValueKey('viewer-menu-save')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('viewer-menu-download')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('viewer-menu-show')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-menu-share')), findsNothing);
      // It opens under the More button, not at the top-left.
      final menu = tester.getRect(
        find.byKey(const ValueKey('viewer-menu-save')),
      );
      final more = tester.getRect(find.byKey(const ValueKey('viewer-more')));
      expect(menu.top, greaterThanOrEqualTo(more.bottom - 1));
      await tester.tap(find.byKey(const ValueKey('viewer-menu-save')));
      await _settle(tester);
      expect(rig.files.gallerySaves, hasLength(1));
      await _finish(tester, rig);
    });

    testWidgets('Download file saves the original under its name', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _phone, gallery: true, count: 1);
      await _open(tester, 0);
      await tester.tap(find.byKey(const ValueKey('viewer-more')));
      await _settle(tester, 4);
      await tester.tap(find.byKey(const ValueKey('viewer-menu-download')));
      await _settle(tester);
      expect(File('${rig.out.path}/photo-0.png').existsSync(), isTrue);
      expect(rig.files.gallerySaves, isEmpty);
      await _finish(tester, rig);
    });

    testWidgets('Show in message closes the browser and asks for the message', (
      tester,
    ) async {
      final rig = await _mount(tester, size: _phone, gallery: true, count: 1);
      final shown = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: MediaBrowser(
            controller: rig.w,
            files: rig.files,
            sharing: rig.sharing,
            items: [MediaItem.image(_images(1).single)],
            initialIndex: 0,
            messageId: 'm1',
            authorized: () => true,
            page: true,
            onClose: () {},
            onShowInMessage: () => shown.add('m1'),
          ),
        ),
      );
      await _settle(tester, 4);
      await tester.tap(find.byKey(const ValueKey('viewer-more')));
      await _settle(tester, 4);
      await tester.tap(find.byKey(const ValueKey('viewer-menu-show')));
      await _settle(tester, 4);
      expect(shown, ['m1']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a window without a share sheet or photo library keeps '
        'Download in the top bar', (tester) async {
      await _mount(
        tester,
        size: _phone,
        gallery: false,
        share: false,
        count: 1,
      );
      await _open(tester, 0);
      expect(find.byKey(const ValueKey('viewer-share')), findsNothing);
      expect(find.byKey(const ValueKey('attachment-download')), findsOneWidget);
    });

    testWidgets('the long press keeps its Save / Share shortcut', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true, count: 1);
      await _open(tester, 0);
      await tester.longPressAt(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
      );
      await _settle(tester, 4);
      expect(find.byKey(const ValueKey('viewer-menu-save')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-menu-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-menu-download')), findsNothing);
    });
  });

  group('drag down to dismiss', () {
    Future<TestGesture> dragStart(WidgetTester tester) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
      );
      await gesture.moveBy(const Offset(0, 30));
      return gesture;
    }

    testWidgets('the stage follows the finger, the scrim and chrome fade', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true, message: _alice);
      await _open(tester, 0);
      final before = tester.getTopLeft(find.byType(ImageZoomSurface));
      final gesture = await dragStart(tester);
      await gesture.moveBy(const Offset(0, 110));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.getTopLeft(find.byType(ImageZoomSurface)).dy,
        greaterThan(before.dy + 100),
      );
      expect(_chromeOpacity(tester), 0);
      expect(
        tester
            .widgetList<ColoredBox>(
              find.descendant(
                of: find.byType(RaftMediaImmersiveShell),
                matching: find.byType(ColoredBox),
              ),
            )
            .any((c) => c.color.a < 1 && c.color.a > 0),
        isTrue,
      );
      await gesture.up(timeStamp: const Duration(seconds: 3));
      await _settle(tester, 8);
      expect(_chromeOpacity(tester), 2, reason: 'sprang back, chrome returns');
    });

    testWidgets('released past 120 dp it closes', (tester) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      final gesture = await dragStart(tester);
      await gesture.moveBy(const Offset(0, 130));
      await gesture.up(timeStamp: const Duration(seconds: 3));
      await _settle(tester, 10);
      expect(find.byType(MediaBrowser), findsNothing);
    });

    testWidgets('a short fast fling closes; a slow short drag does not', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      final center = tester.getCenter(
        find.byKey(const ValueKey('viewer-stage')),
      );
      await tester.flingFrom(center, const Offset(0, 70), 200);
      await _settle(tester, 8);
      expect(find.byType(MediaBrowser), findsOneWidget);
      await tester.flingFrom(center, const Offset(0, 70), 1800);
      await _settle(tester, 10);
      expect(find.byType(MediaBrowser), findsNothing);
    });

    testWidgets('zoomed in, a vertical drag pans instead of closing', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      viewer.zoomFor(0).value = Matrix4.identity()..scaleByDouble(3, 3, 1, 1);
      await tester.pump();
      expect(viewer.zoomed, isTrue);
      await tester.flingFrom(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
        const Offset(0, 300),
        2500,
      );
      await _settle(tester, 8);
      expect(find.byType(MediaBrowser), findsOneWidget);
    });

    testWidgets('touch only: a mouse drag does not close', (tester) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      final mouse = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await mouse.moveBy(const Offset(0, 40));
      await mouse.moveBy(const Offset(0, 300));
      await mouse.up();
      await _settle(tester, 8);
      expect(find.byType(MediaBrowser), findsOneWidget);
    });

    testWidgets('horizontal intent belongs to the pages', (tester) async {
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      await tester.dragFrom(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
        const Offset(-300, 40),
      );
      await _settle(tester, 8);
      expect(find.byType(MediaBrowser), findsOneWidget);
      expect(_counter(tester), '2 / 3');
    });
  });

  group('Hero', () {
    final shuttle = find.byKey(const ValueKey('media-hero-shuttle'));

    for (final (name, size) in [('phone', _phone), ('desktop', _wide)]) {
      testWidgets('$name: the card flies to the stage and back', (
        tester,
      ) async {
        await _mount(tester, size: size, gallery: true, count: 3);
        await tester.tap(find.byTooltip('Preview photo-0.png'));
        await tester.pump();
        await _untilInFlight(tester, shuttle);
        expect(shuttle, findsOneWidget, reason: 'in flight');
        await _settle(tester, 8);
        expect(shuttle, findsNothing);
        // The tapped card wears the Hero for as long as the browser is up.
        expect(
          find.byType(RaftMediaHero, skipOffstage: false),
          findsNWidgets(2),
        );
        _viewer(tester).widget.onClose();
        await tester.pump();
        await _untilInFlight(tester, shuttle);
        expect(shuttle, findsOneWidget, reason: 'back to the card');
        await _settle(tester, 12);
        expect(find.byType(MediaBrowser), findsNothing);
        expect(
          find.byType(RaftMediaHero),
          findsNothing,
          reason: 'card is plain',
        );
      });
    }

    testWidgets('closing on another page than the opener fades, no flight', (
      tester,
    ) async {
      await _mount(tester, size: _phone, gallery: true, count: 3);
      await _open(tester, 0);
      _viewer(tester).goTo(2);
      await _settle(tester, 8);
      _viewer(tester).widget.onClose();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(shuttle, findsNothing);
      await _settle(tester, 12);
      expect(find.byType(MediaBrowser), findsNothing);
    });

    testWidgets('reduced motion: no Hero, an 80 ms cross-fade', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _mount(tester, size: _phone, gallery: true, count: 3);
      await tester.tap(find.byTooltip('Preview photo-0.png'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(shuttle, findsNothing);
      expect(find.byType(RaftMediaHero, skipOffstage: false), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      expect(find.byType(AttachmentView), findsNothing, reason: 'settled');
    });
  });

  group('reduced motion', () {
    testWidgets('page changes snap on a phone', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _mount(tester, size: _phone, count: 5, gallery: true);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      viewer.goTo(1);
      await tester.pump();
      expect(viewer.pages.page, 1.0);
    });

    testWidgets('the chrome toggles without a fade; dragging does not scale', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _mount(tester, size: _phone, gallery: true);
      await _open(tester, 0);
      final width = tester.getSize(find.byType(ImageZoomSurface)).width;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('viewer-stage'))),
      );
      await gesture.moveBy(const Offset(0, 40));
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(tester.getSize(find.byType(ImageZoomSurface)).width, width);
      expect(
        tester.getTopLeft(find.byType(ImageZoomSurface)).dy,
        greaterThan(90),
        reason: 'still follows the finger',
      );
      await gesture.up(timeStamp: const Duration(seconds: 3));
      await _settle(tester, 8);
    });
  });

  group('keyboard map', () {
    Future<void> chord(
      WidgetTester tester,
      LogicalKeyboardKey modifier,
      LogicalKeyboardKey key,
    ) async {
      final platform = switch (defaultTargetPlatform) {
        TargetPlatform.macOS => 'macos',
        TargetPlatform.windows => 'windows',
        _ => 'linux',
      };
      await tester.sendKeyDownEvent(modifier, platform: platform);
      await tester.sendKeyEvent(key, platform: platform);
      await tester.sendKeyUpEvent(modifier, platform: platform);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    final variant = TargetPlatformVariant.only(TargetPlatform.macOS);
    final others = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
    });

    testWidgets('macOS: Cmd+= / Cmd+- / Cmd+0 zoom and fit; Ctrl does not', (
      tester,
    ) async {
      await _mount(tester, size: _wide);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      await chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.equal,
      );
      expect(viewer.zoomed, isFalse, reason: 'Ctrl is not the command key');
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.equal,
      );
      expect(viewer.zoomed, isTrue);
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.digit0,
      );
      expect(viewer.zoomed, isFalse);
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.equal,
      );
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.minus,
      );
      expect(viewer.zoomed, isFalse, reason: '1.5x then back to fit');
    }, variant: variant);

    testWidgets('Windows / Linux: Ctrl+= / Ctrl+- / Ctrl+0; Cmd does not', (
      tester,
    ) async {
      await _mount(tester, size: _wide);
      await _open(tester, 0);
      final viewer = _viewer(tester);
      await chord(
        tester,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.equal,
      );
      expect(viewer.zoomed, isFalse, reason: 'Meta is not the command key');
      await chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.equal,
      );
      expect(viewer.zoomed, isTrue);
      await chord(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.digit0,
      );
      expect(viewer.zoomed, isFalse);
    }, variant: others);

    testWidgets('+ and - zoom, Home and End jump, plain arrows still page', (
      tester,
    ) async {
      await _mount(tester, size: _wide, count: 5);
      await _open(tester, 2);
      final viewer = _viewer(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(viewer.zoomed, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadSubtract);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(viewer.zoomed, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await _settle(tester, 4);
      expect(_counter(tester), '1 / 5');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await _settle(tester, 4);
      expect(_counter(tester), '5 / 5');
    });

    testWidgets('Esc, Ctrl+W and Cmd+W close on every platform', (
      tester,
    ) async {
      await _mount(tester, size: _wide, count: 2);
      for (final modifier in [
        null,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await _open(tester, 0);
        if (modifier == null) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
          await tester.sendKeyUpEvent(modifier);
        }
        await _settle(tester, 12);
        expect(find.byType(MediaBrowser), findsNothing, reason: '$modifier');
      }
    });
  });

  group('accessibility', () {
    testWidgets('page label, selected strip item, zoom actions', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _mount(tester, size: _phone, gallery: true, message: _alice);
      await _open(tester, 0);
      final page = tester.getSemantics(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              (w.properties.label?.startsWith('Image 1 of 3, ') ?? false),
        ),
      );
      expect(
        page.label,
        'Image 1 of 3, photo-0.png, Alice Chen, Oct 13, 2:02 PM',
      );
      final actions = page
          .getSemanticsData()
          .customSemanticsActionIds!
          .map((id) => CustomSemanticsAction.getAction(id)!.label)
          .toSet();
      expect(actions, {'Zoom in', 'Zoom out', 'Fit to screen'});
      final selected = tester.getSemantics(
        find.byKey(const ValueKey('lightbox-thumbnail-0')),
      );
      expect(selected.label, 'Image 1 of 3');
      expect(selected.flagsCollection.isSelected, Tristate.isTrue);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('lightbox-thumbnail-1')))
            .flagsCollection
            .isSelected,
        isNot(Tristate.isTrue),
      );
      // Zoom in without a pinch or a double tap.
      final zoomIn = page
          .getSemanticsData()
          .customSemanticsActionIds!
          .firstWhere(
            (id) => CustomSemanticsAction.getAction(id)!.label == 'Zoom in',
          );
      tester.semantics.performAction(
        find.semantics.byLabel(RegExp(r'^Image 1 of 3, ')),
        SemanticsAction.customAction,
        args: zoomIn,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_viewer(tester).zoomed, isTrue);
      handle.dispose();
    });
  });
}
