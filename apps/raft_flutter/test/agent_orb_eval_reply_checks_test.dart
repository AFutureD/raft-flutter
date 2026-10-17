import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart'
    show evalId;
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_run.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenarios.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_world.dart';

/// The agent layer answers people with `reply`: the scenarios that write must
/// take it as they took send_message and reply_in_thread, card first and once.

OrbEvalScenario scenario(String id) =>
    orbEvalScenarios.firstWhere((s) => s.id == id);

OrbEvalToolCall call(
  String name,
  Map<String, Object?> args,
  Map<String, Object?> result,
) => OrbEvalToolCall(name: name, args: args, result: result, millis: 1);

/// A good run of [id]: the model calls [tool], the app words the card, the
/// person's 确认 runs confirm, and one message goes out.
OrbEvalRun goodRun(
  String id, {
  required String tool,
  required Map<String, Object?> args,
  required String card,
  String done = '已回复。',
  List<String> setup = const [],
  OrbEvalSnapshot? after,
  int writesAtAsk = 0,
  OrbEvalWrite? write,
}) {
  final s = scenario(id);
  final r = OrbEvalRun(ids: {});
  for (final line in setup) {
    r.turns.add(OrbEvalTurn(line, scored: false)..completed = true);
  }
  r.turns.add(
    OrbEvalTurn(s.say.first)
      ..tools.add(call(tool, args, {'status': 'needs_confirmation'}))
      ..addText(card)
      ..completed = true
      ..writesAfter = writesAtAsk
      ..after = after,
  );
  r.turns.add(
    OrbEvalTurn('确认')
      ..tools.add(call('confirm', const {}, {'status': 'done'}))
      ..addText(done)
      ..completed = true
      ..writesAfter = 1
      ..after = after,
  );
  r.writes = [
    write ?? const OrbEvalWrite('POST', '/v2/messages', {'content': '可以'}),
  ];
  return r;
}

List<String> failures(String id, OrbEvalRun run) => [
  for (final c in scenario(id).checks)
    if (c.test(run) case final reason?) '${c.label}: $reason',
];

void main() {
  test('A3: reply(text) with the card worded by the app passes', () {
    final run = goodRun(
      'A3',
      tool: 'reply',
      args: {'text': '可以合'},
      card: '回复 Cody：可以合，要发吗？',
      write: const OrbEvalWrite('POST', '/v2/messages', {'content': '可以合'}),
    );
    expect(failures('A3', run), isEmpty);
  });

  test('C2: reply(text) to the private conversation passes', () {
    final run = goodRun(
      'C2',
      tool: 'reply',
      args: {'text': '晚上看'},
      card: '发给 Cody：晚上看，要发吗？',
      done: '已发送。',
      write: const OrbEvalWrite('POST', '/v2/messages', {'content': '晚上看'}),
    );
    expect(failures('C2', run), isEmpty);
  });

  test('D3: reply(text) to the card on the screen passes', () {
    final run = goodRun(
      'D3',
      tool: 'reply',
      args: {'text': '可以'},
      card: '回复 Cody：可以，要发吗？',
      setup: const ['开始驾驶模式'],
      after: const OrbEvalSnapshot(
        location: '/s/fixture/activity',
        layerOpen: true,
        driving: true,
        drivingIndex: 0,
        cards: [
          {'id': 'a', 'who': 'Cody', 'where': '#raft-flutter', 'title': 't'},
        ],
      ),
    );
    expect(failures('D3', run), isEmpty);
  });

  test('a reply that writes before the card, or never gets a card, still '
      'fails', () {
    final early = goodRun(
      'A3',
      tool: 'reply',
      args: {'text': '可以合'},
      card: '回复 Cody：可以合，要发吗？',
      writesAtAsk: 1,
      write: const OrbEvalWrite('POST', '/v2/messages', {'content': '可以合'}),
    );
    expect(failures('A3', early).any((f) => f.contains('确认之前')), isTrue);
    final none = OrbEvalRun(ids: {});
    none.turns.add(
      OrbEvalTurn('回复他说可以合')
        ..tools.add(call('reply', {'text': '可以合'}, {'error': '不知道要回复谁'}))
        ..addText('不知道回复谁'),
    );
    expect(failures('A3', none).any((f) => f.contains('没有出确认卡')), isTrue);
  });

  group('C1: where navigate went is what counts', () {
    final codyDm = evalId('dm:cody');
    OrbEvalRun navigated(
      Map<String, Object?> args,
      Map<String, Object?> result,
    ) {
      final r = OrbEvalRun(ids: {});
      r.turns.add(
        OrbEvalTurn('看看 Cody 私信')
          ..tools.add(call('navigate', args, result))
          ..addText('Cody 说第 10 步提交了，问你要他补什么。要不要回他？'),
      );
      return r;
    }

    List<String> navFailures(OrbEvalRun r) => [
      for (final c in scenario(
        'C1',
      ).checks.where((c) => c.label.contains('navigate')))
        ?c.test(r),
    ];

    test('by id, or by the name when it lands in that conversation', () {
      expect(navFailures(navigated({'dm_id': codyDm}, {})), isEmpty);
      expect(
        navFailures(
          navigated(
            {'target': 'Cody'},
            {
              'matched': {'kind': 'dm', 'id': codyDm},
            },
          ),
        ),
        isEmpty,
      );
    });

    test('anywhere else fails', () {
      expect(
        navFailures(
          navigated(
            {'target': 'Alice'},
            {
              'matched': {'kind': 'dm', 'id': evalId('dm:alice')},
            },
          ),
        ),
        isNotEmpty,
      );
      expect(
        navFailures(navigated({'dm_id': evalId('dm:alice')}, {})),
        isNotEmpty,
      );
    });
  });
}
