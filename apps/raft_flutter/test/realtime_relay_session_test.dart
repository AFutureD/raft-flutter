import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_language.dart';
import 'package:raft_flutter/features/agent_mode/openai_realtime.dart';
import 'package:raft_flutter/features/agent_mode/voice_layer_text.dart';

import 'agent_openai_realtime_test.dart' show FakeRealtime, b64, settle, until;

/// OpenAI Realtime and Grok Voice as the voice of the layered brain
/// (`OpenAiRealtimeSession` with `relay: true`): it listens and transcribes,
/// never answers by itself and has no tools, and says only the lines the app
/// asks for, one at a time, until the person speaks over them.
///
/// OpenAI: out-of-band `response.create` (`conversation: none`) with the text
/// in its instructions; the server is told not to respond to the person.
/// https://developers.openai.com/api/docs/guides/realtime-conversations
/// Grok: a `force_message` item (text to speech, not model generated); a
/// response it starts by itself is cancelled.
/// https://docs.x.ai/voice-realtime.ws.json
void main() {
  late FakeRealtime server;
  final logs = <String>[];
  final audio = <Uint8List>[];
  final inputs = <String>[];
  var inputDone = 0, started = 0, stopped = 0, interrupted = 0;
  final timings = <(String, int)>[];
  Duration pending = Duration.zero;
  final calls = <String>[];

  setUp(() async {
    HttpOverrides.global = null;
    OpenAiRealtimeSession.resetFallbacks();
    server = FakeRealtime();
    await server.start();
    logs.clear();
    audio.clear();
    inputs.clear();
    calls.clear();
    inputDone = started = stopped = interrupted = 0;
    timings.clear();
    pending = Duration.zero;
  });
  tearDown(() => server.stop());

  OpenAiRealtimeSession relay(
    RealtimeService service, {
    AgentLanguage language = AgentLanguage.zh,
    String? model,
  }) => OpenAiRealtimeSession(
    service: service,
    relay: true,
    modelId: model,
    language: language,
    apiKey: 'sk-test-key-0123456789abcdef0123',
    systemPrompt: relayVoicePromptFor(language),
    tools: const [],
    endpoint: server.uri,
    voice: service == RealtimeService.grok ? 'eve' : 'marin',
    log: logs.add,
    playbackPending: () async => pending,
    relayLead: const Duration(milliseconds: 50),
    onToolCall: (name, args) async {
      calls.add(name);
      return {};
    },
    onAudio: audio.add,
    onInputText: inputs.add,
    onInputDone: () => inputDone++,
    onTiming: (name, ms) => timings.add((name, ms)),
    onSpeechStarted: () => started++,
    onSpeechStopped: () => stopped++,
    onInterrupted: () => interrupted++,
  );

  Future<OpenAiRealtimeSession> connected(
    RealtimeService service, {
    AgentLanguage language = AgentLanguage.zh,
    String? model,
  }) async {
    final s = relay(service, language: language, model: model);
    await s.connect();
    addTearDown(s.close);
    return s;
  }

  /// The server starts the response of the line the client just sent.
  Future<String> created(
    String id, {
    Map<String, Object?>? metadata,
    int nth = 1,
  }) async {
    server.send({
      'type': 'response.created',
      'response': {'id': id, 'metadata': ?metadata},
    });
    return id;
  }

  void sound(String id, {String text = 'x'}) {
    server.send({
      'type': 'response.output_audio.delta',
      'response_id': id,
      'item_id': 'item-$id',
      'delta': b64(List.filled(960, 1)),
    });
    server.send({
      'type': 'response.output_audio_transcript.delta',
      'response_id': id,
      'delta': text,
    });
  }

  void done(String id, {String status = 'completed'}) => server.send({
    'type': 'response.done',
    'response': {'id': id, 'status': status},
  });

  Map<String, dynamic> response(Map<String, dynamic> event) =>
      event['response'] as Map<String, dynamic>;

  group('OpenAI Realtime as the relay voice', () {
    const service = RealtimeService.openai;

    test('the session: the relay instruction, no tools, the server told not '
        'to answer or interrupt by itself, the chosen model', () async {
      await connected(service, model: 'gpt-realtime-2.1');
      final update = await server.waitFor('session.update');
      final s = update['session'] as Map<String, dynamic>;
      expect(s['instructions'], relayVoicePromptFor(AgentLanguage.zh));
      expect(s.containsKey('tools'), isFalse);
      final vad = s['audio']['input']['turn_detection'] as Map<String, dynamic>;
      expect(vad['type'], 'server_vad');
      expect(vad['create_response'], isFalse);
      expect(vad['interrupt_response'], isFalse);
      expect(s['audio']['output']['voice'], 'marin');
      expect(s['audio']['input']['transcription'], isNotEmpty);
      expect(logs.join('\n'), isNot(contains('sk-test')));
    });

    test('the model is the one chosen, else the session\'s own', () {
      OpenAiRealtimeSession make(String? model) => OpenAiRealtimeSession(
        relay: true,
        modelId: model,
        apiKey: 'k',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
      );
      expect(
        make('gpt-realtime-2.1').endpoint.toString(),
        'wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1',
      );
      expect(make('gpt-realtime-2.1').model, 'gpt-realtime-2.1');
      expect(make(null).model, OpenAiRealtimeSession.modelName);
      final grok = OpenAiRealtimeSession(
        service: RealtimeService.grok,
        relay: true,
        modelId: 'grok-voice-3.0',
        apiKey: 'k',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
      );
      expect(
        grok.endpoint.toString(),
        'wss://api.x.ai/v1/realtime?model=grok-voice-3.0',
      );
    });

    test('a line is an out-of-band response with the text to repeat, no '
        'conversation and no context; the sound and the transcript are the '
        'line\'s', () async {
      final s = await connected(service);
      var begun = 0;
      final h = s.say('已经把 136 标成完成。', onStart: () => begun++);
      final event = await server.waitFor('response.create');
      final r = response(event);
      expect(r['conversation'], 'none');
      expect(r['input'], isEmpty);
      expect(r['output_modalities'], ['audio']);
      expect(r['instructions'], contains('已经把 136 标成完成。'));
      expect(r['instructions'], contains('原样'));
      expect(r['instructions'], contains(AgentLanguage.zh.relayLine));
      final tag = (r['metadata'] as Map)['relay'];
      expect(tag, isNotNull);
      expect(s.speaksExactly, isFalse);
      await created('r1', metadata: {'relay': tag});
      sound('r1', text: '已经把');
      await until(() => audio.isNotEmpty);
      expect(begun, 1);
      expect(h.started, isTrue);
      sound('r1', text: '完成。');
      await until(() => h.transcript.contains('完成'));
      expect(h.transcript, '已经把完成。');
      expect(h.finished, isFalse);
      done('r1');
      await h.done.timeout(const Duration(seconds: 2));
      expect(h.cancelled, isFalse);
    });

    test('lines go one at a time: the next is asked for when the previous '
        'is generated', () async {
      final s = await connected(service);
      final a = s.say('第一句。');
      final b = s.say('第二句。');
      await server.waitFor('response.create');
      await settle();
      expect(server.of('response.create'), hasLength(1));
      final tag =
          (response(server.of('response.create').first)['metadata']
              as Map)['relay'];
      await created('r1', metadata: {'relay': tag});
      sound('r1');
      done('r1');
      await a.done.timeout(const Duration(seconds: 2));
      final second = await server.waitFor('response.create', nth: 2);
      expect(response(second)['instructions'], contains('第二句。'));
      await created(
        'r2',
        metadata: {'relay': (response(second)['metadata'] as Map)['relay']},
      );
      sound('r2');
      done('r2');
      await b.done.timeout(const Duration(seconds: 2));
    });

    test('a line is done a moment before its sound has played out, so the '
        'next one is ready in time', () async {
      final s = await connected(service);
      final h = s.say('一句。');
      final tag =
          (response(await server.waitFor('response.create'))['metadata']
              as Map)['relay'];
      await created('r1', metadata: {'relay': tag});
      sound('r1');
      pending = const Duration(milliseconds: 400);
      done('r1');
      await settle();
      // 400 ms still to play, 50 ms of lead: done in about 350 ms.
      expect(h.finished, isFalse);
      await h.done.timeout(const Duration(seconds: 2));
      expect(h.cancelled, isFalse);
    });

    test('a lead-in is phrased by the model from what the person asked, '
        'without repeating the ones already used', () async {
      final s = await connected(service);
      s.lead('看一下 Cody 那边的消息', avoid: const ['好嘞，翻一下未读。']);
      final r = response(await server.waitFor('response.create'));
      final text = r['instructions'] as String;
      expect(r['conversation'], 'none');
      expect(text, contains('看一下 Cody 那边的消息'));
      expect(text, contains('好嘞，翻一下未读。'));
      expect(text, contains('不要客服腔'));
      expect(text, contains('好的例子'));
      expect(text, contains('不好的例子'));
      expect(text, isNot(contains('"""')), reason: 'not a line to repeat');
    });

    test('English: the instructions are in the language chosen', () async {
      final s = await connected(service, language: AgentLanguage.en);
      s.say('Done.');
      s.lead('read the unread');
      final first = response(await server.waitFor('response.create'));
      expect(first['instructions'], contains(AgentLanguage.en.relayLine));
      expect(first['instructions'], contains('exactly as written'));
      final update = await server.waitFor('session.update');
      expect(
        (update['session'] as Map)['instructions'],
        relayVoicePromptFor(AgentLanguage.en),
      );
    });

    test('cutting the speech cancels the response, drops the sound that '
        'still comes and what is queued', () async {
      final s = await connected(service);
      final a = s.say('第一句。');
      final b = s.say('第二句。');
      final tag =
          (response(await server.waitFor('response.create'))['metadata']
              as Map)['relay'];
      await created('r1', metadata: {'relay': tag});
      sound('r1');
      await until(() => audio.length == 1);
      s.cancelSpeech();
      final cancel = await server.waitFor('response.cancel');
      expect(cancel['response_id'], 'r1');
      expect(a.cancelled, isTrue);
      expect(b.cancelled, isTrue);
      await a.done.timeout(const Duration(seconds: 1));
      await b.done.timeout(const Duration(seconds: 1));
      sound('r1');
      done('r1', status: 'cancelled');
      await settle();
      expect(audio, hasLength(1), reason: 'late sound is dropped');
      expect(
        server.of('response.create'),
        hasLength(1),
        reason: 'b never sent',
      );
    });

    test('the person speaking is reported, and the server does not cut the '
        'speech itself: the app does', () async {
      await connected(service);
      server.send({'type': 'input_audio_buffer.speech_started'});
      await until(() => started == 1);
      server.send({'type': 'input_audio_buffer.speech_stopped'});
      await until(() => stopped == 1);
      expect(server.of('conversation.item.truncate'), isEmpty);
      expect(server.of('response.cancel'), isEmpty);
      expect(interrupted, 0);
    });

    test('the transcript, and its end: the person\'s turn is over', () async {
      await connected(service);
      server.send({
        'type': 'conversation.item.input_audio_transcription.delta',
        'item_id': 'i1',
        'delta': '读一下',
      });
      server.send({
        'type': 'conversation.item.input_audio_transcription.delta',
        'item_id': 'i1',
        'delta': '动态',
      });
      server.send({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'i1',
        'transcript': '读一下动态',
      });
      await until(() => inputDone == 1);
      expect(inputs.join(), '读一下动态');
      // A model that sends only the final text (whisper-1).
      server.send({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'i2',
        'transcript': '下一件',
      });
      await until(() => inputDone == 2);
      expect(inputs.last, '下一件');
    });

    test('a tool call of the model is never run and never answered', () async {
      await connected(service);
      server.send({
        'type': 'response.function_call_arguments.done',
        'call_id': 'c1',
        'name': 'send_message',
        'response_id': 'rx',
        'arguments': '{"text":"hi"}',
      });
      await settle();
      expect(calls, isEmpty);
      expect(server.of('conversation.item.create'), isEmpty);
      expect(logs.join('\n'), contains('ignored a tool call'));
    });

    test(
      'an error for a request ends that line, and the next goes on',
      () async {
        final s = await connected(service);
        final a = s.say('一。');
        final b = s.say('二。');
        await server.waitFor('response.create');
        server.send({
          'type': 'error',
          'error': {'type': 'invalid_request_error', 'message': 'no'},
        });
        await a.done.timeout(const Duration(seconds: 2));
        final second = await server.waitFor('response.create', nth: 2);
        expect(response(second)['instructions'], contains('二。'));
        expect(b.finished, isFalse);
      },
    );

    test('a line on a closed session is failed at once', () async {
      final s = await connected(service);
      await s.close();
      final h = s.say('没人听。');
      expect(h.failed, isTrue);
      await h.done.timeout(const Duration(seconds: 1));
    });

    test('drained waits for what is queued, then for the playback', () async {
      final s = await connected(service);
      final h = s.say('一句。');
      final tag =
          (response(await server.waitFor('response.create'))['metadata']
              as Map)['relay'];
      var drained = false;
      s.drained().then((_) => drained = true);
      await settle();
      expect(drained, isFalse);
      await created('r1', metadata: {'relay': tag});
      sound('r1');
      pending = const Duration(milliseconds: 150);
      done('r1');
      await h.done;
      await until(() => drained);
    });
  });

  group('Grok Voice as the relay voice', () {
    const service = RealtimeService.grok;

    test('the session: the relay instruction, no tools, server VAD', () async {
      await connected(service, model: 'grok-voice-3.0');
      final update = await server.waitFor('session.update');
      final s = update['session'] as Map<String, dynamic>;
      expect(s['instructions'], relayVoicePromptFor(AgentLanguage.zh));
      expect(s.containsKey('tools'), isFalse);
      expect(s['turn_detection'], {'type': 'server_vad'});
      expect(s['voice'], 'eve');
    });

    test(
      'a line is a force_message: the text exactly, no response.create',
      () async {
        final s = await connected(service);
        expect(s.speaksExactly, isTrue);
        var begun = 0;
        final h = s.say('已经标成完成。', onStart: () => begun++);
        final event = await server.waitFor('conversation.item.create');
        final item = event['item'] as Map<String, dynamic>;
        expect(item['type'], 'force_message');
        expect(item['role'], 'assistant');
        expect(item['content'], [
          {'type': 'output_text', 'text': '已经标成完成。'},
        ]);
        await settle();
        expect(server.of('response.create'), isEmpty);
        // The server injects the response lifecycle: no metadata on it.
        await created('g1');
        sound('g1');
        await until(() => audio.isNotEmpty);
        expect(begun, 1);
        done('g1');
        await h.done.timeout(const Duration(seconds: 2));
        expect(h.cancelled, isFalse);
      },
    );

    test('a response Grok starts by itself for the person is cancelled and '
        'its sound dropped; the line still plays', () async {
      final s = await connected(service);
      // The person spoke; Grok answers by itself.
      await created('auto1');
      final cancel = await server.waitFor('response.cancel');
      expect(cancel['response_id'], 'auto1');
      sound('auto1');
      await settle();
      expect(audio, isEmpty);
      done('auto1', status: 'cancelled');
      // Then the app's line.
      final h = s.say('好的。');
      await server.waitFor('conversation.item.create');
      await created('g1');
      sound('g1');
      await until(() => audio.length == 1);
      done('g1');
      await h.done.timeout(const Duration(seconds: 2));
    });

    test('a lead-in is a response with instructions that replace the '
        'session\'s for that response only, and a tag', () async {
      final s = await connected(service);
      s.lead('看一下消息');
      final r = response(await server.waitFor('response.create'));
      expect(r['instructions'], contains('看一下消息'));
      expect(r['modalities'], ['audio']);
      expect(r.containsKey('conversation'), isFalse);
      expect(r.containsKey('input'), isFalse);
      final tag = (r['metadata'] as Map)['relay'];
      await created('g1', metadata: {'relay': tag});
      sound('g1', text: '嗯，我看看。');
      done('g1');
    });

    test('cutting the speech cancels the response', () async {
      final s = await connected(service);
      final h = s.say('长长的一句。');
      await server.waitFor('conversation.item.create');
      await created('g1');
      sound('g1');
      await until(() => audio.isNotEmpty);
      s.cancelSpeech();
      final cancel = await server.waitFor('response.cancel');
      expect(cancel['response_id'], 'g1');
      expect(h.cancelled, isTrue);
      sound('g1');
      await settle();
      expect(audio, hasLength(1));
    });

    test('the transcript completes the person\'s turn', () async {
      await connected(service);
      server.send({
        'type': 'conversation.item.input_audio_transcription.updated',
        'item_id': 'i1',
        'transcript': '读一下',
      });
      server.send({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'i1',
        'transcript': '读一下动态',
      });
      await until(() => inputDone == 1);
      expect(inputs.join(), '读一下动态');
    });
  });

  group('where the time goes, and the first sound within a second', () {
    for (final service in RealtimeService.values) {
      test('${service.name}: the socket round trip is measured once, with a '
          'request that changes nothing', () async {
        await connected(service);
        await until(() => timings.any((t) => t.$1 == 'rtt'));
        expect(timings.where((t) => t.$1 == 'rtt'), hasLength(1));
        expect(server.of('session.update'), hasLength(2));
        final a = server.of('session.update').first['session'];
        final b = server.of('session.update').last['session'];
        expect(jsonEncode(b), jsonEncode(a), reason: 'the same settings');
        expect(logs.join('\n'), contains('socket round trip'));
      });

      test('${service.name}: the transcript takes (speech stopped to '
          'transcript complete), and for a line the request to the response '
          'and the response to the first sound', () async {
        final s = await connected(service);
        server.send({'type': 'input_audio_buffer.speech_stopped'});
        await until(() => stopped == 1);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        server.send({
          'type': 'conversation.item.input_audio_transcription.completed',
          'item_id': 'i1',
          'transcript': '读一下',
        });
        await until(() => timings.any((t) => t.$1 == 'transcribe'));
        expect(
          timings.firstWhere((t) => t.$1 == 'transcribe').$2,
          greaterThanOrEqualTo(25),
        );
        final h = s.say('好。');
        final isGrok = service == RealtimeService.grok;
        final event = await server.waitFor(
          isGrok ? 'conversation.item.create' : 'response.create',
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final tag = isGrok
            ? null
            : (response(event)['metadata'] as Map)['relay'];
        await created('r1', metadata: tag == null ? null : {'relay': tag});
        await until(() => timings.any((t) => t.$1 == 'say.created'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        sound('r1');
        await until(() => timings.any((t) => t.$1 == 'say.firstAudio'));
        expect(
          timings.firstWhere((t) => t.$1 == 'say.created').$2,
          greaterThanOrEqualTo(25),
        );
        expect(
          timings.firstWhere((t) => t.$1 == 'say.firstAudio').$2,
          greaterThanOrEqualTo(25),
        );
        expect(
          timings.where((t) => t.$1 == 'say.firstAudio'),
          hasLength(1),
          reason: 'the first sound only',
        );
        done('r1');
        await h.done.timeout(const Duration(seconds: 2));
      });

      test('${service.name}: the sound of a line is kept once and then '
          'played at once, with no request to the service', () async {
        final s = await connected(service);
        final isGrok = service == RealtimeService.grok;
        final making = s.prewarm(['嗯，我看看。']);
        final event = await server.waitFor(
          isGrok ? 'conversation.item.create' : 'response.create',
        );
        final tag = isGrok
            ? null
            : (response(event)['metadata'] as Map)['relay'];
        await created('c1', metadata: tag == null ? null : {'relay': tag});
        sound('c1');
        sound('c1');
        done('c1');
        await making.timeout(const Duration(seconds: 3));
        expect(audio, isEmpty, reason: 'made, not played');
        expect(s.hasClip('嗯，我看看。'), isTrue);
        expect(s.hasClip('别的。'), isFalse);
        final before = server.received.length;
        var begun = 0;
        final h = s.say('嗯，我看看。', onStart: () => begun++);
        expect(begun, 1, reason: 'sounds at once');
        expect(audio, hasLength(2));
        expect(h.transcript, '嗯，我看看。');
        await h.done.timeout(const Duration(seconds: 2));
        expect(server.received.length, before, reason: 'nothing was asked');
      });

      test(
        '${service.name}: a clip being made gives way to a real line',
        () async {
          final s = await connected(service);
          final isGrok = service == RealtimeService.grok;
          final making = s.prewarm(['嗯，我看看。']);
          await server.waitFor(
            isGrok ? 'conversation.item.create' : 'response.create',
          );
          await created('c1', metadata: null);
          s.say('真的一句。');
          final cancel = await server.waitFor('response.cancel');
          expect(cancel['response_id'], 'c1');
          await making.timeout(const Duration(seconds: 3));
          expect(s.hasClip('嗯，我看看。'), isFalse);
        },
      );
    }

    test('the relay asks for the least reasoning, and does without it when '
        'the model refuses it', () async {
      await connected(RealtimeService.openai);
      final first = (await server.waitFor('session.update'))['session'] as Map;
      expect(first['reasoning'], {'effort': 'minimal'});
      await server.stop();
      OpenAiRealtimeSession.resetFallbacks();
      server = FakeRealtime()
        ..rejectUpdates = 1
        ..rejectParam = 'reasoning.effort';
      await server.start();
      await connected(RealtimeService.openai);
      final updates = server.of('session.update').toList();
      expect(updates.length, greaterThanOrEqualTo(2));
      expect(
        (updates.last['session'] as Map).containsKey('reasoning'),
        isFalse,
      );
      expect(
        (updates.last['session'] as Map)['instructions'],
        relayVoicePromptFor(AgentLanguage.zh),
      );
    });

    test('a lead-in that goes on from the acknowledgment says so', () async {
      final s = await connected(RealtimeService.openai);
      s.lead('看一下消息', after: '嗯，我看看。');
      final text =
          response(await server.waitFor('response.create'))['instructions']
              as String;
      expect(text, contains('“嗯，我看看。”'));
      expect(text, contains('不要再说一遍'));
    });
  });

  test('a text session (not a relay) refuses to say lines', () async {
    final s = OpenAiRealtimeSession(
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      endpoint: server.uri,
    );
    expect(() => s.say('x'), throwsStateError);
    // (No connection was made.)
    await Future<void>.delayed(Duration.zero);
    expect(jsonEncode(server.received), '[]');
  });
}
