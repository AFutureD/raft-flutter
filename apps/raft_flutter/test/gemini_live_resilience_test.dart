import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Live model's setup memory survives the app process, a connect drops
/// nothing it need not, the audio of a connecting call is not flushed in one
/// burst, and an unexpected close is resumed once.

GeminiLiveSession _live({
  bool fast = false,
  AgentReasoning reasoning = AgentReasoning.high,
  String? languageCode,
  void Function(String)? onClosed,
  List<String>? log,
}) => GeminiLiveSession(
  apiKey: 'secret-key',
  systemPrompt: 'p',
  tools: const [],
  onToolCall: (n, a) async => {},
  reasoning: reasoning,
  fast: fast,
  languageCode: languageCode,
  preferredModel: 'models/other-live',
  onClosed: onClosed,
  log: log?.add,
);

Map<String, Object?> _config(GeminiLiveSession s, String model) {
  final setup =
      s.setupMessage(
            model,
            affective: s.setupFlags.affective,
            nonBlocking: true,
          )['setup']!
          as Map;
  return (setup['generationConfig'] as Map).cast<String, Object?>();
}

class _Audio extends AgentAudio {
  _Audio() : super.forTesting();
  final mic = StreamController<Uint8List>();
  @override
  bool get supported => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Stream<Uint8List> microphone() => mic.stream;
  @override
  Future<void> play(Uint8List pcm) async {}
  @override
  Future<Duration> pending() async => Duration.zero;
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<void> release() async {}
}

class _FakeLive extends GeminiLiveSession {
  _FakeLive()
    : super(
        apiKey: 'k',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: _noTool,
      );
  static Future<Map<String, Object?>> _noTool(
    String n,
    Map<String, Object?> a,
  ) async => {};
  final gate = Completer<void>();
  bool up = false;
  final sent = <Uint8List>[];
  @override
  bool get connected => up;
  @override
  Future<void> connect() async {
    await gate.future;
    connectTimeline = (pickMs: 12, setupMs: 640, tries: 2);
    up = true;
  }

