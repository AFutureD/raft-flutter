import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_page.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_result.dart'
    show OrbEvalHarness;
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';

/// A session that answers by script instead of a model: when the person's
/// text arrives it calls tools through the orb's own dispatcher, says its
/// words and ends the turn.
class ScriptedSession implements VoiceSession {
  ScriptedSession({
    required this.onToolCall,
    required this.onOutputText,
    required this.onTurnComplete,
    required this.script,
  });

  final Future<void> Function(ScriptedSession s, String text) script;
  final sentTexts = <String>[];
  int closes = 0;
  bool _connected = false;

  @override
  final AgentToolHandler onToolCall;
  @override
  final void Function(String text)? onOutputText;
  @override
  final void Function()? onTurnComplete;

  @override
  bool get connected => _connected;
  @override
  String? get model => 'scripted';
  @override
  void Function(Uint8List pcm24k)? get onAudio => null;
  @override
  void Function(String text)? get onInputText => null;
  @override
  void Function()? get onInterrupted => null;
  @override
  void Function(String reason)? get onClosed => null;

  @override
  Future<void> connect() async => _connected = true;
  @override
  void sendAudio(Uint8List pcm16k) {}
  @override
  void endAudio() {}
  @override
  void addContext(String text) => contexts.add(text);

  final contexts = <String>[];

  @override
  void sendText(String text) {
    sentTexts.add(text);
    unawaited(script(this, text));
  }

  /// The model's turn: the tools it calls, then its words.
  Future<void> turn(
    List<(String, Map<String, Object?>)> calls,
    String words,
  ) async {
    for (final (name, args) in calls) {
      await onToolCall(name, args);
    }
    say(words);
  }

  /// Says [words] and ends the turn.
  void say(String words) {
    onOutputText?.call(words);
    onTurnComplete?.call();
  }

  @override
  Future<void> close() async {
    closes++;
    _connected = false;
  }
}

class Sessions {
  final made = <ScriptedSession>[];

  VoiceSessionFactory factory(
    Future<void> Function(ScriptedSession s, String text) script,
  ) =>
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
      }) {
        final s = ScriptedSession(
          onToolCall: onToolCall,
          onOutputText: onOutputText,
          onTurnComplete: onTurnComplete,
          script: script,
        );
        made.add(s);
        return s;
      };
}

/// The evaluation page over [scenarios], with a scripted session and a
/// temporary folder for the report.
Future<void> mountEvalPage(
  WidgetTester t, {
  required Directory reports,
  required List<OrbEvalScenario> scenarios,
  required VoiceSessionFactory sessionFactory,
  AgentVoiceKey? key,
  int runs = 2,
  Duration turnTimeout = const Duration(seconds: 45),
  OrbEvalHarness harness = OrbEvalHarness.realtime,
  AgentVoiceProvider? voiceProvider,
}) async {
  t.view.physicalSize = const Size(412, 915);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: OrbEvalPage(
        scenarios: scenarios,
        runs: runs,
        sessionFactory: sessionFactory,
        voiceKey: key ?? AgentVoiceKey.forTesting('test-key'),
        reportRoot: () async => reports,
        settle: const Duration(milliseconds: 50),
        turnTimeout: turnTimeout,
        harness: harness,
        voiceProvider: voiceProvider,
      ),
    ),
  );
}

/// Lets the run go: frames and timers on the fake clock, files on the real.
Future<void> finishEvalRun(WidgetTester t) async {
  final verdict = find.byKey(const ValueKey('orb-eval-verdict'));
  for (var i = 0; i < 600 && verdict.evaluate().isEmpty; i++) {
    await t.pump(const Duration(milliseconds: 100));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await t.pump();
}

/// The report the run wrote.
Map<String, dynamic> readEvalReport(Directory reports) {
  final folder = reports.listSync().whereType<Directory>().single;
  return jsonDecode(File('${folder.path}/report.json').readAsStringSync())
      as Map<String, dynamic>;
}
