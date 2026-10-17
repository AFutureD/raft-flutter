import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_run.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenarios.dart';

/// A spoken transcript puts spaces between words ("要发 吗？"): the phrase
/// checks compare without them, and with full-width letters and punctuation as
/// half-width.

OrbEvalRun spoken(String text) {
  final r = OrbEvalRun(ids: {});
  r.turns.add(OrbEvalTurn('x')..addText(text));
  return r;
}

void main() {
  test('compact: no spaces of any kind, full-width as half-width', () {
    expect(orbEvalCompact('要发 吗 ？'), '要发吗？');
    expect(orbEvalCompact('第　10 步'), '第10步');
    expect(orbEvalCompact('１０ 步'), '10步');
    expect(orbEvalCompact('要发吗？'), '要发吗？');
    expect(orbEvalCompact('要发吗？', punctuation: true), '要发吗?');
  });

  test('says: a group met across spaces and in full-width forms', () {
    final check = OrbEvalCheck.says([
      ['Cody'],
      ['第 10 步', '10 步'],
      ['合入', '合并'],
    ]);
    expect(check.test(spoken('Cody 在问 第 10 步 能不能 合 入')), isNull);
    expect(check.test(spoken('Cody在问第１０步能不能合并')), isNull);
    expect(check.test(spoken('Cody 在问 第 11 步 能不能合入')), contains('第 10 步'));
  });

  test('saysMatching: a pattern finds its words across spaces and either '
      'question mark', () {
    final check = OrbEvalCheck.saysMatching(RegExp(r'要发吗|发吗[？?]'), '问一句要不要发');
    expect(check.test(spoken('回复 Cody：可以，要发 吗？')), isNull);
    expect(check.test(spoken('回复 Cody：可以，要 发 吗')), isNull);
    expect(check.test(spoken('回复 Cody：可以。')), contains('问一句要不要发'));
    final q = OrbEvalCheck.saysMatching(RegExp('发吗？'), 'x');
    expect(q.test(spoken('要发吗?')), isNull, reason: 'half-width finds ？');
  });

  test('in order and avoids ignore the spaces too', () {
    final order = OrbEvalCheck.inOrder([
      ['Alice'],
      ['Cody'],
    ], label: '顺序');
    expect(order.test(spoken('Al ice 问你。Co dy 问你。')), isNull);
    expect(order.test(spoken('Cody 问你。Alice 问你。')), isNotNull);
    final avoids = OrbEvalCheck.avoids(RegExp('任务'), '念任务');
    expect(avoids.test(spoken('有 1 个 任 务')), isNotNull);
    expect(avoids.test(spoken('没有别的')), isNull);
  });

  test('D3 and C2 as the device heard them pass their phrase checks', () {
    final d3 = orbEvalScenarios.firstWhere((s) => s.id == 'D3');
    final run = OrbEvalRun(ids: {})
      ..turns.add(OrbEvalTurn('回他可以')..addText('回复 Cody ：可以，要发 吗？'));
    final says = d3.checks
        .where((c) => c.label.contains('先复述') || c.label.contains('问一句'))
        .toList();
    expect(says, hasLength(2));
    for (final c in says) {
      expect(c.test(run), isNull, reason: c.label);
    }
  });
}
