import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 录屏模式: Android's screen recorder cannot capture voice-communication
/// audio, so recording mode plays the agent's voice as media. Dart owns the
/// setting and tells the native side; the audio itself is checked on a
/// device.
void main() {
  const channel = MethodChannel('app.raft/agent-audio');
  final calls = <MethodCall>[];

  setUp(() async {
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    await DevicePreferences.load();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    // Off before and after: the setting is a process-wide singleton.
    AgentVoiceSettings.instance.recordingMode = false;
    calls.clear();
  });
  tearDown(() {
    AgentVoiceSettings.instance.recordingMode = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'off by default, kept, and sent to the native side when it changes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final s = AgentVoiceSettings.instance;
      expect(s.recordingMode, isFalse);
      s.recordingMode = true;
      expect(s.recordingMode, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => (c.method, c.arguments)), [
        ('setRecordingMode', true),
      ]);
      // Persisted on the device, so the next launch starts the same way.
      final stored = DevicePreferences.current!.getString(
        'raft.agentDemo.recording',
      );
      expect(stored, 'on');
      s.recordingMode = false;
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.arguments, false);
      expect(
        DevicePreferences.current!.getString('raft.agentDemo.recording'),
        'off',
      );
    },
  );

  test('a session start re-applies it', () async {
    AgentVoiceSettings.instance.recordingMode = true;
    calls.clear();
    await AgentVoiceSettings.instance.applyRecordingMode();
    expect(calls.single.method, 'setRecordingMode');
    expect(calls.single.arguments, true);
  });

  test('a platform without native audio does not fail', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException();
        });
    AgentVoiceSettings.instance.recordingMode = true;
    await AgentVoiceSettings.instance.applyRecordingMode();
    expect(AgentVoiceSettings.instance.recordingMode, isTrue);
  });

  testWidgets('the switch is in the voice settings, with the echo note', (
    t,
  ) async {
    t.view.physicalSize = const Size(420, 2200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: const AgentVoiceSettingsPage(),
      ),
    );
    final tile = find.byKey(const ValueKey('agent-recording-mode'));
    expect(tile, findsOneWidget);
    expect(t.widget<SwitchListTile>(tile).value, isFalse);
    expect(find.text('录屏模式'), findsOneWidget);
    // The risk is stated where the switch is.
    expect(find.textContaining('录屏时用，建议按住说话'), findsOneWidget);
    expect(find.textContaining('回声'), findsOneWidget);

    await t.tap(tile);
    await t.pump();
    expect(AgentVoiceSettings.instance.recordingMode, isTrue);
    expect(t.widget<SwitchListTile>(tile).value, isTrue);
    expect(calls.last.method, 'setRecordingMode');
    expect(calls.last.arguments, true);
    await t.tap(tile);
    await t.pump();
    expect(AgentVoiceSettings.instance.recordingMode, isFalse);
    expect(calls.last.arguments, false);
  });
}
