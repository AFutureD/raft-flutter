import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/notification_settings_view.dart';
import 'package:raft_flutter/platform/native_notifications.dart';

import 'native_notifications_test.dart' show deferredMacNotifications;

class Adapter implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  FutureOr<Map<String, dynamic>> Function(RequestOptions)? settings;
  int status = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async {
    calls.add(o);
    final data = o.path == '/auth/login'
        ? {
            'accessToken': 'fixture',
            'refreshToken': 'fixture',
            'user': {'id': 'alice'},
          }
        : await settings!(o);
    return ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class Service extends NativeNotificationService {
  Service({TargetPlatform platform = TargetPlatform.android})
    : super(platform: platform) {
    available = true;
  }
  int enables = 0, tests = 0, settings = 0;
  String? testTitle, testBody;
  bool testResult = true, grant = true;
  Completer<void>? gate;
  @override
  Future<void> requestEnable(bool next) async {
    enables++;
    await (gate?.future ?? Future<void>.value());
    enabled = next && grant;
    permitted = grant;
    permissionPromptSkipped = !grant;
    notifyListeners();
  }

  @override
  Future<bool> test({String? title, String? body}) async {
    tests++;
    testTitle = title;
    testBody = body;
    return testResult;
  }

  @override
  Future<void> openSettings() async {
    settings++;
  }
}

Future<(WorkspaceController, Adapter, Service)> fixture() async {
  final a = Adapter();
  final c = RaftClient(
    origin: 'https://example.invalid',
    sessionStore: MemorySessionStore(),
    transport: Dio()..httpClientAdapter = a,
  );
  await c.login('fixture', 'fixture');
  c.selectServer('s1');
  final w = WorkspaceController(c);
  w.server = RaftRecord({'id': 's1', 'name': 'Fixture', 'role': 'guest'});
  w.servers = [w.server!];
  a.settings = (_) => {'serverPushMuted': false, 'prefsVersion': 1};
  return (w, a, Service());
}

Widget host(
  WorkspaceController w,
  NativeNotificationService s, {
  bool dark = false,
  RaftFamily family = RaftFamily.elegant,
  Locale? locale,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('en'), Locale('zh')],
  theme: raftTheme(family, dark: dark),
  home: Scaffold(
    body: SingleChildScrollView(
      child: NotificationSettingsView(controller: w, service: s),
    ),
  ),
);
RaftNotificationSettingsCard card(WidgetTester t) =>
    t.widget(find.byType(RaftNotificationSettingsCard));
Future<void> drain(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 350));
}

