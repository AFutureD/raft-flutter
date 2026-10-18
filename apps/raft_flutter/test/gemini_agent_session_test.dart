import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_mode/agent_thinking.dart';
import 'package:raft_flutter/features/agent_mode/gemini_agent.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;

/// The text agent: the same prompt and tools as the realtime session, over
/// plain generateContent calls with a function-calling loop. A fake transport
/// stands in for the API.

const _models = {
  'models': [
    {
      'name': 'models/gemini-3-flash-preview',
      'supportedGenerationMethods': ['generateContent'],
    },
  ],
};

const _tools = [
  {
    'name': 'navigate',
    'behavior': 'NON_BLOCKING',
    'description': 'go',
    'parameters': {
      'type': 'object',
      'properties': {
        'to': {'type': 'string'},
      },
    },
  },
];

Map<String, Object?> _reply(List<Map<String, Object?>> parts) => {
  'candidates': [
    {
      'content': {'role': 'model', 'parts': parts},
    },
  ],
};

Map<String, Object?> _say(String text) => _reply([
  {'text': text},
]);

Map<String, Object?> _call(
  String name,
  Map<String, Object?> args, {
  String? signature,
}) => _reply([
  {
    'functionCall': {'name': name, 'args': args},
    'thoughtSignature': ?signature,
  },
]);

class Api {
  /// The generateContent replies in order; a completer waits for a gate.
  final replies = <Object>[];
  final requests = <Map<String, Object?>>[];
  final paths = <String>[];

  Future<({int status, String body})> call(
    Uri uri,
    String apiKey,
    Map<String, Object?>? body,
  ) async {
    paths.add(uri.path);
    if (body == null) return (status: 200, body: jsonEncode(_models));
    // What the API saw now, whatever the session does to its history later.
    requests.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    var next = replies.removeAt(0);
    if (next is Future) next = await next;
    if (next is int) return (status: next, body: '{}');
    return (status: 200, body: jsonEncode(next));
  }
}

class Heard {
  final texts = <String>[];
  var turns = 0;
  final closed = <String>[];
  final calls = <(String, Map<String, Object?>)>[];
}

GeminiAgentSession session(
  Api api,
  Heard heard, {
  int maxSteps = 8,
  Map<String, Object?> Function(String, Map<String, Object?>)? tool,
  AgentSteering? steering,
  AgentThinking thinking = AgentThinking.low,
}) => GeminiAgentSession(
  apiKey: 'test-key',
  systemPrompt: 'be the orb',
  tools: _tools,
  steering: steering,
  thinking: thinking,
  transport: api.call,
  maxSteps: maxSteps,
  retryDelay: Duration.zero,
  onToolCall: (name, args) async {
    heard.calls.add((name, args));
    return tool?.call(name, args) ?? {'ok': true};
  },
  onOutputText: heard.texts.add,
  onTurnComplete: () => heard.turns++,
  onClosed: heard.closed.add,
);

AgentScope _scope() => const AgentScope(systemPrompt: 'scoped', tools: _tools);

List<Map<String, Object?>> _contents(Map<String, Object?> request) => [
  for (final c in request['contents'] as List) Map<String, Object?>.from(c),
];

