import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/native_notifications.dart';

import 'native_notifications_test.dart'
    show NotificationPluginFixture, MacPermissionFixture;

class Store extends NotificationPreferenceStore {
  final values = <String, bool>{};
  bool writeFails = false;
  Completer<bool?>? readGate;
  @override
  Future<bool?> read(String key) async =>
      readGate == null ? values[key] : readGate!.future;
  @override
  Future<bool> write(String key, bool value) async {
    if (writeFails) return false;
    values[key] = value;
    return true;
  }
}

void main() {
  NativeNotificationService service(
    Store store,
    MacPermissionFixture permission,
  ) {
    final plugin = NotificationPluginFixture()..mac = permission;
    plugin.initialized.complete(false);
    final s = NativeNotificationService(
      platform: TargetPlatform.macOS,
      plugin: plugin,
      preferences: store,
    );
    addTearDown(s.dispose);
    return s;
  }

  test(
    'failed marker persistence does not ask or silently lose its error',
    () async {
      final store = Store()..writeFails = true;
      final permission = MacPermissionFixture();
      final s = service(store, permission);
      await s.bindAuthenticatedWorkspace('alice');
      await s.requestEnable(true);
      expect(permission.requests, 0);
      expect(s.enabled, isFalse);
      expect(s.error, contains('saved'));
      expect(store.values, isEmpty);
    },
  );
  test(
    'logout while reading the marker cancels before the system request',
    () async {
      final store = Store()..readGate = Completer<bool?>();
      final permission = MacPermissionFixture();
      final s = service(store, permission);
      final entering = s.bindAuthenticatedWorkspace('alice');
      await Future<void>.delayed(Duration.zero);
      await s.bindAuthenticatedWorkspace(null);
      store.readGate!.complete(null);
      await entering;
      expect(permission.requests, 0);
      expect(store.values, isEmpty);
      store.readGate = null;
      await s.bindAuthenticatedWorkspace('bob');
      await s.requestEnable(true);
      expect(permission.requests, 1);
      expect(s.enabled, isTrue);
    },
  );
  test(
    'concurrent workspace changes share one pending device prompt',
    () async {
      final store = Store();
      final permission = MacPermissionFixture()..prompt = Completer<bool?>();
      final s = service(store, permission);
      await s.bindAuthenticatedWorkspace('alice');
      final alice = s.requestEnable(true);
      await Future<void>.delayed(Duration.zero);
      await s.bindAuthenticatedWorkspace('bob');
      final bob = s.requestEnable(true);
      await Future<void>.delayed(Duration.zero);
      expect(permission.requests, 1);
      expect(store.values.values.single, isTrue);
      permission.prompt!.complete(true);
      await Future.wait([alice, bob]);
      expect(permission.requests, 1);
      expect(s.enabled, isTrue);
    },
  );
}
