import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_tool_output.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/openai_realtime.dart';

import 'agent_openai_realtime_test.dart' show FakeRealtime, until;

// A tool result is whatever a handler returns. Before it goes to a realtime
// socket it is made valid JSON of a safe size (the orb's Activity page and
// briefing are big, full of CJK text and emoji). Fixture text only.

enum _Status { open, done }

class _Model {
  Map<String, Object?> toJson() => {'who': 'Cody', 'at': DateTime.utc(2026)};
}

/// An Activity-like result: [rows] rows of long mixed CJK / emoji text.
Map<String, Object?> activity(int rows, {int textChars = 1500}) => {
  'page': 'activity',
  'title': '动态',
  'loading': false,
  'items': [
    for (var i = 0; i < rows; i++)
      {
        'id': 'row-$i',
        'who': 'Cody',
        'where': '#raft-flutter',
        'unread': i.isEven,
        'time': DateTime.utc(2026, 1, 1, 0, i),
        'text': List.generate(
          textChars,
          (j) => j % 7 == 0 ? '🚀' : '这是一条很长的消息，说明发布流程。',
        ).join().substring(0, textChars),
      },
  ],
};

void main() {
  group('guardToolOutput', () {
    test('a small result goes out unchanged', () {
      final out = guardToolOutput({
        'ok': true,
        'items': [1, 'a', null],
      });
      expect(out.truncated, isFalse);
      expect(out.json, '{"ok":true,"items":[1,"a",null]}');
      expect(out.bytes, utf8.encode(out.json).length);
    });

    test('DateTime, BigInt, enum, Uri, NaN, toJson objects and odd values are '
        'plain JSON', () {
      final out = guardToolOutput({
        'at': DateTime.utc(2026, 1, 2, 3),
        'big': BigInt.parse('123456789012345678901234567890'),
        'status': _Status.done,
        'link': Uri.parse('/s/alpha/activity'),
        'nan': double.nan,
        'inf': double.infinity,
        'model': _Model(),
        'wait': const Duration(seconds: 2),
        'set': {1, 2},
      });
      final back = jsonDecode(out.json) as Map<String, dynamic>;
      expect(back['at'], '2026-01-02T03:00:00.000Z');
      expect(back['big'], '123456789012345678901234567890');
      expect(back['status'], 'done');
      expect(back['link'], '/s/alpha/activity');
      expect(back['nan'], isNull);
      expect(back['inf'], isNull);
      expect(back['model'], {'who': 'Cody', 'at': '2026-01-01T00:00:00.000Z'});
      expect(back['wait'], 2000);
      expect(back['set'], [1, 2]);
    });

    test('a lone surrogate (half an emoji) becomes U+FFFD, a pair is kept', () {
      final half = '🚀'.substring(0, 1);
      final out = guardToolOutput({'a': 'x${half}y', 'b': '🚀 ok'});
      expect(out.result['a'], 'x�y');
      expect(out.result['b'], '🚀 ok');
      // What dart:io writes to the socket is valid UTF-8 with no U+FFFD
      // introduced behind our back.
      expect(utf8.decode(utf8.encode(out.json)), out.json);
    });

    test('a large Activity (CJK, emoji) is cut to the limit and says so', () {
      final big = activity(60);
      final whole = utf8
          .encode(
            jsonEncode({
              ...big,
              'items': [
                for (final e in big['items']! as List)
                  {...(e as Map<String, Object?>), 'time': 't'},
              ],
            }),
          )
          .length;
      expect(whole, greaterThan(agentToolOutputLimit * 4));
      final out = guardToolOutput(big);
      expect(out.truncated, isTrue);
      expect(out.bytes, lessThanOrEqualTo(agentToolOutputLimit));
      expect(utf8.encode(out.json).length, out.bytes);
      final back = jsonDecode(out.json) as Map<String, dynamic>;
      expect(back['truncated'], isTrue);
      expect(back['truncatedNote'], contains('已截短'));
      expect(back['page'], 'activity');
      expect(back['items'], isNotEmpty);
      // The kept rows are the first ones, still whole objects.
      expect((back['items'] as List).first['id'], 'row-0');
      // No clip left half an emoji behind.
      for (final unit in out.json.codeUnits.indexed) {
        final u = unit.$2;
        if (u >= 0xD800 && u <= 0xDBFF) {
          final next = out.json.codeUnitAt(unit.$1 + 1);
          expect(next >= 0xDC00 && next <= 0xDFFF, isTrue);
        }
      }
    });

    test(
      'one enormous string is clipped too, and the result stays an object',
      () {
        final out = guardToolOutput({'text': '字' * 200000});
        expect(out.truncated, isTrue);
        expect(out.bytes, lessThanOrEqualTo(agentToolOutputLimit));
        expect((jsonDecode(out.json) as Map)['truncated'], isTrue);
      },
    );

    test('many keys: the last resort still names what was dropped', () {
      final out = guardToolOutput({
        for (var i = 0; i < 4000; i++) 'key$i': 'v',
      });
      expect(out.bytes, lessThanOrEqualTo(agentToolOutputLimit));
      expect((jsonDecode(out.json) as Map)['truncated'], isTrue);
    });
  });

  group('AgentToolResponder (Gemini Live and OpenAI)', () {
    test('answers a huge result with the guarded one, exactly once', () async {
      final sent = <Map<String, Object?>>[];
      final responder = AgentToolResponder(
        handler: (name, args) async => activity(60),
        send: (r) {
          sent.add(r);
          return true;
        },
        log: (_) {},
      );
      await responder.answer([
        {'id': 'c1', 'name': 'describe_page', 'args': <String, Object?>{}},
      ]);
      expect(sent, hasLength(1));
      final response = sent.single['response']! as Map<String, Object?>;
      expect(
        utf8.encode(jsonEncode(response)).length,
        lessThanOrEqualTo(agentToolOutputLimit),
      );
      expect(response['truncated'], isTrue);
    });

    test('an unencodable result still reaches the model as JSON', () async {
      final sent = <Map<String, Object?>>[];
      final responder = AgentToolResponder(
        handler: (name, args) async => {
          'at': DateTime.utc(2026),
          'k': _Status.open,
        },
        send: (r) {
          sent.add(r);
          return true;
        },
        log: (_) {},
      );
      await responder.answer([
        {'id': 'c1', 'name': 'navigate', 'args': <String, Object?>{}},
      ]);
      expect(jsonEncode(sent.single['response']), contains('2026-01-01'));
    });
  });

  group('OpenAI Realtime socket', () {
    late FakeRealtime server;
    final logs = <String>[];
    var tool = <String, Object?>{};

    setUp(() async {
      HttpOverrides.global = null;
      OpenAiRealtimeSession.resetFallbacks();
      server = FakeRealtime();
      await server.start();
      logs.clear();
    });
    tearDown(() => server.stop());

    Future<Map<String, dynamic>> callTool(Map<String, Object?> result) async {
      tool = result;
      final s = OpenAiRealtimeSession(
        apiKey: 'sk-test-key-0123456789abcdef0123',
        systemPrompt: '你是语音助理。',
        tools: const [
          {'name': 'describe_page', 'description': 'd'},
        ],
        endpoint: server.uri,
        voice: 'cedar',
        log: logs.add,
        onToolCall: (name, args) async => tool,
      );
      await s.connect();
      addTearDown(s.close);
      server
        ..send({
          'type': 'response.created',
          'response': {'id': 'r1'},
        })
        ..send({
          'type': 'response.function_call_arguments.done',
          'response_id': 'r1',
          'item_id': 'fc_1',
          'output_index': 0,
          'call_id': 'call_1',
          'name': 'describe_page',
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
        });
      final created = await server.waitFor('conversation.item.create');
      await server.waitFor('response.create');
      return created;
    }

    test('a big Activity arrives as a JSON string within the limit', () async {
      final created = await callTool(activity(60));
      final item = created['item'] as Map<String, dynamic>;
      expect(item['type'], 'function_call_output');
      expect(item['call_id'], 'call_1');
      final output = item['output'] as String;
      expect(
        utf8.encode(output).length,
        lessThanOrEqualTo(agentToolOutputLimit),
      );
      final back = jsonDecode(output) as Map<String, dynamic>;
      expect(back['truncated'], isTrue);
      expect(back['page'], 'activity');
    });

    test(
      'DateTime and enum results are encoded, not replaced by an error',
      () async {
        final created = await callTool({
          'at': DateTime.utc(2026, 1, 2),
          'status': _Status.done,
        });
        final back = jsonDecode(created['item']['output'] as String) as Map;
        expect(back['at'], '2026-01-02T00:00:00.000Z');
        expect(back['status'], 'done');
        expect(back.containsKey('error'), isFalse);
      },
    );

    test(
      'the log names event types and sizes, never the key or the text',
      () async {
        await callTool(activity(60));
        final text = logs.join('\n');
        expect(text, contains('send session.update'));
        expect(text, matches(RegExp(r'send conversation\.item\.create \d+B')));
        expect(text, matches(RegExp(r'send response\.create \d+B')));
        expect(text, isNot(contains('sk-test')));
        expect(text, isNot(contains('这是一条很长的消息')));
      },
    );

    test(
      'a close is logged with its code, reason and the last events',
      () async {
        await callTool({'ok': true});
        logs.clear();
        await server.socket!.close(1002, '');
        await until(() => logs.any((l) => l.contains('socket done')));
        final line = logs.firstWhere((l) => l.contains('socket done'));
        expect(line, contains('code=1002'));
        expect(line, contains('lastSent=response.create'));
        expect(line, contains('lastReceived=response.done'));
        expect(line, isNot(contains('sk-test')));
      },
    );
  });
}
