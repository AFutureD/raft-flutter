import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenarios.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/orb_eval_scripted.dart';

/// The scenarios' checks against a model that answers as it should (scripted):
/// each scenario's fixture data, its start page and its checks must agree on
/// what a good answer is. A scenario that cannot pass here is mis-specified.

typedef Say = Future<void> Function(ScriptedSession s);

Future<void> drive(ScriptedSession s) => s.turn([
  ('set_driving_mode', {'on': true}),
  ('get_briefing', {'show': true}),
], '好，驾驶模式。第一件，Cody 在问第 10 步能不能合入。');

/// The good answers: by scenario, then by the line said.
final Map<String, Map<String, Say>> golden = {
  'A1': {
    '去 raft-flutter 看看谁找我': (s) => s.turn([
      ('navigate', {'channel_id': evalId('raft-flutter')}),
    ], 'Cody 在问第 10 步能不能合入，已经等了 20 分钟。其余两条是进度。'),
  },
  'A2': {
    '去 raft-flutter 看看谁找我': (s) => s.turn([
      ('navigate', {'channel_id': evalId('raft-flutter')}),
    ], 'Cody 找你，在问第 10 步能不能合入。'),
    '他问的是什么？': (s) =>
        s.turn(const [('read_conversation', {})], 'Cody 问：第 10 步可以合入吗？'),
  },
  'A4': {
    '这里有什么新的吗': (s) =>
        s.turn(const [('describe_page', {})], '没有要你处理的。Cody 接着做第 10 步。'),
  },
  'A5': {
    '这个讨论最后定了什么': (s) => s.turn([
      ('read_conversation', {'conversation': evalId('thread:cache')}),
    ], 'Alice 定了：改用方案 B。'),
  },
  'A6': {
    '去 design 频道': (s) => s.turn([
      ('navigate', {'channel_id': evalId('design')}),
    ], '已经打开 design。你还没加入这个频道。'),
  },
  'A7': {
    '去 Roughslutter': (s) => s.turn([
      ('navigate', {'channel_id': evalId('raft-flutter')}),
    ], '是 raft-flutter 吗？我带你过去了。'),
  },
  'B1': {
    '打开动态，什么需要我处理': (s) => s.turn(const [
      ('navigate', {'page': 'activity', 'show': true}),
    ], 'Alice 私信问你周五能不能来评审。Cody 在问第 10 步能不能合入。'),
  },
  'B2': {
    '读一下动态': (s) => s.turn(const [
      ('describe_page', {}),
    ], 'Alice 私信问周五能来评审吗。Cody 在 raft-flutter 问第 10 步可以合入吗。'),
  },
  'B3': {
    '读 Alice 那条原文': (s) => s.turn([
      ('read_conversation', {'conversation': evalId('dm:alice')}),
    ], 'Alice 说：周五能来评审吗？'),
  },
  'B4': {
    '最新那条说了什么': (s) =>
        s.turn(const [('describe_page', {})], '最新的是 Alice 的私信，问周五能不能来评审。'),
  },
  'B5': {
    '有什么要我处理的': (s) =>
        s.turn(const [('get_briefing', {})], '没有要你处理的。构建通过了，第 9 步测试也过了。'),
  },
  'B6': {
    '有什么新的': (s) => s.turn(const [('describe_page', {})], '动态还在加载，稍等再看。'),
  },
  'B8': {
    '打开动态里的第一条消息': (s) => s.turn(const [
      ('open_item', {'n': 1}),
    ], '打开了，是 Alice 的私信。'),
  },
  'B7': {
    '什么要紧': (s) =>
        s.turn(const [('get_briefing', {})], 'Grok 回复了测试的事。另外 1 个任务在等你验收，不急。'),
  },
  'C1': {
    '看看 Cody 私信': (s) => s.turn([
      ('navigate', {'dm_id': evalId('dm:cody')}),
    ], 'Cody 说第 10 步提交了，问你要他补什么。要不要回他？'),
  },
  'C3': {
    '打开 task 136': (s) => s.turn(const [
      ('navigate', {'task_number': 136}),
    ], '任务 136 在验收，是 Cody 做的，等你验收。'),
  },
  'C5': {
    '大家意见是什么': (s) => s.turn(const [
      ('describe_page', {}),
    ], 'Cody 支持方案 A，Grok 支持方案 B，Alice 在问你怎么看。'),
  },
  'D1': {'开始驾驶模式': drive},
  'D2': {
    '开始驾驶模式': drive,
    '下一件': (s) async {
      final r = await s.onToolCall('driving_next', const {});
      final who = (r['item'] as Map)['who'];
      s.say('第二件，$who 找你。');
    },
  },
  'D4': {'开始驾驶模式': drive, '批准吧': (s) async => s.say('这个等你停车后再批准。要我稍后提醒你吗？')},
  'D9': {
    '开始驾驶模式': drive,
    '停车了': (s) => s.turn(const [
      ('set_driving_mode', {'on': false}),
    ], '好，退出驾驶模式。'),
  },
  'E2': {
    '开始驾驶模式': drive,
    '好，看看那几个放了好几天的任务': (s) async => s.say('第一个，整理发布说明，八戒在做，卡在等设计稿。'),
  },
  'E3': {
    '开始驾驶模式': drive,
    '看看这些任务现在什么状态': (s) async => s.say('一共 3 个：两个在做，一个等你验收。'),
  },
};

void main() {
  late Directory reports;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentOrbPreference.instance.resetForTest();
    reports = Directory.systemTemp.createTempSync('orb-eval-golden');
  });
  tearDown(() => reports.deleteSync(recursive: true));

  for (final entry in golden.entries) {
    final id = entry.key;
    testWidgets('$id passes with a good answer', (t) async {
      final scenario = orbEvalScenarios.firstWhere((s) => s.id == id);
      final script = entry.value;
      expect(script.keys.toSet(), {
        ...scenario.setup,
        ...scenario.say,
      }, reason: 'one answer for every line the scenario says');
      final sessions = Sessions();
      await mountEvalPage(
        t,
        reports: reports,
        scenarios: [scenario],
        runs: 1,
        sessionFactory: sessions.factory((s, text) => script[text]!(s)),
      );
      await finishEvalRun(t);
      final report = readEvalReport(reports);
      final result = (report['scenarios'] as List).single as Map;
      expect(
        result['failedChecks'],
        isEmpty,
        reason: '$id: ${result['results']}',
      );
      expect(result['outcome'], 'passed');
      await t.pumpWidget(const SizedBox());
    });
  }

  test(
    'every runnable scenario of the first rounds has a good answer here',
    () {
      final missing = [
        for (final s in orbEvalScenarios)
          if (s.status == OrbEvalStatus.run && !golden.containsKey(s.id)) s.id,
      ];
      expect(missing, isEmpty);
    },
  );
}
