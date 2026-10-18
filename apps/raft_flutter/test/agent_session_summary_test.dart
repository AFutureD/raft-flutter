import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentSpeaker;
import 'package:raft_flutter/features/agent_mode/agent_summary.dart';
import 'package:raft_flutter/features/agent_mode/agent_text_model.dart';

/// After a voice session the agent gets a summary of it, not the transcript.
void main() {
  const you = AgentSpeaker.you;
  const agent = AgentSpeaker.agent;
  final longAgent = '好的，我来给你详细讲一下这件事的来龙去脉。' * 12;
  final longYou = '我想让你把发布前要做的检查项全部整理一遍然后发给我，' * 8;

  final transcript = [
    (you, '明天提醒我看选型'),
    (agent, longAgent),
    (you, longYou),
    (agent, '好，记下了'),
  ];
  const outcomes = [
    AgentToolOutcome(
      name: 'snooze_item',
      args: {'id': 'task-94', 'until': '明天'},
      result: {'status': 'needs_user_confirmation', 'preview': '明天再提醒'},
    ),
    AgentToolOutcome(
      name: 'send_message',
      args: {'channel': 'general'},
      result: {'error': 'needs_user_consent'},
    ),
    // Screen-only tools are not actions.
    AgentToolOutcome(
      name: 'spotlight',
      args: {'id': 'x'},
      result: {'ok': true},
    ),
  ];

  group('the message', () {
    test('a model summary replaces the transcript', () async {
      String? sentSystem;
      String? sentPrompt;
      final message = await AgentSessionSummary.build(
        transcript,
        outcomes,
        generate: (system, prompt) async {
          sentSystem = system;
          sentPrompt = prompt;
          return jsonEncode({
            'lines': ['- 想明天看选型，已设提醒但还在等确认', '想让我整理发布前检查项', ''],
          });
        },
      );
      expect(message, startsWith('${AgentSessionSummary.header}\n'));
      expect(message, startsWith('【语音对话摘要 · 来自 Agent 模式】'));
      expect(message, contains(AgentSessionSummary.instruction));
      expect(message, contains('不需要回复'));
      expect(message, contains('- 想明天看选型，已设提醒但还在等确认'));
      expect(message, contains('- 想让我整理发布前检查项'));
      expect(message, isNot(contains(longAgent)));
      expect(message, isNot(contains(longAgent.substring(0, 40))));
      expect(message, isNot(contains('好，记下了')));
      // The model asked for JSON, in the language of the talk, short.
      expect(sentSystem, contains('JSON'));
      expect(sentSystem, contains('不要逐字复述'));
      // Only what is worth long-term memory; no operation log.
      expect(sentSystem, contains('偏好'));
      expect(sentSystem, contains('驾驶模式'));
      expect(sentSystem, contains('读给用户听'));
      expect(sentSystem, contains('Raft 里已有记录'));
      expect(sentSystem, contains('{"lines":[]}'));
      expect(sentPrompt, contains('明天提醒我看选型'));
    });

    test('the tool outcomes go to the model as structured input', () async {
      String? prompt;
      await AgentSessionSummary.build(
        transcript,
        outcomes,
        generate: (system, p) async {
          prompt = p;
          return '{"lines":["ok"]}';
        },
      );
      expect(prompt, contains('【工具结果】'));
      expect(
        prompt,
        contains(
          'snooze_item(id=task-94, until=明天) -> needs_user_confirmation',
        ),
      );
      expect(
        prompt,
        contains('send_message(channel=general) -> failed: needs_user_consent'),
      );
      expect(prompt, isNot(contains('spotlight')));
    });

    test('navigation and reading tools stay out of the prompt', () async {
      String? prompt;
      await AgentSessionSummary.build(
        transcript,
        [
          for (final name in [
            'navigate',
            'describe_page',
            'read_screen',
            'get_briefing',
            'read_conversation',
            'list_tasks',
            'open_item',
            'set_driving_mode',
            'hide_orb_sheet',
          ])
            AgentToolOutcome(
              name: name,
              args: const {},
              result: const {'ok': true},
            ),
          ...outcomes,
        ],
        generate: (system, p) async {
          prompt = p;
          return '{"lines":["ok"]}';
        },
      );
      for (final name in [
        'navigate',
        'describe_page',
        'read_screen',
        'get_briefing',
        'read_conversation',
        'list_tasks',
        'open_item',
        'set_driving_mode',
        'hide_orb_sheet',
      ]) {
        expect(prompt, isNot(contains('$name(')), reason: name);
      }
      // Writes that left something open still go in.
      expect(prompt, contains('snooze_item('));
      expect(prompt, contains('send_message('));
    });

    test(
      'nothing worth keeping from the model means nothing is sent',
      () async {
        for (final reply in ['{"lines":[]}', '[]', '{"lines":["", "  "]}']) {
          expect(
            await AgentSessionSummary.build(
              transcript,
              outcomes,
              generate: (system, prompt) async => reply,
            ),
            isNull,
            reason: reply,
          );
        }
      },
    );

    test('a model reply is capped to eight short lines', () async {
      final message = await AgentSessionSummary.build(
        transcript,
        outcomes,
        generate: (system, prompt) async => jsonEncode({
          'lines': [for (var i = 0; i < 12; i++) '第$i条 ${'长' * 400}'],
        }),
      );
      final bullets = message!.split('\n').where((l) => l.startsWith('- '));
      expect(bullets, hasLength(8));
      expect(bullets.every((l) => l.length <= 2 + 141), isTrue);
    });

    test('nothing is sent when the person said nothing', () async {
      var asked = false;
      final message = await AgentSessionSummary.build(
        const [(agent, '你好')],
        outcomes,
        generate: (system, prompt) async {
          asked = true;
          return '{"lines":["x"]}';
        },
      );
      expect(message, isNull);
      expect(asked, isFalse);
      expect(await AgentSessionSummary.build(const [], const []), isNull);
    });
  });

  group('without a model', () {
    final chatter = [
      (you, '明天提醒我看选型'),
      (agent, longAgent),
      (you, '打开活动页看看第一条消息'),
      (you, longYou),
      (agent, '好，记下了'),
    ];

    void expectOnlyTheAsk(String? message) {
      expect(message, startsWith(AgentSessionSummary.header));
      expect(message, contains(AgentSessionSummary.instruction));
      expect(message, contains('- 我说过：明天提醒我看选型'));
      // Plain chatter, the agent's words and the operations are not there.
      expect(message, isNot(contains('活动页')));
      expect(message, isNot(contains(longAgent)));
      expect(message, isNot(contains('好，记下了')));
      expect(message, isNot(contains('操作：')));
      expect(message, isNot(contains('snooze_item')));
      expect(message, isNot(contains('needs_user_consent')));
    }

    test('no key (the model call gives nothing)', () async {
      expectOnlyTheAsk(
        await AgentSessionSummary.build(
          chatter,
          outcomes,
          generate: (system, prompt) async => null,
        ),
      );
    });

    test('an error from the model', () async {
      expectOnlyTheAsk(
        await AgentSessionSummary.build(
          chatter,
          outcomes,
          generate: (system, prompt) async => throw const HttpException('500'),
        ),
      );
    });

    test('a reply that is not the asked JSON', () async {
      expectOnlyTheAsk(
        await AgentSessionSummary.build(
          chatter,
          outcomes,
          generate: (system, prompt) async => '这是一段没有 JSON 的话',
        ),
      );
    });

    test('too slow (the timeout)', () async {
      final never = Completer<String?>();
      final watch = Stopwatch()..start();
      final message = await AgentSessionSummary.build(
        chatter,
        outcomes,
        generate: (system, prompt) => never.future,
        timeout: const Duration(milliseconds: 100),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expectOnlyTheAsk(message);
      // The real limit is about 15 seconds.
      expect(AgentSessionSummary.modelTimeout, const Duration(seconds: 15));
    });

    test('plain chatter and operations send nothing', () async {
      final message = await AgentSessionSummary.build(
        const [(you, '打开活动页看看'), (agent, '好的'), (you, '读一下简报'), (you, '开驾驶模式')],
        [
          for (var i = 0; i < 9; i++)
            AgentToolOutcome(
              name: 'set_task_status',
              args: {'n': '$i'},
              result: const {'status': 'done'},
            ),
        ],
        generate: (system, prompt) async => null,
      );
      expect(message, isNull);
    });

    test('each preference or todo marker is kept, clipped, at most 8', () {
      for (final said in [
        '记住我不喝咖啡',
        '以后简报先说 Cody 的事',
        '提醒我明天看选型',
        '别再给我推这个了',
        '不要再提醒了',
        '我喜欢简短的回答',
        '我不喜欢太长的简报',
        '下次先读未读',
      ]) {
        expect(AgentSessionSummary.fallbackLines([said]), [
          '我说过：$said',
        ], reason: said);
      }
      final lines = AgentSessionSummary.fallbackLines([
        '以后${'很长' * 100}',
        for (var i = 0; i < 12; i++) '记住第$i件',
      ]);
      expect(lines, hasLength(AgentSessionSummary.maxLines));
      expect(lines.first.length, lessThanOrEqualTo('我说过：'.length + 61));
      expect(lines.first, endsWith('…'));
    });
  });

  group('tool outcomes', () {
    test('what came of a call is read from the result', () {
      String status(Map<String, Object?> r) =>
          AgentToolOutcome(name: 't', args: const {}, result: r).status;
      expect(status({'ok': true}), 'ok');
      expect(status({'ok': false}), 'failed');
      expect(status({'error': '没有这个'}), 'failed: 没有这个');
      expect(status({'cancelled': true, 'message': '用户叫停了'}), 'cancelled');
      expect(status({'opened': true}), 'opened a page for the person');
      expect(status({'status': 'undone'}), 'undone');
      expect(
        status({'preview': '把 #98 改为进行中'}),
        'preview shown, waiting for the person: 把 #98 改为进行中',
      );
      expect(status({'message': '已发送'}), '已发送');
      expect(status({'other': 1}), 'returned a result');
    });
  });

  group('the text model', () {
    late HttpServer server;
    final requests =
        <({String path, String? auth, Map<String, dynamic> body})>[];
    var status = 200;
    Object reply = const {};

    setUp(() async {
      HttpOverrides.global = null;
      requests.clear();
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        requests.add((
          path: request.uri.path,
          auth: request.headers.value('authorization'),
          body: body,
        ));
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(reply));
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    ResponsesText model({String? key = 'xai-secret-0123456789abcdefABCDEF'}) =>
        ResponsesText(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1/responses'),
          model: 'grok-4.3',
          key: () async => key,
        );

    test(
      'posts the Responses API request and reads the message text',
      () async {
        reply = {
          'output': [
            {'type': 'reasoning', 'summary': []},
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': '{"lines":'},
                {'type': 'output_text', 'text': '["好"]}'},
              ],
            },
          ],
        };
        final text = await model().generate('系统', '请输出 JSON。内容');
        expect(text, '{"lines":["好"]}');
        final r = requests.single;
        expect(r.path, '/v1/responses');
        expect(r.auth, 'Bearer xai-secret-0123456789abcdefABCDEF');
        expect(r.body['model'], 'grok-4.3');
        expect(r.body['instructions'], '系统');
        expect(r.body['input'], '请输出 JSON。内容');
        expect(r.body['store'], false);
        expect(r.body['text'], {
          'format': {'type': 'json_object'},
        });
        expect(r.body['reasoning'], {'effort': 'none'});
      },
    );

    test('no key means no call', () async {
      expect(await model(key: null).generate('s', 'p'), isNull);
      expect(requests, isEmpty);
    });

    test('a refusal is an error (the summary then falls back)', () async {
      status = 401;
      reply = {'error': 'bad key'};
      await expectLater(
        model().generate('s', 'p'),
        throwsA(isA<HttpException>()),
      );
      final message = await AgentSessionSummary.build(
        transcript,
        outcomes,
        generate: model().generate,
      );
      expect(message, contains('我说过：明天提醒我看选型'));
      // The key is never in the message.
      expect(message, isNot(contains('xai-secret')));
    });

    test('the services and models are the documented ones', () {
      final openai = ResponsesText.openAi();
      expect(openai.endpoint.toString(), 'https://api.openai.com/v1/responses');
      expect(openai.model, 'gpt-6-luna');
      final xai = ResponsesText.xai();
      expect(xai.endpoint.toString(), 'https://api.x.ai/v1/responses');
      expect(xai.model, 'grok-4.3');
    });

    test('without any voice key there is no text model', () async {
      const secure = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secure, (call) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(secure, null),
      );
      expect(await generateWithVoiceKey('s', 'p'), isNull);
    });
  });
}
