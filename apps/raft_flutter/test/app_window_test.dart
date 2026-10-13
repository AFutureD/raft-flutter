import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/app_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<String>> run(TargetPlatform platform, String channelName) async {
    final calls = <String>[];
    final channel = MethodChannel(channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await presentAppWindow(platform: platform, channel: channel);
    return calls;
  }

  test('desktop shells are asked to raise the window', () async {
    expect(await run(TargetPlatform.linux, 'app.raft/window'), ['present']);
    expect(await run(TargetPlatform.macOS, 'app.raft/window'), ['present']);
    expect(
      await run(TargetPlatform.windows, 'app.raft/windows-notifications'),
      ['present'],
    );
  });

  test('mobile has no window to raise (the deep link already does)', () async {
    expect(await run(TargetPlatform.android, 'app.raft/window'), isEmpty);
    expect(await run(TargetPlatform.iOS, 'app.raft/window'), isEmpty);
  });

  test('default channels are the ones the native runners register', () async {
    final seen = <String>[];
    for (final (platform, name) in const [
      (TargetPlatform.linux, 'app.raft/window'),
      (TargetPlatform.macOS, 'app.raft/window'),
      (TargetPlatform.windows, 'app.raft/windows-notifications'),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (call) async {
            seen.add('$name:${call.method}');
            return null;
          });
      await presentAppWindow(platform: platform);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    expect(seen, [
      'app.raft/window:present',
      'app.raft/window:present',
      'app.raft/windows-notifications:present',
    ]);
  });
}
