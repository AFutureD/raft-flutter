import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/search_memory.dart';
import 'package:raft_flutter/platform/app_update.dart';

class _Memory implements SearchMemoryStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Map<String, Object?> _row({
  String platform = 'android',
  String arch = 'arm64',
  Object? build = '37',
  String version = '0.1.0',
  String tag = 'v0.1.0+5',
  String artifact = 'raft-flutter-0.1.0+5-android-arm64.apk',
}) => {
  'platform': platform,
  'arch': arch,
  'version': version,
  'buildNumber': build,
  'releaseTag': tag,
  'commit': 'abc',
  'artifact': artifact,
  'sha256': 'x',
  'bytes': 1,
};

String _manifest([List<Object?>? rows]) => jsonEncode(rows ?? [_row()]);

void main() {
  group('parseBuildManifest', () {
    test('reads the array entry for the platform', () {
      final release = parseBuildManifest(_manifest(), 'android-arm64')!;
      expect(release.version, '0.1.0');
      expect(release.buildNumber, 37);
      expect(release.releaseTag, 'v0.1.0+5');
      expect(release.artifact, 'raft-flutter-0.1.0+5-android-arm64.apk');
      expect(
        release.releasePage.toString(),
        'https://github.com/kevinzhow/raft-flutter/releases/tag/v0.1.0+5',
      );
      expect(
        release.downloadUrl.toString(),
        'https://github.com/kevinzhow/raft-flutter/releases/download/v0.1.0+5/'
        'raft-flutter-0.1.0+5-android-arm64.apk',
      );
    });

    test('accepts numeric build numbers and a single object', () {
      expect(
        parseBuildManifest(
          jsonEncode(_row(build: 41)),
          'android-arm64',
        )!.buildNumber,
        41,
      );
    });

    test('takes the highest build and ignores other platforms', () {
      final release = parseBuildManifest(
        _manifest([
          _row(build: '30'),
          _row(platform: 'macos', arch: 'arm64', build: '99'),
          _row(build: '38'),
        ]),
        'android-arm64',
      )!;
      expect(release.buildNumber, 38);
      expect(parseBuildManifest(_manifest(), 'windows-x64'), isNull);
    });

    test('rejects missing, malformed and unsafe fields', () {
      for (final bad in [
        _row(build: null),
        _row(build: 'abc'),
        _row(build: '0'),
        _row(version: ''),
        _row(tag: 'nightly'),
        _row(tag: 'v1/../x'),
        _row(artifact: 'a/b.apk'),
        _row(artifact: ''),
      ]) {
        expect(
          parseBuildManifest(_manifest([bad]), 'android-arm64'),
          isNull,
          reason: '$bad',
        );
      }
      final noArtifact = _row()..remove('artifact');
      expect(
        parseBuildManifest(_manifest([noArtifact]), 'android-arm64'),
        isNull,
      );
    });

    test('bad JSON and wrong shapes are null', () {
      for (final body in [
        '',
        'not json',
        '{',
        '[1, "a", null]',
        'null',
        '"x"',
      ]) {
        expect(parseBuildManifest(body, 'android-arm64'), isNull, reason: body);
      }
    });
  });

  group('appUpdatePlatformKey', () {
    test('maps the distributed platforms', () {
      String? key(TargetPlatform p, [Map<String, String> env = const {}]) =>
          appUpdatePlatformKey(web: false, target: p, environment: env);
      expect(key(TargetPlatform.android), 'android-arm64');
      expect(key(TargetPlatform.macOS), 'macos-arm64');
      expect(key(TargetPlatform.windows), 'windows-x64');
      expect(
        key(TargetPlatform.linux, {'APPIMAGE': '/x.AppImage'}),
        'appimage-x64',
      );
    });

    test('skips iOS, web and Linux outside an AppImage', () {
      expect(
        appUpdatePlatformKey(web: false, target: TargetPlatform.iOS),
        isNull,
      );
      expect(
        appUpdatePlatformKey(web: true, target: TargetPlatform.android),
        isNull,
      );
      expect(
        appUpdatePlatformKey(
          web: false,
          target: TargetPlatform.linux,
          environment: {},
        ),
        isNull,
      );
      expect(
        appUpdatePlatformKey(
          web: false,
          target: TargetPlatform.linux,
          environment: {'APPIMAGE': ''},
        ),
        isNull,
      );
    });
  });

  group('AppUpdateService', () {
    late _Memory storage;
    late DateTime now;
    late List<Uri> requests;
    late List<String> logs;
    Future<String?> Function(Uri) fetcher = (_) async => _manifest();

    AppUpdateService make({
      String version = '0.1.0',
      int? build = 20,
      String? platform = 'android-arm64',
    }) => AppUpdateService(
      currentVersion: version,
      currentBuild: build,
      platformKey: platform,
      fetch: (url) {
        requests.add(url);
        return fetcher(url);
      },
      storage: storage,
      clock: () => now,
      scheduleTimer: false,
      log: logs.add,
    );

    setUp(() {
      storage = _Memory();
      now = DateTime(2026, 10, 13, 9);
      requests = [];
      logs = [];
      fetcher = (_) async => _manifest();
    });

    test('newer remote build is available and unseen', () async {
      final service = make();
      await service.start();
      expect(
        requests.single.toString(),
        'https://github.com/kevinzhow/raft-flutter/releases/latest/download/'
        'build-manifest-android-arm64.json',
      );
      expect(service.available!.buildNumber, 37);
      expect(service.hasUnseen, isTrue);
    });

    test('same or older remote build is not an update', () async {
      for (final build in [37, 38, 2037]) {
        final service = make(build: build);
        await service.start();
        expect(service.available, isNull, reason: '$build');
        expect(service.hasUnseen, isFalse);
      }
    });

    test('markSeen clears the dot until a newer build arrives', () async {
      final service = make();
      await service.start();
      var notified = 0;
      service.addListener(() => notified++);
      service.markSeen();
      expect(service.hasUnseen, isFalse);
      expect(service.available, isNotNull);
      expect(notified, 1);
      service.markSeen();
      expect(notified, 1);

      now = now.add(const Duration(hours: 7));
      fetcher = (_) async => _manifest([_row(build: '38', tag: 'v0.1.0+6')]);
      await service.checkIfDue();
      expect(service.available!.buildNumber, 38);
      expect(service.hasUnseen, isTrue);
    });

    test('seen state and last release survive a restart', () async {
      final first = make();
      await first.start();
      first.markSeen();
      await Future<void>.delayed(Duration.zero);

      fetcher = (_) async => throw StateError('offline');
      requests.clear();
      final second = make();
      await second.start();
      // Within 6 h: no request, remembered release, still seen.
      expect(requests, isEmpty);
      expect(second.available!.buildNumber, 37);
      expect(second.hasUnseen, isFalse);
    });

    test('throttles to one request per interval', () async {
      final service = make();
      await service.start();
      await service.checkIfDue();
      now = now.add(const Duration(hours: 5, minutes: 59));
      await service.checkIfDue();
      expect(requests, hasLength(1));
      now = now.add(const Duration(minutes: 2));
      await service.checkIfDue();
      expect(requests, hasLength(2));
    });

    test('a clock set back counts as due', () async {
      final service = make();
      await service.start();
      now = now.subtract(const Duration(days: 1));
      await service.checkIfDue();
      expect(requests, hasLength(2));
    });

    test('skip rules make no request', () async {
      for (final service in [
        make(version: '0.1.0-dev.abc1234'),
        make(version: '0.1.0-dev.abc1234.dirty'),
        make(build: null),
        make(build: 0),
        make(version: ''),
        make(platform: null),
      ]) {
        await service.start();
        await service.checkIfDue();
        expect(service.enabled, isFalse);
        expect(service.available, isNull);
        expect(service.hasUnseen, isFalse);
      }
      expect(requests, isEmpty);
    });

    test('forThisBuild without defines is disabled', () {
      final service = AppUpdateService.forThisBuild(
        platformKey: 'android-arm64',
        fetch: (_) async => _manifest(),
        storage: storage,
      );
      expect(service.enabled, isFalse);
    });

    test('failures are silent, logged once, and retried sooner', () async {
      fetcher = (_) async => throw StateError('offline');
      final service = make();
      var notified = 0;
      service.addListener(() => notified++);
      await service.start();
      expect(service.available, isNull);
      expect(service.hasUnseen, isFalse);
      expect(notified, 0);
      expect(logs, hasLength(1));

      now = now.add(const Duration(minutes: 10));
      await service.checkIfDue();
      expect(requests, hasLength(1));
      now = now.add(const Duration(minutes: 21));
      await service.checkIfDue();
      expect(requests, hasLength(2));
      expect(logs, hasLength(1), reason: 'logged once per run');

      fetcher = (_) async => _manifest();
      now = now.add(const Duration(minutes: 31));
      await service.checkIfDue();
      expect(service.hasUnseen, isTrue);
    });

    test('404 and unusable manifests keep what was known', () async {
      final service = make();
      await service.start();
      for (final body in [
        null,
        'garbage',
        _manifest([_row(build: 'x')]),
      ]) {
        now = now.add(const Duration(hours: 7));
        fetcher = (_) async => body;
        await service.checkIfDue();
        expect(service.available!.buildNumber, 37);
      }
      expect(logs, isEmpty);
    });

    test('corrupt stored state behaves like a first run', () async {
      storage.values[AppUpdateService.storageKey] = '{broken';
      final service = make();
      await service.start();
      expect(service.hasUnseen, isTrue);
    });
  });
}
