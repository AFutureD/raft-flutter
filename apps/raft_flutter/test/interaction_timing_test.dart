import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/interaction_timing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.raft/interaction');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });
  test(
    'macOS reads system setting asynchronously with safe fallback',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final held = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) {
        expect(call.method, 'doubleClickInterval');
        return held.future;
      });
      final result = platformDoubleClickInterval();
      held.complete(0.5);
      expect(await result, const Duration(milliseconds: 500));
      for (final invalid in [null, '500', double.nan, double.infinity, 0, -1]) {
        messenger.setMockMethodCallHandler(channel, (_) async => invalid);
        expect(
          await platformDoubleClickInterval(),
          const Duration(milliseconds: 300),
        );
      }
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      expect(
        await platformDoubleClickInterval(),
        const Duration(milliseconds: 300),
      );
      messenger.setMockMethodCallHandler(channel, null);
      expect(
        await platformDoubleClickInterval(),
        const Duration(milliseconds: 300),
      );
    },
  );
  test('non-macOS never calls the native channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => fail('unexpected native call'),
    );
    expect(
      await platformDoubleClickInterval(),
      const Duration(milliseconds: 300),
    );
  });
}
