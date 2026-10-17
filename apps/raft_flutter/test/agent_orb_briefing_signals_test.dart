import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_signals.dart';

/// The relevance signals: what needs the person, what is progress, what is
/// routine. Fixture people only.
final _now = DateTime.utc(2026, 10, 17, 12);
const _me = OrbMe(id: 'kevin', names: {'Kevin', 'kevin'});

OrbMessage msg(
  String text, {
  String id = 'm1',
  String from = 'Cody',
  String fromId = 'cody',
  String type = 'agent',
  bool mentionsMe = false,
  int minutesAgo = 20,
}) => OrbMessage(
  id: id,
  text: text,
  senderId: fromId,
  senderName: from,
  senderType: type,
  at: _now.subtract(Duration(minutes: minutesAgo)),
  mentionsMe: mentionsMe,
);

OrbMessage mine(String text, {String id = 'mine', int minutesAgo = 10}) => msg(
  text,
  id: id,
  from: 'Kevin',
  fromId: 'kevin',
  type: 'user',
  minutesAgo: minutesAgo,
);

OrbCandidate cand(
  List<OrbMessage> messages, {
  OrbSource source = OrbSource.thread,
  bool rowMention = false,
  bool following = false,
  bool parentMine = false,
  OrbMessage? parent,
  int unread = 1,
}) => OrbCandidate(
  id: 'c1',
  source: source,
  messages: messages,
  parent: parent,
  rowMention: rowMention,
  following: following,
  parentMineHint: parentMine,
  unread: unread,
);

OrbSignal classify(OrbCandidate c) =>
    OrbSignals.classify(c, me: _me, now: _now);

