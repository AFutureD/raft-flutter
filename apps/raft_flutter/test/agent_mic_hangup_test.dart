import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_ui/raft_ui.dart';

/// The mic toggles the call: one tap starts a voice conversation, and a tap
/// while it connects, listens or speaks hangs it up at once. Fake audio and a
/// fake voice session; real taps on the real dock inside the floating foot.

class _Audio extends AgentAudio {
  _Audio() : super.forTesting();
  int micStarts = 0, micStops = 0, playbackStops = 0;

  @override
  bool get supported => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<Uint8List> microphone() {
    final c = StreamController<Uint8List>(
      onListen: () => micStarts++,
      onCancel: () => micStops++,
    );
    return c.stream;
  }

  @override
  Future<void> play(Uint8List pcm) async {}

  @override
  Future<Duration> pending() async => Duration.zero;

  @override
  Future<void> stopPlayback() async => playbackStops++;

  @override
  Future<void> release() async {}
}

class _Session implements VoiceSession {
  _Session({
    required this.onAudio,
    required this.onClosed,
    required this.onToolCall,
  });

  final connectGate = Completer<void>();
  bool _connected = false;
  int closes = 0, endAudios = 0;

  @override
  bool get connected => _connected;
  @override
  String? get model => 'fake-model';
  @override
  final AgentToolHandler onToolCall;
  @override
  final void Function(Uint8List pcm24k)? onAudio;
  @override
  final void Function(String reason)? onClosed;
  @override
  void Function(String text)? get onInputText => null;
  @override
  void Function(String text)? get onOutputText => null;
  @override
  void Function()? get onTurnComplete => null;
  @override
  void Function()? get onInterrupted => null;

  @override
  Future<void> connect() async {
    await connectGate.future;
    _connected = true;
  }

  @override
  void sendAudio(Uint8List pcm16k) {}
  @override
  void endAudio() => endAudios++;
  @override
  void sendText(String text) {}
  @override
  void addContext(String text) {}
  @override
  Future<void> close() async {
    closes++;
    _connected = false;
  }
}

void main() {
  late _Audio audio;
  late List<_Session> sessions;
  late AgentVoiceController voice;

  setUp(() {
    audio = _Audio();
    sessions = [];
    voice = AgentVoiceController(
      tools: const [],
      onToolCall: (name, args) async => {},
      systemPrompt: () => 'test',
      audio: audio,
      key: AgentVoiceKey.forTesting('test-key'),
      sessionFactory:
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
          }) {
            final s = _Session(
              onAudio: onAudio,
              onClosed: onClosed,
              onToolCall: onToolCall,
            );
            sessions.add(s);
            return s;
          },
    );
  });
  tearDown(() => voice.dispose());

  Future<void> pumpDock(WidgetTester t) async {
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(
          body: HandsFree(
            // The foot floats over the page in a Stack, like the real screen.
            child: HfScreenFrame(
              content: const SizedBox.expand(),
              foot: ListenableBuilder(
                listenable: voice,
                builder: (context, _) => AgentVoiceDock(
                  lines: voice.lines,
                  state: voice.state,
                  notice: voice.notice,
                  onSubmit: (_) {},
                  onMicDown: () => unawaited(voice.micDown()),
                  onMicUp: voice.micUp,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> tapMic(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('agent-orb')));
    await t.pump();
    await t.pump();
  }

  Future<void> connected(WidgetTester t) async {
    sessions.last.connectGate.complete();
    await t.pump();
    await t.pump();
  }

  void expectHungUp(_Session s, {int sessionsMade = 1}) {
    expect(voice.state, AgentMicState.idle);
    expect(voice.live, isFalse);
    expect(s.closes, greaterThanOrEqualTo(1), reason: 'session closed');
    expect(s.connected, isFalse);
    expect(audio.micStops, audio.micStarts, reason: 'capture stopped');
    expect(sessions, hasLength(sessionsMade));
  }

  Finder micIcon(IconData icon) => find.descendant(
    of: find.byKey(const ValueKey('agent-orb')),
    matching: find.byIcon(icon),
  );

  testWidgets('a tap starts the call; a tap while connecting cancels it', (
    t,
  ) async {
    await pumpDock(t);
    await tapMic(t);
    expect(sessions, hasLength(1));
    expect(voice.state, AgentMicState.connecting);
    expect(audio.micStarts, 1);
    expect(micIcon(Icons.more_horiz_rounded), findsOneWidget);

    await tapMic(t); // hang up while the session is still connecting
    expect(voice.state, AgentMicState.idle);
    expect(micIcon(Icons.mic_rounded), findsOneWidget);
    expect(sessions.single.closes, 1);
    expect(audio.micStops, 1);

    // The connection that was in flight finishes late: it must not revive.
    await connected(t);
    expectHungUp(sessions.single);
  });

  testWidgets('a tap while listening hangs up', (t) async {
    await pumpDock(t);
    await tapMic(t);
    await connected(t);
    expect(voice.state, AgentMicState.live);
    expect(voice.live, isTrue);

    await tapMic(t);
    expectHungUp(sessions.single);
    expect(micIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.text('按住说话 · 点一下实时对话'), findsOneWidget);
  });

  testWidgets('a tap while the model speaks (live) hangs up', (t) async {
    await pumpDock(t);
    await tapMic(t);
    await connected(t);
    sessions.single.onAudio!(Uint8List(8));
    await t.pump();

    await tapMic(t);
    expectHungUp(sessions.single);
    expect(audio.playbackStops, greaterThanOrEqualTo(1));
  });

  testWidgets('a tap while the model speaks (after hold-to-talk) hangs up', (
    t,
  ) async {
    await pumpDock(t);
    // Hold to talk, release: the turn is sent and the model answers.
    unawaited(voice.micDown());
    await t.pump();
    await t.pump();
    voice.micUp(const Duration(seconds: 1));
    await connected(t);
    sessions.single.onAudio!(Uint8List(8));
    await t.pump();
    expect(voice.state, AgentMicState.speaking);
    expect(micIcon(Icons.graphic_eq_rounded), findsOneWidget);

    await tapMic(t);
    expectHungUp(sessions.single);
    expect(micIcon(Icons.mic_rounded), findsOneWidget);
  });

  testWidgets('holding the mic while the model speaks still interrupts it', (
    t,
  ) async {
    await pumpDock(t);
    unawaited(voice.micDown());
    await t.pump();
    await t.pump();
    voice.micUp(const Duration(seconds: 1));
    await connected(t);
    sessions.single.onAudio!(Uint8List(8));
    await t.pump();
    final stops = audio.playbackStops;

    final g = await t.startGesture(
      t.getCenter(find.byKey(const ValueKey('agent-orb'))),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(audio.playbackStops, greaterThan(stops), reason: 'interrupted');
    expect(voice.state, AgentMicState.holding);
    expect(sessions.single.closes, 0, reason: 'a hold is not a hang up');
    await g.up();
    await t.pump();
    expect(sessions.single.closes, 0);
  });

  testWidgets('after a hang up, the next tap starts a new call', (t) async {
    await pumpDock(t);
    await tapMic(t);
    await connected(t);
    await tapMic(t);
    expectHungUp(sessions.single);

    await tapMic(t);
    expect(sessions, hasLength(2));
    expect(voice.state, AgentMicState.connecting);
    await connected(t);
    expect(voice.state, AgentMicState.live);
    expect(sessions.last.closes, 0);
    await tapMic(t);
    expect(voice.state, AgentMicState.idle);
    expect(sessions.last.closes, 1);
  });
}
