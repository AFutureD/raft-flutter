import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';

/// Every function call id gets exactly one response, so the model is never
/// left "waiting for the updates to load".
void main() {
  Map<String, Object?> call(String id, String name) => {
    'id': id,
    'name': name,
    'args': <String, Object?>{},
  };

  late List<Map<String, Object?>> sent;
  late List<String> logs;

  AgentToolResponder responder(
    AgentToolHandler handler, {
    bool nonBlocking = false,
    Duration timeout = const Duration(seconds: 8),
  }) => AgentToolResponder(
    handler: handler,
    quietNames: () => nonBlocking ? {'begin_surface', 'add_component'} : {},
    timeout: timeout,
    log: logs.add,
    send: (response) {
      sent.add(response);
      return true;
    },
  );

  setUp(() {
    sent = [];
    logs = [];
  });

  List<Object?> ids() => [for (final r in sent) r['id']];

  for (final nonBlocking in [false, true]) {
    final mode = nonBlocking ? 'non-blocking' : 'blocking';

    test(
      '$mode: each call answered once, errors and throws included',
      () async {
        final r = responder((name, args) async {
          if (name == 'boom') throw StateError('x');
          if (name == 'read_tasks') return {'error': 'nope'};
          return {'ok': true};
        }, nonBlocking: nonBlocking);
        await r.answer([
          call('1', 'begin_surface'),
          call('2', 'read_tasks'),
          call('3', 'boom'),
          call('4', 'add_component'),
        ]);
        expect(ids()..sort(), ['1', '2', '3', '4']);
        expect(
          sent.firstWhere((x) => x['id'] == '3')['response'],
          containsPair('error', contains('x')),
        );
        // Only the non-blocking functions carry a scheduling hint.
        expect(
          (sent.firstWhere((x) => x['id'] == '1')['response']
              as Map)['scheduling'],
          nonBlocking ? 'SILENT' : isNull,
        );
        expect(
          (sent.firstWhere((x) => x['id'] == '2')['response']
              as Map)['scheduling'],
          isNull,
        );
      },
    );

    testWidgets('$mode: a tool that never returns is answered once', (
      tester,
    ) async {
      {
        final never = Completer<Map<String, Object?>>();
        var done = false;
        final r = responder(
          (name, args) =>
              name == 'read_tasks' ? never.future : Future.value({'ok': true}),
          nonBlocking: nonBlocking,
        );
        r
            .answer([call('1', 'read_tasks'), call('2', 'begin_surface')])
            .then((_) => done = true);
        await tester.pump(const Duration(seconds: 7));
        // The screen operation is answered at once; the read still waits.
        expect(ids(), ['2']);
        expect(done, isFalse);
        await tester.pump(const Duration(seconds: 2));
        expect(done, isTrue);
        expect(ids(), ['2', '1']);
        final timedOut = sent.last['response'] as Map;
        expect(timedOut['error'], contains('8 秒'));
        // It finishing late must not answer a second time.
        never.complete({'late': true});
        await tester.pump();
        expect(ids(), ['2', '1']);
      }
    });
  }

  testWidgets('a timed-out non-blocking call is told when idle', (
    tester,
  ) async {
    {
      final r = responder(
        (name, args) => Completer<Map<String, Object?>>().future,
        nonBlocking: true,
      );
      unawaited(r.answer([call('1', 'begin_surface')]));
      await tester.pump(const Duration(seconds: 9));
      expect((sent.single['response'] as Map)['scheduling'], 'WHEN_IDLE');
    }
  });

  testWidgets('tools that read and then ask a model get longer than 8 s', (
    tester,
  ) async {
    final gates = {
      'get_briefing': Completer<Map<String, Object?>>(),
      'navigate': Completer<Map<String, Object?>>(),
      'describe_page': Completer<Map<String, Object?>>(),
    };
    final r = responder((name, args) => gates[name]!.future);
    unawaited(
      r.answer([
        call('1', 'get_briefing'),
        call('2', 'navigate'),
        call('3', 'describe_page'),
      ]),
    );
    await tester.pump(const Duration(seconds: 9));
    // A plain read gives up at 8 s; the briefing and navigate are still on.
    expect(ids(), ['3']);
    expect((sent.single['response'] as Map)['error'], contains('8 秒'));
    gates['navigate']!.complete({'route': '/s/alpha/activity'});
    await tester.pump(const Duration(seconds: 1));
    expect(ids(), ['3', '2']);
    expect((sent.last['response'] as Map)['route'], '/s/alpha/activity');
    await tester.pump(const Duration(seconds: 17));
    expect(ids(), ['3', '2', '1']);
    expect((sent.last['response'] as Map)['error'], contains('25 秒'));
  });

  test('a repeated id is not answered twice', () async {
    final r = responder((name, args) async => {'ok': true});
    await r.answer([call('1', 'show_tasks')]);
    await r.answer([call('1', 'show_tasks')]);
    expect(ids(), ['1']);
  });

  test('a call the server cancelled gets no response', () async {
    final gate = Completer<Map<String, Object?>>();
    final r = responder((name, args) => gate.future);
    final done = r.answer([call('1', 'read_tasks'), call('2', 'read_tasks')]);
    r.cancel(['1']);
    gate.complete({'ok': true});
    await done;
    expect(ids(), ['2']);
  });

  test('calls and responses are logged with their ids', () async {
    final r = responder((name, args) async => {'ok': true});
    await r.answer([call('abc', 'show_tasks')]);
    expect(logs.any((l) => l.contains('call show_tasks id=abc')), isTrue);
    expect(
      logs.any((l) => l.contains('response show_tasks id=abc ok')),
      isTrue,
    );
  });
}
