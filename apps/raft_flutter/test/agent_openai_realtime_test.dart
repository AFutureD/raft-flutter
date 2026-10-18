import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/runtime/agent_tool_set.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/openai_realtime.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';

/// A local server that speaks enough of the Realtime API: it answers the
/// connection with `session.created`, a `session.update` with
/// `session.updated`, and records everything the client sends.
class FakeRealtime {
  late final HttpServer _server;
  final received = <Map<String, dynamic>>[];
  final requestHeaders = <HttpHeaders>[];
  final requestUris = <Uri>[];
  WebSocket? socket;

  /// The first [rejectUpdates] `session.update`s are answered with an error
  /// naming [rejectParam].
  int rejectUpdates = 0;
  String rejectParam = '';

  /// Refuses the upgrade with this status.
  int? refuseWith;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requestHeaders.add(request.headers);
      requestUris.add(request.uri);
      if (refuseWith != null) {
        request.response.statusCode = refuseWith!;
        await request.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      socket = ws;
      ws.add(jsonEncode({'type': 'session.created', 'session': {}}));
      ws.listen((raw) {
        final event = jsonDecode(raw as String) as Map<String, dynamic>;
        received.add(event);
        if (event['type'] == 'session.update') {
          if (rejectUpdates > 0) {
            rejectUpdates--;
            ws.add(
              jsonEncode({
                'type': 'error',
                'error': {
                  'type': 'invalid_request_error',
                  'code': 'unknown_parameter',
                  'message': 'Unknown parameter: $rejectParam.',
                  'param': rejectParam,
                },
              }),
            );
          } else {
            try {
              ws.add(jsonEncode({'type': 'session.updated', 'session': {}}));
            } catch (_) {
              /* the client has gone */
            }
          }
        }
      });
    });
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}/v1/realtime');

  void send(Map<String, Object?> event) => socket!.add(jsonEncode(event));

  Iterable<Map<String, dynamic>> of(String type) =>
      received.where((e) => e['type'] == type);

  /// The [nth] event of [type] the client sent (waits for it).
  Future<Map<String, dynamic>> waitFor(String type, {int nth = 1}) async {
    for (var i = 0; i < 300; i++) {
      final found = of(type).toList();
      if (found.length >= nth) return found[nth - 1];
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail(
      'the client never sent $type #$nth; got '
      '${received.map((e) => e['type']).toList()}',
    );
  }

  Future<void> stop() async {
    await socket?.close();
    await _server.close(force: true);
  }
}

Future<void> until(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(reason ?? 'condition never became true');
}

/// Gives the client time to (not) do something.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 120));

String b64(List<int> bytes) => base64Encode(bytes);

