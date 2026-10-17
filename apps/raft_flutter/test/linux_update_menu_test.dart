import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/main.dart';
import 'package:raft_flutter/platform/app_services.dart';
import 'package:raft_flutter/platform/app_update.dart';
import 'package:raft_flutter/platform/local_network_access.dart';
import 'package:raft_flutter/platform/linux_application_menu.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_updater/raft_updater.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_global_server_selector_test.dart' show RootCache, RootContent;
import 'support/memory_storage.dart';

const _menu = MethodChannel('app.raft/linux-menu');
Future<List<InternetAddress>> _addresses(String _) async => [
  InternetAddress('203.0.113.1'),
];
Future<Object?> _request(WidgetTester t) async {
  final response = Completer<Object?>();
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    _menu.name,
    const StandardMethodCodec().encodeMethodCall(
      const MethodCall('checkForUpdates'),
    ),
    (data) {
      try {
        response.complete(
          data == null
              ? null
              : const StandardMethodCodec().decodeEnvelope(data),
        );
      } catch (error, stack) {
        response.completeError(error, stack);
      }
    },
  );
  return response.future;
}

Future<void> _flush(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

String _manifest() => jsonEncode([
  {
    'platform': 'appimage',
    'arch': 'x64',
    'version': '0.1.0',
    'buildNumber': '10',
    'releaseTag': 'v0.1.0+10',
    'artifact': 'raft-0.1.0+10.AppImage',
  },
]);

void main() {
  tearDownAll(
    () => (AppUpdater.instance.availability as ChangeNotifier).dispose(),
  );
  testWidgets('Linux menu checks updates before sign-in without a workspace', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues({
      'raft.mode': 'light',
      'raft.light': 'elegant',
    });
    var requests = 0;
    final response = Completer<String>();
    final update = AppUpdateService(
      currentVersion: '0.1.0',
      currentBuild: 10,
      platformKey: 'appimage-x64',
      storage: MemoryStorage(),
      scheduleTimer: false,
      fetch: (_) {
        requests++;
        return response.future;
      },
    );
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _menu,
      (_) async => null,
    );
    try {
      await t.pumpWidget(
        RaftApp(
          sessionStore: MemorySessionStore(),
          services: AppServices.withUpdates(
            update,
            localNetwork: const LocalNetworkAccess(lookup: _addresses),
          ),
          nativeContent: RootContent(),
          nativeSharing: NativeSharing(),
          openWorkspaceCache: () async => RootCache(),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      unawaited(_request(t));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(
        requests,
        1,
        reason: 'Native menu must reach the existing updater before sign-in',
      );
      expect(find.text('Checking for updates…'), findsOneWidget);
      response.complete(
        jsonEncode([
          {
            'platform': 'appimage',
            'arch': 'x64',
            'version': '0.1.0',
            'buildNumber': '10',
            'releaseTag': 'v0.1.0+10',
            'artifact': 'raft-0.1.0+10.AppImage',
          },
        ]),
      );
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.text("You're on the latest version"), findsOneWidget);
      expect(find.text('Checking for updates…'), findsNothing);
    } finally {
      if (!response.isCompleted) response.complete('[]');
      await t.pumpWidget(const SizedBox.shrink());
      await _flush(t);
      update.dispose();
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(_menu, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
  for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
    testWidgets(
      '$family Linux check failure clears after retry and reopen; draft survives',
      (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        var requests = 0;
        final update = AppUpdateService(
          currentVersion: '0.1.0',
          currentBuild: 10,
          platformKey: 'appimage-x64',
          storage: MemoryStorage(),
          scheduleTimer: false,
          fetch: (_) async {
            if (++requests == 1) throw const SocketException('Fixture offline');
            return _manifest();
          },
        );
        final navigator = GlobalKey<NavigatorState>();
        final draft = TextEditingController();
        final states = <Map>[];
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(_menu, (
          call,
        ) async {
          states.add(call.arguments as Map);
          return null;
        });
        try {
          await t.pumpWidget(
            MaterialApp(
              navigatorKey: navigator,
              theme: raftTheme(family),
              builder: (context, child) => LinuxApplicationMenu(
                navigatorKey: navigator,
                appUpdate: update,
                child: child!,
              ),
              home: Scaffold(body: TextField(controller: draft)),
            ),
          );
          await t.enterText(
            find.byType(TextField),
            'Keep the signed-out draft',
          );
          unawaited(_request(t));
          await _flush(t);
          expect(find.text("Couldn't check for updates"), findsOneWidget);
          expect(states.last['ready'], isFalse);
          final duplicate = _request(t);
          await _flush(t);
          expect(await duplicate, isFalse);
          expect(requests, 1);
          await t.tap(
            find.byKey(const ValueKey('settings-about-update-check')),
          );
          await _flush(t);
          expect(find.text("You're on the latest version"), findsOneWidget);
          expect(find.text("Couldn't check for updates"), findsNothing);
          expect(draft.text, 'Keep the signed-out draft');
          await t.tap(find.byType(RaftCloseButton));
          await _flush(t);
          expect(states.last['ready'], isTrue);
          unawaited(_request(t));
          await _flush(t);
          expect(requests, 3);
          expect(find.text("You're on the latest version"), findsOneWidget);
          expect(find.text("Couldn't check for updates"), findsNothing);
          expect(draft.text, 'Keep the signed-out draft');
        } finally {
          navigator.currentState?.popUntil((r) => r.isFirst);
          await _flush(t);
          await t.pumpWidget(const SizedBox.shrink());
          await _flush(t);
          draft.dispose();
          update.dispose();
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            _menu,
            null,
          );
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  for (final throws in [false, true]) {
    testWidgets('Linux unsupported package download retry; throws=$throws', (
      t,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final navigator = GlobalKey<NavigatorState>();
      var opens = 0;
      final urls = <Uri>[];
      final updater = AppUpdater(
        platform: TargetPlatform.linux,
        openUrl: (url) async {
          urls.add(url);
          if (++opens == 1) {
            if (throws) throw PlatformException(code: 'browser-unavailable');
            return false;
          }
          return true;
        },
      );
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _menu,
        (_) async => null,
      );
      try {
        await t.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: raftTheme(RaftFamily.elegant),
            builder: (context, child) => LinuxApplicationMenu(
              navigatorKey: navigator,
              appUpdate: null,
              updater: updater,
              child: child!,
            ),
            home: const Scaffold(body: Text('Signed out')),
          ),
        );
        final response = _request(t);
        await _flush(t);
        expect(find.byType(RaftAlertDialog), findsOneWidget);
        expect(opens, 1);
        await t.tap(
          find.byWidgetPredicate(
            (w) => w is RaftButton && w.label == 'Try again',
          ),
        );
        await _flush(t);
        expect(await response, isTrue);
        expect(opens, 2);
        expect(urls, [AppUpdater.releasePage, AppUpdater.releasePage]);
        expect(find.byType(RaftAlertDialog), findsNothing);
        expect(find.text('Signed out'), findsOneWidget);
      } finally {
        navigator.currentState?.popUntil((r) => r.isFirst);
        await _flush(t);
        await t.pumpWidget(const SizedBox.shrink());
        await _flush(t);
        (updater.availability as ChangeNotifier).dispose();
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(_menu, null);
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
