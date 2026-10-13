import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/search_memory.dart';
import 'package:raft_flutter/features/workspace_settings.dart';
import 'package:raft_flutter/platform/app_update.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_updater/raft_updater.dart';

import 'workspace_source_location_contract_test.dart' show pageFixture;

class _Memory implements SearchMemoryStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// An [AppUpdater] whose native side is replaced by a scripted outcome.
class _FakeUpdater implements AppUpdater {
  _FakeUpdater({bool available = true, this.outcome = AppUpdateOutcome.started})
    : _availability = ValueNotifier<bool>(available);

  final ValueNotifier<bool> _availability;
  AppUpdateOutcome outcome;
  int calls = 0;

  @override
  bool get available => _availability.value;
  @override
  ValueListenable<bool> get availability => _availability;
  @override
  String? get unavailableReason => null;
  @override
  String get feedUrl => '';

  @override
  Future<AppUpdateOutcome> checkAndInstall() async {
    calls++;
    return outcome;
  }
}

AppUpdateService _service(String platform) => AppUpdateService(
  currentVersion: '0.1.0',
  currentBuild: 20,
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

Future<List<String>> _mount(
  WidgetTester t,
  AppUpdateService service,
  AppUpdater? updater,
  TargetPlatform platform,
) async {
  final launched = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/url_launcher'),
    (call) async {
      if (call.method == 'launch') {
        launched.add((call.arguments as Map)['url'] as String);
      }
      return true;
    },
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    ),
  );
  final (w, _) = await pageFixture(t, section: 'chat');
  t.view.physicalSize = const Size(1000, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.runAsync(service.start);
  await t.pumpWidget(
    MaterialApp(
      theme: raftTheme(
        RaftFamily.elegant,
        dark: false,
      ).copyWith(platform: platform),
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkspaceAboutSection(
            controller: w,
            appUpdate: service,
            updater: updater,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return launched;
}

final _action = find.byKey(const ValueKey('settings-about-update-action'));

void main() {
  for (final (platform, key) in [
    (TargetPlatform.macOS, 'macos-arm64'),
    (TargetPlatform.windows, 'windows-x64'),
  ]) {
    group('$platform with an in-place updater', () {
      testWidgets('reads Update now and starts the native updater', (t) async {
        final service = _service(key);
        addTearDown(service.dispose);
        final updater = _FakeUpdater();
        final launched = await _mount(t, service, updater, platform);
        expect(find.text('Update now'), findsOneWidget);
        expect(find.text('View release'), findsNothing);
        await t.tap(_action);
        await t.pumpAndSettle();
        expect(updater.calls, 1);
        // Sparkle/WinSparkle show their own dialog: nothing else opens.
        expect(launched, isEmpty);
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('openedReleasePage is not opened a second time', (t) async {
        final service = _service(key);
        addTearDown(service.dispose);
        final updater = _FakeUpdater(
          outcome: AppUpdateOutcome.openedReleasePage,
        );
        final launched = await _mount(t, service, updater, platform);
        await t.tap(_action);
        await t.pumpAndSettle();
        expect(updater.calls, 1);
        expect(launched, isEmpty);
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('failed falls back to the release page', (t) async {
        final service = _service(key);
        addTearDown(service.dispose);
        final updater = _FakeUpdater(outcome: AppUpdateOutcome.failed);
        final launched = await _mount(t, service, updater, platform);
        await t.tap(_action);
        await t.pumpAndSettle();
        expect(updater.calls, 1);
        expect(launched, [
          'https://github.com/kevinzhow/raft-flutter/releases/tag/v0.1.0+5',
        ]);
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('falls back to View release once updating is disabled', (
        t,
      ) async {
        final service = _service(key);
        addTearDown(service.dispose);
        final updater = _FakeUpdater();
        await _mount(t, service, updater, platform);
        expect(find.text('Update now'), findsOneWidget);
        updater._availability.value = false;
        await t.pumpAndSettle();
        expect(find.text('Update now'), findsNothing);
        expect(find.text('View release'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      });
    });

    testWidgets('$platform without an in-place updater keeps View release', (
      t,
    ) async {
      final service = _service(key);
      addTearDown(service.dispose);
      final updater = _FakeUpdater(available: false);
      final launched = await _mount(t, service, updater, platform);
      expect(find.text('View release'), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
      await t.tap(_action);
      await t.pumpAndSettle();
      expect(updater.calls, 0);
      expect(launched, [
        'https://github.com/kevinzhow/raft-flutter/releases/tag/v0.1.0+5',
      ]);
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Android ignores the updater and downloads the APK', (t) async {
    final service = _service('android-arm64');
    addTearDown(service.dispose);
    final updater = _FakeUpdater();
    final launched = await _mount(t, service, updater, TargetPlatform.android);
    expect(find.text('Download update'), findsOneWidget);
    expect(find.text('Update now'), findsNothing);
    await t.tap(_action);
    await t.pumpAndSettle();
    expect(updater.calls, 0);
    expect(launched, [
      'https://github.com/kevinzhow/raft-flutter/releases/download/v0.1.0+5/raft-flutter-0.1.0+5-android-arm64.zip',
    ]);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Linux AppImage ignores the updater and views the release', (
    t,
  ) async {
    final service = _service('appimage-x64');
    addTearDown(service.dispose);
    final updater = _FakeUpdater();
    final launched = await _mount(t, service, updater, TargetPlatform.linux);
    expect(find.text('View release'), findsOneWidget);
    expect(find.text('Update now'), findsNothing);
    await t.tap(_action);
    await t.pumpAndSettle();
    expect(updater.calls, 0);
    expect(launched, [
      'https://github.com/kevinzhow/raft-flutter/releases/tag/v0.1.0+5',
    ]);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('no card without a newer release, even when updatable', (
    t,
  ) async {
    final service = AppUpdateService(
      currentVersion: '0.1.0',
      currentBuild: 99,
      platformKey: 'macos-arm64',
      storage: _Memory(),
      scheduleTimer: false,
      fetch: (_) async => '[]',
    );
    addTearDown(service.dispose);
    await _mount(t, service, _FakeUpdater(), TargetPlatform.macOS);
    expect(find.text('Update now'), findsNothing);
    expect(_action, findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
