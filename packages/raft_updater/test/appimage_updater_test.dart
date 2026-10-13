import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_updater/raft_updater.dart';

import 'fake_release_server.dart';
import 'zsync_support.dart';

const _tag = 'v0.1.1+7';
const _artifact = 'raft-flutter-0.1.1+7-appimage-x64.AppImage';

void main() {
  late Directory directory;
  late FakeReleaseServer server;
  late File installed;
  late Uint8List oldBytes, newBytes;
  late List<String> logs;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('appimage-update');
    server = await FakeReleaseServer.start();
    final pair = fixturePair();
    oldBytes = pair.old;
    newBytes = pair.current;
    installed = File('${directory.path}/Raft.AppImage')
      ..writeAsBytesSync(oldBytes);
    await Process.run('chmod', ['0750', installed.path]);
    server.files[_artifact] = newBytes;
    server.files['$_artifact.zsync'] = makeZsync(newBytes, url: _artifact);
    logs = [];
  });

  tearDown(() async {
    await server.close();
    directory.deleteSync(recursive: true);
  });

  AppImageRelease release({String? sha256Hex, int? bytes}) => AppImageRelease(
    tag: _tag,
    artifact: _artifact,
    sha256: sha256Hex ?? sha256.convert(newBytes).toString(),
    bytes: bytes ?? newBytes.length,
  );

  AppImageUpdater updater({
    Future<void> Function()? quit,
    Map<String, String>? environment,
    int? processId,
    int rangeGap = 4096,
  }) => AppImageUpdater(
    path: installed.path,
    information: AppImageUpdateInformation.parse(
      AppImageUpdateInformation.official,
    )!,
    http: AppImageHttp((_) async => HttpClient()),
    origin: server.origin,
    environment:
        environment ??
        {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
    quit: quit ?? () async {},
    processId: processId,
    rangeGap: rangeGap,
    pieceSize: 64 * 1024,
    log: logs.add,
  );

  List<String> leftovers() => directory
      .listSync()
      .map(
        (e) => e.uri.pathSegments.last.isEmpty
            ? e.uri.pathSegments[e.uri.pathSegments.length - 2]
            : e.uri.pathSegments.last,
      )
      .where((name) => name != 'Raft.AppImage')
      .toList();

  Future<AppImageUpdateStatus> run(AppImageUpdater u, AppImageRelease r) async {
    await u.install(r);
    return u.status.value;
  }

  test('transfers only the changed blocks and replaces the file atomically', () async {
    final u = updater();
    final phases = <AppImageUpdateStage?>[];
    u.status.addListener(() => phases.add(u.status.value.stage));
    final status = await run(u, release());
    expect(
      status.phase,
      AppImageUpdatePhase.ready,
      reason: '${status.failure}',
    );
    expect(installed.readAsBytesSync(), newBytes);
    expect(leftovers(), isEmpty, reason: 'no .part, no backup');
    // Permissions of the old file survive (the AppImage must stay executable).
    expect(installed.statSync().mode & 0x1ff, 0x1e8); // 0750
    // A 1.5 MB file whose changes touch ~40 KB: well under a tenth is fetched.
    final report = u.lastReport!;
    expect(report.targetBytes, newBytes.length);
    expect(report.downloadedBytes, lessThan(newBytes.length ~/ 10));
    expect(report.downloadedBytes, server.rangeBytes);
    expect(
      report.reusedBytes + report.downloadedBytes,
      greaterThanOrEqualTo(newBytes.length),
    );
    expect(
      server.requests
          .where((r) => r.contains('/objects/') && r.contains('bytes='))
          .length,
      report.requests,
    );
    expect(
      phases,
      containsAllInOrder([
        AppImageUpdateStage.preparing,
        AppImageUpdateStage.downloading,
        AppImageUpdateStage.verifying,
        AppImageUpdateStage.installing,
      ]),
    );
    // The release asset URLs are the GitHub layout, '+' kept in the tag.
    expect(
      server.requests.first,
      startsWith('GET /kevinzhow/raft-flutter/releases/download/v0.1.1+7/'),
    );
    expect(
      server.requests.every((r) => !r.contains('releases/latest')),
      isTrue,
    );
  });

  test('a wrong SHA-256 in the manifest discards the download and keeps the old file', () async {
    final u = updater();
    final status = await run(
      u,
      release(sha256Hex: sha256.convert(oldBytes).toString()),
    );
    expect(status.phase, AppImageUpdatePhase.failed);
    expect(status.failure!.kind, AppImageUpdateFailureKind.verification);
    expect(installed.readAsBytesSync(), oldBytes);
    expect(leftovers(), isEmpty);
  });

  test(
    'a corrupted download fails the zsync SHA-1 even when the manifest matches',
    () async {
      // Serve a file whose bytes differ from what the control file describes.
      final bad = Uint8List.fromList(newBytes)..[376000] ^= 0xff;
      server.files[_artifact] = bad;
      final u = updater();
      final status = await run(u, release());
      expect(status.failure!.kind, AppImageUpdateFailureKind.verification);
      expect(installed.readAsBytesSync(), oldBytes);
      expect(leftovers(), isEmpty);
    },
  );

  test('a release without a .zsync file says so', () async {
    server.files.remove('$_artifact.zsync');
    final status = await run(updater(), release());
    expect(status.failure!.kind, AppImageUpdateFailureKind.noDeltaFile);
    expect(installed.readAsBytesSync(), oldBytes);
  });

  test(
    'a control file that does not describe the manifest release is refused',
    () async {
      final status = await run(updater(), release(bytes: newBytes.length + 1));
      expect(status.failure!.kind, AppImageUpdateFailureKind.releaseMismatch);
      server.files['$_artifact.zsync'] = makeZsync(
        newBytes,
        url: 'http://evil.example/$_artifact',
      );
      final other = await run(updater(), release());
      expect(other.failure!.kind, AppImageUpdateFailureKind.releaseMismatch);
      expect(installed.readAsBytesSync(), oldBytes);
    },
  );

  test(
    'a server that ignores Range is reported, not downloaded in full',
    () async {
      server.ignoreRange = true;
      final status = await run(updater(), release());
      expect(status.failure!.kind, AppImageUpdateFailureKind.rangesUnsupported);
      expect(installed.readAsBytesSync(), oldBytes);
      expect(leftovers(), isEmpty);
    },
  );

  test('an expired CDN link is resolved again', () async {
    server.expireLinks = 1;
    server.expireRangeLinks = 2;
    final status = await run(updater(), release());
    expect(
      status.phase,
      AppImageUpdatePhase.ready,
      reason: '${status.failure}',
    );
    expect(installed.readAsBytesSync(), newBytes);
  });

  test(
    'a connection cut mid-range resumes from the first missing byte',
    () async {
      server.dropRangeAfter = 5000;
      final status = await run(updater(), release());
      expect(
        status.phase,
        AppImageUpdatePhase.ready,
        reason: '${status.failure}',
      );
      expect(installed.readAsBytesSync(), newBytes);
    },
  );

  test('an unreachable server is a network failure naming the host', () async {
    await server.close();
    final status = await run(updater(), release());
    expect(status.failure!.kind, AppImageUpdateFailureKind.network);
    expect(status.failure!.detail, '127.0.0.1');
    expect(installed.readAsBytesSync(), oldBytes);
  });

  test('a read-only folder is reported before anything is replaced', () async {
    await Process.run('chmod', ['0555', directory.path]);
    addTearDown(() => Process.run('chmod', ['0755', directory.path]));
    if (File('${directory.path}/probe').existsSync()) return;
    // Root ignores directory permissions; the check is meaningless there.
    final probe = await Process.run('sh', [
      '-c',
      'touch "${directory.path}/probe" 2>/dev/null && rm "${directory.path}/probe" && echo writable',
    ]);
    if ('${probe.stdout}'.contains('writable')) return;
    final status = await run(updater(), release());
    expect(status.failure!.kind, AppImageUpdateFailureKind.notWritable);
    expect(installed.readAsBytesSync(), oldBytes);
  });

  test('cancel stops the update and removes the partial file', () async {
    final u = updater();
    u.status.addListener(() {
      if (u.status.value.stage == AppImageUpdateStage.downloading) u.cancel();
    });
    final status = await run(u, release());
    expect(status.failure!.kind, AppImageUpdateFailureKind.cancelled);
    expect(installed.readAsBytesSync(), oldBytes);
    expect(leftovers(), isEmpty);
  });

  test('restart waits for this process, uses the host environment and quits', () async {
    final u = updater(
      environment: {
        'PATH': '/appimage/bin:/usr/bin:/bin',
        'RAFT_APPIMAGE_HOST_PATH_SET': 'x',
        'RAFT_APPIMAGE_HOST_PATH': '/usr/bin:/bin',
        'RAFT_APPIMAGE_HOST_LD_LIBRARY_PATH_SET': '',
        'RAFT_APPIMAGE_HOST_LD_LIBRARY_PATH': '',
        'LD_LIBRARY_PATH': '/appimage/lib',
        'APPIMAGE': installed.path,
      },
    );
    expect(await u.restart(), isFalse, reason: 'nothing installed yet');
    final marker = File('${directory.path}.marker');
    addTearDown(() {
      if (marker.existsSync()) marker.deleteSync();
    });
    // The "new AppImage" records what the restarted process sees.
    var quit = 0;
    final launcher = updater(
      quit: () async => quit++,
      environment: {
        'PATH': '/appimage/bin:/usr/bin:/bin',
        'RAFT_APPIMAGE_HOST_PATH_SET': 'x',
        'RAFT_APPIMAGE_HOST_PATH': '/usr/bin:/bin',
        'RAFT_APPIMAGE_HOST_LD_LIBRARY_PATH_SET': '',
        'LD_LIBRARY_PATH': '/appimage/lib',
        'APPIMAGE': installed.path,
        'MARKER': marker.path,
      },
    );
    server.files[_artifact] = FakeReleaseServer.text(
      '#!/bin/sh\nprintf "%s|%s|%s" "\$PATH" "\${LD_LIBRARY_PATH-unset}" "\${APPIMAGE-unset}" > "\$MARKER"\n',
    );
    final script = server.files[_artifact]!;
    server.files['$_artifact.zsync'] = makeZsync(
      script,
      url: _artifact,
      blockSize: 512,
    );
    final status = await run(
      launcher,
      release(
        sha256Hex: sha256.convert(script).toString(),
        bytes: script.length,
      ),
    );
    expect(
      status.phase,
      AppImageUpdatePhase.ready,
      reason: '${status.failure}',
    );
    // The old process: still alive when restart is called, gone a moment later.
    final old = await Process.start('sleep', ['1']);
    final waiting = updater(
      quit: () async => quit++,
      processId: old.pid,
      environment: {
        'PATH': '/appimage/bin:/usr/bin:/bin',
        'RAFT_APPIMAGE_HOST_PATH_SET': 'x',
        'RAFT_APPIMAGE_HOST_PATH': '/usr/bin:/bin',
        'RAFT_APPIMAGE_HOST_LD_LIBRARY_PATH_SET': '',
        'LD_LIBRARY_PATH': '/appimage/lib',
        'APPIMAGE': installed.path,
        'MARKER': marker.path,
      },
    );
    await waiting.install(
      release(
        sha256Hex: sha256.convert(script).toString(),
        bytes: script.length,
      ),
    );
    expect(await waiting.restart(), isTrue);
    expect(quit, 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      marker.existsSync(),
      isFalse,
      reason: 'must wait for the old process to exit',
    );
    for (var i = 0; i < 100 && !marker.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(marker.readAsStringSync(), '/usr/bin:/bin|unset|unset');
  });

  test('restart keeps --appimage-extract-and-run for an AppImage started without FUSE', () async {
    final marker = File('${directory.path}.args');
    addTearDown(() {
      if (marker.existsSync()) marker.deleteSync();
    });
    final script = FakeReleaseServer.text(
      '#!/bin/sh\nprintf "%s" "\$*" > "\$MARKER"\n',
    );
    server.files[_artifact] = script;
    server.files['$_artifact.zsync'] = makeZsync(
      script,
      url: _artifact,
      blockSize: 512,
    );
    Future<String> restartedArguments(String appDir) async {
      if (marker.existsSync()) marker.deleteSync();
      installed.writeAsBytesSync(oldBytes);
      final old = await Process.start('true', const []);
      await old.exitCode;
      final u = updater(
        processId: old.pid,
        environment: {
          'PATH': '/usr/bin:/bin',
          'APPDIR': appDir,
          'MARKER': marker.path,
        },
      );
      await u.install(
        release(
          sha256Hex: sha256.convert(script).toString(),
          bytes: script.length,
        ),
      );
      expect(
        u.status.value.phase,
        AppImageUpdatePhase.ready,
        reason: '${u.status.value.failure}',
      );
      expect(await u.restart(), isTrue);
      for (var i = 0; i < 100 && !marker.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return marker.readAsStringSync();
    }

    expect(await restartedArguments('/tmp/.mount_RaftXyz'), '');
    expect(
      await restartedArguments('/tmp/appimage_extracted_0123abcd'),
      '--appimage-extract-and-run',
    );
  });
}
