import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentPriority;
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_snooze.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_reference_table.dart';
import 'package:raft_flutter/features/agent_mode/runtime/agent_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/agent_action_harness.dart';
import 'support/agent_capability_world.dart';

/// "稍后": set aside until a time, kept on the device across visits, back on
/// time, and askable.
void main() {
  late ActionHarness h;
  late AgentSnoozeStore store;
  var now = DateTime(2026, 10, 17, 10);

  AgentAttentionItem item(
    String id, {
    int? number,
    String headline = 'Cody 提交了登录跳转修复，等你验收',
    String channel = 'general',
    AgentPriority priority = AgentPriority.decision,
  }) => AgentAttentionItem(
    id: id,
    priority: priority,
    headline: headline,
    ask: '验收',
    reason: '你派的任务',
    at: worldNow,
    taskId: number == null ? null : id,
    taskNumber: number,
    channelId: 'ch-$channel',
    channelName: channel,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DevicePreferences.adopt(await SharedPreferences.getInstance());
    AgentModeData.clearSession();
    now = DateTime(2026, 10, 17, 10);
    h = ActionHarness();
    store = AgentSnoozeStore(h.w, now: () => now, timers: false);
    h.tools = h.rebuild(env: AgentCapabilityEnv(
      data: AgentModeData(h.w, now: () => worldNow),
      snooze: store,
    ));
    AgentModeData.remember(
      h.w,
      AgentAttention(
        items: [
          item('t-98', number: 98),
          item(
            't-7',
            number: 7,
            headline: 'Grok 的导出报表任务卡住了',
            priority: AgentPriority.blocked,
          ),
          item(
            'mention:ch-design',
            headline: 'Ada 在 design 里点名了你',
            channel: 'design',
            priority: AgentPriority.mention,
          ),
        ],
      ),
    );
  });
  tearDown(() async {
    DevicePreferences.reset();
    AgentModeData.clearSession();
    await h.dispose();
  });

  group('the store', () {
    test('hides the item now and puts it back when the time comes', () {
      final hidden = AgentModeData.hidden(h.w);
      store.snooze(item('t-98', number: 98), now.add(const Duration(hours: 3)));
      expect(hidden, contains('t-98'));
      expect(store.isSnoozed('t-98'), isTrue);

      now = now.add(const Duration(hours: 2, minutes: 59));
      store.tick();
      expect(hidden, contains('t-98'));

      now = now.add(const Duration(minutes: 2));
      var told = 0;
      store.addListener(() => told++);
      store.tick();
      expect(hidden, isNot(contains('t-98')));
      expect(store.active, isEmpty);
      expect(told, 1);
      final back = store.takeResurfaced();
      expect(back.single.id, 't-98');
      expect(store.takeResurfaced(), isEmpty, reason: 'told once');
    });

    test('is kept on the device: a new visit still has it hidden', () {
      store.snooze(
        item('t-98', number: 98),
        DateTime(2026, 10, 18, 9),
      );
      final stored = DevicePreferences.current!.getKeys().where(
        (k) => k.startsWith('raft.agentModeSnoozed'),
      );
      expect(stored, hasLength(1));

      // The app was closed and opened again: nothing is in memory.
      AgentModeData.clearSession();
      final next = AgentSnoozeStore(h.w, now: () => now, timers: false);
      final entry = next.active.single;
      expect(entry.id, 't-98');
      expect(entry.taskNumber, 98);
      expect(entry.until, DateTime(2026, 10, 18, 9));
      expect(AgentModeData.hidden(h.w), contains('t-98'));
    });

    test('what came due while the app was closed is back, and told once', () {
      store.snooze(item('t-98', number: 98), DateTime(2026, 10, 17, 18));
      AgentModeData.clearSession();
      now = DateTime(2026, 10, 18, 8); // next morning
      final next = AgentSnoozeStore(h.w, now: () => now, timers: false);
      expect(next.active, isEmpty);
      expect(AgentModeData.hidden(h.w), isNot(contains('t-98')));
      expect(next.takeResurfaced().single.headline, contains('登录跳转'));
      expect(next.takeResurfaced(), isEmpty);
      // And the device forgot it.
      expect(
        DevicePreferences.current!.getKeys().where(
          (k) => k.startsWith('raft.agentModeSnoozed'),
        ),
        isEmpty,
      );
    });

    test('unsnooze puts back now, and snoozing again replaces the time', () {
      store.snooze(item('t-98', number: 98), DateTime(2026, 10, 18, 9));
      store.snooze(item('t-98', number: 98), DateTime(2026, 10, 19, 9));
      expect(store.active, hasLength(1));
      expect(store.active.single.until, DateTime(2026, 10, 19, 9));
      expect(store.unsnooze('t-98'), isTrue);
      expect(AgentModeData.hidden(h.w), isNot(contains('t-98')));
      expect(store.unsnooze('t-98'), isFalse);
    });

    test('times: later, tonight, tomorrow, next week', () {
      final wed = DateTime(2026, 10, 14, 10); // a Wednesday
      expect(AgentSnoozeStore.untilFor('later', wed), DateTime(2026, 10, 14, 13));
      expect(AgentSnoozeStore.untilFor('tonight', wed), DateTime(2026, 10, 14, 19));
      expect(
        AgentSnoozeStore.untilFor('tonight', DateTime(2026, 10, 14, 18)),
        DateTime(2026, 10, 15, 9),
      );
      expect(AgentSnoozeStore.untilFor('tomorrow', wed), DateTime(2026, 10, 15, 9));
      expect(AgentSnoozeStore.untilFor('next_week', wed), DateTime(2026, 10, 19, 9));
      expect(
        AgentSnoozeStore.untilFor('next_week', DateTime(2026, 10, 19, 9)),
        DateTime(2026, 10, 26, 9),
      );
    });
  });

  group('attention.snooze', () {
    test('previews exactly what will happen, then sets it aside', () async {
      final r = await h.act('attention.snooze', {
        'item': '#98',
        'when': 'tomorrow',
      });
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect(h.summary(r), contains('#98'));
      expect(h.summary(r), contains('明天 09:00'));
      expect(h.changes(r).single, '首页: 待处理 → 稍后（明天 09:00）');
      expect((r['preview'] as Map)['reversible'], isTrue);
      expect(store.active, isEmpty, reason: 'nothing before 确认');

      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect((done['result'] as Map)['entity'], 'task');
      expect((done['result'] as Map)['id'], 't-98');
      expect(store.active.single.until, DateTime(2026, 10, 18, 9));
      expect(AgentModeData.hidden(h.w), contains('t-98'));
      expect(h.tools.audit.entries.single.capability, 'attention.snooze');
    });

    test('the item can be named by id, task id, channel or words', () async {
      for (final ref in ['t-7', '7', 'Grok', 'mention:ch-design', 'ch-design']) {
        final r = await h.act('attention.snooze', {'item': ref});
        expect(r['status'], 'needs_confirmation', reason: '$ref $r');
      }
    });

    test('hours and until override when; the default is three hours', () async {
      var r = await h.act('attention.snooze', {'item': '98', 'hours': 5});
      expect(h.summary(r), contains('今天 15:00'));
      r = await h.act('attention.snooze', {
        'item': '98',
        'until': '2026-10-20T08:30:00',
      });
      expect(h.summary(r), contains('10-20 08:30'));
      r = await h.act('attention.snooze', {'item': '98'});
      expect(h.summary(r), contains('今天 13:00'));
    });

    test('bad calls stop at the preview', () async {
      for (final (args, message) in [
        ({'item': '98', 'until': '2026-10-17T09:00:00'}, '已经过了'),
        ({'item': '98', 'until': '2027-01-01T09:00:00'}, '30 天'),
        ({'item': '98', 'until': 'someday'}, '看不懂'),
        ({'item': '555'}, '没有“555”'),
        ({'item': '98', 'hours': 9999}, '不能大于'),
        ({'item': '98', 'when': 'never'}, '之一'),
        (<String, Object?>{}, '缺少参数 item'),
      ]) {
        final r = await h.act('attention.snooze', args);
        expect('${r['error']}', contains(message), reason: '$args');
        expect(r.containsKey('confirmToken'), isFalse);
      }
      expect(store.active, isEmpty);
    });

    test('ambiguous words give candidates', () async {
      AgentModeData.remember(
        h.w,
        AgentAttention(
          items: [
            item('a', number: 1, headline: '导出报表 A'),
            item('b', number: 2, headline: '导出报表 B'),
          ],
        ),
      );
      final r = await h.act('attention.snooze', {'item': '导出报表'});
      expect('${r['error']}', contains('多件事'));
      expect(r['candidates'], hasLength(2));
    });

    test('undo puts it back; undoing a re-snooze restores the old time', () async {
      var done = await h.run('attention.snooze', {'item': '98', 'when': 'tomorrow'});
      expect(done['status'], 'done');
      expect((done['undo'] as Map)['label'], '放回首页');
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone', reason: '$undone');
      expect(store.active, isEmpty);
      expect(AgentModeData.hidden(h.w), isNot(contains('t-98')));

      await h.run('attention.snooze', {'item': '98', 'when': 'tomorrow'});
      done = await h.run('attention.snooze', {'item': '98', 'when': 'next_week'});
      expect((done['undo'] as Map)['label'], '改回 明天 09:00');
      await h.undoSaid();
      expect(store.active.single.until, DateTime(2026, 10, 18, 9));
    });
  });

  group('attention.snoozed and attention.unsnooze', () {
    test('"我稍后的有哪些": soonest first, with when', () async {
      store.snooze(item('t-98', number: 98), DateTime(2026, 10, 18, 9));
      store.snooze(item('t-7', number: 7), DateTime(2026, 10, 17, 19));
      final r = await h.tools.run('query', {'capability': 'attention.snoozed'});
      final rows = ((r!['result'] as Map)['snoozed'] as List).cast<Map>();
      expect(rows.map((e) => e['number']), [7, 98]);
      expect(rows.first['until'], '今天 19:00');
      expect(rows.first['remindIn'], '9 小时后');
      expect(rows.last['until'], '明天 09:00');
    });

    test('nothing set aside says so', () async {
      final r = await h.tools.run('query', {'capability': 'attention.snoozed'});
      expect((r!['result'] as Map)['count'], 0);
      expect((r['result'] as Map)['message'], isNotNull);
    });

    test('find answers the questions people ask', () async {
      for (final (said, id) in [
        ('我稍后的有哪些', 'attention.snoozed'),
        ('这个明天再看', 'attention.snooze'),
        ('先放一放，晚点再说', 'attention.snooze'),
      ]) {
        final r = await h.tools.run('find', {'intent': said});
        final ids = [for (final m in r!['matches'] as List) (m as Map)['id']];
        expect(ids.take(2), contains(id), reason: said);
      }
    });

    test('unsnooze puts it back now, and undo sets it aside again', () async {
      store.snooze(item('t-98', number: 98), DateTime(2026, 10, 18, 9));
      final r = await h.act('attention.unsnooze', {'item': '98'});
      expect(h.changes(r).single, contains('稍后（明天 09:00） → 待处理'));
      final done = await h.approve(r);
      expect(done['status'], 'done');
      expect(store.active, isEmpty);
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone');
      expect(store.active.single.until, DateTime(2026, 10, 18, 9));
    });

    test('unsnooze of something not set aside is said', () async {
      final r = await h.act('attention.unsnooze', {'item': '98'});
      expect('${r['error']}', contains('稍后的事里没有'));
    });
  });

  test('the runtime tells the model when something comes back', () async {
    final told = <String>[];
    final rt = AgentRuntime(
      workspace: h.w,
      data: AgentModeData(h.w, now: () => worldNow),
      surfaces: AgentSurfaceHost(
        begin: (_) => const {},
        changed: (draft, {added}) => const {},
        isOpen: (_) => false,
      ),
      references: () => AgentReferenceTable.empty,
      modelLink: _Link(told),
    );
    addTearDown(rt.dispose);
    // The app's own store, on the real clock, with a timer while the runtime lives.
    final live = AgentSnoozeStore.of(h.w);
    live.snooze(
      item('t-98', number: 98),
      DateTime.now().add(const Duration(milliseconds: 150)),
    );
    expect(AgentModeData.hidden(h.w), contains('t-98'));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(AgentModeData.hidden(h.w), isNot(contains('t-98')));
    expect(told.single, contains('#98'));
    expect(told.single, contains('稍后'));
  });

  test('registry: local capabilities, change risk, previewed', () {
    for (final id in ['attention.snooze', 'attention.unsnooze']) {
      final c = h.tools.registry[id]!;
      expect(c.risk, AgentCapabilityRisk.change);
      expect(c.preview, isNotNull);
      expect(c.parity, isNull, reason: 'touches no server data');
    }
    expect(h.tools.registry['attention.snoozed']!.isQuery, isTrue);
  });
}

class _Link implements AgentModelLink {
  _Link(this.told);
  final List<String> told;
  @override
  Future<bool> tell(String note) async {
    told.add(note);
    return true;
  }

  @override
  void stopSpeaking() {}
}
