import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/key_info.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_run.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/orb_key_info.dart';

/// Wording is free; the key information is not: what the voice said must carry
/// the numbers, the names and, for a confirmation card, what it does, to whom,
/// the words and that it asks for a yes.

Map<String, Object?> replyCard() => {
  'status': 'needs_confirmation',
  'preview': {
    'summary': '回复 Cody 的消息：“晚上看”',
    'changes': ['回复: Cody：第 10 步可以合入吗 → Cody：第 10 步可以合入吗', '内容:  → 晚上看'],
  },
};

Map<String, Object?> statusCard() => {
  'status': 'needs_confirmation',
  'preview': {
    'summary': '把 #136 改为 已完成',
    'changes': ['状态: 等验收 → 已完成'],
  },
};

void main() {
  group('numbers and contents', () {
    test('a number is said in digits or in Chinese', () {
      for (final spoken in ['一百三十六号', '136', '一三六', '第一百三十六个']) {
        expect(saysNumber(keyCompact(spoken), '136'), isTrue, reason: spoken);
      }
      expect(saysNumber('第十步', '10'), isTrue);
      expect(saysNumber('二十分钟', '20'), isTrue);
      expect(saysNumber('两个', '2'), isTrue);
      expect(saysNumber('第十一步', '10'), isFalse);
      expect(saysNumber('一百三十七', '136'), isFalse);
    });

    test('a content is mostly there, in any wording around it', () {
      expect(contentCoverage('晚上看', keyCompact('回复他，晚上看吧')), 1);
      expect(contentCoverage('晚上看', keyCompact('回复他，明天')), 0);
      expect(
        contentCoverage('周五下午三点评审', keyCompact('周五三点评审')),
        greaterThan(.5),
      );
    });
  });

  group('the key information of an answer', () {
    const say = 'Cody 在问第 10 步能不能合入，已经等了 20 分钟。';
    final info = orbSayKeyInfo(say);

    test('another wording, order and filler words are fine', () {
      for (final spoken in [
        '好的，Cody 问你第十步能不能合入，他已经等了二十分钟了。',
        '等了 20 分钟了，Cody 想问第 10 步的事，能合入吗？',
        'cody 在问 第10步 能不能合入，等了20分钟',
      ]) {
        expect(info.missingIn(spoken), isEmpty, reason: spoken);
        expect(info.contradictionsIn(spoken), isEmpty, reason: spoken);
      }
    });

    test('a lost number or name is listed', () {
      expect(info.missingIn('Cody 在问能不能合入，已经等了 20 分钟。'), ['数字 10']);
      expect(info.missingIn('Cody 在问第 10 步能不能合入，等了一会儿。'), ['数字 20']);
      expect(info.missingIn('有人在问第 10 步能不能合入，等了 20 分钟。'), ['名字 Cody']);
    });

    test('a number or a person the answer does not have contradicts it', () {
      expect(info.contradictionsIn('Cody 问第 11 步，等了 20 分钟'), ['多出数字 11']);
      expect(
        info.contradictionsIn('Alice 问第 10 步，等了 20 分钟', knownNames: ['Alice']),
        ['多出人名 Alice'],
      );
      // Its own people are fine.
      expect(
        info.contradictionsIn('Cody 问第 10 步', knownNames: ['Alice', 'Cody']),
        isEmpty,
      );
    });
  });

  group('a confirmation card', () {
    final reply = orbCardKeyInfoOfResult(
      'reply_in_thread',
      const {},
      replyCard(),
    )!;

    test('a result that is no card has none', () {
      expect(
        orbCardKeyInfoOfResult('reply_in_thread', const {}, {'status': 'done'}),
        isNull,
      );
    });

    test('the verb, the person, the words and the question are all there', () {
      for (final spoken in [
        '我准备回复 Cody，说晚上看。要发吗？',
        'Cody 那边我替你回一句晚上看，发出去可以吗',
        '要不要给 Cody 发一条：晚上看？',
      ]) {
        expect(reply.missingIn(spoken), isEmpty, reason: spoken);
      }
    });

    test('each missing piece is named', () {
      expect(reply.missingIn('回复 Cody，晚上看。'), [
        '问他要不要做（等他确认）',
      ], reason: 'said as a fact, not asked');
      expect(reply.missingIn('要回复他，晚上看，可以吗？'), ['对象 Cody']);
      expect(reply.missingIn('要回复 Cody，说明天吗？'), ['内容「晚上看」']);
      expect(reply.missingIn('Cody 晚上看，行吗？'), ['动作（发…）']);
    });

    test('a task card needs its number and the new state', () {
      final card = orbCardKeyInfoOfResult(
        'set_task_status',
        const {},
        statusCard(),
      )!;
      expect(card.missingIn('把 136 号标成完成，要改吗？'), isEmpty);
      expect(card.missingIn('把一百三十六号任务标成完成，可以吗'), isEmpty);
      expect(card.missingIn('把这个任务标成完成，要改吗？'), ['数字 136']);
      expect(card.missingIn('把 #136 的事，要处理吗？'), ['动作（标成…）']);
      expect(card.contradictionsIn('把 #137 标成完成，要改吗？'), ['多出数字 137']);
    });

    test('a sensitive card is about the buttons, not a yes', () {
      final result = {...statusCard(), 'next': '这是敏感操作：屏幕上出了确认卡，要用户自己点两次'};
      final card = orbCardKeyInfoOfResult('set_task_status', const {}, result)!;
      expect(card.missingIn('这是敏感操作，把 #136 标成完成，请你点屏幕上的确认。'), isEmpty);
      expect(card.missingIn('把 #136 标成完成，要改吗？'), ['请他点屏幕上的确认']);
    });
  });

  group('the evaluation check', () {
    OrbEvalRun runOf(
      String say,
      String heard, {
      List<String> spoken = const [],
      List<OrbEvalToolCall> tools = const [],
    }) {
      final t = OrbEvalTurn('说点什么')..addText(heard);
      t.asks.add(OrbEvalAsk(request: 'x', say: say, millis: 1));
      t.spoken.addAll(spoken);
      t.tools.addAll(tools);
      return OrbEvalRun(ids: {})..turns.add(t);
    }

    final check = OrbEvalCheck.keyInfoSpoken();

    OrbEvalToolCall card(String tool, Map<String, Object?> result) =>
        OrbEvalToolCall(name: tool, args: const {}, result: result, millis: 1);

    test('a paraphrase passes', () {
      expect(
        check.test(
          runOf(
            'Cody 在问第 10 步能不能合入，已经等了 20 分钟。',
            '好的，Cody 问你第十步能合入吗？他等了二十分钟了。',
          ),
        ),
        isNull,
      );
    });

    test('what was missing or wrong is listed with both texts', () {
      final reason = check.test(
        runOf('Cody 在问第 10 步能不能合入，已经等了 20 分钟。', '有人问能不能合入。'),
      );
      expect(reason, contains('漏了：数字 10、数字 20、名字 Cody'));
      expect(reason, contains('say「Cody 在问第 10 步'));
      expect(reason, contains('说出「有人问能不能合入。」'));
      final wrong = check.test(
        runOf('Cody 问第 10 步。', 'Alice 问第 11 步，Cody 也在。'),
      );
      expect(wrong, contains('不对：多出数字 11、多出人名 Alice'));
    });

    test('the card of the turn adds what to confirm; the spoken sentences of '
        'the app\'s voice count', () {
      final tools = [card('reply_in_thread', replyCard())];
      const say = '回复 Cody：晚上看，要发吗？';
      expect(
        check.test(runOf(say, '我替你回复 Cody，晚上看，发吗？', tools: tools)),
        isNull,
      );
      expect(
        check.test(
          runOf(say, '', spoken: ['回复 Cody：晚上看，', '要发吗？'], tools: tools),
        ),
        isNull,
      );
      // The same words, no question.
      expect(
        check.test(runOf('回复 Cody：晚上看。', '我替你回复 Cody，晚上看。', tools: tools)),
        contains('问他要不要做'),
      );
    });

    test('no ask fails; an empty say asks for nothing', () {
      final none = OrbEvalRun(ids: {})..turns.add(OrbEvalTurn('下一件'));
      expect(check.test(none), contains('没有交给 Agent'));
      expect(check.test(runOf('', '')), isNull);
    });
  });
}