void main() {
  for (final theme in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    testWidgets('member mute real checkbox/keyboard/save $theme', (t) async {
      final f = (await t.runAsync(fixture))!;
      final (w, a, s) = f;
      addTearDown(w.dispose);
      addTearDown(s.dispose);
      await t.pumpWidget(host(w, s, family: theme.$1, dark: theme.$2));
      await t.pumpAndSettle();
      expect(card(t).onSave, isNull);
      expect(card(t).muted, isFalse);
      await t.tap(find.byType(RaftCheckbox));
      await drain(t);
      expect(card(t).onSave, isNotNull);
      a.settings = (o) {
        expect(o.method, 'PATCH');
        expect(o.data, {'serverPushMuted': true});
        return {'serverPushMuted': true, 'prefsVersion': 2};
      };
      await t.ensureVisible(
        find.byKey(const ValueKey('notification-settings-save')),
      );
      await t.tap(find.byKey(const ValueKey('notification-settings-save')));
      await t.pumpAndSettle();
      expect(w.server!.json['serverPushMuted'], true);
      expect(card(t).onSave, isNull);
      expect(
        find.text('Notifications from Fixture are muted.'),
        findsOneWidget,
      );
      expect(a.calls.where((o) => o.method == 'PATCH').length, 1);
      // Keyboard traversal uses the actual recipe controls, not direct callbacks.
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await drain(t);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
    'server projection seeds the first frame; channel switches keep it without reloading',
    (t) async {
      final (w, a, s) = (await t.runAsync(fixture))!;
      addTearDown(w.dispose);
      addTearDown(s.dispose);
      w.server = RaftRecord({
        ...w.server!.json,
        'serverPushMuted': true,
        'notificationPrefsVersion': 4,
      });
      w.channel = RaftChannel({'id': 'c1', 'name': 'design', 'joined': true});
      final gate = Completer<Map<String, dynamic>>();
      a.settings = (_) => gate.future;
      await t.pumpWidget(host(w, s));
      // First frame: final value, editable, no loading state.
      expect(card(t).muted, true);
      expect(card(t).status, isNot('Checking…'));
      expect(card(t).onMutedChanged, isNotNull);
      int reads() => a.calls
          .where((o) => o.path.endsWith('/notification-settings'))
          .length;
      final before = reads();
      for (var i = 0; i < 3; i++) {
        w.channel = RaftChannel({'id': 'c$i', 'name': 'c$i', 'joined': true});
        w.channelGeneration++;
        w.threadGeneration++;
        w.notifyListeners();
        await t.pump();
        expect(card(t).muted, true, reason: 'switch $i');
        expect(card(t).status, isNot('Checking…'), reason: 'switch $i');
      }
      expect(reads(), before);
      gate.complete({'serverPushMuted': true, 'prefsVersion': 4});
      await t.pumpAndSettle();
      expect(card(t).muted, true);
      // An identity change still clears before the new read lands.
      w.server = RaftRecord({'id': 's1', 'name': 'Fixture', 'role': 'member'});
      final next = Completer<Map<String, dynamic>>();
      a.settings = (_) => next.future;
      w.notifyListeners();
      await t.pump();
      expect(card(t).muted, false);
      expect(card(t).onMutedChanged, isNull);
      next.complete({'serverPushMuted': false, 'prefsVersion': 1});
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('late GET cannot undo accepted newer realtime preference', (
    t,
  ) async {
    final (w, a, s) = (await t.runAsync(fixture))!;
    addTearDown(w.dispose);
    addTearDown(s.dispose);
    final gate = Completer<Map<String, dynamic>>();
    a.settings = (_) => gate.future;
    await t.pumpWidget(host(w, s));
    await t.pump();
    w.server = RaftRecord({
      ...w.server!.json,
      'serverPushMuted': true,
      'notificationPrefsVersion': 8,
    });
    w.notifyListeners();
    await t.pump();
    expect(card(t).muted, true);
    gate.complete({'serverPushMuted': false, 'prefsVersion': 3});
    await t.pumpAndSettle();
    expect(card(t).muted, true);
    expect(w.server!.json['notificationPrefsVersion'], 8);
  });
  testWidgets(
    'scope retirement rejects old PATCH and immediately clears checkbox',
    (t) async {
      final (w, a, s) = (await t.runAsync(fixture))!;
      addTearDown(w.dispose);
      addTearDown(s.dispose);
      await t.pumpWidget(host(w, s));
      await t.pumpAndSettle();
      await t.tap(find.byType(RaftCheckbox));
      await drain(t);
      final gate = Completer<Map<String, dynamic>>();
      a.settings = (_) => gate.future;
      await t.tap(find.byKey(const ValueKey('notification-settings-save')));
      await t.pump();
      w.server = null;
      w.notifyListeners();
      await t.pump();
      expect(card(t).muteDescription, isNull);
      expect(card(t).muted, false);
      gate.complete({'serverPushMuted': true, 'prefsVersion': 9});
      await t.pumpAndSettle();
      expect(w.server, isNull);
      expect(card(t).message, isNull);
    },
  );
  testWidgets(
    'GET failure retries and PATCH 403 retires verified mutation admission',
    (t) async {
      final (w, a, s) = (await t.runAsync(fixture))!;
      addTearDown(w.dispose);
      addTearDown(s.dispose);
      a.status = 503;
      a.settings = (_) => {'error': 'unavailable'};
      await t.pumpWidget(host(w, s));
      await t.pumpAndSettle();
      expect(card(t).onMutedChanged, isNull);
      expect(find.text('Retry'), findsOneWidget);
      a.status = 200;
      a.settings = (_) => {'serverPushMuted': false, 'prefsVersion': 1};
      await t.tap(find.text('Retry'));
      await t.pumpAndSettle();
      await t.tap(find.byType(RaftCheckbox));
      await drain(t);
      a.status = 403;
      a.settings = (_) => {'error': 'revoked'};
      await t.tap(find.byKey(const ValueKey('notification-settings-save')));
      await t.pumpAndSettle();
      expect(card(t).onSave, isNull);
      expect(card(t).onMutedChanged, isNull);
      expect(
        find.text('Failed to update server notification setting.'),
        findsOneWidget,
      );
    },
  );
  testWidgets('phone: enable requests the permission once, then sends a test', (
    t,
  ) async {
    final (w, a, s) = (await t.runAsync(fixture))!;
    addTearDown(w.dispose);
    addTearDown(s.dispose);
    await t.pumpWidget(host(w, s));
    await t.pumpAndSettle();
    expect(card(t).title, 'Phone notifications');
    expect(card(t).status, 'Not enabled');
    expect(card(t).actionLabel, 'Enable notifications');
    expect(card(t).hint, contains('on Android, Settings → Apps → Raft'));
    expect(card(t).hint, isNot(contains('iOS')));
    s.gate = Completer<void>();
    await t.tap(find.text('Enable notifications'));
    await t.pump();
    expect(s.enables, 1);
    expect(card(t).onAction, isNull);
    expect(card(t).onMutedChanged, isNull);
    s.gate!.complete();
    await t.pumpAndSettle();
    expect(s.settings, 0);
    expect(card(t).status, 'Enabled');
    expect(card(t).actionLabel, 'Send test notification');
    await t.tap(find.text('Send test notification'));
    await t.pumpAndSettle();
    expect(s.tests, 1);
    expect(card(t).message, contains('Test notification sent'));
    expect(card(t).error, isNull);
  });
  testWidgets(
    'phone: a permission the system stops asking about opens settings',
    (t) async {
      final (w, a, s) = (await t.runAsync(fixture))!;
      addTearDown(w.dispose);
      addTearDown(s.dispose);
      s.grant = false;
      await t.pumpWidget(host(w, s));
      await t.pumpAndSettle();
      await t.tap(find.text('Enable notifications'));
      await t.pumpAndSettle();
      expect(s.enables, 1);
      expect(s.settings, 1);
      expect(card(t).status, 'Not enabled');
      expect(card(t).actionLabel, 'Enable notifications');
    },
  );
  testWidgets('phone: a prompt the person declined does not open settings', (
    t,
  ) async {
    final (w, a, s) = (await t.runAsync(fixture))!;
    addTearDown(w.dispose);
    addTearDown(s.dispose);
    s.grant = false;
    await t.pumpWidget(host(w, s));
    await t.pumpAndSettle();
    s.permissionPromptSkipped = false;
    // Requested a prompt (answered "deny"): requestEnable leaves the flag unset.
    final declining = _Declining();
    addTearDown(declining.dispose);
    await t.pumpWidget(host(w, declining));
    await t.pumpAndSettle();
    await t.tap(find.text('Enable notifications'));
    await t.pumpAndSettle();
    expect(declining.settings, 0);
  });
  testWidgets('phone: iOS shows only the iOS path; zh copy and pill', (
    t,
  ) async {
    final (w, a, unused) = (await t.runAsync(fixture))!;
    final s = Service(platform: TargetPlatform.iOS)..enabled = true;
    addTearDown(w.dispose);
    addTearDown(s.dispose);
    addTearDown(unused.dispose);
    await t.pumpWidget(host(w, s, locale: const Locale('zh')));
    await t.pumpAndSettle();
    expect(find.text('手机通知'), findsOneWidget);
    expect(find.text('已开启'), findsOneWidget);
    expect(find.textContaining('iOS 在“设置 → 通知 → Raft”'), findsOneWidget);
    expect(find.textContaining('Android'), findsNothing);
    expect(find.text('发一条测试通知'), findsOneWidget);
    s.enabled = false;
    s.notifyListeners();
    await t.pump();
    expect(find.text('未开启'), findsOneWidget);
    expect(find.text('开启通知'), findsOneWidget);
  });
  testWidgets('phone: unavailable disables the action and says why', (t) async {
    final (w, a, s) = (await t.runAsync(fixture))!;
    addTearDown(w.dispose);
    addTearDown(s.dispose);
    s.available = false;
    s.initialized = true;
    await t.pumpWidget(host(w, s));
    await t.pumpAndSettle();
    expect(card(t).status, 'Unavailable');
    expect(
      card(t).hint,
      'System notifications are unavailable on this device.',
    );
    expect(card(t).onAction, isNull);
  });
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
  ]) {
    testWidgets('desktop $platform: Web card, no server read, one test', (
      t,
    ) async {
      final (w, a, unused) = (await t.runAsync(fixture))!;
      final s = Service(platform: platform);
      addTearDown(w.dispose);
      addTearDown(s.dispose);
      addTearDown(unused.dispose);
      await t.pumpWidget(host(w, s));
      // First frame is final: no checking state, no server read, no mute form.
      expect(card(t).status, 'Managed by the system');
      expect(card(t).title, 'Desktop notifications');
      expect(card(t).description, startsWith('Raft Desktop shows system'));
      expect(card(t).muteDescription, isNull);
      expect(card(t).actionLabel, 'Send a test notification');
      expect(
        card(t).hint,
        contains(switch (platform) {
          TargetPlatform.macOS =>
            'macOS → System Settings → Notifications → Raft.',
          TargetPlatform.windows =>
            'Windows → Settings → System → Notifications.',
          _ => "Linux → your desktop environment's notification settings.",
        }),
      );
      expect(card(t).hint, isNot(contains('Raft Desktop.')));
      if (platform == TargetPlatform.windows) {
        expect(card(t).hint, isNot(contains('ask for permission')));
        expect(card(t).hint, contains('directly to the notification center'));
      }
      await t.pumpAndSettle();
      expect(
        a.calls.where((o) => o.path.contains('notification-settings')),
        isEmpty,
      );
      await t.tap(find.text('Send a test notification'));
      await t.pumpAndSettle();
      expect(s.tests, 1);
      expect(s.enables, 0);
      expect(s.testTitle, 'Raft Desktop');
      expect(
        s.testBody,
        'Test notification — desktop notifications are working.',
      );
      expect(
        card(t).message,
        startsWith('Test notification posted to the system.'),
      );
      expect(card(t).error, isNull);
      s.testResult = false;
      await t.tap(find.text('Send a test notification'));
      await t.pumpAndSettle();
      expect(card(t).message, isNull);
      expect(card(t).error, 'Could not post a test notification.');
      if (platform == TargetPlatform.windows) {
        await t.tap(find.text('Open notification settings'));
        await t.pumpAndSettle();
        expect(s.settings, 1);
        expect(s.enables, 0);
      }
    });
  }
  testWidgets(
    'macOS deferred authorization keeps the desktop action usable and requests permission on test',
    (t) async {
      final (w, a, unused) = (await t.runAsync(fixture))!;
      final (service, plugin, mac) = deferredMacNotifications();
      addTearDown(w.dispose);
      addTearDown(unused.dispose);
      addTearDown(service.dispose);
      await service.bind('alice');
      await t.pumpWidget(host(w, service, locale: const Locale('zh')));
      expect(find.text('此桌面版本无法显示系统通知。'), findsNothing);
      expect(card(t).title, 'Desktop notifications');
      expect(card(t).muteDescription, isNull);
      expect(card(t).onAction, isNotNull);
      expect(mac.requests, 0);
      await t.tap(find.text('发一条测试通知'));
      await t.pumpAndSettle();
      expect(mac.requests, 1);
      expect(service.enabled, true);
      expect(plugin.sent, ['raft-notification-test']);
      expect(
        a.calls.where((call) => call.path.contains('notification-settings')),
        isEmpty,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('desktop: unavailable build shows Web unavailable copy', (
    t,
  ) async {
    final (w, a, unused) = (await t.runAsync(fixture))!;
    final s = Service(platform: TargetPlatform.linux)
      ..available = false
      ..initialized = true;
    addTearDown(w.dispose);
    addTearDown(s.dispose);
    addTearDown(unused.dispose);
    await t.pumpWidget(host(w, s, locale: const Locale('zh')));
    expect(find.text('不可用'), findsOneWidget);
    expect(find.text('此桌面版本无法显示系统通知。'), findsOneWidget);
    expect(card(t).onAction, isNull);
  });
  testWidgets(
    'same-principal replacement controller rejects retired pending GET',
    (t) async {
      final (old, a, s) = (await t.runAsync(fixture))!;
      final (next, b, unused) = (await t.runAsync(fixture))!;
      addTearDown(old.dispose);
      addTearDown(next.dispose);
      addTearDown(s.dispose);
      addTearDown(unused.dispose);
      final gate = Completer<Map<String, dynamic>>();
      a.settings = (_) => gate.future;
      await t.pumpWidget(host(old, s));
      await t.pump();
      b.settings = (_) => {'serverPushMuted': false, 'prefsVersion': 4};
      await t.pumpWidget(host(next, s));
      await t.pumpAndSettle();
      expect(card(t).muted, false);
      expect(next.server!.json['notificationPrefsVersion'], 4);
      gate.complete({'serverPushMuted': true, 'prefsVersion': 20});
      await t.pumpAndSettle();
      expect(card(t).muted, false);
      expect(next.server!.json['notificationPrefsVersion'], 4);
    },
  );
}

class _Declining extends Service {
  @override
  Future<void> requestEnable(bool next) async {
    enables++;
    permitted = false;
    permissionPromptSkipped = false;
    notifyListeners();
  }
}
