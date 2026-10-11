import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Windows host facts; policy and message authority remain in the client.
class WindowsNotifications {
  WindowsNotifications({
    MethodChannel? channel,
    this.lab = const bool.fromEnvironment('RAFT_WINDOWS_NOTIFICATION_LAB'),
  }) : channel =
           channel ?? const MethodChannel('app.raft/windows-notifications');

  final MethodChannel channel;
  final bool lab;
  static const appId = 'app.raft.raft_flutter';
  static const activationGuid = 'b951813c-37ff-5d5c-95ac-f9573572c87c';
  static const labAppId = 'app.raft.raft_flutter.notificationlab';
  static const labActivationGuid = 'c7f8c268-2e7c-5079-9305-1a7294c70d9d';
  void Function(String)? onTap;

  Future<void> initialize() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'activated' && call.arguments is String) {
        receiveLink(Uri.tryParse(call.arguments as String));
      }
    });
    await channel.invokeMethod<void>('configureSdk', {
      'appId': lab ? labAppId : appId,
      'guid': lab ? labActivationGuid : activationGuid,
    });
    final pending = await channel.invokeListMethod<String>('takeActivations');
    for (final value in pending ?? const <String>[]) {
      receiveLink(Uri.tryParse(value));
    }
  }

  bool receiveLink(Uri? uri) {
    if (uri == null ||
        uri.scheme != (lab ? 'raft-notification-lab' : 'raft-notification') ||
        uri.host != 'open' ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.toString().length > 16384) {
      return false;
    }
    final payloads = uri.queryParametersAll['payload'];
    if (payloads?.length != 1 || payloads!.single.length > 4096) {
      return false;
    }
    onTap?.call(payloads.single);
    return true;
  }

  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    if (payload.length > 4096) {
      throw ArgumentError('Notification target too long');
    }
    final uri = Uri(
      scheme: lab ? 'raft-notification-lab' : 'raft-notification',
      host: 'open',
      queryParameters: {'payload': payload},
    );
    await channel.invokeMethod<void>('show', {
      'id': id,
      'title': title,
      'body': body,
      'uri': uri.toString(),
    });
  }

  Future<void> cancelAll() => channel.invokeMethod<void>('cancelAll');

  Future<WindowsInitializationSettings> prepare() async {
    final icon = await channel.invokeMethod<String>('configure', {
      'appId': lab ? labAppId : appId,
      'guid': lab ? labActivationGuid : activationGuid,
    });
    return WindowsInitializationSettings(
      appName: lab ? 'Raft notification lab' : 'Raft',
      appUserModelId: lab ? labAppId : appId,
      guid: lab ? labActivationGuid : activationGuid,
      iconPath: icon,
    );
  }

  Future<bool> permitted() async =>
      await channel.invokeMethod<bool>('permission', lab ? labAppId : appId) ??
      false;

  Future<void> present() => channel.invokeMethod<void>('present');
}