void main() {
  test(
    'connect resolves the model; a text-only reply is said and ends',
    () async {
      final api = Api()..replies.add(_say('你好'));
      final heard = Heard();
      final s = session(api, heard);
      expect(s.connected, isFalse);
      await s.connect();
      expect(s.connected, isTrue);
      expect(s.model, 'models/gemini-3-flash-preview');

      s.sendText('hi');
      await pumpEventQueue();

      expect(heard.texts, ['你好']);
      expect(heard.turns, 1);
      final r = api.requests.single;
      expect(
        api.paths.last,
        '/v1beta/models/gemini-3-flash-preview:generateContent',
      );
      expect(r['systemInstruction'], {
        'parts': [
          {'text': 'be the orb'},
        ],
      });
      // The declarations are the realtime session's, without NON_BLOCKING.
      final declared =
          ((r['tools'] as List).single as Map)['functionDeclarations'];
      expect((declared as List).single, {
        'name': 'navigate',
        'description': 'go',
        'parameters': _tools.single['parameters'],
      });
      final config = r['generationConfig'] as Map;
      expect(config['temperature'], .3);
      expect(config['thinkingConfig'], {'thinkingLevel': 'low'});
      expect(config.containsKey('responseMimeType'), isFalse);
      expect(_contents(r).single, {
        'role': 'user',
        'parts': [
          {'text': 'hi'},
        ],
      });
    },
  );

  test('a function call runs the tool and its response goes back with the '
      'model part, thoughtSignature included', () async {
    final api = Api()
      ..replies.addAll([
        _call('navigate', {'to': 'home'}, signature: 'sig-1'),
        _say('到了'),
      ]);
    final heard = Heard();
    final s = session(api, heard, tool: (_, _) => {'location': '/home'});
    await s.connect();

    s.sendText('go home');
    await pumpEventQueue();

    expect(heard.calls.map((c) => c.$1), ['navigate']);
    expect(heard.calls.single.$2, {'to': 'home'});
    expect(heard.texts, ['到了']);
    expect(heard.turns, 1);
    expect(api.requests, hasLength(2));
    final second = _contents(api.requests.last);
    expect(second.map((c) => c['role']), ['user', 'model', 'user']);
    expect(second[1]['parts'], [
      {
        'functionCall': {
          'name': 'navigate',
          'args': {'to': 'home'},
        },
        'thoughtSignature': 'sig-1',
      },
    ]);
    expect(second[2]['parts'], [
      {
        'functionResponse': {
          'name': 'navigate',
          'response': {'location': '/home'},
        },
      },
    ]);
  });

  test(
    'several calls in one reply run in order, answered in one turn',
    () async {
      final api = Api()
        ..replies.addAll([
          _reply([
            {
              'functionCall': {'name': 'a', 'args': <String, Object?>{}},
            },
            {
              'functionCall': {'name': 'b', 'args': <String, Object?>{}},
            },
          ]),
          _say('done'),
        ]);
      final heard = Heard();
      final s = session(api, heard, tool: (name, _) => {'who': name});
      await s.connect();
      s.sendText('x');
      await pumpEventQueue();

      expect(heard.calls.map((c) => c.$1), ['a', 'b']);
      final parts = _contents(api.requests.last).last['parts'] as List;
      expect(parts.map((p) => (p as Map)['functionResponse']['response']), [
        {'who': 'a'},
        {'who': 'b'},
      ]);
    },
  );

  test(
    'a tool that throws is answered with an error, not a dead turn',
    () async {
      final api = Api()..replies.addAll([_call('navigate', {}), _say('出错了')]);
      final heard = Heard();
      final s = session(api, heard, tool: (_, _) => throw StateError('boom'));
      await s.connect();
      s.sendText('x');
      await pumpEventQueue();

      final answer =
          (_contents(api.requests.last).last['parts'] as List).single as Map;
      expect(answer['functionResponse']['response'], contains('error'));
      expect(heard.texts, ['出错了']);
      expect(heard.turns, 1);
    },
  );

  test('the step cap stops a model that keeps calling, and the history stays '
      'valid for the next turn', () async {
    final api = Api()
      ..replies.addAll([
        for (var i = 0; i < 3; i++) _call('navigate', {'to': '$i'}),
        _say('later'),
      ]);
    final heard = Heard();
    final s = session(api, heard, maxSteps: 3);
    await s.connect();

    s.sendText('loop');
    await pumpEventQueue();

    expect(api.requests, hasLength(3));
    // The last step's call was not run: no step is left to read its answer.
    expect(heard.calls, hasLength(2));
    expect(heard.turns, 1);
    expect(heard.texts, isEmpty);
    expect(heard.closed, isEmpty);

    s.sendText('again');
    await pumpEventQueue();
    final roles = _contents(api.requests.last).map((c) => c['role']).toList();
    expect(roles, [
      'user',
      'model',
      'user',
      'model',
      'user',
      'model',
      'user',
      'user',
    ]);
    // Every model call has its answer right after it.
    final contents = _contents(api.requests.last);
    expect(
      (contents[6]['parts'] as List).single,
      containsPair('functionResponse', isA<Map>()),
    );
    expect(heard.texts, ['later']);
  });

  test(
    'addContext sends nothing by itself and rides along the next turn',
    () async {
      final api = Api()..replies.add(_say('ok'));
      final heard = Heard();
      final s = session(api, heard);
      await s.connect();

      s.addContext('用户在首页');
      await pumpEventQueue();
      expect(api.requests, isEmpty);
      expect(heard.turns, 0);

      s.sendText('这是什么');
      await pumpEventQueue();
      expect(_contents(api.requests.single).single, {
        'role': 'user',
        'parts': [
          {'text': '用户在首页'},
          {'text': '这是什么'},
        ],
      });
    },
  );

  test('a second sendText waits for the first turn to end', () async {
    final gate = Completer<Map<String, Object?>>();
    final api = Api()..replies.addAll([gate.future, _say('second')]);
    final heard = Heard();
    final s = session(api, heard);
    await s.connect();

    s.sendText('one');
    s.sendText('two');
    await pumpEventQueue();
    expect(api.requests, hasLength(1));

    gate.complete(_say('first'));
    await pumpEventQueue();
    expect(api.requests, hasLength(2));
    expect(heard.texts, ['first', 'second']);
    expect(heard.turns, 2);
    final roles = _contents(api.requests.last).map((c) => c['role']).toList();
    expect(roles, ['user', 'model', 'user']);
  });

  test('close during a turn drops its result; a failed call closes the '
      'session with a reason that has no key in it', () async {
    final gate = Completer<Map<String, Object?>>();
    final api = Api()..replies.add(gate.future);
    final heard = Heard();
    final s = session(api, heard);
    await s.connect();
    s.sendText('x');
    await pumpEventQueue();
    await s.close();
    gate.complete(_say('late'));
    await pumpEventQueue();
    expect(heard.texts, isEmpty);
    expect(heard.turns, 0);
    expect(s.connected, isFalse);

    final api2 = Api()..replies.add(401);
    final heard2 = Heard();
    final s2 = session(api2, heard2);
    await s2.connect();
    s2.sendText('x');
    await pumpEventQueue();
    expect(heard2.closed, ['generateContent 401']);
    expect(s2.connected, isFalse);
    expect(heard2.closed.join(), isNot(contains('test-key')));
  });

  test('a 400 on the thinking setting is asked again without it; a 503 is '
      'tried again', () async {
    final api = Api()..replies.addAll([400, 503, _say('ok')]);
    final heard = Heard();
    final s = session(api, heard);
    await s.connect();
    s.sendText('x');
    await pumpEventQueue();

    expect(api.requests, hasLength(3));
    expect(
      (api.requests[0]['generationConfig'] as Map)['thinkingConfig'],
      isNotNull,
    );
    expect(
      (api.requests[1]['generationConfig'] as Map).containsKey(
        'thinkingConfig',
      ),
      isFalse,
    );
    expect(heard.texts, ['ok']);
  });

  test('steering decides the instruction and tools of every request, also '
      'the second of one turn', () async {
    final api = Api()
      ..replies.addAll([
        _call('navigate', {'to': 'x'}),
        _say('好'),
      ]);
    final heard = Heard();
    var asked = 0;
    var waiting = false;
    final s = session(
      api,
      heard,
      tool: (_, _) {
        waiting = true;
        return {'status': 'needs_confirmation'};
      },
      steering: AgentSteering(
        scope: () {
          asked++;
          return waiting
              ? const AgentScope(
                  systemPrompt: 'a card waits',
                  tools: [
                    {'name': 'confirm', 'description': 'yes'},
                  ],
                )
              : const AgentScope(systemPrompt: 'normal', tools: _tools);
        },
      ),
    );
    await s.connect();
    s.sendText('x');
    await pumpEventQueue();

    expect(asked, 2);
    String system(Map<String, Object?> r) =>
        ((r['systemInstruction'] as Map)['parts'] as List).single['text']
            as String;
    List names(Map<String, Object?> r) => [
      for (final d
          in ((r['tools'] as List).single as Map)['functionDeclarations']
              as List)
        (d as Map)['name'],
    ];
    expect(system(api.requests[0]), 'normal');
    expect(names(api.requests[0]), ['navigate']);
    expect(system(api.requests[1]), 'a card waits');
    expect(names(api.requests[1]), ['confirm']);
  });

  group('the app\'s own words', () {
    AgentSteering rules({
      Future<String?> Function(String, AgentToolHandler)? intercept,
      AgentReview? Function(String, List<AgentToolRun>, AgentToolHandler)?
      review,
    }) => AgentSteering(
      scope: () => const AgentScope(systemPrompt: 's', tools: _tools),
      intercept: intercept,
      review: review,
    );

    test(
      'a tool with app_say ends the turn with those words; the model '
      'is not asked again and later calls in the reply are not run',
      () async {
        final api = Api()
          ..replies.add(
            _reply([
              {
                'functionCall': {'name': 'ask', 'args': <String, Object?>{}},
              },
              {
                'functionCall': {
                  'name': 'confirm',
                  'args': <String, Object?>{},
                },
              },
            ]),
          );
        final heard = Heard();
        final s = session(
          api,
          heard,
          steering: rules(),
          tool: (name, _) => name == 'ask'
              ? {'status': 'needs_confirmation', 'app_say': '回复 Cody：可以，要发吗？'}
              : {'status': 'done'},
        );
        await s.connect();
        s.sendText('回他可以');
        await pumpEventQueue();

        expect(heard.texts, ['回复 Cody：可以，要发吗？']);
        expect(heard.turns, 1);
        expect(api.requests, hasLength(1));
        // The second call was answered without being run.
        expect(heard.calls.map((c) => c.$1), ['ask']);

        // The history stays valid: the calls are answered, the words are the
        // model's turn, and the key itself is not shown to the model.
        api.replies.add(_say('嗯'));
        s.sendText('确认');
        await pumpEventQueue();
        final c = _contents(api.requests.last);
        expect(c.map((e) => e['role']), [
          'user',
          'model',
          'user',
          'model',
          'user',
        ]);
        final answers = (c[2]['parts'] as List).cast<Map>();
        expect(answers, hasLength(2));
        expect(answers.first['functionResponse']['response'], {
          'status': 'needs_confirmation',
        });
        expect(
          answers.last['functionResponse']['response']['error'],
          contains('结束'),
        );
        expect(c[3]['parts'], [
          {'text': '回复 Cody：可以，要发吗？'},
        ]);
      },
    );

    test(
      'preload rides with the person\'s words of each turn, as context',
      () async {
        final api = Api()..replies.addAll([_say('好'), _say('嗯')]);
        final heard = Heard();
        var n = 0;
        final s = session(
          api,
          heard,
          steering: AgentSteering(
            scope: () => const AgentScope(systemPrompt: 's', tools: _tools),
            preload: () => '（情况 ${++n}）',
          ),
        );
        await s.connect();
        s.addContext('（先前的提示）');
        s.sendText('第一句');
        await pumpEventQueue();
        s.sendText('第二句');
        await pumpEventQueue();

        List<String> texts(Map<String, Object?> request, int turn) {
          final c = (request['contents'] as List)[turn] as Map;
          return [
            for (final p in (c['parts'] as List))
              if ((p as Map)['text'] is String) '${p['text']}',
          ];
        }

        expect(texts(api.requests.first, 0), ['（先前的提示）', '（情况 1）', '第一句']);
        // Asked again for the next turn.
        final last = api.requests.last;
        expect((last['contents'] as List).length, 3);
        expect(texts(last, 2), ['（情况 2）', '第二句']);
      },
    );

    test(
      'intercept answers a turn itself, through the tools the model has',
      () async {
        final api = Api();
        final heard = Heard();
        final s = session(
          api,
          heard,
          tool: (_, _) => {'status': 'done'},
          steering: rules(
            intercept: (said, run) async {
              if (said != '确认') return null;
              final r = await run('confirm', const {});
              return r['status'] == 'done' ? '已发送。' : null;
            },
          ),
        );
        await s.connect();
        s.sendText('确认');
        await pumpEventQueue();

        expect(api.requests, isEmpty);
        expect(heard.calls.map((c) => c.$1), ['confirm']);
        expect(heard.texts, ['已发送。']);
        expect(heard.turns, 1);

        // Not intercepted: the model answers, and sees what went before.
        api.replies.add(_say('在'));
        s.sendText('你好');
        await pumpEventQueue();
        expect(heard.texts, ['已发送。', '在']);
        final c = _contents(api.requests.single);
        expect(c.map((e) => e['role']), ['user', 'model', 'user']);
        expect((c[0]['parts'] as List).single, {'text': '确认'});
        expect((c[1]['parts'] as List).single, {'text': '已发送。'});
      },
    );

    test(
      'review: told once to try again, and then the new words are said',
      () async {
        final api = Api()
          ..replies.addAll([_say('要发吗？'), _call('navigate', {}), _say('好了')]);
        final heard = Heard();
        var reviews = 0;
        final s = session(
          api,
          heard,
          steering: rules(
            review: (reply, runs, run) {
              reviews++;
              return reply == '要发吗？' ? const AgentReview(retry: '先调用工具') : null;
            },
          ),
        );
        await s.connect();
        s.sendText('x');
        await pumpEventQueue();

        expect(heard.texts, ['好了']);
        expect(heard.turns, 1);
        expect(reviews, 2);
        final c = _contents(api.requests.first);
        expect(api.requests, hasLength(3));
        expect(c, hasLength(1));
        final second = _contents(api.requests[1]);
        expect(second.map((e) => e['role']), ['user', 'model', 'user']);
        expect((second[2]['parts'] as List).single, {'text': '先调用工具'});
      },
    );

    test(
      'review: a second retry is not allowed; replacement words win',
      () async {
        final api = Api()..replies.addAll([_say('a'), _say('b')]);
        final heard = Heard();
        final s = session(
          api,
          heard,
          steering: rules(
            review: (reply, runs, run) => reply == 'a'
                ? const AgentReview(retry: 'again')
                : const AgentReview(retry: 'again', text: '改过的'),
          ),
        );
        await s.connect();
        s.sendText('x');
        await pumpEventQueue();
        expect(api.requests, hasLength(2));
        expect(heard.texts, ['改过的']);
      },
    );

    test('review is shown the tools the turn ran', () async {
      final api = Api()
        ..replies.addAll([
          _call('navigate', {'to': 'x'}),
          _say('到了'),
        ]);
      final heard = Heard();
      List<AgentToolRun>? seen;
      final s = session(
        api,
        heard,
        tool: (_, _) => {'title': 'X'},
        steering: rules(
          review: (reply, runs, run) {
            seen = runs;
            return null;
          },
        ),
      );
      await s.connect();
      s.sendText('x');
      await pumpEventQueue();
      expect(seen!.map((r) => r.name), ['navigate']);
      expect(seen!.single.args, {'to': 'x'});
      expect(seen!.single.result, {'title': 'X'});
    });

    test(
      'speak says the words after the turn under way and tells the model',
      () async {
        final api = Api();
        final gate = Completer<Map<String, Object?>>();
        api.replies.add(gate.future);
        final heard = Heard();
        final s = session(api, heard);
        await s.connect();
        s.sendText('x');
        s.speak('已取消。');
        await pumpEventQueue();
        expect(heard.texts, isEmpty);
        gate.complete(_say('好'));
        await pumpEventQueue();
        expect(heard.texts, ['好', '已取消。']);
        expect(heard.turns, 2);

        api.replies.add(_say('嗯'));
        s.sendText('y');
        await pumpEventQueue();
        final parts = (_contents(api.requests.last).last['parts'] as List)
            .map((p) => (p as Map)['text'])
            .toList();
        expect(parts, ['（App 已经替你对用户说了：“已取消。”）', 'y']);
      },
    );
  });

  test('generationConfig per level: Gemini 3 names it, 2.5 budgets it', () {
    Map<String, Object?>? of(String model, AgentThinking level) =>
        GeminiAgentSession.generationConfig(
              model,
              level: level,
            )['thinkingConfig']
            as Map<String, Object?>?;
    for (final level in AgentThinking.values) {
      expect(of('models/gemini-3.5-flash-lite', level), {
        'thinkingLevel': level.name,
      });
    }
    expect(of('models/gemini-2.5-flash', AgentThinking.minimal), {
      'thinkingBudget': 0,
    });
    expect(of('models/gemini-2.5-flash', AgentThinking.low), {
      'thinkingBudget': 1024,
    });
    expect(of('models/gemini-2.5-flash', AgentThinking.medium), {
      'thinkingBudget': 4096,
    });
    expect(of('models/gemini-2.5-flash', AgentThinking.high), {
      'thinkingBudget': 8192,
    });
    // A model without a setting gets none; the default is the old low.
    expect(of('models/other', AgentThinking.high), isNull);
    expect(
      GeminiAgentSession.generationConfig(
        'models/gemini-3-flash',
      )['thinkingConfig'],
      {'thinkingLevel': 'low'},
    );
  });

  test('the level goes in every request, and a 400 still drops it', () async {
    final api = Api()..replies.addAll([400, _say('好')]);
    final heard = Heard();
    final s = session(api, heard, thinking: AgentThinking.high);
    await s.connect();
    s.sendText('x');
    await pumpEventQueue();
    expect((api.requests[0]['generationConfig'] as Map)['thinkingConfig'], {
      'thinkingLevel': 'high',
    });
    expect(
      (api.requests[1]['generationConfig'] as Map).containsKey(
        'thinkingConfig',
      ),
      isFalse,
    );
    expect(heard.texts, ['好']);
  });

  test('generationConfig: the default is low (a 1024 budget for 2.5)', () {
    expect(
      GeminiAgentSession.generationConfig(
        'models/gemini-2.5-flash',
      )['thinkingConfig'],
      {'thinkingBudget': 1024},
    );
    expect(
      GeminiAgentSession.generationConfig(
        'models/gemini-3-flash',
      )['thinkingConfig'],
      {'thinkingLevel': 'low'},
    );
  });

  test('cancelTurn: a turn cut short in a tool says nothing and leaves no '
      'half of itself; the next turn goes on', () async {
    final api = Api()
      ..replies.addAll([
        _call('navigate', {'to': 'home'}),
        _say('好'),
      ]);
    final heard = Heard();
    final gate = Completer<void>();
    final started = Completer<void>();
    final s = GeminiAgentSession(
      apiKey: 'test-key',
      systemPrompt: 'be the orb',
      tools: _tools,
      transport: api.call,
      retryDelay: Duration.zero,
      onToolCall: (name, args) async {
        started.complete();
        await gate.future;
        return {'ok': true};
      },
      onOutputText: heard.texts.add,
      onTurnComplete: () => heard.turns++,
      onClosed: heard.closed.add,
    );
    await s.connect();
    s.sendText('去主页');
    await started.future;
    // A turn queued behind it is dropped too.
    s.sendText('queued');
    s.cancelTurn();
    gate.complete();
    await pumpEventQueue();
    expect(heard.texts, isEmpty);
    expect(heard.turns, 0);
    expect(heard.closed, isEmpty);
    expect(s.connected, isTrue);
    expect(api.requests, hasLength(1), reason: 'no second model call');

    s.sendText('再来');
    await pumpEventQueue();
    expect(heard.texts, ['好']);
    // The cancelled turn is not in the history the model sees.
    expect(_contents(api.requests.last), [
      {
        'role': 'user',
        'parts': [
          {'text': '再来'},
        ],
      },
    ]);
  });

  group('streaming the final answer', () {
    Map<String, Object?> chunk(List<Map<String, Object?>> parts) =>
        _reply(parts);
    Map<String, Object?> words(String t) => chunk([
      {'text': t},
    ]);

    /// A stream transport that gives the chunks of each call in turn;
    /// [after] runs after the chunk with that index of the call.
    ({
      GeminiStreamTransport transport,
      List<Uri> uris,
      List<Map<String, String>> keys,
      List<Map<String, Object?>> bodies,
    })
    fake(
      List<List<Map<String, Object?>>> calls, {
      void Function(int call, int index)? after,
    }) {
      final uris = <Uri>[];
      final keys = <Map<String, String>>[];
      final bodies = <Map<String, Object?>>[];
      var call = 0;
      Stream<Map<String, Object?>> transport(
        Uri uri,
        String key,
        Map<String, Object?> body,
      ) async* {
        uris.add(uri);
        keys.add({'key': key});
        bodies.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
        final mine = call++;
        for (var i = 0; i < calls[mine].length; i++) {
          yield calls[mine][i];
          after?.call(mine, i);
          await Future<void>.delayed(Duration.zero);
        }
      }

      return (transport: transport, uris: uris, keys: keys, bodies: bodies);
    }

    AgentSteering steering({bool Function(List<AgentToolRun>, String)? safe}) =>
        AgentSteering(
          scope: () => const AgentScope(systemPrompt: 'scoped', tools: _tools),
          streamSafe: safe ?? (_, _) => true,
        );

    GeminiAgentSession streaming(
      Heard heard,
      GeminiStreamTransport stream, {
      AgentSteering? steer,
      List<String>? drafts,
      Api? api,
    }) => GeminiAgentSession(
      apiKey: 'test-key',
      systemPrompt: 'be the orb',
      tools: _tools,
      steering: steer ?? steering(),
      transport: (api ?? Api()).call,
      streamTransport: stream,
      onDraft: (drafts ?? <String>[]).add,
      retryDelay: Duration.zero,
      onToolCall: (name, args) async {
        heard.calls.add((name, args));
        return {'ok': true};
      },
      onOutputText: heard.texts.add,
      onTurnComplete: () => heard.turns++,
      onClosed: heard.closed.add,
    );

    test('the answer after a tool streams as drafts in order, and is said '
        'once in full', () async {
      final f = fake([
        [
          chunk([
            {
              'functionCall': {'name': 'navigate', 'args': {}},
              'thoughtSignature': 'sig',
            },
          ]),
        ],
        [words('第一句。'), words('第二'), words('句。')],
      ]);
      final heard = Heard();
      final drafts = <String>[];
      final s = streaming(heard, f.transport, drafts: drafts);
      await s.connect();
      s.sendText('go');
      await pumpEventQueue();

      expect(drafts, ['第一句。', '第二', '句。']);
      expect(heard.texts, ['第一句。第二句。']);
      expect(heard.turns, 1);
      expect(f.uris.first.path, endsWith(':streamGenerateContent'));
      expect(f.uris.first.queryParameters, {'alt': 'sse'});
      // The scope of the steering reaches the request, the key only the
      // transport's argument.
      expect((f.bodies.first['systemInstruction'] as Map)['parts'], [
        {'text': 'scoped'},
      ]);
      expect(jsonEncode(f.bodies), isNot(contains('test-key')));
      // The history carries the merged model words and the signature.
      expect(_contents(f.bodies.last)[1]['parts'], [
        {
          'functionCall': {'name': 'navigate', 'args': {}},
          'thoughtSignature': 'sig',
        },
      ]);
    });

    test('the words of the first step are never drafted', () async {
      final f = fake([
        [
          words('我先看看。'),
          chunk([
            {
              'functionCall': {'name': 'navigate', 'args': {}},
            },
          ]),
        ],
        [words('好了。')],
      ]);
      final heard = Heard();
      final drafts = <String>[];
      final s = streaming(heard, f.transport, drafts: drafts);
      await s.connect();
      s.sendText('go');
      await pumpEventQueue();

      expect(drafts, ['好了。']);
      // What is said at the end is the whole turn's words, as ever.
      expect(heard.texts, ['我先看看。\n好了。']);
      // The step-one words stay in the history, merged into one part.
      expect(_contents(f.bodies.last)[1]['parts'], [
        {'text': '我先看看。'},
        {
          'functionCall': {'name': 'navigate', 'args': {}},
        },
      ]);
    });

    test('streamSafe false stops the drafts for the turn; the words are '
        'still all said at the end', () async {
      final f = fake([
        [
          chunk([
            {
              'functionCall': {'name': 'navigate', 'args': {}},
            },
          ]),
        ],
        [words('甲。'), words('乙。'), words('丙。')],
      ]);
      final heard = Heard();
      final drafts = <String>[];
      final asked = <(int, String)>[];
      final s = streaming(
        heard,
        f.transport,
        drafts: drafts,
        steer: steering(
          safe: (runs, draft) {
            asked.add((runs.length, draft));
            return draft.length < 4;
          },
        ),
      );
      await s.connect();
      s.sendText('go');
      await pumpEventQueue();

      expect(drafts, ['甲。']);
      // The text of the step so far, with the tool run, and not asked again
      // once it said no.
      expect(asked, [(1, '甲。'), (1, '甲。乙。')]);
      expect(heard.texts, ['甲。乙。丙。']);
      expect(heard.turns, 1);
    });

    test('without onDraft or streamSafe the plain transport is used', () async {
      for (final withDraft in [false, true]) {
        final api = Api()..replies.addAll([_call('navigate', {}), _say('好。')]);
        final f = fake(const []);
        final heard = Heard();
        final drafts = <String>[];
        final s = GeminiAgentSession(
          apiKey: 'test-key',
          systemPrompt: 'be the orb',
          tools: _tools,
          // Draft callback without streamSafe, or streamSafe without it.
          steering: withDraft ? const AgentSteering(scope: _scope) : steering(),
          transport: api.call,
          streamTransport: f.transport,
          onDraft: withDraft ? drafts.add : null,
          retryDelay: Duration.zero,
          onToolCall: (_, _) async => {'ok': true},
          onOutputText: heard.texts.add,
          onTurnComplete: () => heard.turns++,
        );
        await s.connect();
        s.sendText('go');
        await pumpEventQueue();

        expect(f.uris, isEmpty);
        expect(api.requests, hasLength(2));
        expect(drafts, isEmpty);
        expect(heard.texts, ['好。']);
      }
    });

    test(
      'reasoning parts are never drafted, and stay in the history',
      () async {
        final f = fake([
          [
            chunk([
              {
                'functionCall': {'name': 'navigate', 'args': {}},
              },
            ]),
          ],
          [
            chunk([
              {'text': '想一想', 'thought': true},
            ]),
            chunk([
              {'text': '想完了', 'thought': true, 'thoughtSignature': 'sg'},
              {'text': '答案。'},
            ]),
          ],
        ]);
        final heard = Heard();
        final drafts = <String>[];
        final asked = <String>[];
        final s = streaming(
          heard,
          f.transport,
          drafts: drafts,
          steer: steering(
            safe: (_, draft) {
              asked.add(draft);
              return true;
            },
          ),
        );
        await s.connect();
        s.sendText('go');
        await pumpEventQueue();

        expect(drafts, ['答案。']);
        expect(asked, ['答案。']);
        expect(heard.texts, ['答案。']);
      },
    );

    test('the turn cancelled mid-stream: no more drafts, nothing said, no '
        'half of it left', () async {
      late GeminiAgentSession s;
      final f = fake(
        [
          [
            chunk([
              {
                'functionCall': {'name': 'navigate', 'args': {}},
              },
            ]),
          ],
          [words('甲。'), words('乙。'), words('丙。')],
        ],
        after: (call, i) {
          if (call == 1 && i == 0) s.cancelTurn();
        },
      );
      final heard = Heard();
      final drafts = <String>[];
      s = streaming(heard, f.transport, drafts: drafts);
      await s.connect();
      s.sendText('go');
      await pumpEventQueue();

      expect(drafts, ['甲。']);
      expect(heard.texts, isEmpty);
      expect(heard.turns, 0);
      expect(heard.closed, isEmpty);

      // The next turn starts from a clean history.
      final g = fake([
        [words('新的。')],
      ]);
      final next = streaming(heard, g.transport, drafts: drafts);
      await next.connect();
      next.sendText('again');
      await pumpEventQueue();
      expect(heard.texts, ['新的。']);
    });

    test('a review retry ends the drafts of the turn', () async {
      final f = fake([
        [
          chunk([
            {
              'functionCall': {'name': 'navigate', 'args': {}},
            },
          ]),
        ],
        [words('要发吗？')],
        [words('改好。')],
      ]);
      final heard = Heard();
      final drafts = <String>[];
      final s = streaming(
        heard,
        f.transport,
        drafts: drafts,
        steer: AgentSteering(
          scope: _scope,
          streamSafe: (_, _) => true,
          review: (reply, runs, run) =>
              reply.contains('要发吗') ? const AgentReview(retry: '先出卡') : null,
        ),
      );
      await s.connect();
      s.sendText('go');
      await pumpEventQueue();

      expect(drafts, ['要发吗？']);
      expect(heard.texts, ['改好。']);
    });

    test('a failed stream is asked again like a plain call', () async {
      var calls = 0;
      Stream<Map<String, Object?>> flaky(
        Uri uri,
        String key,
        Map<String, Object?> body,
      ) async* {
        if (calls++ == 0) throw const GeminiStreamFailure(503);
        yield words('好。');
      }

      final heard = Heard();
      final s = streaming(heard, flaky);
      await s.connect();
      s.sendText('go');
      await pumpEventQueue();
      expect(calls, 2);
      expect(heard.texts, ['好。']);
    });

    test('geminiSseChunks reads the data events', () async {
      final chunks = await geminiSseChunks(
        Stream.fromIterable([
          'data: {"a":1}\r\n\r\nda',
          'ta: {"b":\n',
          'data: 2}\n\n: comment\ndata: not json\n\ndata: {"c":3}',
        ]),
      ).toList();
      expect(chunks, [
        {'a': 1},
        {'b': 2},
        {'c': 3},
      ]);
    });
  });
}
