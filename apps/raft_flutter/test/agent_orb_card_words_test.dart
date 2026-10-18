import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_actions.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_card_words.dart';

/// The words the app says about a confirm card in the agent layer: the
/// restatement from the card, the result, and what counts as a plain yes or no.

OrbPendingAction card(
  String capability,
  String summary,
  List<OrbCardRow> rows, {
  int total = 1,
}) => OrbPendingAction(
  token: 't',
  cardId: 'c',
  capabilityId: capability,
  summary: summary,
  rows: rows,
  heard: false,
  total: total,
);

void main() {
  group('the restatement names who and what', () {
    test('a reply names the person it answers, not the channel', () {
      final p = card('messages.reply_thread', '回复 Cody 的消息：“可以合”', const [
        OrbCardRow('回复', 'Cody：@Sam 第 10 步可以合入吗？'),
        OrbCardRow('内容', '可以合'),
        OrbCardRow('所在', '#raft-flutter'),
      ]);
      expect(orbRestate(p), '回复 Cody：可以合，要发吗？');
    });

    test('a private message goes "给" the person, a channel "到" it', () {
      final dm = card('messages.send', '发到私信 Alice：“好”', const [
        OrbCardRow('发到', '私信 Alice'),
        OrbCardRow('内容', '好'),
      ]);
      expect(orbRestate(dm), '发给 Alice：好，要发吗？');
      final channel = card('messages.send', '发到#general：“好”', const [
        OrbCardRow('发到', '#general'),
        OrbCardRow('内容', '好'),
      ]);
      expect(orbRestate(channel), '发到 #general：好，要发吗？');
    });

    test('a task status reads the number and the new status', () {
      final p = card('tasks.set_status', '把 #136 重构第 10 步 改为 已完成', const [
        OrbCardRow('状态', '已完成', from: '等验收'),
      ]);
      expect(orbRestate(p), '把 #136 标成完成，要改吗？');
      final progress = card(
        'tasks.set_status',
        '把 #136 重构第 10 步 改为 进行中',
        const [],
      );
      expect(orbRestate(progress), '把 #136 标成进行中，要改吗？');
    });

    test('a nudge and a reminder say what they do', () {
      final nudge = card('tasks.nudge', '催 Cody（#136 重构）：“现在到哪了”', const [
        OrbCardRow('催', 'Cody'),
        OrbCardRow('内容', '现在到哪了'),
      ]);
      expect(orbRestate(nudge), '催 Cody：现在到哪了，要催吗？');
      // The task it is about, by number, when the card names it.
      final withTask = card('tasks.nudge', '催 Cody（#136 重构）：“现在到哪了”', const [
        OrbCardRow('催', 'Cody'),
        OrbCardRow('任务', '#136 重构'),
        OrbCardRow('内容', '现在到哪了'),
      ]);
      expect(orbRestate(withTask), '催 Cody（#136）：现在到哪了，要催吗？');
      final snooze = card(
        'attention.snooze',
        '把 Cody 的提问 先放一放，今晚再提醒你',
        const [],
      );
      expect(orbRestate(snooze), '把 Cody 的提问 先放一放，今晚再提醒你，要记下吗？');
    });

    test('anything else is its own summary and a question', () {
      final p = card('channels.join', '加入 #design', const []);
      expect(orbRestate(p), '加入 #design，要做吗？');
    });

    test('a long text is cut for the ear', () {
      final p = card('messages.send', 'x', [
        const OrbCardRow('发到', '私信 Ada'),
        OrbCardRow('内容', '很长' * 40),
      ]);
      expect(orbRestate(p).length, lessThan(90));
      expect(orbRestate(p), contains('…'));
    });

    test('a sensitive card asks for the buttons, not for a yes', () {
      final p = card('agents.stop', '停掉 Cody', const [], total: 2);
      final said = orbRestate(p);
      expect(said, contains('停掉 Cody'));
      expect(said, contains('点屏幕上的确认'));
      expect(said, isNot(contains('要发吗')));
    });
  });

  test('the result is said as the capability worded it', () {
    expect(orbDoneLine('已发送'), '已发送。');
    expect(orbDoneLine('已改为 已完成。'), '已改为 已完成。');
    expect(orbDoneLine(''), '已完成。');
  });

  group('a plain yes', () {
    test('the short answers that mean "do it"', () {
      for (final said in [
        '确认',
        '确认。',
        '发吧',
        '好',
        '好的',
        '好，发吧',
        '嗯',
        '嗯，可以',
        '对',
        '对对对',
        '可以',
        '行',
        '没问题',
        '确定发送',
        '就这样',
        'OK',
        'yes',
      ]) {
        expect(orbPlainYes(said), isTrue, reason: said);
      }
    });

    test('anything with more in it is left to the model', () {
      for (final said in [
        '好，不过改成明天',
        '可以吗',
        '不对',
        '不发',
        '好像不太对',
        '发给 Cody 吧',
        '等一下',
        '确认一下他是谁',
        '',
        '对吗？',
      ]) {
        expect(orbPlainYes(said), isFalse, reason: said);
      }
    });
  });

  group('a plain no', () {
    test('the short answers that mean "drop it"', () {
      for (final said in [
        '取消',
        '取消。',
        '算了',
        '算了吧',
        '不用了',
        '不发了',
        '先不发',
        '不要了',
      ]) {
        expect(orbPlainNo(said), isTrue, reason: said);
      }
    });

    test('a no with a new ask in it is left to the model', () {
      for (final said in ['不对，改成明天', '不用了，你帮我看下任务', '好', '确认', '']) {
        expect(orbPlainNo(said), isFalse, reason: said);
      }
    });
  });
}
