import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_stream.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_consent.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_reference_table.dart';
import 'package:raft_flutter/features/agent_mode/runtime/agent_runtime.dart';
import 'package:raft_flutter/features/agent_mode/runtime/agent_turn.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

class _Link implements AgentModelLink {
  final told = <String>[];
  var stopped = 0;

  @override
  Future<bool> tell(String note) async {
    told.add(note);
    return true;
  }

  @override
  void stopSpeaking() => stopped++;
}

/// The screen as the runtime sees it: layers begun, and which are open.
class _Screen {
  final begun = <AgentSurfaceDraft>[];
  final ended = <AgentSurfaceDraft>[];
  late final host = AgentSurfaceHost(
    begin: (draft) {
      begun.add(draft);
      return const {};
    },
    changed: (draft, {added}) => const {},
    isOpen: begun.contains,
    ended: ended.add,
  );
}

void main() {
  late ActivityClient client;
  late CapabilityWorld w;
  late _Screen screen;
  late _Link link;
  late AgentRuntime rt;
  var clock = worldNow;

  setUp(() {
    clock = worldNow;
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.ledger.switchServer('s1');
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_progress')
          taskRow(
            't3',
            9,
            'in_progress',
            title: '丙',
            claimedById: 'a-cody',
            claimedByName: 'Cody',
          ),
      ],
    };
    w.routes['/tasks/channel/ch-general/number/9'] = (_) => {
      'task': {...taskRow('t3', 9, 'in_progress', title: '丙'), 'revision': 4},
    };
    w.routes['/channels/ch-general/members'] = (_) => {
      'humans': [
        {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
      ],
      'agents': [
        {'id': 'a-cody', 'name': 'cody', 'displayName': 'Cody'},
      ],
    };
    screen = _Screen();
    link = _Link();
    rt = AgentRuntime(
      workspace: w,
      data: AgentModeData(w, now: () => worldNow),
      surfaces: screen.host,
      references: () => AgentReferenceTable.empty,
      modelLink: link,
      now: () => clock,
    );
  });
  tearDown(() async {
    rt.dispose();
    w.dispose();
    await client.dispose();
  });

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) => rt.runTool(name, args);

  /// The phases the machine went through, consecutive duplicates dropped.
  List<AgentPhase> trace() {
    final seen = <AgentPhase>[rt.phase];
    rt.addListener(() {
      if (seen.last != rt.phase) seen.add(rt.phase);
    });
    return seen;
  }

  group('the state machine', () {
    test('the table only names phases it defines, and idle has no way in '
        'but a request', () {
      for (final e in agentPhaseTransitions.entries) {
        expect(e.value, isNot(contains(e.key)));
        expect(agentPhaseTransitions.keys, containsAll(e.value));
      }
      expect(agentPhaseTransitions[AgentPhase.idle], {
        AgentPhase.acting,
      }, reason: 'idle leaves through a new turn, or a call nobody asked for');
    });

    test('a typed request: understanding, acting, presenting, idle', () async {
      final phases = trace();
      expect(rt.phase, AgentPhase.idle);
      final turn = rt.submitText('看所有频道')!;
      expect(turn.userText, '看所有频道');
      expect(rt.phase, AgentPhase.understanding);
      final r = await call('show_list', {'kind': 'channels'});
      expect(r['ok'], isTrue);
      rt.modelSpoke();
      rt.modelTurnComplete();
      expect(phases, [
        AgentPhase.idle,
        AgentPhase.understanding,
        AgentPhase.acting,
        AgentPhase.presenting,
        AgentPhase.idle,
      ]);
      expect(turn.status, AgentTurnStatus.finished);
      expect(rt.illegalTransitions, isEmpty);
    });

    test('a spoken request starts at listening', () async {
      final phases = trace();
      rt.beginListening();
      expect(rt.phase, AgentPhase.listening);
      rt.userTranscript('看所有', fresh: true);
      rt.userTranscript('任务', fresh: false);
      expect(rt.current!.userText, '看所有任务');
      rt.userDone();
      await call('show_list', {'kind': 'tasks'});
      rt.modelSpoke();
      rt.modelTurnComplete();
      expect(phases, [
        AgentPhase.idle,
        AgentPhase.listening,
        AgentPhase.understanding,
        AgentPhase.acting,
        AgentPhase.presenting,
        AgentPhase.idle,
      ]);
      expect(rt.illegalTransitions, isEmpty);
    });

    test('a preview waits for the person, a confirm goes on', () async {
      final phases = trace();
      rt.submitText('跟大家说你好');
      final preview = await call('send_message', {
        'channel': 'general',
        'text': '你好',
      });
      expect(preview['status'], 'needs_confirmation');
      expect(rt.phase, AgentPhase.awaitingConfirmation);
      expect(rt.current!.pendingConfirmations, {preview['confirmToken']});
      rt.modelTurnComplete();
      // The model is done, the person has not decided: the turn stays open.
      expect(rt.phase, AgentPhase.awaitingConfirmation);
      expect(rt.current!.status, AgentTurnStatus.open);

      rt.consent.cardTapped(rt.consent.active.single.cardId, yes: true);
      final done = await call('confirm', {'token': preview['confirmToken']});
      expect(done['status'], 'done');
      rt.modelTurnComplete();
      expect(rt.phase, AgentPhase.idle);
      expect(phases, [
        AgentPhase.idle,
        AgentPhase.understanding,
        AgentPhase.acting,
        AgentPhase.awaitingConfirmation,
        AgentPhase.acting,
        AgentPhase.understanding,
        AgentPhase.idle,
      ]);
      expect(rt.illegalTransitions, isEmpty);
    });

    test('a call nobody asked for opens a turn of its own', () async {
      expect(rt.current, isNull);
      await call('show_list', {'kind': 'channels'});
      expect(rt.current!.source, AgentTurnSource.model);
      expect(rt.illegalTransitions, isEmpty);
    });
  });

  group('a new request replaces the old one', () {
    test('a read still in flight is dropped when it arrives', () async {
      final slow = Completer<Object?>();
      w.routes['/messages/search'] = (_) => slow.future;
      rt.submitText('搜一下上线');
      final old = call('search_messages', {'q': '上线'});
      await pumpEventQueue();
      expect(rt.current!.inFlight.single.name, 'search_messages');

      rt.submitText('看所有频道');
      expect(rt.current!.previous?.status, AgentTurnStatus.superseded);
      final next = await call('show_list', {'kind': 'channels'});
      expect(next['ok'], isTrue);

      // The model is answered at once, not when the server is done.
      final dropped = await old;
      expect(dropped['cancelled'], isTrue);
      expect(dropped.containsKey('refs'), isFalse);

      slow.complete({
        'results': [
          {
            'id': 'm1',
            'channelId': 'ch-general',
            'senderName': 'Ada',
            'content': '上线了',
          },
        ],
      });
      await pumpEventQueue();
      expect([for (final d in screen.begun) d.title], ['频道 · 3']);
      expect(rt.turns.first.status, AgentTurnStatus.cancelled);
    });

    test('speaking over the model does the same', () async {
      final slow = Completer<Object?>();
      w.routes['/messages/search'] = (_) => slow.future;
      rt.submitText('搜一下上线');
      final old = call('search_messages', {'q': '上线'});
      await pumpEventQueue();

      rt.modelInterrupted();
      expect(rt.phase, AgentPhase.listening);
      expect(rt.current!.source, AgentTurnSource.bargeIn);
      // Calls made before the person had said anything are not about what
      // they are about to say.
      final stale = await call('show_list', {'kind': 'channels'});
      expect(stale['stale'], isTrue);
      expect(screen.begun, isEmpty);

      rt.userTranscript('不对，看所有任务', fresh: true);
      rt.userDone();
      final next = await call('show_list', {'kind': 'tasks'});
      expect(next['ok'], isTrue);
      expect((await old)['cancelled'], isTrue);
      slow.complete({'results': []});
      await pumpEventQueue();
      expect(screen.begun, hasLength(1));
      expect(rt.illegalTransitions, isEmpty);
    });

    Future<String> beginAgents() async {
      final r = await call('begin_surface', {
        'surface_id': 'agents',
        'title': 'Agent 们',
        'layout': '{"component":"Column","id":"root","children":[{"component":"Section","id":"busy","title":"在忙"}]}',
      });
      expect(r['ok'], isTrue, reason: '$r');
      return 'agents';
    }

    test('a screen being streamed stops, and what is shown stays', () async {
      rt.submitText('Agent 们在干什么');
      final id = await beginAgents();
      final added = await call('add_component', {
        'surface_id': id,
        'parent_id': 'busy',
        'component': '{"component":"Callout","text":"Cody 在做 #9"}',
      });
      expect(added['ok'], isTrue, reason: '$added');
      expect(rt.surfaceStopped(id), isFalse);

      rt.submitText('看所有频道');
      expect(rt.surfaceStopped(id), isTrue);
      expect(screen.ended, hasLength(1), reason: 'the badge stops composing');
      await call('show_list', {'kind': 'channels'});

      final late = await call('add_component', {
        'surface_id': id,
        'parent_id': 'busy',
        'component': '{"component":"Callout","text":"Bo 在做 #10"}',
      });
      expect(late['stopped'], isTrue);
      // The component that was already there is still there.
      final draft = screen.begun.first;
      expect(draft.find('busy')!.children, hasLength(1));
      expect(draft.find('busy')!.children.single.string('text'), 'Cody 在做 #9');
    });

    test('adding to the old screen is going on from it', () async {
      rt.submitText('Agent 们在干什么');
      final id = await beginAgents();
      rt.submitText('再加上卡住的');
      expect(rt.surfaceStopped(id), isTrue);
      final more = await call('add_component', {
        'surface_id': id,
        'parent_id': 'busy',
        'component': '{"component":"Callout","text":"Bo 卡住了"}',
      });
      expect(more['ok'], isTrue, reason: '$more');
      expect(rt.surfaceStopped(id), isFalse);
      expect(rt.turns.first.status, AgentTurnStatus.merged);
    });
  });

  group('confirmations', () {
    Future<Map<String, Object?>> preview() async {
      rt.submitText('跟大家说你好');
      final r = await call('send_message', {
        'channel': 'general',
        'text': '你好',
      });
      rt.modelTurnComplete();
      expect(rt.consent.active, hasLength(1));
      return r;
    }

    test('an unrelated request cancels it, the card says 已取消', () async {
      final r = await preview();
      rt.submitText('看所有频道');
      // Not yet: the model has not said what this is about.
      expect(rt.consent.active, hasLength(1));
      await call('show_list', {'kind': 'channels'});
      expect(rt.consent.active, isEmpty);
      expect(rt.consent.cancelledCards, hasLength(1));
      expect(rt.turns.first.status, AgentTurnStatus.cancelled);
      // The model's confirm for it is a no.
      final late = await call('confirm', {'token': r['confirmToken']});
      expect(late['status'], 'declined');
      expect(w.sent, isEmpty);
    });

    test(
      'a request the model answers with words alone cancels it too',
      () async {
        await preview();
        rt.submitText('今天天气怎么样');
        rt.modelTurnComplete();
        expect(rt.consent.active, isEmpty);
        expect(rt.consent.cancelledCards, hasLength(1));
      },
    );

    test('an additive request keeps it', () async {
      final r = await preview();
      rt.submitText('再看看所有频道');
      final shown = await call('show_list', {
        'kind': 'channels',
        'additive': true,
      });
      expect(shown['ok'], isTrue, reason: '$shown');
      expect(rt.consent.active, hasLength(1));
      expect(rt.consent.cancelledCards, isEmpty);
      expect(rt.turns.first.status, AgentTurnStatus.merged);
      expect(rt.current!.pendingConfirmations, {r['confirmToken']});
      // And it can still be confirmed, by the person.
      rt.consent.cardTapped(rt.consent.active.single.cardId, yes: true);
      expect(
        (await call('confirm', {'token': r['confirmToken']}))['status'],
        'done',
      );
    });

    test('a call that names the old turn keeps it', () async {
      await preview();
      final old = rt.current!.id;
      rt.submitText('嗯，再看看所有频道');
      await call('show_list', {'kind': 'channels', 'turn': old});
      expect(rt.consent.active, hasLength(1));
    });

    test('confirming its token is going on from it', () async {
      final r = await preview();
      rt.submitText('好');
      rt.consent.userSaid('好', fresh: false);
      final done = await call('confirm', {'token': r['confirmToken']});
      expect(done['status'], 'done', reason: '$done');
      expect(rt.turns.first.status, AgentTurnStatus.merged);
      expect(rt.consent.cancelledCards, isEmpty);
    });

    test(
      'a yes the person already gave is not cancelled by a word after it',
      () async {
        final r = await preview();
        rt.consent.cardTapped(rt.consent.active.single.cardId, yes: true);
        rt.submitText('看所有频道');
        rt.modelTurnComplete();
        expect(rt.consent.cancelledCards, isEmpty);
        expect(
          (await call('confirm', {'token': r['confirmToken']}))['status'],
          'done',
        );
      },
    );

    test(
      'a preview that comes back for a request that was dropped is not shown',
      () async {
        final slow = Completer<Object?>();
        w.routes['/tasks/channel/ch-general/number/9'] = (_) => slow.future;
        rt.submitText('把 #9 改成完成');
        final old = call('set_task_status', {'task': '9', 'status': 'done'});
        await pumpEventQueue();
        rt.submitText('算了，看所有频道');
        await call('show_list', {'kind': 'channels'});
        slow.complete({
          'task': {
            ...taskRow('t3', 9, 'in_progress', title: '丙'),
            'revision': 4,
          },
        });
        expect((await old)['cancelled'], isTrue);
        await pumpEventQueue();
        expect(rt.consent.active, isEmpty);
      },
    );
  });

  group('停 / 算了 / 等一下', () {
    test('cancel everything with no round trip to the model', () async {
      final slow = Completer<Object?>();
      w.routes['/messages/search'] = (_) => slow.future;
      rt.submitText('跟大家说你好');
      final r = await call('send_message', {
        'channel': 'general',
        'text': '你好',
      });
      final inflight = call('search_messages', {'q': '上线'});
      await pumpEventQueue();
      await call('begin_surface', {'surface_id': 'agents', 'title': 'Agent 们'});

      expect(rt.submitText('算了'), isNull, reason: 'nothing is sent on');
      expect(link.told, isEmpty);
      expect(link.stopped, 1);
      expect(rt.phase, AgentPhase.idle);
      expect((await inflight)['cancelled'], isTrue);
      expect(rt.surfaceStopped('agents'), isTrue);
      expect(rt.consent.active, isEmpty);
      expect(rt.consent.cancelledCards, hasLength(1));
      expect(rt.notices, ['已停止']);
      expect(
        rt.consent.take(r['confirmToken']! as String),
        AgentConsentVerdict.declined,
      );
      expect(
        (await call('confirm', {'token': r['confirmToken']}))['cancelled'],
        isTrue,
      );
      // Whatever the model still tries afterwards is refused.
      final more = await call('show_list', {'kind': 'channels'});
      expect(more['cancelled'], isTrue);
      expect(screen.begun.map((d) => d.id), ['agents']);
      slow.complete({'results': []});
      // The next thing the person says starts normally.
      rt.submitText('看所有频道');
      expect((await call('show_list', {'kind': 'channels'}))['ok'], isTrue);
      expect(rt.illegalTransitions, isEmpty);
    });

    test(
      'also by voice, from the transcript, and for each stop word',
      () async {
        for (final word in [
          '停',
          '等一下',
          '算了算了',
          '好，算了吧',
          'stop',
          'never mind',
        ]) {
          rt.beginListening();
          rt.userTranscript(word, fresh: true);
          expect(rt.current!.stopRequest, isTrue, reason: word);
          expect(rt.phase, AgentPhase.idle, reason: word);
        }
        expect(link.stopped, 6);
        expect(link.told, isEmpty);
      },
    );

    test('the model is muted after a stop, until the person speaks again', () {
      rt.submitText('停');
      expect(rt.muted, isTrue);
      rt.submitText('看所有频道');
      expect(rt.muted, isFalse);
    });

    test('a call long after they began to speak is not stale', () async {
      rt.beginListening(bargeIn: true);
      clock = clock.add(
        AgentRuntime.staleWindow + const Duration(milliseconds: 1),
      );
      // The words may be late (or never transcribed): the model answering
      // after this long is answering them.
      expect((await call('show_list', {'kind': 'channels'}))['ok'], isTrue);
      expect(rt.illegalTransitions, isEmpty);
    });

    test('a stop that goes on into a request is the request', () async {
      rt.beginListening();
      rt.userTranscript('等一下', fresh: true);
      expect(rt.current!.stopRequest, isTrue);
      rt.userTranscript('，看所有频道', fresh: false);
      expect(rt.current!.stopRequest, isFalse);
      expect(rt.phase, AgentPhase.listening);
      rt.userDone();
      expect((await call('show_list', {'kind': 'channels'}))['ok'], isTrue);
    });

    test('words that only contain a stop word are requests', () {
      for (final text in ['等一下，把 #9 改成完成', '不要', '好的', '看所有任务', '别急着合并这个 PR']) {
        expect(rt.submitText(text), isNotNull, reason: text);
      }
      expect(link.stopped, 0);
    });

    test('the stop button is the same thing', () async {
      rt.submitText('搜一下上线');
      rt.cancelAll();
      expect(rt.phase, AgentPhase.idle);
      expect(link.stopped, 1);
    });
  });

  group('what the model is told', () {
    test('the turn start says what the last turn was and what waits', () async {
      expect(rt.submitText('看所有频道')!.id, 't1');
      await call('show_list', {'kind': 'channels'});
      rt.modelTurnComplete();
      rt.submitText('跟大家说你好');
      final line = rt.contextLine();
      expect(line, contains('这是 t2'));
      expect(line, contains('上一轮 t1「看所有频道」：已完成（展示了 3 项：channels）'));
      expect(line, isNot(contains('additive')));

      final r = await call('send_message', {
        'channel': 'general',
        'text': '你好',
      });
      expect(r['ctx'], contains('上一轮 t1'));
      rt.modelTurnComplete();
      rt.submitText('再看看所有频道');
      final next = rt.contextLine();
      expect(next, contains('上一轮 t2「跟大家说你好」'));
      expect(next, contains('待用户确认：发到#general'));
      expect(next, contains('token ${r['confirmToken']}'));
      expect(next, contains('additive:true'));
      expect(next.length, lessThan(400), reason: 'a compact line');
    });

    test('the first call of a turn carries it, once', () async {
      rt.submitText('看所有频道');
      await call('show_list', {'kind': 'channels'});
      rt.modelTurnComplete();
      rt.submitText('看所有任务');
      final first = await call('show_list', {'kind': 'tasks'});
      expect(first['ctx'], contains('上一轮 t1'));
      expect(
        (await call('show_list', {'kind': 'dms'})).containsKey('ctx'),
        isFalse,
      );
    });

    test('after the session dropped the old turns (context compression) the '
        'next turn still says what was done and what waits', () async {
      rt.submitText('看所有频道');
      await call('show_list', {'kind': 'channels'});
      rt.modelTurnComplete();
      rt.submitText('看所有任务');
      await call('show_list', {'kind': 'tasks'});
      rt.modelTurnComplete();
      rt.submitText('跟大家说你好');
      final r = await call('send_message', {
        'channel': 'general',
        'text': '你好',
      });
      rt.modelTurnComplete();
      // The model's window was compressed: it has none of the turns above.
      // Only the line the app gives it at the start of a turn is left.
      rt.submitText('刚才做了什么');
      final line = rt.contextLine();
      expect(line, contains('t3「跟大家说你好」'));
      expect(line, contains('等用户确认：发到#general'));
      expect(line, contains('待用户确认：发到#general'));
      expect(line, contains('token ${r['confirmToken']}'));
      expect(line, contains('更早：'));
      expect(line, contains('t1「看所有频道」展示了 3 项：channels'));
      expect(line, contains('t2「看所有任务」'));
      expect(line.length, lessThan(600), reason: 'still a compact line');
    });

    test('a stopped turn is said to be stopped', () async {
      rt.submitText('搜一下上线');
      rt.submitText('算了');
      rt.submitText('看所有频道');
      expect(rt.contextLine(), contains('用户叫停了'));
    });
  });

  group('undo is the person\'s decision', () {
    test('the model\'s undo runs only after they said so', () async {
      rt.submitText('给这条点个赞');
      w.routes['/messages/context/m-1'] = (_) => {
        'messages': [
          {
            'id': 'm-1',
            'channelId': 'ch-general',
            'content': '周五上线可以吗？',
            'senderName': 'Cody',
            'senderType': 'agent',
            'createdAt': hoursAgo(1),
            'seq': '10',
          },
        ],
      };
      final r = await call('react', {'message': 'm-1', 'emoji': '🎉'});
      expect(r['status'], 'needs_confirmation', reason: '$r');
      rt.consent.cardTapped(rt.consent.active.single.cardId, yes: true);
      expect(
        (await call('confirm', {'token': r['confirmToken']}))['status'],
        'done',
      );
      rt.modelTurnComplete();

      rt.submitText('嗯');
      expect((await call('undo'))['error'], 'needs_user_consent');
      rt.submitText('撤销刚才那个');
      expect((await call('undo'))['status'], 'undone');
    });
  });

  test('dispose cancels what is open', () {
    final turn = rt.submitText('搜一下上线')!;
    final other = AgentRuntime(
      workspace: w,
      data: AgentModeData(w, now: () => worldNow),
      surfaces: screen.host,
      references: () => AgentReferenceTable.empty,
    );
    final t = other.submitText('x')!;
    other.dispose();
    expect(t.cancellation.reason, AgentCancelReason.closed);
    expect(turn.cancellation.isCancelled, isFalse);
    debugPrint('');
  });
}
