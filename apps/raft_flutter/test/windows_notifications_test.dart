import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/native_notifications.dart';
import 'package:raft_flutter/platform/content_coordinator.dart';
import 'package:raft_flutter/platform/windows_notifications.dart';

import 'native_notifications_test.dart' show NotificationPluginFixture;

class WindowsHostFixture extends WindowsNotifications {
  bool allowed = true, fail = false;
  int reads = 0, presentations = 0;
  Completer<bool>? permission;
  int initializations = 0;
  String? coldPayload;
  final sent = <String>[];
  @override
  Future<void> initialize() async {
    initializations++;
    if (coldPayload != null) onTap?.call(coldPayload!);
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async => sent.add(payload);
  @override
  Future<void> cancelAll() async => sent.clear();
  @override
  Future<bool> permitted() async {
    reads++;
    if (fail) throw StateError('Notifier unavailable');
    return permission?.future ?? allowed;
  }

  @override
  Future<void> present() async {
    presentations++;
  }
}

class _NoDesktopOptIn extends NotificationPreferenceStore {
  @override
  Future<bool?> read(String key) => throw StateError('Windows follows the OS');
  @override
  Future<bool> write(String key, bool value) =>
      throw StateError('No private opt-in');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NotificationPluginFixture plugin;
  late WindowsHostFixture windows;
  late NativeNotificationService service;
  setUp(() {
    plugin = NotificationPluginFixture()..initialized.complete(true);
    windows = WindowsHostFixture();
    service = NativeNotificationService(
      plugin: plugin,
      windows: windows,
      platform: TargetPlatform.windows,
      preferences: _NoDesktopOptIn(),
    );
  });
  tearDown(() => service.dispose());

  test('Windows initializes stable identity and icon, follows OS without mobile opt-in', () async {
    await service.bind('alice');
    expect(windows.initializations, 1);
    expect(plugin.settings, isNull);
    expect(service.enabled, true);
    expect(service.canOpenSettings, true);
    // Desktop notifications have a single owner: the accepted Activity inbox.
    expect(service.receivesMessages, false);
    await service.show(title: 'Raft', body: 'DM', payload: 'target');
    expect(windows.sent, ['target']);

    await service.bind(null);
    expect(windows.sent, isEmpty);
    expect(service.enabled, false);
  });

  test('OS block suppresses both message and test; a later grant restores delivery', () async {
    windows.allowed = false;
    await service.bind('alice');
    expect(service.available, true);
    expect(service.enabled, false);
    expect(await service.test(), false);
    expect(windows.sent, isEmpty);
    windows.allowed = true;
    await service.refreshPermission();
    expect(service.enabled, true);
    await service.show(title: 'Raft', body: 'DM', payload: 'granted');
    expect(windows.sent, ['granted']);
    windows.allowed = false;
    await service.show(title: 'Raft', body: 'DM', payload: 'revoked');
    expect(windows.sent, ['granted']);
    expect(service.error, contains('system settings'));
  });

  test('permission failure fails closed; foreground queue and account fence suppress private alerts', () async {
    await service.bind('alice');
    service.deliveryAllowed = () => false;
    await service.show(title: 'Raft', body: 'DM', payload: 'foreground');
    expect(windows.sent, isEmpty);
    service.deliveryAllowed = () => true;
    windows.permission = Completer<bool>();
    final queued = service.show(
      title: 'Raft',
      body: 'private',
      payload: 'old-account',
    );
    await Future<void>.delayed(Duration.zero);
    final logout = service.bind(null);
    windows.permission!.complete(true);
    await Future.wait([queued, logout]);
    expect(windows.sent, isEmpty);
    windows.permission = null;
    await service.bind('bob');
    windows.fail = true;
    await service.show(title: 'Raft', body: 'DM', payload: 'unavailable');
    expect(service.enabled, false);
    expect(windows.sent, isEmpty);
  });

  test(
    'warm callback and cold launch payload reach the same authorization owner',
    () async {
      final taps = <String>[];
      service.onTap = taps.add;
      windows.coldPayload = 'cold-target';
      await service.initialize();
      windows.onTap!('warm-target');
      expect(taps, ['cold-target', 'warm-target']);
      await service.presentWindow();
      expect(windows.presentations, 1);
    },
  );

  test(
    'cold protocol argument is handled after the SDK callback is ready',
    () async {
      final coordinator = NativeContentCoordinator(
        notifications: service,
        links: const Stream.empty(),
      );
      await coordinator.init(
        initialArguments: [
          Uri(
            scheme: 'raft-notification',
            host: 'open',
            queryParameters: {'payload': 'raft-notification-test'},
          ).toString(),
        ],
      );
      expect(windows.presentations, 1);
      await coordinator.dispose();
    },
  );

  test('lab uses a separate Windows identity and native registration receives the same GUID', () async {
    const channel = MethodChannel('fixture/windows-notifications');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'configure' ? 'C:/fixture/raft.ico' : true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final host = WindowsNotifications(channel: channel, lab: true);
    final settings = await host.prepare();
    expect(settings.appUserModelId, WindowsNotifications.labAppId);
    expect(settings.guid, WindowsNotifications.labActivationGuid);
    expect(calls.single.arguments, {
      'appId': settings.appUserModelId,
      'guid': settings.guid,
    });
    expect(await host.permitted(), true);
    expect(calls.last.arguments, WindowsNotifications.labAppId);
  });

  test('SDK protocol transport preserves payload and rejects ambiguous activation links', () async {
    const channel = MethodChannel('fixture/windows-sdk');
    final calls = <MethodCall>[];
    final taps = <String>[];
    final payload = jsonEncode({
      'principal': 'alice',
      'uri': 'raft://v1/a?x=中文&y="quoted"',
    });
    final link = Uri(
      scheme: 'raft-notification',
      host: 'open',
      queryParameters: {'payload': payload},
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'takeActivations' ? [link.toString()] : null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final host = WindowsNotifications(channel: channel)..onTap = taps.add;
    await host.initialize();
    expect(taps, [payload]);
    // ShellExecute normalizes an authority with an empty path to '/'.
    expect(host.receiveLink(link.replace(path: '/')), true);
    expect(taps, [payload, payload]);
    await host.show(id: 7, title: 'Raft <&>', body: '中文', payload: payload);
    expect(Uri.parse((calls.last.arguments as Map)['uri'] as String), link);
    expect(calls.first.method, 'configureSdk');
    expect(
      host.receiveLink(Uri.parse('raft-notification://other?payload=test')),
      false,
    );
    expect(
      host.receiveLink(
        Uri.parse('raft-notification://open?payload=a&payload=b'),
      ),
      false,
    );
    expect(
      host.receiveLink(Uri.parse('raft-notification-lab://open?payload=test')),
      false,
    );
    for (final value in [
      'raft-notification://open/other?payload=test',
      'raft-notification://open:123?payload=test',
      'raft-notification://user@open?payload=test',
      'raft-notification://open?payload=test#extra',
    ]) {
      expect(host.receiveLink(Uri.parse(value)), false);
    }
    expect(
      host.receiveLink(
        Uri(
          scheme: 'raft-notification',
          host: 'open',
          queryParameters: {'payload': 'x' * 4097},
        ),
      ),
      false,
    );
    expect(taps, [payload, payload]);
  });
}