void main() {
  group('needs you', () {
    final table = <String, (OrbCandidate, OrbReason)>{
      'a mention that asks a question': (
        cand([msg('@Kevin 这个方案你看可以吗？', mentionsMe: true)]),
        OrbReason.mentionAsk,
      ),
      'a mention that requests something': (
        cand([msg('@Kevin 麻烦你看一下第 10 步', mentionsMe: true)]),
        OrbReason.mentionAsk,
      ),
      'a mention that asks in English': (
        cand([msg('@Kevin can you review the PR?', mentionsMe: true)]),
        OrbReason.mentionAsk,
      ),
      'the row says mention and the newest message asks': (
        cand([msg('进度如何？你需要看一下吗')], rowMention: true),
        OrbReason.mentionAsk,
      ),
      'a reply to my message that asks something': (
        cand([msg('你说的是 v2 接口吗？')], parentMine: true, parent: mine('接口改成 v2')),
        OrbReason.replyAsk,
      ),
      'a private message that asks something': (
        cand([
          msg('周五的设计评审你能参加吗？', from: 'Alice', fromId: 'alice', type: 'user'),
        ], source: OrbSource.dm),
        OrbReason.dmAsk,
      ),
      'an explicit wait for my approval, mentioned': (
        cand([msg('@Kevin 方案写好了，等你批准就开工。', mentionsMe: true)]),
        OrbReason.awaitingApproval,
      ),
      'an explicit wait for my decision in a thread I started': (
        cand([msg('两种做法都行，等你决定。')], parentMine: true),
        OrbReason.awaitingApproval,
      ),
      'a build failure': (
        cand([
          msg(
            '构建失败：raft-flutter main 的 Android 打包没过',
            from: 'CI',
            fromId: 'ci',
            type: 'system',
          ),
        ], source: OrbSource.channel),
        OrbReason.buildFailure,
      ),
      'a release failure in English': (
        cand([msg('Release failed on step 3')], source: OrbSource.channel),
        OrbReason.buildFailure,
      ),
    };
    table.forEach((name, row) {
      test(name, () {
        final s = classify(row.$1);
        expect(s.bucket, OrbBucket.needsYou);
        expect(s.reason, row.$2);
        expect(s.ambiguous, isFalse);
      });
    });

    test(
      'the waiting time counts from the request, not from the latest message',
      () {
        final s = classify(
          cand([
            msg('@Kevin 等你批准就开工', mentionsMe: true, minutesAgo: 90, id: 'a'),
            msg('我先去吃饭', id: 'b', minutesAgo: 5),
          ]),
        );
        expect(s.bucket, OrbBucket.needsYou);
        expect(
          s.since!.isAtSameMomentAs(_now.subtract(const Duration(minutes: 90))),
          isTrue,
        );
        expect(s.request!.id, 'a');
        expect(s.who, 'Cody');
      },
    );

    test('what I already answered is not waiting for me', () {
      final s = classify(
        cand([
          msg('@Kevin 等你批准', mentionsMe: true, id: 'a', minutesAgo: 30),
          mine('批准', minutesAgo: 10),
        ]),
      );
      expect(s.bucket, OrbBucket.routine);
    });

    test('a failure that was fixed is not a failure', () {
      final s = classify(
        cand([msg('构建失败已修复，重新跑通过了')], source: OrbSource.channel),
      );
      expect(s.reason, isNot(OrbReason.buildFailure));
    });
  });

  group('tasks and agents', () {
    Map<String, dynamic> task(String status, {int hoursAgo = 1}) => {
      'id': 't1',
      'status': status,
      'claimedByName': 'Grok',
      'createdByName': 'Kevin',
      'updatedAt': _now.subtract(Duration(hours: hoursAgo)).toIso8601String(),
    };

    test('a task I created that is in review awaits my approval', () {
      final s = classify(
        OrbCandidate(
          id: 't1',
          source: OrbSource.task,
          task: task('in_review'),
          taskCreated: true,
        ),
      );
      expect(s.bucket, OrbBucket.needsYou);
      expect(s.reason, OrbReason.awaitingApproval);
      expect(s.who, 'Grok');
      expect(
        s.since!.isAtSameMomentAs(_now.subtract(const Duration(hours: 1))),
        isTrue,
      );
    });

    test('a task that mentions me and is in review awaits my approval', () {
      final s = classify(
        OrbCandidate(
          id: 't1',
          source: OrbSource.task,
          task: task('in_review'),
          taskMentioned: true,
        ),
      );
      expect(s.reason, OrbReason.awaitingApproval);
    });

    test('a task assigned to me and blocked needs me', () {
      for (final t in [task('blocked'), task('in_progress', hoursAgo: 6)]) {
        final s = classify(
          OrbCandidate(
            id: 't1',
            source: OrbSource.task,
            task: t,
            taskAssigned: true,
          ),
        );
        expect(s.bucket, OrbBucket.needsYou, reason: '${t['status']}');
        expect(s.reason, OrbReason.assignedBlocked);
      }
    });

    test('a task assigned to me that moves is progress, not a request', () {
      final s = classify(
        OrbCandidate(
          id: 't1',
          source: OrbSource.task,
          task: task('in_progress', hoursAgo: 1),
          taskAssigned: true,
        ),
      );
      expect(s.bucket, OrbBucket.progress);
    });

    test('a task that is not mine is routine', () {
      final s = classify(
        OrbCandidate(id: 't1', source: OrbSource.task, task: task('in_review')),
      );
      expect(s.bucket, OrbBucket.routine);
    });

    test('an agent I manage that is blocked needs me; one I do not manage '
        'does not', () {
      OrbSignal agent({required bool managed, bool blocked = true}) => classify(
        OrbCandidate(
          id: 'agent:a1',
          source: OrbSource.agent,
          agentName: 'CodexMac',
          agentBlocked: blocked,
          agentManaged: managed,
        ),
      );
      expect(agent(managed: true).bucket, OrbBucket.needsYou);
      expect(agent(managed: true).reason, OrbReason.agentBlocked);
      expect(agent(managed: true).who, 'CodexMac');
      expect(agent(managed: false).bucket, OrbBucket.routine);
      expect(agent(managed: true, blocked: false).bucket, OrbBucket.routine);
    });

    test('a merged thread task in review still awaits me when the thread '
        'content alone is routine', () {
      final s = classify(
        OrbCandidate(
          id: 'row',
          source: OrbSource.thread,
          messages: [msg('我在跑测试')],
          task: task('in_review'),
          taskCreated: true,
          unread: 1,
        ),
      );
      expect(s.bucket, OrbBucket.needsYou);
      expect(s.reason, OrbReason.awaitingApproval);
    });
  });

  group('ambiguous: only the model can tell asking from FYI', () {
    test('a mention without a request', () {
      final s = classify(cand([msg('Mac 验证通过，@Kevin 知悉', mentionsMe: true)]));
      expect(s.ambiguous, isTrue);
      expect(s.reason, OrbReason.mentionFyi);
      // Until the model says it asks, it is not a demand.
      expect(s.bucket, OrbBucket.progress);
    });

    test('a reply to me without a question', () {
      final s = classify(
        cand([msg('收到，我来改')], parentMine: true, parent: mine('改一下')),
      );
      expect(s.ambiguous, isTrue);
      expect(s.reason, OrbReason.replyFyi);
    });

    test('a private message without a question', () {
      final s = classify(
        cand([
          msg('新的颜色方案已更新', from: 'Alice', fromId: 'alice', type: 'user'),
        ], source: OrbSource.dm),
      );
      expect(s.ambiguous, isTrue);
      expect(s.reason, OrbReason.dmFyi);
    });

    test('"已确认" is a report, not a request', () {
      final s = classify(cand([msg('@Kevin 已确认，已经合入', mentionsMe: true)]));
      expect(s.reason, OrbReason.mentionFyi);
    });
  });

  group('progress and routine', () {
    test('a result in a channel is progress', () {
      final s = classify(
        cand([
          msg('Mac 验证通过，截图已经放进 PR 描述。', from: 'CodexMac', fromId: 'cm'),
        ], source: OrbSource.channel),
      );
      expect(s.bucket, OrbBucket.progress);
      expect(s.who, 'CodexMac');
    });

    test('chatter in a channel is routine', () {
      final s = classify(cand([msg('午饭吃什么')], source: OrbSource.channel));
      expect(s.bucket, OrbBucket.routine);
    });

    test('a new message in a thread I follow is progress', () {
      final s = classify(cand([msg('正在修，改完会补一条回归测试。')], following: true));
      expect(s.bucket, OrbBucket.progress);
    });

    test('a system event on something I follow is progress and names its '
        'actor, never 有人', () {
      final s = classify(
        cand([
          msg(
            '🔄 Cody moved #136 to in_review',
            from: '',
            fromId: 'system',
            type: 'system',
          ),
        ], following: true),
      );
      expect(s.bucket, OrbBucket.progress);
      expect(s.reason, OrbReason.systemEvent);
      expect(s.who, 'Cody');
      expect(s.whoKind, 'system');
    });

    test('a system event with no named actor is 系统, a system event on '
        'something that is not mine is routine', () {
      final named = classify(
        cand([
          msg('任务已自动归档', from: '', fromId: 'system', type: 'system'),
        ], following: true),
      );
      expect(named.who, '系统');
      final other = classify(
        cand([
          msg(
            '🔄 Cody moved #136 to done',
            from: '',
            fromId: 'system',
            type: 'system',
          ),
        ], source: OrbSource.channel),
      );
      expect(other.bucket, OrbBucket.routine);
    });

    test('a mention row that carries no message at all is routine', () {
      expect(classify(cand(const [])).bucket, OrbBucket.routine);
    });
  });

  group('the template-row problem', () {
    test('the verdict comes from the fetched content, not the row text', () {
      // The Activity row only says "Cody 说了 …，3 条回复"; the fetched
      // message is the request.
      const template = 'Cody 说了 方案已经写好，3 条回复';
      final withContent = OrbCandidate(
        id: 'row',
        source: OrbSource.thread,
        messages: [msg('@Kevin 第 10 步的方案写好了，等你批准就开工。', mentionsMe: true)],
        rowMention: true,
        unread: 2,
        sourceIds: const [template],
      );
      expect(classify(withContent).reason, OrbReason.awaitingApproval);

      // The reverse: a template that sounds like a request over content that
      // is not one.
      final fyi = OrbCandidate(
        id: 'row2',
        source: OrbSource.channel,
        messages: [msg('午饭吃什么')],
        unread: 1,
        sourceIds: const ['Alice 问了 你能确认吗？'],
      );
      expect(classify(fyi).bucket, OrbBucket.routine);
    });
  });
}
