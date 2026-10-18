import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_language.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/openai_realtime.dart';
import 'package:raft_flutter/features/agent_mode/voice_clip_store.dart';
import 'package:raft_flutter/features/agent_mode/voice_layer_text.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';

import 'agent_openai_realtime_test.dart' show FakeRealtime, until;
import 'layered_voice_realtime_test.dart' show Agent;

/// The whole path from the person's words to the speaker, with the real relay
/// session on a local server: a kept acknowledgment is handed to the player as
/// soon as it is due, even while the voice's lead-in is still being asked for.
/// (The lead-in used to be asked for first and the acknowledgment waited for
/// its whole response, about a second.)
class _Kept implements VoiceClipStore {
  _Kept(this.kept);
  final Map<String, List<Uint8List>> kept;
  @override
  Future<List<Uint8List>?> read(String key) async => kept[key];
  @override
  Future<void> write(String key, List<Uint8List> chunks) async {}
}

@visibleForTesting
void main() {
  late FakeRealtime server;

  setUp(() async {
    HttpOverrides.global = null;
    OpenAiRealtimeSession.resetFallbacks();
    server = FakeRealtime();
    await server.start();
  });
  tearDown(() async {
    OpenAiRealtimeSession.clipStore = null;
    await server.stop();
  });

  test(
    'a kept acknowledgment is handed to the player within 100 ms of being '
    'due, while the lead-in request is pending (and is sent after it)',
    () async {
      OpenAiRealtimeSession.clipStore = _Kept({
        for (final p in ackPhrases(AgentLanguage.zh))
          'openai||marin|zh|$p': [Uint8List(4800), Uint8List(4800)],
      });
      final log = <(String, DateTime)>[];
      final audio = <DateTime>[];
      late Agent agent;
      final session = LayeredVoiceSession(
        voiceProvider: AgentVoiceProvider.openai,
        apiKey: 'k',
        agentApiKey: 'g',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
        steering: AgentSteering(
          scope: () => const AgentScope(systemPrompt: '', tools: []),
        ),
        voice: 'marin',
        ackTarget: const Duration(milliseconds: 150),
        log: (line) => log.add((line, DateTime.now())),
        onAudio: (_) => audio.add(DateTime.now()),
        liveBuilder: (p) => OpenAiRealtimeSession(
          service: RealtimeService.openai,
          relay: true,
          apiKey: p.apiKey,
          voice: p.voice,
          language: p.language,
          systemPrompt: p.systemPrompt,
          tools: const [],
          endpoint: server.uri,
          onToolCall: p.onToolCall,
          onAudio: p.onAudio,
          onInputText: p.onInputText,
          onInputDone: p.onInputDone,
          onSpeechStarted: p.onSpeechStarted,
          onSpeechStopped: p.onSpeechStopped,
          onTiming: p.onTiming,
          onClosed: p.onClosed,
        ),
        agentBuilder: (p) => agent = Agent(p),
      );
      addTearDown(session.close);
      await session.connect();
      await until(() => log.isNotEmpty, reason: 'connected');
      // The kept sound is there before the first turn.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      session.sendText('读一下动态');
      await until(
        () => log.any((l) => l.$1.contains('stage name=lead-requested')),
        reason: 'the lead-in was asked for',
      );
      final due = log.firstWhere(
        (l) => l.$1.contains('stage name=ack-requested'),
      );
      final lead = log.firstWhere(
        (l) => l.$1.contains('stage name=lead-requested'),
      );
      expect(
        lead.$2.isBefore(due.$2),
        isFalse,
        reason: 'the lead-in is asked for after the acknowledgment',
      );
      // The lead-in is on the wire and has no answer; the acknowledgment is
      // already with the player.
      final request = await server.waitFor('response.create');
      expect((request['response'] as Map)['instructions'], contains('读一下动态'));
      await until(() => audio.length >= 2, reason: 'the clip is handed over');
      expect(
        audio.first.difference(due.$2).inMilliseconds,
        lessThan(100),
        reason: 'handed to the player within 100 ms of being due',
      );
      expect(audio, hasLength(2), reason: 'the whole clip, at once');
      expect(
        log.any((l) => l.$1.contains('speak who=openai kind=ack')),
        isTrue,
      );
      expect(agent.asked, ['读一下动态']);
    },
  );
}
