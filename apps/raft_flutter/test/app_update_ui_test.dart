import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_flutter/data/search_memory.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/mobile_workspace_navigation.dart';
import 'package:raft_flutter/features/workspace_settings.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_flutter/platform/app_update.dart';
import 'package:raft_flutter/platform/client_release_notes.dart';
import 'package:raft_ui/raft_ui.dart';

import 'app_global_server_selector_test.dart' show RootFixture;
import 'workspace_source_location_contract_test.dart' show pageFixture, frames;
import 'flutter_test_config.dart' show leakDebt;

class _Memory implements SearchMemoryStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

ClientReleaseNotes _notes(String text) => ClientReleaseNotes(
  storage: _Memory(),
  fetch: (_) async => jsonEncode({
    'items': [
      {
        'releaseId': 'v0.1.0+7',
        'tag': 'v0.1.0+7',
        'version': '0.1.0',
        'date': '2026-10-14',
        'state': 'published',
        'entries': [
          {'type': 'feature', 'text': text, 'emphasis': false},
        ],
      },
    ],
    'nextCursor': null,
  }),
);

AppUpdateService _service({
  int build = 20,
  String platform = 'macos-arm64',
  bool withNotes = false,
}) => AppUpdateService(
  currentVersion: '0.1.0',
  currentBuild: build,
  platformKey: platform,
  storage: _Memory(),
  scheduleTimer: false,
  releaseNotes: withNotes ? _notes('Fork guard notes') : null,
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

Future<WorkspaceController> _mount(
  WidgetTester t,
  AppUpdateService? update, {
  double width = 1280,
  RaftFamily family = RaftFamily.elegant,
  bool dark = false,
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
      theme: raftTheme(family, dark: dark),
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
  return w;
}

/// Both layouts of the one real host: the desktop shell and the phone shell
/// (a page stack of mirror controllers, see mobile_workspace_route.dart). A
/// service the phone pages do not receive makes a feature vanish without any
/// error, so every host-level test below runs on both.
const _widths = [1280.0, 390.0];
bool _phone(double width) => width < 768;
String _on(double width) => _phone(width) ? 'phone' : 'desktop';

/// Opens the Settings destination: the rail on desktop, the tab bar on phone.
Future<void> _openSettings(
  WidgetTester t,
  WorkspaceController w,
  double width,
) async {
  if (_phone(width)) {
    // The tab bar only shows on a tab root; start from the Settings root.
    w.navigation.navigate(RaftLocation.parse('/s/demo/settings'));
    w.notifyListeners();
  } else {
    await t.tap(find.byKey(const Key('rail-settings')));
  }
  await t.pumpAndSettle();
}

/// The attention dot on the entry to Settings: the rail icon or the tab.
bool _entryDot(WidgetTester t, double width) => _phone(width)
    ? _tabAttention(t)
    : _railDotIn(find.byKey(const Key('rail-settings'))).evaluate().isNotEmpty;

Future<void> _openDestination(WidgetTester t, String id) async {
  await t.tap(find.byKey(ValueKey('workspace-settings-nav-$id')));
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  await t.pumpAndSettle();
}

Finder _dotIn(Finder of) =>
    find.descendant(of: of, matching: find.byType(RaftAttentionDot));
Finder _railDotIn(Finder of) =>
    find.descendant(of: of, matching: find.byType(RaftRailAttention));

/// Fills of the decorated boxes painted below [of] (recipe boxes wrap theirs
/// in a layered decoration).
List<Color> _fills(Finder of) => [
  for (final e
      in find
          .descendant(of: of, matching: find.byType(DecoratedBox))
          .evaluate())
    ?switch ((e.widget as DecoratedBox).decoration) {
      final BoxDecoration d => d.color,
      final RaftLayeredDecoration d => d.base.color,
      _ => null,
    },
];

/// The dot below [of] is painted with the theme's `--danger` token, never the
/// regular attention fill.
void _expectDanger(WidgetTester t, Finder of) {
  final tokens = RaftTokens.of(t.element(of.first));
  expect(tokens.colors['danger'], tokens.semantic.danger);
  expect(_fills(of), contains(tokens.semantic.danger));
  expect(_fills(of), isNot(contains(tokens.accentFill)));
}

bool _tabAttention(WidgetTester t) => t
    .widget<RaftMobileNav>(find.byKey(const Key('workspace-mobile-navigation')))
    .items
    .firstWhere((i) => i.id == 'settings')
    .attention;

void main() {
  // Leak debt (other): see docs/development.md, Leak tracking.
  leakDebt(const ['ValueNotifier<bool>']);
  for (final width in _widths) {
    testWidgets(
      '${_on(width)}: dot on Settings and About until About is opened',
      (t) async {
        final update = _service();
        addTearDown(update.dispose);
        await t.runAsync(update.start);
        final w = await _mount(t, update, width: width);
        if (!_phone(width)) expect(_entryDot(t, width), isTrue);

        await _openSettings(t, w, width);
        expect(_entryDot(t, width), isTrue);
        final about = find.byType(RaftSettingsSidebarList);
        expect(find.text('About'), findsOneWidget);
        expect(_dotIn(about), findsOneWidget);
        _expectDanger(t, _dotIn(about));
        // Opening Settings alone does not mark the release as seen.
        expect(update.hasUnseen, isTrue);

        await _openDestination(t, 'about');
        expect(find.text('New version available: 0.1.0 (37)'), findsOneWidget);
        _expectDanger(
          t,
          _dotIn(find.byKey(const ValueKey('settings-about-update'))),
        );
        expect(
          find.byKey(const ValueKey('settings-about-update-action')),
          findsOneWidget,
        );
        expect(find.text('View release'), findsOneWidget);
        expect(update.hasUnseen, isFalse);
        if (_phone(width)) {
          // The covered list rebuilds when it comes back to the front.
          await t.pageBack();
          await t.pumpAndSettle();
        }
        expect(_entryDot(t, width), isFalse);
        expect(_dotIn(find.byType(RaftSettingsSidebarList)), findsNothing);
        if (!_phone(width)) {
          // The row stays so the user can still act on it.
          expect(find.text('New version available: 0.1.0 (37)'), findsOne);
        }
        await t.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({TargetPlatform.macOS}),
    );

    testWidgets('${_on(width)}: Android offers the APK download', (t) async {
      final update = _service(platform: 'android-arm64');
      addTearDown(update.dispose);
      await t.runAsync(update.start);
      final w = await _mount(t, update, width: width);
      await _openSettings(t, w, width);
      await _openDestination(t, 'about');
      expect(find.text('Download update'), findsOneWidget);
      expect(find.text('View release'), findsNothing);
      await t.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant({TargetPlatform.android}));

    testWidgets('${_on(width)}: a newer build brings the dot back after it '
        'was seen', (t) async {
      final update = _service();
      addTearDown(update.dispose);
      await t.runAsync(update.start);
      update.markSeen();
      final w = await _mount(t, update, width: width);
      await _openSettings(t, w, width);
      expect(_entryDot(t, width), isFalse);
      expect(_dotIn(find.byType(RaftSettingsSidebarList)), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('${_on(width)}: no dot and no row when up to date or without '
        'a service', (t) async {
      final current = _service(build: 37);
      addTearDown(current.dispose);
      await t.runAsync(current.start);
      var w = await _mount(t, current, width: width);
      await _openSettings(t, w, width);
      expect(_entryDot(t, width), isFalse);
      await _openDestination(t, 'about');
      expect(find.textContaining('New version available'), findsNothing);
      // Up to date is still answered: the Updates card never goes away.
      expect(find.text("You're on the latest version"), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-about-update-check')),
        findsOne,
      );
      await t.pumpWidget(const SizedBox());

      w = await _mount(t, null, width: width);
      await _openSettings(t, w, width);
      expect(_entryDot(t, width), isFalse);
      await _openDestination(t, 'about');
      expect(find.byKey(const ValueKey('settings-about-update')), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('${_on(width)}: Release Notes load from the update service '
        'source', (t) async {
      final update = _service(withNotes: true);
      addTearDown(update.dispose);
      await t.runAsync(update.start);
      final w = await _mount(t, update, width: width);
      await _openSettings(t, w, width);
      await _openDestination(t, 'release-notes');
      expect(find.text('Fork guard notes'), findsOneWidget);
      expect(
        find.text('Release notes are unavailable right now.'),
        findsNothing,
      );
      await t.pumpWidget(const SizedBox());
    });
  }

  for (final width in _widths) {
    for (final (name, family, dark) in [
      ('brutal light', RaftFamily.brutal, false),
      ('elegant light', RaftFamily.elegant, false),
      ('elegant dark', RaftFamily.elegant, true),
    ]) {
      testWidgets(
        '${_on(width)}: About row dot is the danger token, the entry keeps '
        'its colour in $name',
        (t) async {
          final update = _service();
          addTearDown(update.dispose);
          await t.runAsync(update.start);
          final w = await _mount(
            t,
            update,
            width: width,
            family: family,
            dark: dark,
          );
          if (!_phone(width)) {
            final settings = find.byKey(const Key('rail-settings'));
            // The rail keeps the theme's own attention colour, not the red.
            final rail = find.descendant(
              of: settings,
              matching: find.byKey(const ValueKey('rail-attention-indicator')),
            );
            expect(rail, findsOneWidget);
            expect(
              _fills(rail),
              isNot(contains(RaftTokens.of(t.element(rail)).semantic.danger)),
            );
          }
          await _openSettings(t, w, width);
          expect(_entryDot(t, width), isTrue);
          _expectDanger(t, _dotIn(find.byType(RaftSettingsSidebarList)));
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final (name, family, dark) in [
    ('brutal light', RaftFamily.brutal, false),
    ('elegant light', RaftFamily.elegant, false),
    ('elegant dark', RaftFamily.elegant, true),
  ]) {
    testWidgets('phone: Settings tab dot keeps the attention colour in $name', (
      t,
    ) async {
      final update = _service();
      addTearDown(update.dispose);
      await t.runAsync(update.start);
      final (w, _) = await pageFixture(t, section: 'chat');
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(family, dark: dark),
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
      final tokens = RaftTokens.of(
        t.element(find.byType(WorkspaceMobileTabBar)),
      );
      final tab = find.byKey(const Key('mobile-tab-settings'));
      expect(
        _fills(tab),
        contains(
          tokens.brutal
              ? tokens.colors['color-brutal-pink']
              : tokens.accentFill,
        ),
      );
      expect(_fills(tab), isNot(contains(tokens.semantic.danger)));
      update.markSeen();
      await t.pumpAndSettle();
      expect(_tabAttention(t), isFalse);
      await t.pumpWidget(const SizedBox());
    });
  }
  // The phone shell renders every page inside _MobileWorkspaceContent, a
  // WorkspaceView built from the host's fields; the update service has to be
  // carried across or About loses the Updates card and Release Notes loses its
  // source (v0.1.0+7 on Android showed neither).
  group('phone (actual RaftApp, 390 wide, Android)', () {
    AppUpdateService android() => AppUpdateService(
      currentVersion: '0.1.0',
      currentBuild: 41,
      platformKey: 'android-arm64',
      target: TargetPlatform.android,
      storage: _Memory(),
      scheduleTimer: false,
      releaseNotes: _notes('Phone notes arrive'),
      fetch: (_) async => jsonEncode([
        {
          'platform': 'android',
          'arch': 'arm64',
          'version': '0.1.0',
          'buildNumber': '42',
          'releaseTag': 'v0.1.0+8',
          'artifact': 'raft-flutter-0.1.0+8-android-arm64.apk',
        },
      ]),
    );

    Future<RootFixture> openSettings(WidgetTester t, AppUpdateService s) async {
      final f = RootFixture();
      await f.mount(
        t,
        'elegant-light',
        390,
        uri: Uri.parse('/s/alpha'),
        appUpdate: s,
      );
      await t.runAsync(s.start);
      await t.tap(find.byKey(const Key('mobile-tab-settings')));
      await f.flush(t);
      return f;
    }

    testWidgets('About shows the Updates card and the red dots', (t) async {
      final update = android();
      addTearDown(update.dispose);
      final f = await openSettings(t, update);
      expect(_tabAttention(t), isTrue);
      await t.tap(find.byKey(const ValueKey('workspace-settings-nav-about')));
      await f.flush(t);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const ValueKey('settings-about-update')),
        findsOneWidget,
      );
      expect(find.text('New version available: 0.1.0 (42)'), findsOneWidget);
      expect(find.text('Download update'), findsOneWidget);
      expect(find.text('Check for updates'), findsOneWidget);
      await f.close(t);
    });

    testWidgets('Release Notes load from the update service source', (t) async {
      final update = android();
      addTearDown(update.dispose);
      final f = await openSettings(t, update);
      await t.tap(
        find.byKey(const ValueKey('workspace-settings-nav-release-notes')),
      );
      await f.flush(t);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Phone notes arrive'), findsOneWidget);
      expect(
        find.text('Release notes are unavailable right now.'),
        findsNothing,
      );
      await f.close(t);
    });
  });

  test('About shows the running version with its CI build number', () {
    expect(
      WorkspaceAboutSection.versionLabel(version: '0.1.0', build: '41'),
      '0.1.0 (41)',
    );
    expect(
      WorkspaceAboutSection.versionLabel(version: '0.1.0-dev.abc', build: ''),
      '0.1.0-dev.abc',
    );
    expect(
      WorkspaceAboutSection.versionLabel(version: 'development', build: '0'),
      'development',
    );
  });
}
