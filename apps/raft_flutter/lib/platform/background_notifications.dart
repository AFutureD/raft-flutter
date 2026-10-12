import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:raft_client/raft_client.dart';
import 'package:workmanager/workmanager.dart';

import 'auth_audit_log.dart';
import 'background_inbox.dart';
import 'content_coordinator.dart';
import 'content_target.dart';
import 'session_owner.dart';
import 'system_proxy_bootstrap.dart';
import 'session_store.dart';

export 'session_owner.dart';

bool get mobileBackgroundSupported => Platform.isAndroid || Platform.isIOS;

@pragma('vm:entry-point')
void backgroundNotificationDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  Workmanager().executeTask((task, _) async {
    if (task != backgroundInboxTask && task != Workmanager.iOSBackgroundTask) {
      return true;
    }
    return runBackgroundInbox();
  });
}

Future<bool> runBackgroundInbox() async {
  final started = DateTime.now();
  final mode = IsolateNameServer.lookupPortByName(sessionOwnerName) == null
      ? 'headless'
      : 'existing-session-owner';
  var success = false;
  try {
    return success = await _runBackgroundInbox();
  } finally {
    try {
      await BackgroundInboxStore().recordWake(mode, started, success);
    } catch (_) {}
  }
}

/// A worker is a guest of the session. It never waits for, takes from or
/// outlives a foreground: a live owner polls for it, a live guest makes it
/// skip this wake, and it stops at once when preempted.
Future<bool> _runBackgroundInbox({
  Duration busyBudget = const Duration(seconds: 8),
}) async {
  final waitedSince = DateTime.now();
  RaftClient? client;
  Timer? budget;
  var preempted = false;
  GuestSessionStore? guestStore;
  final owner = NativeSessionOwner(
    onPreempt: () async {
      preempted = true;
      // Stop in-flight requests first; then fence and drain credential writes.
      client?.http.close(force: true);
      await guestStore?.preempt();
    },
  );
  try {
    while (true) {
      final (probe, polled) = await NativeSessionOwner.probe();
      if (probe == OwnerProbe.delegated) return polled;
      if (probe == OwnerProbe.none && owner.registerGuest()) break;
      // Another guest is mid-run (or registered between probe and register).
      // This wake is a guest: wait a little for it, then try the next period.
      if (DateTime.now().difference(waitedSince) > busyBudget) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    guestStore = GuestSessionStore(SecureSessionStore());
    if (preempted) return true;
    final store = BackgroundInboxStore(),
        scope = await BackgroundInboxStore().scope();
    if (scope == null || !await store.enabled(scope)) return true;
    final fields = scope.split('\n');
    if (fields.length != 3 ||
        !ContentTarget.validId(fields[1]) ||
        !ContentTarget.validId(fields[2])) {
      return true;
    }
    final origin = Uri.tryParse(fields[0]);
    if (origin == null ||
        !['https', 'http'].contains(origin.scheme) ||
        origin.userInfo.isNotEmpty ||
        origin.host.isEmpty ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        origin.query.isNotEmpty ||
        origin.fragment.isNotEmpty) {
      return true;
    }
    final plugin = FlutterLocalNotificationsPlugin();
    if (await plugin.initialize(settings: notificationInitialization) != true ||
        !await notificationPermission(plugin)) {
      return true;
    }
    if (preempted) return true;
    // This isolate has its own proxy state. The platform bridge is not
    // registered in a worker engine, so the saved manual / direct choice and
    // the environment apply here; the OS proxy is the foreground's.
    await startSystemProxy(origins: [fields[0]]);
    if (preempted) return true;
    client = RaftClient(
      origin: fields[0],
      sessionStore: guestStore,
      clientKind: 'mobile',
      // A guest never signs the account out: if the server rejects the
      // credentials it just stops, and the foreground meets the same
      // rejection with the user in front of it (and the right message).
      allowSessionEnd: false,
      auditSink: AuthAuditLog.shared,
      recoveryBackoff: const [],
    );
    client.http.options.connectTimeout = const Duration(seconds: 3);
    client.http.options.receiveTimeout = const Duration(seconds: 5);
    // BGAppRefresh has a short OS budget. Closing transport stops in-flight
    // requests before ownership is released; no abandoned refresh can persist.
    budget = Timer(
      const Duration(seconds: 20),
      () => client?.http.close(force: true),
    );
    if (!await client.restore() ||
        preempted ||
        client.restoredOffline ||
        client.user?.id != fields[1]) {
      return true;
    }
    client.selectServer(fields[2]);
    return await BackgroundInboxPoller(
      client: client,
      store: store,
      authorize: (target, valid) async {
        final server = await NativeContentCoordinator.authorizeClient(
          client!,
          target,
          valid,
        );
        if (server.flag('serverPushMuted')) {
          throw const RaftApiException('Notifications are muted.');
        }
      },
      deliver: (alert, selected) async {
        if (preempted ||
            await store.scope() != selected ||
            !await store.enabled(selected) ||
            !await notificationPermission(plugin)) {
          return false;
        }
        await plugin.show(
          id: messageNotificationId(selected, alert.target.messageId!),
          title: alert.title,
          body: alert.body,
          payload: notificationPayload(client!, alert.target),
          notificationDetails: notificationDetails,
        );
        return true;
      },
    ).run();
  } catch (_) {
    return false;
  } finally {
    budget?.cancel();
    try {
      await client?.dispose();
    } finally {
      owner.release();
    }
  }
}

const notificationInitialization = InitializationSettings(
  android: AndroidInitializationSettings('ic_notification'),
  iOS: DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  ),
  macOS: DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
    defaultPresentBadge: false,
  ),
  linux: LinuxInitializationSettings(defaultActionName: 'Open Raft'),
);
const notificationDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'raft_messages_v1',
    'Raft messages',
    channelDescription: 'Direct messages, mentions and followed conversations.',
    icon: 'ic_notification',
    importance: Importance.high,
    priority: Priority.high,
    visibility: NotificationVisibility.private,
  ),
  iOS: DarwinNotificationDetails(),
  macOS: DarwinNotificationDetails(),
  linux: LinuxNotificationDetails(),
  windows: WindowsNotificationDetails(),
);
Future<bool> notificationPermission(
  FlutterLocalNotificationsPlugin plugin,
) async {
  if (Platform.isAndroid) {
    return await plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.areNotificationsEnabled() ??
        false;
  }
  if (Platform.isIOS) {
    return (await plugin
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >()
                ?.checkPermissions())
            ?.isEnabled ??
        false;
  }
  return true;
}

