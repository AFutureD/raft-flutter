import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/attachment_image_repository.dart';
import 'package:raft_flutter/data/cache_clear.dart';
import 'package:raft_flutter/features/storage_settings.dart';
import 'package:raft_ui/raft_ui.dart';

void main() {
  late Directory root;
  late AttachmentDiskCache cache;
  late CacheClear coordinator;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('raft-storage-settings');
    cache = AttachmentDiskCache(() async => root);
    coordinator = CacheClear()..register('disk', cache.clear);
  });
  tearDown(() => root.delete(recursive: true));

  // The size is read off the first frame, from the disk.
  bool calculated() => find.text('Calculating…').evaluate().isEmpty;

  Future<void> pumpPage(WidgetTester t, {AttachmentDiskCache? with_}) async {
    t.view.physicalSize = const Size(900, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: RaftToastHost(
          child: Scaffold(
            body: SingleChildScrollView(
              child: StorageSettingsPage(
                key: UniqueKey(),
                cache: with_,
                coordinator: coordinator,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(t, until: calculated);
  }

  Future<void> fill(WidgetTester t, int bytes) async {
    await t.runAsync(
      () => cache.write(
        AttachmentImageStoreKey(
          identity: AttachmentImageKey.identityOf(
            'https://x.invalid',
            'u',
            's',
          ),
          channelId: 'c',
          entry: '["a$bytes","r","original"]',
        ),
        Uint8List(bytes),
      ),
    );
  }

  Future<void> fillPublic(WidgetTester t, int bytes) => t.runAsync(
    () => cache.writePublic('https://x.invalid/a$bytes.webp', Uint8List(bytes)),
  );

  String text(WidgetTester t, String key) =>
      t.widget<Text>(find.byKey(Key(key))).data!;

  String size(WidgetTester t) => t
      .widget<Text>(
        find.descendant(
          of: find.byKey(const Key('storage-size')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  testWidgets('shows the cache size, off the first frame', (t) async {
    await fill(t, 3 * 1024 * 1024);
    await fill(t, 512 * 1024);
    t.view.physicalSize = const Size(900, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: Scaffold(
          body: StorageSettingsPage(
            key: UniqueKey(),
            cache: cache,
            coordinator: coordinator,
          ),
        ),
      ),
    );
    // The first frame does not wait for the disk.
    expect(size(t), 'Calculating…');
    expect(
      t
          .widget<RaftSettingsRecipeButton>(
            find.byKey(const Key('storage-clear')),
          )
          .onPressed,
      isNull,
    );
    await settle(t, until: calculated);
    expect(size(t), 'Cache size: 3.5 MB');
    expect(find.byType(RaftSettingsSectionHeader), findsOneWidget);
    expect(find.text('Cache'), findsOneWidget);
  });

  testWidgets('breaks the total down by what is stored', (t) async {
    await fill(t, 3 * 1024 * 1024);
    await fillPublic(t, 512 * 1024);
    await pumpPage(t, with_: cache);
    expect(size(t), 'Cache size: 3.5 MB');
    expect(text(t, 'storage-attachments-size'), '3.0 MB');
    expect(text(t, 'storage-public-size'), '512.0 KB');
    expect(find.text('Attachments and previews'), findsOneWidget);
    expect(find.text('Profile pictures and icons'), findsOneWidget);
  });

  testWidgets('the breakdown reads in Chinese', (t) async {
    await fill(t, 1024);
    await fillPublic(t, 1024);
    t.view.physicalSize = const Size(900, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: StorageSettingsPage(cache: cache, coordinator: coordinator),
        ),
      ),
    );
    await settle(t, until: calculated);
    expect(find.text('附件和预览'), findsOneWidget);
    expect(find.text('头像和图标'), findsOneWidget);
  });

  testWidgets('clearing asks first, then empties the cache and says so', (
    t,
  ) async {
    await fill(t, 2 * 1024 * 1024);
    await fillPublic(t, 1024 * 1024);
    final session = File('${root.path}/session.json')
      ..writeAsStringSync('keep');
    await pumpPage(t, with_: cache);
    expect(size(t), 'Cache size: 3.0 MB');

    await t.tap(find.byKey(const Key('storage-clear')));
    await settle(t);
    expect(find.byKey(const ValueKey('storage-clear-dialog')), findsOneWidget);
    expect(
      find.textContaining('They are downloaded again the next time you open'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'so are your sign-in, drafts, settings, files you saved and files shared to Raft',
      ),
      findsOneWidget,
    );

    // Cancel leaves everything as it was.
    await t.tap(find.text('Cancel'));
    await settle(t);
    expect(find.byKey(const ValueKey('storage-clear-dialog')), findsNothing);
    expect(size(t), 'Cache size: 3.0 MB');
    expect((await t.runAsync(cache.sizeBytes)), 3 * 1024 * 1024);

    await t.tap(find.byKey(const Key('storage-clear')));
    await settle(t);
    await t.tap(find.byKey(const Key('storage-clear-confirm')));
    await settle(
      t,
      until: () =>
          find
              .byKey(const ValueKey('storage-clear-dialog'))
              .evaluate()
              .isEmpty &&
          find.text('Cache size: 0 B').evaluate().isNotEmpty,
    );
    expect(find.byKey(const ValueKey('storage-clear-dialog')), findsNothing);
    expect(find.text('Cache cleared.'), findsOneWidget);
    expect(size(t), 'Cache size: 0 B');
    expect(text(t, 'storage-attachments-size'), '0 B');
    expect(text(t, 'storage-public-size'), '0 B');
    expect((await t.runAsync(cache.sizeBytes)), 0);
    expect(session.existsSync(), isTrue, reason: 'only the cache is cleared');
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('goes through the coordinator: a layer registered later is '
      'cleared too, one that fails keeps the dialog open', (t) async {
    await fill(t, 1024);
    var memory = 0;
    coordinator.register('memory', () => memory++);
    coordinator.register('broken', () => throw const FileSystemException('x'));
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);
    await pumpPage(t, with_: cache);
    await t.tap(find.byKey(const Key('storage-clear')));
    await settle(
      t,
      until: () => find
          .byKey(const Key('storage-clear-confirm'))
          .evaluate()
          .isNotEmpty,
    );
    await t.tap(find.byKey(const Key('storage-clear-confirm')));
    await settle(
      t,
      until: () => find
          .text('Some of the cache could not be cleared. Try again.')
          .evaluate()
          .isNotEmpty,
    );
    expect(memory, 1);
    expect((await t.runAsync(cache.sizeBytes)), 0);
    expect(find.byKey(const ValueKey('storage-clear-dialog')), findsOneWidget);
    expect(
      find.text('Some of the cache could not be cleared. Try again.'),
      findsOneWidget,
    );
    expect(reported, hasLength(1));
  });

  testWidgets('without a cache there is nothing to clear', (t) async {
    await pumpPage(t);
    expect(size(t), 'Cache size: 0 B');
    expect(
      t
          .widget<RaftSettingsRecipeButton>(
            find.byKey(const Key('storage-clear')),
          )
          .onPressed,
      isNull,
    );
  });
}

/// Real file I/O needs real time between frames: at least 12 frames, and when
/// [until] is given, more (up to ten seconds) until it holds, so a slow disk
/// on a loaded machine is waited for instead of guessed at.
Future<void> settle(WidgetTester t, {bool Function()? until}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  for (var i = 0; ; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await t.pump(const Duration(milliseconds: 50));
    if (i >= 11 && (until == null || until())) return;
    if (DateTime.now().isAfter(deadline)) return;
  }
}
