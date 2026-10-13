import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/attachment_image_repository.dart';
import 'package:raft_flutter/features/storage_settings.dart';
import 'package:raft_ui/raft_ui.dart';

void main() {
  late Directory root;
  late AttachmentDiskCache cache;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('raft-storage-settings');
    cache = AttachmentDiskCache(() async => root);
  });
  tearDown(() => root.delete(recursive: true));

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
              child: StorageSettingsPage(key: UniqueKey(), cache: with_),
            ),
          ),
        ),
      ),
    );
    await settle(t);
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
          body: StorageSettingsPage(key: UniqueKey(), cache: cache),
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
    await settle(t);
    expect(size(t), 'Cache size: 3.5 MB');
    expect(find.byType(RaftSettingsSectionHeader), findsOneWidget);
    expect(find.text('Attachment cache'), findsOneWidget);
  });

  testWidgets('clearing asks first, then empties the cache and says so', (
    t,
  ) async {
    await fill(t, 2 * 1024 * 1024);
    final session = File('${root.path}/session.json')
      ..writeAsStringSync('keep');
    await pumpPage(t, with_: cache);
    expect(size(t), 'Cache size: 2.0 MB');

    await t.tap(find.byKey(const Key('storage-clear')));
    await settle(t);
    expect(find.byKey(const ValueKey('storage-clear-dialog')), findsOneWidget);
    expect(
      find.textContaining('Your sign-in, drafts, settings and files you saved'),
      findsWidgets,
    );

    // Cancel leaves everything as it was.
    await t.tap(find.text('Cancel'));
    await settle(t);
    expect(find.byKey(const ValueKey('storage-clear-dialog')), findsNothing);
    expect(size(t), 'Cache size: 2.0 MB');
    expect((await t.runAsync(cache.sizeBytes))!, 2 * 1024 * 1024);

    await t.tap(find.byKey(const Key('storage-clear')));
    await settle(t);
    await t.tap(find.byKey(const Key('storage-clear-confirm')));
    await settle(t);
    expect(find.byKey(const ValueKey('storage-clear-dialog')), findsNothing);
    expect(find.text('Cache cleared.'), findsOneWidget);
    expect(size(t), 'Cache size: 0 B');
    expect((await t.runAsync(cache.sizeBytes))!, 0);
    expect(session.existsSync(), isTrue, reason: 'only the cache is cleared');
    await t.pump(const Duration(seconds: 6));
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

/// Real file I/O needs real time between frames.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}
