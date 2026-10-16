import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_screen_snapshot.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_reference_table.dart'
    as refs;

AgentScreenPart _item(
  int n, {
  String title = '标题',
  String text = '',
  AgentItemView? view,
  bool entity = true,
}) => AgentScreenPart(
  HfDescription(['#general · 你派的任务', '$title$n$text', '已等 $n 小时']),
  n: n,
  facts: ['频道 #general（id ch-general）'],
  actions: const ['通过', '打开讨论', '稍后'],
  view: view,
  entity: entity
      ? refs.AgentEntityRef(type: 'task', label: title, id: 't$n').at(n)
      : null,
);

AgentScreenSnapshot _snapshot(
  List<AgentScreenPart> parts, {
  int? current,
  Map<int, AgentItemView>? views,
  AgentScreenPart? detail,
}) => AgentScreenSnapshot(
  layer: 1,
  kind: '首页',
  title: '现在需要你',
  head: const HfDescription(['现在需要你', '1件等你决定']),
  parts: parts,
  current: current,
  detail: detail,
  views: views,
);

void main() {
  group('agentClip keeps the head and the tail', () {
    test('a short text is left alone', () {
      expect(agentClip('一句话', 20), '一句话');
    });

    test('a long one says how much is gone', () {
      final text = [for (var i = 0; i < 300; i++) '字$i'].join();
      final clipped = agentClip(text, 100);
      expect(clipped.length, lessThanOrEqualTo(100));
      expect(clipped, startsWith('字0字1'));
      expect(clipped, endsWith('字299'));
      final n = int.parse(
        RegExp(r'…\((\d+) chars omitted\)…').firstMatch(clipped)![1]!,
      );
      final marker = RegExp(r'…\(\d+ chars omitted\)…')
          .firstMatch(clipped)![0]!;
      // The marker stands for exactly the characters that are not there.
      expect(clipped.length - marker.length + n, text.length);
    });

    test('never cuts an emoji in two', () {
      final text = '😀' * 200;
      final clipped = agentClip(text, 61);
      for (final part in clipped.split(RegExp(r'…\(\d+ chars omitted\)…'))) {
        expect(part.runes.every((r) => r == 0x1F600), isTrue, reason: part);
      }
    });
  });

  test('the token estimate counts a Chinese character as one', () {
    expect(agentTokenEstimate('现在需要你'), 5);
    expect(agentTokenEstimate('abcdefgh'), 2);
  });

  group('the snapshot text', () {
    test('every item has its handle, its words, what is behind them and '
        'what can be done', () {
      final text = _snapshot([_item(1), _item(2)], current: 2).text();
      expect(text, startsWith('【屏幕】第 1 层「现在需要你」(首页)'));
      expect(text, contains('① #general · 你派的任务 ｜ 标题1 ｜ 已等 1 小时'));
      expect(text, contains('② #general'));
      expect(text, contains('⟨task:t1 · 频道 #general（id ch-general）⟩'));
      expect(text, contains('可做：通过 / 打开讨论 / 稍后'));
      expect(text, contains('共 2 条'));
      expect(text, contains('当前这一条：②'));
    });

    test('it says which items are in view and how many are not', () {
      final text = _snapshot(
        [
          _item(1, view: AgentItemView.above),
          _item(2, view: AgentItemView.whole),
          _item(3, view: AgentItemView.partly),
          _item(4, view: AgentItemView.below),
          _item(5, view: AgentItemView.below),
        ],
        views: {
          1: AgentItemView.above,
          2: AgentItemView.whole,
          3: AgentItemView.partly,
          4: AgentItemView.below,
          5: AgentItemView.below,
        },
      ).text();
      expect(text, contains('眼前 ②–③，上面已滚过 1 条，下面还有 2 条没看到'));
      expect(text, contains('〔已滚过，在上面〕'));
      expect(text, contains('〔只露出一部分〕'));
      expect(text, contains('〔在下面，要往下翻〕'));
    });

    test('the current item\'s detail is told in full', () {
      final text = _snapshot(
        [_item(1)],
        current: 1,
        detail: const AgentScreenPart(
          HfDescription(
            ['等你决定 · #general', '要你做：验收「选型」', '谁：Cindy'],
            actions: ['通过', '稍后'],
          ),
          n: 1,
        ),
      ).text();
      expect(text, contains('【当前这一条 ① 的详情'));
      expect(text, contains('  要你做：验收「选型」'));
      expect(text, contains('  谁：Cindy'));
      expect(text, contains('  可做：通过 / 稍后'));
    });

    test('a long line keeps its head and tail, with the marker', () {
      final long = '开头${'中间' * 600}结尾';
      final text = _snapshot([_item(1, text: long)]).text();
      expect(text, contains('开头'));
      expect(text, contains('结尾'));
      expect(text, contains(RegExp(r'…\(\d+ chars omitted\)…')));
      expect(text.length, lessThan(AgentScreenLimits.total));
    });
  });

  group('the size is bounded', () {
    final many = [
      for (var n = 1; n <= 40; n++)
        _item(
          n,
          text: '，这是一条比较长的说明' * 20,
          view: n <= 3 ? AgentItemView.whole : AgentItemView.below,
        ),
    ];

    test('out of view items shrink to a few words, and the ones in view and '
        'the current one stay whole', () {
      final text = _snapshot(
        many,
        current: 2,
        views: {
          for (var n = 1; n <= 40; n++)
            n: n <= 3 ? AgentItemView.whole : AgentItemView.below,
        },
      ).text();
      expect(text.length, lessThanOrEqualTo(AgentScreenLimits.total));
      // Every item is still there, by number.
      for (final n in [1, 2, 3, 4, 20, 40]) {
        expect(text, contains(refs.agentHandle(n)), reason: '$n');
      }
      // The ones in view keep their words; the far ones are a few words.
      expect(text, contains('标题3'));
      expect(text, contains('⟨task:t3 '));
      expect(text, isNot(contains('⟨task:t40 ')));
    });

    test('when even that is too much the last ones are counted', () {
      final text = _snapshot([
        for (var n = 1; n <= 120; n++) _item(n, text: '，说明' * 40),
      ], current: 1).text();
      expect(text.length, lessThanOrEqualTo(AgentScreenLimits.total));
      expect(text, contains('没有列出'));
      expect(text, contains('① '));
    });
  });
}
