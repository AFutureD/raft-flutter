import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_service.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_writer.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/orb_arrival_brief.dart';
import 'package:raft_flutter/features/agent_orb/orb_prompt.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';

import 'agent_orb_briefing_service_test.dart'
    show FakeGemini, channelRow, dmRow, msg, threadRow;
import 'agent_orb_nav_tools_test.dart' show Fixture;
import 'support/agent_capability_world.dart';

// What `navigate` brings back on arrival at a conversation or the Activity:
// the briefing of the place (who needs the person, for what), read by the app
// instead of left to the model to make out of the page. Fictional data only.

OrbMatch match(OrbKind kind, String id, [Map<String, Object?>? data]) =>
    OrbMatch(
      kind: kind,
      id: id,
      title: id,
      score: 1,
      reason: '',
      data: data ?? const {},
    );

void main() {
  group('the scope of a destination', () {
    test(
      'Activity, channels, DMs and discussions have one; other pages not',
      () {
        expect(
          orbArrivalScope(match(OrbKind.page, 'activity')),
          OrbBriefScope.activity,
        );
        expect(
          orbArrivalScope(match(OrbKind.channel, 'ch-general')),
          const OrbBriefScope.conversation('ch-general'),
        );
        expect(
          orbArrivalScope(match(OrbKind.dm, 'dm-1')),
          const OrbBriefScope.conversation('dm-1'),
        );
        expect(
          orbArrivalScope(
            match(OrbKind.thread, 'p1', {'threadChannelId': 'th1'}),
          ),
          const OrbBriefScope.conversation('th1'),
        );
        expect(orbArrivalScope(match(OrbKind.thread, 'p1')), isNull);
        expect(orbArrivalScope(match(OrbKind.page, 'settings')), isNull);
        expect(orbArrivalScope(match(OrbKind.task, '#136')), isNull);
        expect(orbArrivalScope(match(OrbKind.profile, 'a-cody')), isNull);
      },
    );
  });

  group('the briefing it brings', () {
    late CapabilityWorld w;
    late OrbToolContext ctx;

    setUp(() {
      AgentModeData.clearSession();
      final world = capabilityWorld();
      w = world.$2;
      w.ledger.switchServer('s1');
      final client = world.$1;
      w.routes['/channels/inbox'] = (_) => {
        'items': [
          threadRow(),
          channelRow('ch-general', 'general', msgId: 'cm2'),
          dmRow(),
        ],
        'totalUnreadCount': 4,
        'hasMore': false,
      };
      w.routes['/messages/context/p1'] = (_) => {
        'messages': [msg('p1', 9, '重构第 10 步：拆分 activity 数据层', minutes: 300)],
      };
      w.routes['/tasks/server'] = (_) => {'tasks': []};
      w.routes['/agents'] = (_) => [
        {
          'id': 'a-cody',
          'name': 'cody',
          'displayName': 'Cody',
          'status': 'active',
          'runtime': 'codex',
          'creatorType': 'user',
          'creatorId': 'kevin',
        },
      ];
      w.routes['/servers/s1/members'] = (_) => [
        {'userId': 'kevin', 'name': 'kevin', 'displayName': 'Kevin'},
        {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
      ];
      final messages = {
        'th1': [
          msg('th1-m1', 11, '第 10 步的方案写好了。'),
          msg(
            'th1-m2',
            12,
            '@Kevin 第 10 步的方案已经写好，等你批准就开工。',
            mentions: ['kevin'],
          ),
        ],
        'ch-general': [
          msg('cm2', 5, 'Mac 验证通过，截图已经放进 PR 描述。', from: 'CodexMac'),
        ],
        'dm-1': [
          msg(
            'dm-m1',
            3,
            '周五的设计评审你能参加吗？',
            from: 'Ada',
            fromId: 'ada',
            type: 'user',
            minutes: 47,
          ),
        ],
      };
      for (final e in messages.entries) {
        client.responses['GET /messages/channel/${e.key}'] = {
          'messages': e.value,
          'hasMore': false,
        };
      }
      ctx = OrbToolContext(
        workspace: w,
        navigatorContext: _NoContext(),
        operating: ValueNotifier(false),
      );
    });

    OrbArrivalBrief arrival({FakeGemini? model}) => orbArrivalBrief(
      serviceFor: (_) =>
          OrbBriefingService(w, model: model, now: () => worldNow),
    );

    test(
      'a private conversation: who asks, what, how long, what to do',
      () async {
        final b = await arrival()(ctx, match(OrbKind.dm, 'dm-1'));
        expect(b!['scope'], 'conversation:dm-1');
        final needs = (b['needsYou']! as List).cast<Map<String, Object?>>();
        expect(needs, hasLength(1));
        expect(needs.single['who'], 'Ada');
        expect(needs.single['where'], contains('Ada'));
        expect(needs.single['since'], '已等 47 分钟');
        expect(needs.single['ask'], '回复');
        expect(needs.single['title'], contains('设计评审'));
        expect(b['sinceLastTime'], isNull, reason: 'the whole picture');
      },
    );

    test('the Activity: the same facts as get_briefing, grouped', () async {
      final b = await arrival()(ctx, match(OrbKind.page, 'activity'));
      expect(b!['scope'], 'activity');
      final who = [for (final i in (b['needsYou']! as List)) (i as Map)['who']];
      expect(who, containsAll(['Cody', 'Ada']));
      expect(b['routineCount'], isA<int>());
      expect(b['overview'], contains('2 件需要你处理'));
    });

    test('arriving twice says the whole picture both times, and does not use '
        'up what get_briefing reports as new', () async {
      final service = OrbBriefingService(w, now: () => worldNow);
      final brief = orbArrivalBrief(serviceFor: (_) => service);
      final first = await brief(ctx, match(OrbKind.dm, 'dm-1'));
      final second = await brief(ctx, match(OrbKind.dm, 'dm-1'));
      expect((second!['needsYou']! as List), hasLength(1));
      expect(second['sinceLastTime'], isNull);
      expect(first!['needsYou'], second['needsYou']);
    });

    test(
      'the model is asked with a short wait, the rules word the rest',
      () async {
        final slow = _SlowGemini();
        final started = Stopwatch()..start();
        final b = await arrival(model: slow)(
          ctx,
          match(OrbKind.dm, 'dm-1'),
        ).timeout(const Duration(seconds: 12));
        expect(slow.calls, greaterThan(0));
        // The model never answered; the facts are still there.
        expect(((b!['needsYou']!) as List).single['who'], 'Ada');
        expect(
          started.elapsed,
          lessThan(orbArrivalModelWait + const Duration(seconds: 3)),
        );
      },
    );

    test('a page without facts has no briefing', () async {
      expect(await arrival()(ctx, match(OrbKind.page, 'settings')), isNull);
    });
  });

  group('navigate', () {
    OrbTool navigate(OrbArrivalBrief? brief) =>
        orbNavigationTools(arrivalBrief: brief)
            .firstWhere((t) => t.name == 'navigate');

    Future<Map<String, Object?>> go(
      WidgetTester t,
      Fixture fx,
      OrbArrivalBrief? brief,
      String target,
    ) async {
      Map<String, Object?>? out;
      unawaited(
        navigate(brief)
            .handler({'target': target}, fx.ctx)
            .then((v) => out = v),
      );
      for (var i = 0; i < 40 && out == null; i++) {
        await fx.f.flush(t);
      }
      expect(out, isNotNull, reason: 'navigate did not answer');
      return out!;
    }

    testWidgets(
      'a conversation arrives with the briefing of that conversation',
      (t) async {
        final fx = Fixture();
        await fx.mount(t);
        final asked = <OrbMatch>[];
        final r = await go(t, fx, (ctx, m) async {
          asked.add(m);
          return {'scope': 'conversation:${m.id}', 'needsYou': <Object?>[]};
        }, 'raft-flutter');
        expect(r['error'], isNull);
        expect(asked.single.kind, OrbKind.channel);
        expect(r['briefing'], {
          'scope': 'conversation:ca',
          'needsYou': <Object?>[],
        });
        final page = r['page']! as Map;
        expect(page['route'], contains('/channel/ca'));
        // The briefing says what matters: the page's own list (every item
        // with its id, ~15 KB on a real Activity) stays out, so the model
        // neither waits on it nor reads ids from it aloud.
        expect(page.values.whereType<List>(), isEmpty);
        expect(page['itemsNote'], contains('describe_page'));
        await fx.f.close(t);
      },
    );

    // The briefing reads the data layer itself: it starts with the page
    // read, not after it, so its model wait does not add to the page wait.
    testWidgets('the briefing starts while the page is still loading', (
      t,
    ) async {
      final fx = Fixture()..caPage = Completer<void>();
      await fx.mount(t);
      var briefed = false;
      Map<String, Object?>? out;
      unawaited(
        navigate((c, m) async {
          briefed = true;
          return {'scope': 'conversation:${m.id}'};
        }).handler({'target': 'raft-flutter'}, fx.ctx).then((v) => out = v),
      );
      await fx.f.flush(t);
      await fx.f.flush(t);
      expect(out, isNull, reason: 'the page has not arrived');
      expect(briefed, isTrue);
      fx.caPage!.complete();
      for (var i = 0; i < 20 && out == null; i++) {
        await fx.f.flush(t);
      }
      expect(out!['briefing'], {'scope': 'conversation:ca'});
      await fx.f.close(t);
    });

    testWidgets('the Activity too; a settings page has none', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final scopes = <String?>[];
      Future<Map<String, Object?>?> brief(OrbToolContext c, OrbMatch m) async {
        final scope = orbArrivalScope(m);
        scopes.add(scope?.key);
        return scope == null ? null : {'scope': scope.key};
      }

      final activity = await go(t, fx, brief, '动态');
      expect(activity['briefing'], {'scope': 'activity'});
      final settings = await go(t, fx, brief, '设置');
      expect(settings.containsKey('briefing'), isFalse);
      expect(settings.containsKey('briefingNote'), isFalse);
      expect(scopes, ['activity', null]);
      await fx.f.close(t);
    });

    testWidgets('a briefing that fails does not fail the navigation', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await go(
        t,
        fx,
        (c, m) async => throw StateError('boom'),
        'raft-flutter',
      );
      expect(r['error'], isNull);
      expect(r['route'], contains('/channel/ca'));
      expect(r.containsKey('briefing'), isFalse);
      expect(r['briefingNote'], contains('get_briefing'));
      await fx.f.close(t);
    });

    testWidgets('a briefing that never comes is given up after the wait', (
      t,
    ) async {
      final fx = Fixture();
      await fx.mount(t);
      final never = Completer<Map<String, Object?>?>();
      Map<String, Object?>? out;
      unawaited(
        navigate((c, m) => never.future)
            .handler({'target': 'raft-flutter'}, fx.ctx)
            .then((v) => out = v),
      );
      await fx.f.flush(t);
      expect(out, isNull, reason: 'still waiting for the facts');
      await t.pump(orbArrivalWait + const Duration(seconds: 1));
      await fx.f.flush(t);
      expect(out!['route'], contains('/channel/ca'));
      expect(out!['briefingNote'], isA<String>());
      await fx.f.close(t);
    });

    // Eval B2: on the Activity, "读一下动态" made the model call navigate
    // (already there) and it read the briefing, tasks and all, instead of
    // the rows. Already there, the rows come along with a note.
    testWidgets('already there: the page keeps its rows and says how to read '
        'them', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      Future<Map<String, Object?>?> brief(OrbToolContext c, OrbMatch m) async =>
          {'scope': 'conversation:${m.id}'};
      await go(t, fx, brief, 'raft-flutter');
      final again = await go(t, fx, brief, 'raft-flutter');
      expect(again['alreadyThere'], isTrue);
      final page = again['page']! as Map;
      expect(page.values.whereType<List>(), isNotEmpty);
      expect(again['readNote'], contains('按 page'));
      await fx.f.close(t);
    });

    testWidgets('without a briefer navigate is what it was', (t) async {
      final fx = Fixture();
      await fx.mount(t);
      final r = await go(t, fx, null, 'raft-flutter');
      expect(r.containsKey('briefing'), isFalse);
      expect((r['page']! as Map).values.whereType<List>(), isNotEmpty);
      expect(r.containsKey('briefingNote'), isFalse);
      await fx.f.close(t);
    });
  });

  group('the prompt', () {
    final prompt = orbSystemPrompt(channels: 'raft-flutter、design');

    // Kevin: give it ASD-STE100 so it knows how to say things. The rules,
    // not the English word list.
    // Kevin wanted the big-text-and-cards briefing on screen.
    test('a briefing request navigates with show; a plain move does not', () {
      expect(prompt, contains('navigate 带上 show: true'));
      expect(prompt, contains('只是“去某个地方”就不要 show'));
    });

    // Kevin: "读动态的内容" got tasks; reading the Activity is its rows.
    test(
      'reading the Activity reads its rows in page order, not the briefing',
      () {
        expect(prompt, contains('读一下动态'));
        expect(prompt, contains('describe_page'));
        expect(prompt, contains('按页面上的顺序'));
        expect(prompt, contains('不要拿简报代替'));
      },
    );

    // On the G100 Flash wrote "Cindy 在等你处理…任务" for an agent that was
    // stuck: a blocked agent is not waiting for the person.
    test('a blocked agent is stuck, not waiting for the person', () {
      expect(OrbBriefingWriter.system, contains('agentBlocked'));
      expect(OrbBriefingWriter.system, contains('卡住了'));
      expect(OrbBriefingWriter.system, contains('不要写成“在等你”'));
    });

    test(
      'speaks in short, active, one-thing sentences and never reads ids',
      () {
        for (final text in [prompt, OrbBriefingWriter.system]) {
          expect(text, contains('ASD-STE100'));
          expect(text, contains('一句只说一件事'));
          expect(text, contains('主动'));
          expect(text, contains('绝不'));
          expect(text, contains('id'));
        }
      },
    );

    test('leads with what needs the user, and counts the routine', () {
      expect(prompt, contains('需要用户'));
      expect(prompt, contains('只说条数'));
      expect(prompt, contains('谁'));
      expect(prompt, contains('要做什么'));
    });

    test('never guesses who said what, and quotes only returned text', () {
      expect(prompt, contains('不要猜'));
      expect(prompt, contains('who'));
      expect(prompt, contains('只引用工具返回'));
    });

    test('tells the model to choose ids, with target as the last resort', () {
      final p = orbSystemPrompt(channels: 'raft-flutter [ca]、design [cb]');
      expect(p, contains('page 列表里选 id'));
      expect(p, contains('list_targets'));
      expect(p, contains('channel_id'));
      expect(p, contains('target 只用在'));
      expect(p, contains('raft-flutter [ca]'));
    });

    test('navigate already brings the briefing: no second get_briefing', () {
      expect(prompt, contains('navigate'));
      expect(prompt, contains('briefing'));
      expect(prompt, contains('不要再调 get_briefing'));
    });
  });
}

class _NoContext extends BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SlowGemini extends FakeGemini {
  @override
  Future<String?> generate(String system, String prompt) {
    prompts.add(prompt);
    return Completer<String?>().future;
  }
}
