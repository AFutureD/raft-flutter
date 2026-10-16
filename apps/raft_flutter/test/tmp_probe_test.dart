import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_ui/raft_ui.dart';

import 'agent_activity_home_test.dart' as home;

void main() {
  testWidgets('probe', (t) async {
    FlutterSecureStorage.setMockInitialValues({});
    AgentModeData.clearSession();
    final (client, w) = home.probeWorld();
    final data = home.probeData(w);
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: raftTheme(RaftFamily.brutal),
      home: AgentModePage(controller: w, data: data, model: const AgentScriptedModel()),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('agent-keyboard')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('agent-input')), '看看第一个');
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 4));
    await t.pumpAndSettle();
    void dump(String when) {
      final page = t.getRect(find.byKey(const ValueKey('hf-page')));
      final card = t.getRect(find.byKey(const ValueKey('attention-card-activity:thread:th1')));
      final done = t.getRect(find.byKey(const ValueKey('attention-done-activity:thread:th1')));
      debugPrint('$when page=$page card=$card done=$done');
    }
    dump('keyboard open');
    await t.tap(find.byKey(const ValueKey('agent-keyboard')));
    await t.pumpAndSettle();
    dump('keyboard closed');
    await client.dispose();
  });
}
