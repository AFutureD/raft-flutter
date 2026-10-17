import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_orb/orb_agent_review.dart';
import 'package:raft_flutter/features/agent_orb/orb_key_facts.dart';

/// The key facts of what the person asked about, and the answer that leaves
/// one out (A1: "第 10 步" missing; C3: "等你验收" missing).

AgentToolRun run(String name, Map<String, Object?> result) =>
    AgentToolRun(name, const {}, result);

Map<String, Object?> codyItem({String since = '已等 20 分钟'}) => {
  'who': 'Cody',
  'title': 'Cody 问你：第 10 步可以合入吗？',
  'since': since,
  'where': '#raft-flutter',
};

/// navigate to #raft-flutter, as the briefing comes with it.
AgentToolRun arrived({List<Map<String, Object?>>? items}) => run('navigate', {
  'title': '#raft-flutter',
  'briefing': {
    'scope': 'conversation:c1',
    'needsYou': items ?? [codyItem()],
    'progress': <Object?>[],
    'routineCount': 0,
  },
});

AgentToolRun openedTask({String status = 'in_review'}) => run('navigate', {
  'title': '#136 重构第 10 步',
  'matched': {'kind': 'task', 'id': '#136'},
  'page': {
    'page': 'task',
    'task': {
      'number': 136,
      'title': '重构第 10 步',
      'status': status,
      'assignee': 'Cody',
    },
    'discussion': <Object?>[],
  },
});

List<String> shown(List<OrbFact> f) => [for (final x in f) x.shown];

