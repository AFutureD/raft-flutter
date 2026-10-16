import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/openai_realtime.dart';
import 'package:raft_flutter/features/agent_mode/runtime/agent_tool_set.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';

import 'agent_openai_realtime_test.dart' show FakeRealtime, b64, settle, until;

/// Grok Voice (xAI) runs on the OpenAI Realtime session with the documented
/// differences: https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech
/// and https://docs.x.ai/developers/rest-api-reference/inference/voice
void main() {
  const key = 'xai-test-key-0123456789abcdef0123';
  late FakeRealtime server;
  final logs = <String>[];
  final calls = <(String, Map<String, Object?>)>[];
  final inputs = <String>[];
  final outputs = <String>[];
  final audio = <Uint8List>[];
  var turns = 0;
  var interrupted = 0;
  final closed = <String>[];
  Duration pending = Duration.zero;
  Future<Map<String, Object?>> Function(String, Map<String, Object?>) handler =
      (name, args) async => {'ok': true};

  OpenAiRealtimeSession session({
    Duration? idleClose,
    List<Map<String, Object?>>? tools,
  }) => OpenAiRealtimeSession(
    service: RealtimeService.grok,
    apiKey: key,
    systemPrompt: '你是语音助理。',
    tools: tools ?? agentModeToolDeclarations(),
    endpoint: server.uri,
    voice: 'eve',
    idleClose: idleClose,
    log: logs.add,
    playbackPending: () async => pending,
    onToolCall: (name, args) {
      calls.add((name, args));
      return handler(name, args);
    },
    onAudio: audio.add,
    onInputText: inputs.add,
    onOutputText: outputs.add,
    onTurnComplete: () => turns++,
    onInterrupted: () => interrupted++,
    onClosed: closed.add,
  );

  Future<OpenAiRealtimeSession> connected({Duration? idleClose}) async {
    final s = session(idleClose: idleClose);
    await s.connect();
    addTearDown(s.close);
    return s;
  }

  setUp(() async {
    HttpOverrides.global = null; // A real loopback server, not the test mock.
    OpenAiRealtimeSession.resetFallbacks();
    server = FakeRealtime();
    await server.start();
    logs.clear();
    calls.clear();
    inputs.clear();
    outputs.clear();
    audio.clear();
    closed.clear();
    turns = 0;
    interrupted = 0;
    pending = Duration.zero;
    handler = (name, args) async => {'ok': true};
  });
  tearDown(() => server.stop());

  group('setup', () {
    test('the endpoint and model are the documented ones', () {
      final s = OpenAiRealtimeSession(
        service: RealtimeService.grok,
        apiKey: key,
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
      );
      expect(
        s.endpoint.toString(),
        'wss://api.x.ai/v1/realtime?model=grok-voice-latest',
      );
      expect(s.model, 'grok-voice-latest');
    });

    test('the key goes in a bearer header and is never logged', () async {
      final s = await connected();
      expect(
        server.requestHeaders.single.value('authorization'),
        'Bearer $key',
      );
      expect(server.of('session.update'), hasLength(1));
      s.sendText('hi');
      await s.close();
      expect(logs.join('\n'), isNot(contains('xai-test')));
    });

    test('the session.update has Grok\'s shape', () async {
      await connected();
      final update = await server.waitFor('session.update');
      final s = update['session'] as Map<String, dynamic>;
      // Not OpenAI's: no type, no output_modalities, no reasoning/truncation,
      // voice and turn_detection at the top level.
      expect(s.containsKey('type'), isFalse);
      expect(s.containsKey('output_modalities'), isFalse);
      expect(s.containsKey('reasoning'), isFalse);
      expect(s.containsKey('truncation'), isFalse);
      expect(s['instructions'], '你是语音助理。');
      expect(s['voice'], 'eve');
      expect(s['turn_detection'], {'type': 'server_vad'});
      final a = s['audio'] as Map<String, dynamic>;
      expect(a['input']['format'], {'type': 'audio/pcm', 'rate': 24000});
      expect(a['output']['format'], {'type': 'audio/pcm', 'rate': 24000});
      expect(a['input']['transcription'], {'model': 'grok-transcribe'});
      expect(a.containsKey('voice'), isFalse);
      // The same tools, descriptions and parameters as OpenAI gets.
      expect(
        s['tools'],
        OpenAiRealtimeSession.functionTools(agentModeToolDeclarations()),
      );
      for (final t in s['tools'] as List) {
        expect((t as Map)['type'], 'function');
      }
    });

    test('a refused transcription setting is dropped and retried', () async {
      server
        ..rejectUpdates = 1
        ..rejectParam = 'session.audio.input.transcription.model';
      await connected();
      final updates = server.of('session.update').toList();
      expect(updates, hasLength(2));
      expect(
        (updates.last['session']['audio']['input'] as Map).containsKey(
          'transcription',
        ),
        isFalse,
      );
    });

    test('a refused key says so', () async {
      server.refuseWith = 401;
      final s = session();
      await expectLater(
        s.connect(),
        throwsA(
          isA<OpenAiRealtimeException>().having(
            (e) => e.message,
            'message',
            contains('xAI'),
          ),
        ),
      );
    });
  });

  group('audio and transcripts', () {
    test('microphone audio is sent at 24 kHz; the end sends silence', () async {
      final s = await connected();
      s.sendAudio(Uint8List(640));
      final append = await server.waitFor('input_audio_buffer.append');
      expect(
        base64Decode(append['audio'] as String).length,
        inInclusiveRange(958, 960),
      );
      s.endAudio();
      final tail = await server.waitFor('input_audio_buffer.append', nth: 2);
      final bytes = base64Decode(tail['audio'] as String);
      expect(bytes.length, greaterThan(24000 * 2));
      expect(bytes.every((b) => b == 0), isTrue);
    });

    test('speech and its transcript reach the callbacks', () async {
      await connected();
      server
        ..send({
          'type': 'response.output_audio.delta',
          'response_id': 'r1',
          'item_id': 'i1',
          'content_index': 0,
          'delta': b64([1, 2, 3, 4]),
        })
        ..send({
          'type': 'response.output_audio_transcript.delta',
          'delta': '你好',
        });
      await until(() => audio.isNotEmpty && outputs.isNotEmpty);
      expect(audio.single, [1, 2, 3, 4]);
      expect(outputs, ['你好']);
    });

    test(
      'cumulative user transcripts are passed on as new text only',
      () async {
        await connected();
        for (final t in ['Hello', 'Hello, how', 'Hello, how are you?']) {
          server.send({
            'type': 'conversation.item.input_audio_transcription.updated',
            'item_id': 'u1',
            'transcript': t,
          });
        }
        server.send({
          'type': 'conversation.item.input_audio_transcription.completed',
          'item_id': 'u1',
          'transcript': 'Hello, how are you?',
        });
        await until(() => inputs.join().length >= 19);
        await settle();
        expect(inputs.join(), 'Hello, how are you?');
        expect(inputs.first, 'Hello');
      },
    );

    test('a transcript that only arrives complete is passed on once', () async {
      await connected();
      server.send({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'u2',
        'transcript': '打开 design 频道',
      });
      await until(() => inputs.isNotEmpty);
      await settle();
      expect(inputs, ['打开 design 频道']);
    });
  });

  group('turns and tools', () {
    Map<String, Object?> call(
      String name, {
      String id = 'call_1',
      String args = '{}',
    }) => {
      'type': 'response.function_call_arguments.done',
      'response_id': 'r1',
      'item_id': 'fc_$id',
      'output_index': 0,
      'call_id': id,
      'name': name,
      'arguments': args,
    };
    Map<String, Object?> done({bool withCall = true}) => {
      'type': 'response.done',
      'response': {
        'id': 'r1',
        'status': 'completed',
        'usage': {
          'input_tokens': 120,
          'output_tokens': 30,
          'total_tokens': 150,
        },
        'output': [
          if (withCall) {'type': 'function_call'},
        ],
      },
    };
    Map<String, Object?> created() => {
      'type': 'response.created',
      'response': {'id': 'r1'},
    };

    test('a response without tools completes the turn', () async {
      await connected();
      server
        ..send(created())
        ..send(done(withCall: false));
      await until(() => turns == 1);
      expect(server.of('response.create'), isEmpty);
    });

    test('call, handler, output intact, then response.create', () async {
      handler = (name, args) async => {
        'ok': true,
        'shown': [name, args['name']],
        'nested': {'a': 1},
      };
      await connected();
      server
        ..send(created())
        ..send(call('open_channel', args: '{"name":"general"}'))
        ..send(done());
      final output = await server.waitFor('conversation.item.create');
      expect(calls.single.$1, 'open_channel');
      expect(calls.single.$2, {'name': 'general'});
      expect(output['item']['type'], 'function_call_output');
      expect(output['item']['call_id'], 'call_1');
      expect(jsonDecode(output['item']['output'] as String), {
        'ok': true,
        'shown': ['open_channel', 'general'],
        'nested': {'a': 1},
      });
      await server.waitFor('response.create');
      final order = server.received.map((e) => e['type']).toList();
      expect(
        order.indexOf('conversation.item.create'),
        lessThan(order.indexOf('response.create')),
      );
      expect(turns, 0);
    });

    test('two calls get one response.create after both outputs', () async {
      await connected();
      server
        ..send(created())
        ..send(call('open_channel', id: 'c1'))
        ..send(call('go_back', id: 'c2'))
        ..send(done());
      await server.waitFor('response.create');
      await settle();
      expect(server.of('conversation.item.create'), hasLength(2));
      expect(server.of('response.create'), hasLength(1));
    });

    test('a call that arrives after response.done still continues', () async {
      await connected();
      server
        ..send(created())
        ..send(done(withCall: false));
      await until(() => turns == 1);
      server.send(call('open_channel'));
      await server.waitFor('response.create');
      expect(server.of('conversation.item.create'), hasLength(1));
    });

    test(
      'the next answer waits until the speech before it was heard',
      () async {
        pending = const Duration(milliseconds: 400);
        await connected();
        server
          ..send(created())
          ..send(call('open_channel'))
          ..send(done());
        await server.waitFor('conversation.item.create');
        final sentOutput = DateTime.now();
        await server.waitFor('response.create');
        expect(
          DateTime.now().difference(sentOutput),
          greaterThan(const Duration(milliseconds: 250)),
        );
      },
    );

    test('a handler that throws is answered with an error', () async {
      handler = (name, args) async => throw StateError('boom');
      await connected();
      server
        ..send(created())
        ..send(call('open_channel'))
        ..send(done());
      final output = await server.waitFor('conversation.item.create');
      expect(
        jsonDecode(output['item']['output'] as String),
        containsPair('error', isA<String>()),
      );
      await server.waitFor('response.create');
    });

    test('text from the app asks for a response', () async {
      final s = await connected();
      s.sendText('（用户正在试听你的声音。）');
      final item = await server.waitFor('conversation.item.create');
      expect(item['item']['role'], 'user');
      expect(item['item']['content'], [
        {'type': 'input_text', 'text': '（用户正在试听你的声音。）'},
      ]);
      await server.waitFor('response.create');
    });
  });

  group('interruption', () {
    test('speaking over the model stops playback and truncates', () async {
      pending = const Duration(milliseconds: 50);
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        // 9600 bytes of 24 kHz PCM16 is 200 ms.
        ..send({
          'type': 'response.output_audio.delta',
          'response_id': 'r1',
          'item_id': 'item_7',
          'content_index': 0,
          'delta': b64(Uint8List(9600)),
        });
      await until(() => audio.isNotEmpty);
      server.send({
        'type': 'input_audio_buffer.speech_started',
        'audio_start_ms': 1000,
        'item_id': 'u1',
      });
      final truncate = await server.waitFor('conversation.item.truncate');
      expect(interrupted, 1);
      expect(truncate['item_id'], 'item_7');
      expect(truncate['content_index'], 0);
      expect(truncate['audio_end_ms'], 150);
    });

    test('a call from a response the person spoke over is not run', () async {
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send({'type': 'input_audio_buffer.speech_started', 'item_id': 'u1'});
      await settle();
      server.send({
        'type': 'response.function_call_arguments.done',
        'response_id': 'r1',
        'call_id': 'c9',
        'name': 'open_channel',
        'arguments': '{}',
      });
      final output = await server.waitFor('conversation.item.create');
      expect(calls, isEmpty);
      expect(
        jsonDecode(output['item']['output'] as String),
        containsPair('error', isA<String>()),
      );
    });
  });

  group('billing per minute', () {
    test('usage of a response is logged (Grok reports totals only)', () async {
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send({
          'type': 'response.done',
          'response': {
            'id': 'r1',
            'status': 'completed',
            'usage': {
              'input_tokens': 120,
              'output_tokens': 30,
              'total_tokens': 150,
            },
            'output': [],
          },
        });
      await until(() => logs.any((l) => l.startsWith('usage response=r1')));
      final line = logs.firstWhere((l) => l.startsWith('usage'));
      expect(line, contains('input=120'));
      expect(line, contains('output=30'));
      expect(line, contains('total=150'));
    });

    test('the time the session was open is logged with its price', () async {
      final s = await connected();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await s.close();
      final line = logs.singleWhere((l) => l.startsWith('session closed'));
      expect(line, contains('s open'));
      expect(line, contains('\$0.08/min'));
      expect(logs.join('\n'), isNot(contains('xai-test')));
    });

    test('an idle session is closed quietly and opens again on use', () async {
      final s = await connected(idleClose: const Duration(milliseconds: 200));
      expect(s.connected, isTrue);
      await until(() => !s.connected, reason: 'never closed when idle');
      await until(
        () => logs.any((l) => l.startsWith('session idle after')),
        reason: 'idle close was not logged with the open time',
      );
      await settle();
      // The server ended nothing: no "closed" report to the person.
      expect(closed, isEmpty);
      // The next use connects again.
      await s.connect();
      expect(s.connected, isTrue);
      expect(server.requestUris, hasLength(2));
      s.sendText('hello again');
      await server.waitFor('response.create');
    });

    test('traffic keeps the session open', () async {
      final s = await connected(idleClose: const Duration(milliseconds: 300));
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        s.sendAudio(Uint8List(640));
      }
      expect(s.connected, isTrue);
      await until(() => !s.connected, reason: 'never closed once quiet');
    });

    test('a running tool or response keeps the session open', () async {
      final release = Completer<void>();
      handler = (name, args) async {
        await release.future;
        return {'ok': true};
      };
      final s = await connected(idleClose: const Duration(milliseconds: 150));
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send({
          'type': 'response.function_call_arguments.done',
          'response_id': 'r1',
          'call_id': 'c1',
          'name': 'open_channel',
          'arguments': '{}',
        });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(s.connected, isTrue);
      release.complete();
      await server.waitFor('conversation.item.create');
    });

    test('OpenAI sessions are not closed when idle', () async {
      final s = OpenAiRealtimeSession(
        apiKey: 'sk-test-key-0123456789abcdef0123',
        systemPrompt: 'p',
        tools: const [],
        endpoint: server.uri,
        log: logs.add,
        onToolCall: (n, a) async => {},
      );
      await s.connect();
      addTearDown(s.close);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(s.connected, isTrue);
      expect(s.model, 'gpt-realtime-2.1-mini');
    });
  });

  group('provider and keys', () {
    test('the factory builds the Grok session', () {
      final s = createVoiceSession(
        provider: AgentVoiceProvider.grok,
        apiKey: 'k',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
        voice: 'rex',
      );
      expect(s, isA<OpenAiRealtimeSession>());
      expect(s.model, 'grok-voice-latest');
      expect((s as OpenAiRealtimeSession).service, RealtimeService.grok);
    });

    test('a scanned xai- key goes to Grok, whatever is chosen', () {
      const grok = 'xai-abcdefghijklmnopqrstuvwxyz0123456789ABCDEF';
      final g = parseScannedKey(
        'XAI_API_KEY=$grok\n',
        preferred: AgentVoiceProvider.openai,
      );
      expect(g?.provider, AgentVoiceProvider.grok);
      expect(g?.key, grok);
      // A bare token belongs to the chosen provider.
      final bare = parseScannedKey(
        'abcdefghijklmnopqrstuvwx',
        preferred: AgentVoiceProvider.grok,
      );
      expect(bare?.provider, AgentVoiceProvider.grok);
      // With two keys in the text the chosen provider's wins.
      const openai = 'sk-proj-abcdefghijklmnopqrstuvwxyz0123456789';
      final both = parseScannedKey(
        '$openai $grok',
        preferred: AgentVoiceProvider.grok,
      );
      expect(both?.provider, AgentVoiceProvider.grok);
      expect(
        voiceKeyFor(AgentVoiceProvider.grok).runtimeType.toString(),
        'GrokVoiceKey',
      );
    });
  });
}
