import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/search_memory.dart';
import 'package:raft_flutter/features/mobile_workspace_navigation.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_flutter/platform/app_update.dart';
import 'package:raft_ui/raft_ui.dart';

import 'workspace_source_location_contract_test.dart' show pageFixture, frames;

class _Memory implements SearchMemoryStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

AppUpdateService _service({int build = 20, String platform = 'macos-arm64'}) =>
    AppUpdateService(
      currentVersion: '0.1.0',
      currentBuild: build,
      platformKey: platform,
      storage: _Memory(),
      scheduleTimer: false,
      fetch: (_) async => jsonEncode([
        {
          'platform': platform.split('-').first,
          'arch': platform.split('-').last,
          'version': '0.1.0',
          'buildNumber': '37',
          'releaseTag': 'v0.1.0+5',
          'artifact': 'raft-flutter-0.1.0+5-$platform.zip',
        },
      ]),
    );

Future<void> _mount(
  WidgetTester t,
  AppUpdateService? update, {
  double width = 1280,
}) async {
  final (w, api) = await pageFixture(t, section: 'chat');
  api.routes['GET /agents'] = (_) => [];
  api.routes['GET /servers/s1/members'] = (_) => [];
  api.routes['GET /product-feedback/tickets'] = (_) => {
    'items': [],
    'unread_total': 0,
  };
  t.view.physicalSize = Size(width, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: raftTheme(RaftFamily.elegant),
      home: WorkspaceView(
        controller: w,
        appearance: const RaftAppearance(light: RaftFamily.elegant),
        onAppearance: (_) async {},
        onLogout: () async {},
        appUpdate: update,
      ),
    ),
  );
  await frames(t, () {});
  await t.pumpAndSettle();
}

Finder _dotIn(Finder of) =>
    find.descendant(of: of, matching: find.byType(RaftAttentionDot));
Finder _railDotIn(Finder of) =>
    find.descendant(of: of, matching: find.byType(RaftRailAttention));
bool _tabAttention(WidgetTester t) => t
    .widget<RaftMobileNav>(find.byKey(const Key('workspace-mobile-navigation')))
    .items
    .firstWhere((i) => i.id == 'settings')
    .attention;

void main() {
  testWidgets(
    'desktop: dot on Settings and About until About is opened',
    (t) async {
      final update = _service();
      addTearDown(update.dispose);
      await t.runAsync(update.start);
      await _mount(t, update);

      final settings = find.byKey(const Key('rail-settings'));
      expect(_railDotIn(settings), findsOneWidget);

      await t.tap(settings);
      await t.pumpAndSettle();
      final about = find.byType(RaftSettingsSidebarList);
      expect(find.text('About'), findsOneWidget);
      expect(_dotIn(about), findsOneWidget);
      // Opening Settings alone does not mark the release as seen.
      expect(update.hasUnseen, isTrue);

      await t.tap(find.text('About'));
      await t.pumpAndSettle();
      expect(find.text('New version available: 0.1.0 (37)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-about-update-action')),
        findsOneWidget,
      );
      expect(find.text('View release'), findsOneWidget);
      expect(update.hasUnseen, isFalse);
      expect(_railDotIn(settings), findsNothing);
      expect(_dotIn(about), findsNothing);
      // The row stays so the user can still act on it.
      expect(find.text('New version available: 0.1.0 (37)'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    'Android offers the APK download',
    (t) async {
      final update = _service(platform: 'android-arm64');
      addTearDown(update.dispose);
      await t.runAsync(update.start);
      await _mount(t, update);
      await t.tap(find.byKey(const Key('rail-settings')));
      await t.pumpAndSettle();
      await t.tap(find.text('About'));
      await t.pumpAndSettle();
      expect(find.text('Download update'), findsOneWidget);
      expect(find.text('View release'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('a newer build brings the dot back after it was seen', (t) async {
    final update = _service();
    addTearDown(update.dispose);
    await t.runAsync(update.start);
    update.markSeen();
    await _mount(t, update);
    expect(_railDotIn(find.byKey(const Key('rail-settings'))), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('no dot and no row when up to date or without a service', (
    t,
  ) async {
    final current = _service(build: 37);
    addTearDown(current.dispose);
    await t.runAsync(current.start);
    await _mount(t, current);
    expect(_railDotIn(find.byKey(const Key('rail-settings'))), findsNothing);
    await t.tap(find.byKey(const Key('rail-settings')));
    await t.pumpAndSettle();
    await t.tap(find.text('About'));
    await t.pumpAndSettle();
    expect(find.textContaining('New version available'), findsNothing);
    await t.pumpWidget(const SizedBox());

    await _mount(t, null);
    expect(_railDotIn(find.byKey(const Key('rail-settings'))), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('phone: dot on the Settings tab', (t) async {
    final update = _service();
    addTearDown(update.dispose);
    await t.runAsync(update.start);
    final (w, _) = await pageFixture(t, section: 'chat');
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: Scaffold(
          body: const SizedBox(),
          bottomNavigationBar: WorkspaceMobileTabBar(
            controller: w,
            selectedId: 'home',
            onSelected: (_) {},
            appUpdate: update,
          ),
        ),
      ),
    );
    expect(_tabAttention(t), isTrue);
    update.markSeen();
    await t.pumpAndSettle();
    expect(_tabAttention(t), isFalse);
    await t.pumpWidget(const SizedBox());
  });
}