void main() {
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
    List<Map<String, Object?>>? tools,
    String prompt = '你是语音助理。',
    AgentReasoning reasoning = AgentReasoning.low,
  }) => OpenAiRealtimeSession(
    reasoning: reasoning,
    apiKey: 'sk-test-key-0123456789abcdef0123',
    systemPrompt: prompt,
    tools: tools ?? agentModeToolDeclarations(),
    endpoint: server.uri,
    voice: 'cedar',
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

  Future<OpenAiRealtimeSession> connected({
    List<Map<String, Object?>>? tools,
  }) async {
    final s = session(tools: tools);
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
    test(
      'connects with the key as a bearer token and sends one update',
      () async {
        await connected();
        expect(
          server.requestHeaders.single.value('authorization'),
          'Bearer sk-test-key-0123456789abcdef0123',
        );
        expect(server.of('session.update'), hasLength(1));
        // The key is never put in the log.
        expect(logs.join('\n'), isNot(contains('sk-test')));
      },
    );

    test(
      'the session.update carries prompt, tools, voice, audio and VAD',
      () async {
        await connected();
        final update = await server.waitFor('session.update');
        final s = update['session'] as Map<String, dynamic>;
        expect(s['type'], 'realtime');
        expect(s['output_modalities'], ['audio']);
        expect(s['instructions'], '你是语音助理。');
        expect(s['reasoning'], {'effort': 'low'});
        final audioConfig = s['audio'] as Map<String, dynamic>;
        expect(audioConfig['input']['format'], {
          'type': 'audio/pcm',
          'rate': 24000,
        });
        expect(audioConfig['output']['format'], {
          'type': 'audio/pcm',
          'rate': 24000,
        });
        expect(audioConfig['output']['voice'], 'cedar');
        expect(audioConfig['input']['transcription']['model'], isNotEmpty);
        final vad =
            audioConfig['input']['turn_detection'] as Map<String, dynamic>;
        expect(vad['type'], 'server_vad');
        expect(vad['silence_duration_ms'], lessThanOrEqualTo(500));
        expect(vad['create_response'], isTrue);
        expect(vad['interrupt_response'], isTrue);
      },
    );

    test(
      'every tool reaches the model with its name, description and schema',
      () async {
        await connected();
        final update = await server.waitFor('session.update');
        final sent = (update['session']['tools'] as List)
            .cast<Map<String, dynamic>>();
        final all = agentModeToolDeclarations();
        expect(sent.length, all.length);
        for (var i = 0; i < sent.length; i++) {
          final source = all[i];
          expect(sent[i]['type'], 'function');
          expect(sent[i]['name'], source['name']);
          expect(sent[i]['description'], source['description']);
          expect(
            sent[i]['parameters'],
            source['parameters'] ??
                {'type': 'object', 'properties': <String, Object?>{}},
          );
          expect(sent[i].containsKey('behavior'), isFalse);
        }
      },
    );

    test('the reasoning effort is the one chosen in the voice settings', () {
      for (final r in AgentReasoning.values) {
        expect(session(reasoning: r).sessionConfig()['reasoning'], {
          'effort': r.name,
        }, reason: r.name);
      }
    });

    test(
      'a refused effort steps down one level at a time, then goes',
      () async {
        server
          ..rejectUpdates = 2
          ..rejectParam = 'session.reasoning.effort';
        final s = session(reasoning: AgentReasoning.high);
        await s.connect();
        addTearDown(s.close);
        final efforts = [
          for (final u in server.of('session.update'))
            (u['session'] as Map)['reasoning'],
        ];
        expect(efforts, [
          {'effort': 'high'},
          {'effort': 'medium'},
          {'effort': 'low'},
        ]);
      },
    );

    test('the session config is the same every time (the cache applies)', () {
      final a = session().sessionConfig();
      final b = session().sessionConfig();
      expect(jsonEncode(a), jsonEncode(b));
      expect(a.keys.first, 'type');
      // Nothing that changes sits in front of the instructions.
      expect(jsonEncode(a), isNot(contains('timestamp')));
    });

    test(
      'an update that names an optional setting is retried without it',
      () async {
        server
          ..rejectUpdates = 1
          ..rejectParam = 'session.reasoning';
        await connected();
        expect(server.of('session.update'), hasLength(2));
        final second = server.of('session.update').last['session'];
        expect(second.containsKey('reasoning'), isFalse);
      },
    );

    test('a refusal that names nothing optional is an error', () async {
      server
        ..rejectUpdates = 1
        ..rejectParam = 'session.tools';
      final s = session();
      await expectLater(
        s.connect(),
        throwsA(
          isA<OpenAiRealtimeException>().having(
            (e) => e.message,
            'message',
            contains('session.tools'),
          ),
        ),
      );
      expect(s.connected, isFalse);
    });

    test('a refused key says so', () async {
      server.refuseWith = 401;
      await expectLater(
        session().connect(),
        throwsA(
          isA<OpenAiRealtimeException>().having(
            (e) => e.message,
            'message',
            contains('Key'),
          ),
        ),
      );
    });
  });

  group('audio', () {
    test('microphone audio is sent at 24 kHz', () async {
      final s = await connected();
      // 20 ms at 16 kHz is 320 samples; at 24 kHz it is 480.
      s.sendAudio(Uint8List(640));
      final append = await server.waitFor('input_audio_buffer.append');
      expect(
        base64Decode(append['audio'] as String).length,
        inInclusiveRange(958, 960),
      );
    });

    test(
      'ending the microphone sends silence so the server ends the turn',
      () async {
        final s = await connected();
        s.endAudio();
        final append = await server.waitFor('input_audio_buffer.append');
        final bytes = base64Decode(append['audio'] as String);
        // More than the VAD silence, all zeros, 24 kHz PCM16.
        expect(
          bytes.length,
          greaterThan(24000 * 2 * OpenAiRealtimeSession.silenceMs ~/ 1000),
        );
        expect(bytes.every((b) => b == 0), isTrue);
      },
    );

    test('speech from the model reaches onAudio unchanged', () async {
      await connected();
      server.send({
        'type': 'response.output_audio.delta',
        'response_id': 'r1',
        'item_id': 'i1',
        'content_index': 0,
        'delta': b64([1, 2, 3, 4]),
      });
      await until(() => audio.isNotEmpty);
      expect(audio.single, [1, 2, 3, 4]);
    });
  });

  group('transcripts', () {
    test(
      'what the model says and what the person said are passed on',
      () async {
        await connected();
        server
          ..send({
            'type': 'response.output_audio_transcript.delta',
            'item_id': 'i1',
            'delta': '你好',
          })
          ..send({
            'type': 'conversation.item.input_audio_transcription.delta',
            'item_id': 'u1',
            'delta': '看看',
          })
          ..send({
            'type': 'conversation.item.input_audio_transcription.delta',
            'item_id': 'u1',
            'delta': '任务',
          })
          ..send({
            'type': 'conversation.item.input_audio_transcription.completed',
            'item_id': 'u1',
            'transcript': '看看任务',
          });
        await until(() => outputs.isNotEmpty && inputs.length >= 2);
        await settle();
        expect(outputs, ['你好']);
        // Streamed pieces are not repeated by the final transcript.
        expect(inputs, ['看看', '任务']);
      },
    );

    test('a transcript that only arrives complete is passed on once', () async {
      await connected();
      server.send({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'u2',
        'transcript': '你好吗',
      });
      await until(() => inputs.isNotEmpty);
      expect(inputs, ['你好吗']);
    });
  });

  group('turns', () {
    test('a response without tools completes the turn', () async {
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send({
          'type': 'response.done',
          'response': {'id': 'r1', 'status': 'completed', 'output': []},
        });
      await until(() => turns == 1);
    });

    test('the usage of a response is logged, cached tokens included', () async {
      await connected();
      server.send({
        'type': 'response.done',
        'response': {
          'id': 'r9',
          'status': 'completed',
          'output': [],
          'usage': {
            'total_tokens': 253,
            'input_tokens': 132,
            'output_tokens': 121,
            'input_token_details': {
              'text_tokens': 119,
              'audio_tokens': 13,
              'cached_tokens': 64,
              'cached_tokens_details': {'text_tokens': 64, 'audio_tokens': 0},
            },
            'output_token_details': {'text_tokens': 30, 'audio_tokens': 91},
          },
        },
      });
      await until(() => logs.any((l) => l.startsWith('usage')));
      final line = logs.firstWhere((l) => l.startsWith('usage'));
      expect(line, contains('input=132'));
      expect(line, contains('cached=64 48%'));
      expect(line, contains('output=121'));
      expect(line, contains('audio=91'));
    });

    test('text from the app asks for a response', () async {
      final s = await connected();
      s.sendText('（屏幕提示）有新消息');
      final item = await server.waitFor('conversation.item.create');
      expect(item['item']['role'], 'user');
      expect(item['item']['content'], [
        {'type': 'input_text', 'text': '（屏幕提示）有新消息'},
      ]);
      await server.waitFor('response.create');
    });

    test(
      'text sent while the model is answering waits for it to finish',
      () async {
        final s = await connected();
        server.send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        });
        await settle();
        s.sendText('再问一句');
        await server.waitFor('conversation.item.create');
        await settle();
        expect(server.of('response.create'), isEmpty);
        server.send({
          'type': 'response.done',
          'response': {'id': 'r1', 'status': 'completed', 'output': []},
        });
        await server.waitFor('response.create');
      },
    );
  });

  group('tool calls', () {
    Map<String, Object?> call(
      String name, {
      String id = 'call_1',
      String args = '{}',
      String response = 'r1',
    }) => {
      'type': 'response.function_call_arguments.done',
      'response_id': response,
      'item_id': 'fc_$id',
      'output_index': 0,
      'call_id': id,
      'name': name,
      'arguments': args,
    };

    Map<String, Object?> done({
      String id = 'r1',
      String status = 'completed',
      bool withCall = true,
    }) => {
      'type': 'response.done',
      'response': {
        'id': id,
        'status': status,
        'output': [
          if (withCall) {'type': 'function_call'},
        ],
      },
    };

    test('call, handler, function_call_output, then response.create', () async {
      handler = (name, args) async => {
        'ok': true,
        'shown': [name, args['name']],
      };
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send(call('open_channel', args: '{"name":"general"}'))
        ..send(done());
      final output = await server.waitFor('conversation.item.create');
      expect(calls.single.$1, 'open_channel');
      expect(calls.single.$2, {'name': 'general'});
      expect(output['item']['type'], 'function_call_output');
      expect(output['item']['call_id'], 'call_1');
      // The result goes back intact, as JSON.
      expect(jsonDecode(output['item']['output'] as String), {
        'ok': true,
        'shown': ['open_channel', 'general'],
      });
      await server.waitFor('response.create');
      // The order: output first, then the request to go on.
      final order = server.received.map((e) => e['type']).toList();
      expect(
        order.indexOf('conversation.item.create'),
        lessThan(order.indexOf('response.create')),
      );
      // A response that called a tool is not the end of the turn.
      expect(turns, 0);
    });

    test('a handler that throws is answered with an error', () async {
      handler = (name, args) async => throw StateError('boom');
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send(call('open_channel'))
        ..send(done());
      final output = await server.waitFor('conversation.item.create');
      expect(
        jsonDecode(output['item']['output'] as String)['error'],
        contains('boom'),
      );
      await server.waitFor('response.create');
    });

    test(
      'several calls of one response are answered, then one response.create',
      () async {
        await connected();
        server
          ..send({
            'type': 'response.created',
            'response': {'id': 'r1'},
          })
          ..send(call('open_channel', id: 'a'))
          ..send(call('next_batch', id: 'b'))
          ..send(done());
        await server.waitFor('conversation.item.create', nth: 2);
        await server.waitFor('response.create');
        await settle();
        expect(
          server
              .of('conversation.item.create')
              .map((e) => e['item']['call_id']),
          containsAll(['a', 'b']),
        );
        expect(server.of('response.create'), hasLength(1));
      },
    );

    test('screen operations run in the order they were called', () async {
      final order = <String>[];
      handler = (name, args) async {
        if (name == 'begin_surface') {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        order.add(name);
        return {'ok': true};
      };
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send(call('begin_surface', id: 'a'))
        ..send(call('add_component', id: 'b'))
        ..send(done());
      await server.waitFor('conversation.item.create', nth: 2);
      expect(order, ['begin_surface', 'add_component']);
    });

    test('a non-blocking answer carries no Gemini scheduling field', () async {
      handler = (name, args) async => {'ok': true, 'screen': 'x'};
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send(call('spotlight', args: '{"number":2}'))
        ..send(done());
      final output = await server.waitFor('conversation.item.create');
      expect(jsonDecode(output['item']['output'] as String), {
        'ok': true,
        'screen': 'x',
      });
    });

    test(
      'arguments that are not JSON are answered without running the tool',
      () async {
        await connected();
        server
          ..send({
            'type': 'response.created',
            'response': {'id': 'r1'},
          })
          ..send(call('open_channel', args: '{oops'))
          ..send(done());
        final output = await server.waitFor('conversation.item.create');
        expect(
          jsonDecode(output['item']['output'] as String)['error'],
          contains('JSON'),
        );
        expect(calls, isEmpty);
      },
    );

    test('a slow tool is answered with an error after the timeout', () async {
      handler = (name, args) => Completer<Map<String, Object?>>().future;
      final s = OpenAiRealtimeSession(
        apiKey: 'sk-test-key-0123456789abcdef0123',
        systemPrompt: 'p',
        tools: agentModeToolDeclarations(),
        endpoint: server.uri,
        log: logs.add,
        toolTimeout: const Duration(milliseconds: 50),
        onToolCall: (name, args) => handler(name, args),
      );
      await s.connect();
      addTearDown(s.close);
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send(call('open_channel'))
        ..send(done());
      final output = await server.waitFor('conversation.item.create');
      expect(
        jsonDecode(output['item']['output'] as String)['error'],
        isNotEmpty,
      );
    });

    test('the same tools run the same way as for Gemini', () {
      // The shared responder is what answers every call exactly once.
      expect(
        GeminiLiveSession.nonBlockingNames(agentModeToolDeclarations()),
        containsAll(['spotlight', 'begin_surface', 'set_mood']),
      );
    });
  });

  group('interruption', () {
    test(
      'speaking over the model stops playback and truncates what was not heard',
      () async {
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
      },
    );

    test('speaking when the model is silent interrupts nothing', () async {
      await connected();
      server.send({
        'type': 'input_audio_buffer.speech_started',
        'audio_start_ms': 0,
        'item_id': 'u1',
      });
      await settle();
      expect(interrupted, 0);
      expect(server.of('conversation.item.truncate'), isEmpty);
    });

    test('a call from a response the person spoke over is not run', () async {
      await connected();
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send({
          'type': 'input_audio_buffer.speech_started',
          'audio_start_ms': 0,
          'item_id': 'u1',
        });
      await settle();
      server
        ..send({
          'type': 'response.function_call_arguments.done',
          'response_id': 'r1',
          'item_id': 'fc',
          'call_id': 'late',
          'name': 'open_channel',
          'arguments': '{"name":"x"}',
        })
        ..send({
          'type': 'response.done',
          'response': {
            'id': 'r1',
            'status': 'cancelled',
            'output': [
              {'type': 'function_call'},
            ],
          },
        });
      final output = await server.waitFor('conversation.item.create');
      expect(output['item']['call_id'], 'late');
      expect(calls, isEmpty);
      await settle();
      // The person is talking: the server answers them, we do not go on.
      expect(server.of('response.create'), isEmpty);
      expect(turns, 0);
    });

    test(
      'a slow tool finishing after the person spoke does not continue',
      () async {
        final gate = Completer<Map<String, Object?>>();
        handler = (name, args) => gate.future;
        await connected();
        server
          ..send({
            'type': 'response.created',
            'response': {'id': 'r1'},
          })
          ..send({
            'type': 'response.function_call_arguments.done',
            'response_id': 'r1',
            'item_id': 'fc',
            'call_id': 'slow',
            'name': 'list_agents',
            'arguments': '{}',
          })
          ..send({
            'type': 'response.done',
            'response': {
              'id': 'r1',
              'status': 'completed',
              'output': [
                {'type': 'function_call'},
              ],
            },
          })
          ..send({
            'type': 'input_audio_buffer.speech_started',
            'audio_start_ms': 0,
            'item_id': 'u1',
          })
          ..send({
            'type': 'input_audio_buffer.speech_stopped',
            'audio_end_ms': 5,
          });
        await settle();
        gate.complete({'agents': []});
        await server.waitFor('conversation.item.create');
        await settle();
        expect(server.of('response.create'), isEmpty);
      },
    );
  });

  group('errors and closing', () {
    test('the server closing the socket is reported', () async {
      await connected();
      await server.socket!.close(1001, 'session expired');
      await until(() => closed.isNotEmpty);
      expect(closed.single, 'session expired');
    });

    test('closing it ourselves is quiet', () async {
      final s = await connected();
      await s.close();
      await settle();
      expect(closed, isEmpty);
      expect(s.connected, isFalse);
    });

    test(
      'an error event after setup is logged and the session stays',
      () async {
        final s = await connected();
        server.send({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'code': 'x',
            'message': 'Something small',
          },
        });
        await until(() => logs.any((l) => l.contains('Something small')));
        expect(s.connected, isTrue);
        expect(closed, isEmpty);
      },
    );

    test('a failed response ends the session with the reason', () async {
      await connected();
      server.send({
        'type': 'response.done',
        'response': {
          'id': 'r1',
          'status': 'failed',
          'output': [],
          'status_details': {
            'type': 'failed',
            'error': {'type': 'insufficient_quota', 'message': '额度用完了'},
          },
        },
      });
      await until(() => closed.isNotEmpty);
      expect(closed.single, '额度用完了');
    });
  });

  group('Pcm16Resampler', () {
    Uint8List ramp(int from, int count) {
      final b = ByteData(count * 2);
      for (var i = 0; i < count; i++) {
        b.setInt16(i * 2, (from + i) * 10, Endian.little);
      }
      return b.buffer.asUint8List();
    }

    test('16 kHz to 24 kHz makes three samples for two', () {
      final r = Pcm16Resampler(inRate: 16000, outRate: 24000);
      final out = r.convert(ramp(0, 300));
      // The last sample waits for its neighbour in the next chunk.
      expect(out.length ~/ 2, inInclusiveRange(448, 450));
    });

    test('chunk boundaries do not change the result', () {
      final whole = Pcm16Resampler(
        inRate: 16000,
        outRate: 24000,
      ).convert(ramp(0, 320));
      final r = Pcm16Resampler(inRate: 16000, outRate: 24000);
      final parts = BytesBuilder()
        ..add(r.convert(ramp(0, 7)))
        ..add(r.convert(ramp(7, 101)))
        ..add(r.convert(ramp(108, 1)))
        ..add(r.convert(ramp(109, 211)));
      final joined = parts.toBytes();
      final n = joined.length < whole.length ? joined.length : whole.length;
      expect(n, greaterThan(400));
      expect(joined.sublist(0, n), whole.sublist(0, n));
    });

    test('a steady level stays steady and a ramp stays a ramp', () {
      final r = Pcm16Resampler(inRate: 16000, outRate: 24000);
      final b = ByteData(200)..setInt16(0, 0);
      for (var i = 0; i < 100; i++) {
        b.setInt16(i * 2, 1000, Endian.little);
      }
      final flat = ByteData.sublistView(r.convert(b.buffer.asUint8List()));
      for (var i = 0; i < flat.lengthInBytes ~/ 2; i++) {
        expect(flat.getInt16(i * 2, Endian.little), 1000);
      }
      final ramped = ByteData.sublistView(
        Pcm16Resampler(inRate: 16000, outRate: 24000).convert(ramp(0, 100)),
      );
      var previous = -1;
      for (var i = 0; i < ramped.lengthInBytes ~/ 2; i++) {
        final v = ramped.getInt16(i * 2, Endian.little);
        expect(v, greaterThanOrEqualTo(previous));
        previous = v;
      }
    });
  });

  group('providers', () {
    test('the right session is built for each provider', () {
      VoiceSession build(AgentVoiceProvider p) => createVoiceSession(
        provider: p,
        apiKey: 'k',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
        voice: 'v',
      );
      expect(build(AgentVoiceProvider.gemini), isA<GeminiLiveSession>());
      expect(build(AgentVoiceProvider.openai), isA<OpenAiRealtimeSession>());
      expect(build(AgentVoiceProvider.openai).model, 'gpt-realtime-2.1-mini');
    });

    test('a scanned key goes to the provider it belongs to', () {
      const gemini = 'AIzaSyA1234567890123456789012345678901234';
      const openai = 'sk-proj-abcdefghijklmnopqrstuvwxyz0123456789';
      final g = parseScannedKey(
        'GEMINI_API_KEY=$gemini\n',
        preferred: AgentVoiceProvider.openai,
      );
      expect(g?.provider, AgentVoiceProvider.gemini);
      expect(g?.key, gemini);
      final o = parseScannedKey(
        'OPENAI_API_KEY=$openai',
        preferred: AgentVoiceProvider.gemini,
      );
      expect(o?.provider, AgentVoiceProvider.openai);
      expect(o?.key, openai);
      // A bare token belongs to the provider chosen in the settings.
      final bare = parseScannedKey(
        'abcdefghijklmnopqrstuvwx',
        preferred: AgentVoiceProvider.openai,
      );
      expect(bare?.provider, AgentVoiceProvider.openai);
      expect(
        parseScannedKey(
          'https://example.com/a b',
          preferred: AgentVoiceProvider.gemini,
        ),
        isNull,
      );
      expect(
        parseScannedKey(null, preferred: AgentVoiceProvider.gemini),
        isNull,
      );
    });
  });
}
