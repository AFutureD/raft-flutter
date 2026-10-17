import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/orb_state.dart';

import 'agent_orb_shell_test.dart' show OrbFixture;
import 'layered_voice_session_test.dart' show FakeLive, SlowAgent;

/// The orb on the layered voice: it is thinking while the agent works, and a
/// slow agent gets the person a cue of the app's own (the voice says nothing).

void main() {
  testWidgets('thinking while an ask is out; one cue when it is slow', (
    t,
  ) async {
    final f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    FakeLive? live;
    var cues = 0;
    f
      ..agentLayer = true
      ..slowCue = (() => cues++)
      ..sessionFactory =
          ({
            required provider,
            required apiKey,
            required systemPrompt,
            required tools,
            required onToolCall,
            required voice,
            reasoning = AgentReasoning.low,
            onAudio,
            onInputText,
            onOutputText,
            onTurnComplete,
            onInterrupted,
            onClosed,
            playbackPending,
            steering,
          }) => LayeredVoiceSession(
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            tools: tools,
            onToolCall: onToolCall,
            steering: steering!,
            slowAfter: const Duration(milliseconds: 300),
            onOutputText: onOutputText,
            onTurnComplete: onTurnComplete,
            liveBuilder: (p) => live = FakeLive(p),
            agentBuilder: (p) =>
                SlowAgent(p, const Duration(milliseconds: 900)),
          );
    await f.pump();
    unawaited(f.controller.sendText('去动态'));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(live, isNotNull);

    final answer = live!.onToolCall('ask_agent', {'request': '去动态'});
    await t.pump(const Duration(milliseconds: 100));
    expect(f.controller.voice.asking, isTrue);
    expect(f.controller.state, OrbState.thinking);
    expect(cues, 0, reason: 'not slow yet');

    await t.pump(const Duration(milliseconds: 400));
    expect(cues, 1, reason: 'slow: the app cues');
    expect(f.controller.state, OrbState.thinking);

    await t.pump(const Duration(milliseconds: 600));
    expect(await answer, {'say': '好了。'});
    await t.pump();
    expect(f.controller.voice.asking, isFalse);
    expect(cues, 1, reason: 'once per ask');
  });
}