String notificationPayload(RaftClient client, ContentTarget target) =>
    jsonEncode({
      'origin': client.origin,
      'principal': client.user!.id,
      'serverId': target.serverId,
      'uri': target.nativeUri(target.serverId!).toString(),
    });

class BackgroundNotificationScheduler {
  final store = BackgroundInboxStore();
  Future<void> _tail = Future.value();
  Future<void>? _initializing;
  String? _boundScope;
  bool? _boundEnabled;
  Future<void> initialize() async {
    if (!mobileBackgroundSupported) return;
    await (_initializing ??= Workmanager()
        .initialize(backgroundNotificationDispatcher)
        .catchError((Object e, StackTrace stack) {
          _initializing = null;
          Error.throwWithStackTrace(e, stack);
        }));
  }

  Future<void> get settled => _tail;
  Future<void> bind(String? scope, bool enabled) {
    if (!mobileBackgroundSupported) return Future.value();
    _tail = _tail.catchError((Object _) {}).then((_) async {
      if (_boundScope == scope && _boundEnabled == enabled) return;
      if (!enabled || scope == null) {
        await store.select(null);
        await initialize();
        await Workmanager().cancelByUniqueName(backgroundInboxTask);
        if (scope != null) await store.forget(scope);
        _boundScope = scope;
        _boundEnabled = enabled;
        return;
      }
      await store.activate(scope);
      await store.select(scope);
      await initialize();
      await Workmanager().registerPeriodicTask(
        backgroundInboxTask,
        backgroundInboxTask,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
      );
      _boundScope = scope;
      _boundEnabled = enabled;
    });
    return _tail;
  }
}
