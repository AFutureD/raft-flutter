import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';

import 'support/agent_capability_world.dart';

void main() {
  // A held task without a number: the briefing heard "null 超过 11 小时没动"
  // and the voice model fell back to the task's id.
  test('an agent holding a task without a number names the task by its '
      'title, never "null"', () async {
    final world = capabilityWorld();
    final w = world.$2;
    w.ledger.switchServer('s1');
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_progress')
          {
            ...taskRow(
              't9',
              0,
              'in_progress',
              title: '逻辑漂移复核',
              claimedById: 'a-cody',
              claimedByName: 'Cody',
              updated: 11,
            ),
          }..remove('taskNumber'),
      ],
    };
    final agents = await AgentModeData(w, now: () => worldNow).agents();
    final cody = agents.firstWhere((a) => a.id == 'a-cody');
    expect(cody.activity, isNot(contains('null')));
    expect(cody.activity, contains('「逻辑漂移复核」'));
    w.dispose();
    await world.$1.dispose();
  });
}