  @override
  void sendAudio(Uint8List pcm16k) => sent.add(pcm16k);
  @override
  Future<void> close() async => up = false;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DevicePreferences.load();
    GeminiLiveSession.forgetSetups();
  });
  tearDown(() {
    GeminiLiveSession.forgetSetups();
    DevicePreferences.reset();
  });

  group('the setup memory is kept on the device', () {
    test('a new process connects with what the model accepted', () {
      final first = _live()..useModel('models/other-live');
      first.dropRefused(
        'Unknown name "enableAffectiveDialog"',
        nonBlocking: true,
      );
      first.dropRefused('Thinking level is not supported', nonBlocking: true);
      first.rememberSetup();

      // A new app process: nothing in memory, the storage is still there.
      GeminiLiveSession.forgetSetups(storage: false);
      expect(GeminiLiveSession.rememberedSetup('models/other-live'), isNull);
      final second = _live()..useModel('models/other-live');
      expect(second.setupFlags.affective, isFalse);
      expect(second.thinkingUsed, 'medium');
      expect(_config(second, 'models/other-live')['thinkingConfig'], {
        'thinkingLevel': 'medium',
      });
    });

    test('it is kept per kind of session', () {
      final relay = _live(fast: true)..useModel('models/other-live');
      relay.dropRefused(
        'Unknown name "enableAffectiveDialog"',
        nonBlocking: true,
      );
      relay.rememberSetup();
      GeminiLiveSession.forgetSetups(storage: false);
      expect(
        (_live()..useModel('models/other-live')).setupFlags.affective,
        isTrue,
      );
      expect(
        (_live(fast: true)..useModel('models/other-live')).setupFlags.affective,
        isFalse,
      );
    });

    test('an unreadable entry is ignored', () async {
      await DevicePreferences.current!.setString(
        'raft.agentDemo.liveSetup.other-live|full|talk',
        '{not json',
      );
      final s = _live()..useModel('models/other-live');
      expect(s.setupFlags.affective, isTrue);
    });

    test('gemini-3.8-live starts seeded: no affective dialog, no thinking', () {
      final s = _live()..useModel('models/gemini-3.8-live');
      expect(s.setupFlags.affective, isFalse);
      expect(s.thinkingUsed, 'none');
      expect(
        _config(s, 'models/gemini-3.8-live'),
        isNot(contains('thinkingConfig')),
      );
      final relay = _live(fast: true)..useModel('models/gemini-3.8-live');
      expect(relay.thinkingUsed, 'none');
      // Other models, and the thinking variant, are not seeded.
      expect(
        (_live()..useModel('models/gemini-3.8-live-thinking'))
            .setupFlags
            .affective,
        isTrue,
      );
      expect((_live()..useModel('models/other-live')).thinkingUsed, 'high');
    });

    test('a refused seeded setup drops the feature and updates the memory', () {
      final s = _live(languageCode: 'cmn-CN')
        ..useModel('models/gemini-3.8-live');
      expect(
        s.dropRefused('languageCode is not supported', nonBlocking: true),
        'languageCode',
      );
      s.rememberSetup();
      GeminiLiveSession.forgetSetups(storage: false);
      final next = _live(languageCode: 'cmn-CN')
        ..useModel('models/gemini-3.8-live');
      expect(next.setupFlags.languageCode, isFalse);
      expect(
        next.setupFlags.affective,
        isFalse,
        reason: 'the seed still holds',
      );
    });
  });

  group('audio captured while connecting', () {
    Uint8List chunk(int bytes, int fill) =>
        Uint8List(bytes)..fillRange(0, bytes, fill);

    test('only the last second is kept', () {
      final chunks = [for (var i = 0; i < 80; i++) chunk(3200, i)];
      final kept = AgentVoiceController.lastAudio(
        chunks,
        AgentVoiceController.flushLimitBytes,
      );
      expect(kept.fold<int>(0, (a, c) => a + c.lengthInBytes), 32000);
      expect(kept.last.first, 79);
      expect(kept.first.first, 70);
      // Less than a second is kept whole.
      expect(
        AgentVoiceController.lastAudio(chunks.take(3).toList(), 32000),
        hasLength(3),
      );
    });

    test('an open call flushes a second, not the whole backlog', () async {
      final audio = _Audio();
      final fake = _FakeLive();
      final logs = <String>[];
      final voice = AgentVoiceController(
        tools: const [],
        onToolCall: (n, a) async => {},
        systemPrompt: () => 'p',
        audio: audio,
        key: AgentVoiceKey.forTesting('k'),
        log: logs.add,
        sessionFactory: ({
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
        }) => fake,
      );
      addTearDown(voice.dispose);
      unawaited(voice.micDown());
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 80; i++) {
        audio.mic.add(chunk(3200, i % 256));
      }
      await Future<void>.delayed(Duration.zero);
      voice.micUp(const Duration(milliseconds: 100)); // A tap: an open call.
      fake.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.sent.fold<int>(0, (a, c) => a + c.lengthInBytes), 32000);
      final line = logs.singleWhere((l) => l.contains('connect-timeline'));
      expect(
        line,
        matches(
          RegExp(
            r'^voice-turn connect-timeline pick=12ms setup=640ms tries=2 firstAudioReady=\d+ms$',
          ),
        ),
      );
    });
  });

  group('an unexpected close', () {
    late HttpServer server;
    late List<String> serverEvents;
    late int connections;
    late int closeAfterMs;
    late int closeCode;
    late Set<int> closing;
    final realOpener = GeminiLiveSession.socketOpener;
    final realLister = GeminiLiveSession.modelLister;

    setUp(() async {
      serverEvents = [];
      connections = 0;
      closeAfterMs = 0;
      closeCode = 1011;
      closing = {1}; // The server closes these connections.
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        final ws = await WebSocketTransformer.upgrade(request);
        final n = ++connections;
        ws.listen((raw) {
          final message = jsonDecode(raw as String) as Map;
          if (message.containsKey('setup')) {
            serverEvents.add(
              'setup ${jsonEncode((message['setup'] as Map)['sessionResumption'])}',
            );
            ws.add(jsonEncode({'setupComplete': {}}));
            if (closing.contains(n)) {
              ws.add(
                jsonEncode({
                  'sessionResumptionUpdate': {
                    'resumable': true,
                    'newHandle': 'h$n',
                  },
                }),
              );
              Future<void>.delayed(
                Duration(milliseconds: closeAfterMs),
                () => ws.close(closeCode, 'boom'),
              );
            }
          }
        });
      });
      GeminiLiveSession.modelLister = (_) async => ['models/other-live'];
      GeminiLiveSession.socketOpener = (url, headers) =>
          WebSocket.connect('ws://127.0.0.1:${server.port}/');
      GeminiLiveSession.forgetModels();
    });
    tearDown(() async {
      GeminiLiveSession.socketOpener = realOpener;
      GeminiLiveSession.modelLister = realLister;
      GeminiLiveSession.forgetModels();
      await server.close(force: true);
    });

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('is resumed once with the handle, silently', () async {
      final closed = <String>[];
      final log = <String>[];
      final session = _live(onClosed: closed.add, log: log);
      await session.connect();
      await until(() => connections == 2 && serverEvents.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connections, 2);
      expect(serverEvents.last, contains('"handle":"h1"'));
      expect(closed, isEmpty);
      expect(session.connected, isTrue);
      expect(
        log.where(
          (l) => l.startsWith('voice-turn closed code=1011 reason=boom after='),
        ),
        hasLength(1),
      );
      expect(log.any((l) => RegExp(r'sentBytes=\d+$').hasMatch(l)), isTrue);
      await session.close();
    });

    test('does not loop: a second drop right after is reported', () async {
      final closed = <String>[];
      closing = {1, 2};
      final session = _live(onClosed: closed.add);
      await session.connect();
      await until(() => closed.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(connections, 2, reason: 'one resumption, no more');
      expect(closed, hasLength(1));
      expect(session.connected, isFalse);
    });

    test('a failed resumption is reported', () async {
      final closed = <String>[];
      final session = _live(onClosed: closed.add);
      await session.connect();
      GeminiLiveSession.socketOpener = (_, _) async =>
          throw const SocketException('offline');
      await until(() => closed.isNotEmpty);
      expect(closed, hasLength(1));
      expect(connections, 1);
    });

    test('a normal close, or one we ask for, is not resumed', () async {
      closeCode = 1000;
      final closed = <String>[];
      final session = _live(onClosed: closed.add);
      await session.connect();
      await until(() => closed.isNotEmpty);
      expect(connections, 1);
      expect(closed, hasLength(1));

      closeCode = 1011;
      closeAfterMs = 200;
      final mine = <String>[];
      final other = _live(onClosed: mine.add);
      await other.connect();
      await other.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(connections, 2);
      expect(mine, isEmpty);
    });

    test('a hang up during the resumption leaves nothing open', () async {
      closeAfterMs = 0;
      final session = _live();
      await session.connect();
      await until(() => connections == 2 || !session.connected);
      await session.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(session.connected, isFalse);
    });
  });
}