void main() {
  group('what comes out of a read', () {
    test('A1: who, the step, what is asked and how long', () {
      final facts = orbKeyFacts([arrived()], said: '去 raft-flutter 看看谁找我');
      expect(shown(facts), ['Cody', '第 10 步', '合入', '20分钟']);
    });

    test('a step is said "第 10 步", "第10步" or "10 步"', () {
      final step = orbKeyFacts([arrived()], said: '谁找我')[1];
      for (final said in ['第 10 步', '第10步', '10步']) {
        expect(step.isIn('Cody 问$said'), isTrue, reason: said);
      }
      expect(step.isIn('Cody 问第 11 步'), isFalse);
    });

    test('an ask has its synonyms: 合入 ⇄ 合并 ⇄ merge', () {
      final ask = orbKeyFacts([arrived()], said: '谁找我')[2];
      for (final w in ['合入', '合并', 'merge', '并入']) {
        expect(ask.isIn('让你$w'), isTrue, reason: w);
      }
      expect(ask.isIn('让你看看'), isFalse);
    });

    test(
      'C3: a task is its title or number, how it stands, and who has it',
      () {
        final facts = orbKeyFacts([openedTask()], said: '打开 task 136');
        expect(shown(facts), ['重构第 10 步', '验收', 'Cody']);
        expect(facts.map((f) => f.say), [
          '任务 #136「重构第 10 步」',
          '等验收',
          'Cody 负责',
        ]);
        final status = facts[1];
        for (final w in ['等验收', '验收', '评审', 'review', '审阅', '等你审']) {
          expect(status.isIn('任务$w'), isTrue, reason: w);
        }
        expect(status.isIn('任务在进行中'), isFalse);
        // The number alone names it too.
        expect(facts[0].isIn('任务 136 在等验收'), isTrue);
      },
    );

    test('task_detail reads the same, from its own words', () {
      final facts = orbKeyFacts([
        run('task_detail', {
          'task': {
            'number': 141,
            'title': '整理发布说明',
            'statusText': '进行中',
            'assignee': '八戒',
          },
        }),
      ], said: '141 怎么样了');
      expect(shown(facts), ['整理发布说明', '进行中', '八戒']);
    });

    test('A5: what a conversation settled — who said it, and the plan', () {
      final facts = orbKeyFacts([
        run('read_conversation', {
          'conversation': {'id': 't1', 'type': 'conversation'},
          'messages': [
            {'from': 'Cody', 'text': '方案 B 的内存占用要先测一下。'},
            {'from': 'Alice', 'text': '好，就这样定了：改用方案 B。'},
            {'from': 'Sam', 'fromMe': true, 'text': '收到'},
          ],
        }),
      ], said: '这个讨论最后定了什么');
      expect(shown(facts), ['Alice', '方案 B']);
      expect(facts[1].isIn('定用方案B'), isTrue);
      // Not asked what was settled: no facts.
      expect(
        orbKeyFacts([
          run('read_conversation', {'messages': <Object?>[]}),
        ], said: '他问的是什么'),
        isEmpty,
      );
    });

    test(
      'nothing for small talk, an act, a page still loading or an error',
      () {
        expect(orbKeyFacts(const [], said: '你好'), isEmpty);
        expect(
          orbKeyFacts([
            run('confirm', {'status': 'done'}),
          ], said: '确认'),
          isEmpty,
        );
        expect(
          orbKeyFacts([
            run('navigate', {...openedTask().result, 'loading': true}),
          ], said: '打开 task 136'),
          isEmpty,
        );
        expect(
          orbKeyFacts([
            run('navigate', {'error': 'x'}),
          ], said: '打开 task 136'),
          isEmpty,
        );
        // A page that is not about the person's asking.
        expect(orbKeyFacts([arrived()], said: '去 raft-flutter'), isEmpty);
      },
    );
  });

  group('the answer that leaves one out', () {
    test('A1: "第 10 步" missing: the app adds it in a sentence, at once', () {
      final r = orbReviewReply(
        'Cody 在 #raft-flutter 等了 20 分钟，想让你批准合并。要回复他吗？',
        [arrived()],
        cardUp: false,
        said: '去 raft-flutter 看看谁找我',
      );
      expect(r?.retry, isNull, reason: 'no round trip to the model');
      expect(
        r?.text,
        'Cody 在 #raft-flutter 等了 20 分钟，想让你批准合并。这是第 10 步的事。要回复他吗？',
      );
    });

    test('C3: the status missing is added: 等验收', () {
      final r = orbReviewReply(
        '已经帮你打开 #136 重构第 10 步了。测试都过了，Cody 正瞅着呢，要现在通过吗？',
        [openedTask()],
        cardUp: false,
        said: '打开 task 136',
      );
      expect(r?.retry, isNull);
      expect(r?.text, '已经帮你打开 #136 重构第 10 步了。这件在等你验收。测试都过了，Cody 正瞅着呢，要现在通过吗？');
    });

    test('several missing share the one sentence; a reply without an end '
        'gets one', () {
      final r = orbReviewReply(
        'Cody 在 raft-flutter',
        [arrived()],
        cardUp: false,
        said: '谁找我',
      );
      expect(r?.text, 'Cody 在 raft-flutter。他在问第 10 步能不能合入，已经等了 20 分钟。');
    });

    test('complete answers pass, in the model\'s own words', () {
      expect(
        orbReviewReply(
          'Cody 问你第10步能不能合并，已经等了20分钟了。',
          [arrived()],
          cardUp: false,
          said: '去 raft-flutter 看看谁找我',
        ),
        isNull,
      );
      expect(
        orbReviewReply(
          'Cody 的任务 #136“重构第 10 步”在等验收，要通过吗？',
          [openedTask()],
          cardUp: false,
          said: '打开 task 136',
        ),
        isNull,
      );
    });

    test('while driving it stays one added sentence', () {
      final r = orbReviewReply(
        '迁移旧的缓存。',
        [
          run('task_detail', {
            'task': {
              'number': 142,
              'title': '迁移旧的缓存',
              'statusText': '等验收',
              'assignee': 'Cody',
            },
          }),
        ],
        cardUp: false,
        driving: true,
        said: '看看 142',
      );
      expect(r?.text, '迁移旧的缓存。这件在等你验收，由 Cody 负责。');
      expect('。'.allMatches(r!.text!).length, 2);
    });
  });

  group('the sentence that adds what is missing reads aloud', () {
    String added(List<Map<String, Object?>> items, String reply) {
      final facts = orbKeyFacts([arrived(items: items)], said: '谁找我');
      return orbWithSentence(
        reply,
        orbFactsSentence(orbMissingFacts(facts, reply)),
      );
    }

    Map<String, Object?> item(String who, String title, String since) => {
      'who': who,
      'title': title,
      'since': since,
      'where': '#raft-flutter',
    };

    test('what is asked is a clause of its own, before the question', () {
      final text = added([
        item('Cody', 'Cody 请你批准', '已等 5 分钟'),
      ], 'Cody 找你，等了 5 分钟。要直接回复他吗？');
      expect(text, 'Cody 找你，等了 5 分钟。他在等你批准。要直接回复他吗？');
      expect(text, isNot(contains('补充')));
    });

    test('the step and the verb are one clause, and the wait follows', () {
      expect(
        added([item('Cody', 'Cody 问你：第 10 步可以合入吗？', '已等 20 分钟')], 'Cody 找你。'),
        'Cody 找你。他在问第 10 步能不能合入，已经等了 20 分钟。',
      );
      expect(
        added([
          item('Cody', 'Cody 想让你评审第 10 步', '已等 20 分钟'),
        ], 'Cody 找你，等了 20 分钟。'),
        'Cody 找你，等了 20 分钟。他在等你评审第 10 步。',
      );
    });

    test('a missing name is named; the topic alone is "这是…的事"', () {
      expect(
        added([item('Cody', '周五的事', '已等 3 分钟')], '有人找你，等了 3 分钟。'),
        '有人找你，等了 3 分钟。Cody 找你，这是周五的事。',
      );
    });

    test('a task says how it stands, and who has it', () {
      final facts = orbKeyFacts([openedTask()], said: '打开 task 136');
      expect(
        orbFactsSentence(orbMissingFacts(facts, '好的。')),
        '任务 #136「重构第 10 步」在等你验收，由 Cody 负责。',
      );
      expect(
        orbFactsSentence([
          facts.firstWhere((f) => f.kind == OrbFactKind.status),
        ]),
        '这件在等你验收。',
      );
    });

    test('with several things, each is about its own asker; at most two', () {
      final facts = orbKeyFacts([
        arrived(
          items: [
            item('Cody', 'Cody 问你：第 10 步可以合入吗？', '已等 20 分钟'),
            item('八戒', '八戒请你批准', '已等 5 分钟'),
            item('Alice', 'Alice 请你评审', '已等 1 小时'),
          ],
        ),
      ], said: '谁找我');
      final s = orbFactsSentence(orbMissingFacts(facts, '三个人找你。'));
      expect(s, contains('Cody 找你，在问第 10 步能不能合入，已经等了 20 分钟'));
      expect(s, contains('；'));
      expect(s, isNot(contains('Alice')));
      expect('。'.allMatches(s).length, 1, reason: 'one sentence');
    });

    test('a reply without an end gets one; a question alone gets it first', () {
      expect(orbWithSentence('Cody 在等', '他在等你批准。'), 'Cody 在等。他在等你批准。');
      expect(orbWithSentence('要回复他吗？', '他在等你批准。'), '他在等你批准。要回复他吗？');
    });
  });
}
