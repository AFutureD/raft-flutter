import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_memory.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Fictional agents.
class _Server extends WorkspaceController {
  _Server(super.client);

  /// What `/agents` answers; null makes the read fail.
  List<Map<String, dynamic>>? agents = [];

  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) async {
    if (path == '/agents') {
      if (agents == null) throw StateError('offline');
      return agents;
    }
    return <String, dynamic>{};
  }
}

void main() {
  late ActivityClient client;
  late _Server w;
  final settings = AgentVoiceSettings.instance;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await DevicePreferences.load();
    settings.brain = null;
    client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
    client.selectServer('s1');
    w = _Server(client)..server = RaftRecord({'id': 's1', 'role': 'owner'});
    w.agents = [
      {'id': 'a1', 'displayName': 'Cindy'},
      {
        'id': 'a-old',
        'displayName': 'Old',
        'deletedAt': '2026-10-01T00:00:00Z',
      },
    ];
  });
  tearDown(() async {
    settings.brain = null;
    w.dispose();
    await client.dispose();
  });

  test('a stored agent that is archived is cleared to 独立记忆', () async {
    settings.brain = (id: 'a-old', name: 'Old');
    expect(await AgentBrain(w).liveBrain(settings), isNull);
    expect(settings.brain, isNull);
  });

  test('an agent that is gone from the list is cleared too', () async {
    settings.brain = (id: 'a-missing', name: 'Gone');
    expect(await AgentBrain(w).liveBrain(settings), isNull);
    expect(settings.brain, isNull);
  });

  test('an active agent is kept', () async {
    settings.brain = (id: 'a1', name: 'Cindy');
    final live = await AgentBrain(w).liveBrain(settings);
    expect(live?.id, 'a1');
    expect(settings.brain?.id, 'a1');
  });

  test('when the list cannot be read the choice is kept', () async {
    w.agents = null;
    settings.brain = (id: 'a-old', name: 'Old');
    expect((await AgentBrain(w).liveBrain(settings))?.id, 'a-old');
    expect(settings.brain?.id, 'a-old');
  });

  test('no stored agent: nothing to check', () async {
    expect(await AgentBrain(w).liveBrain(settings), isNull);
  });

  testWidgets('the picker drops an archived choice and shows 独立记忆', (t) async {
    settings.brain = (id: 'a-old', name: 'Old');
    t.view.physicalSize = const Size(420, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentVoiceSettingsPage(agents: AgentBrain(w).agents),
      ),
    );
    await t.pumpAndSettle();
    expect(settings.brain, isNull);
    expect(find.text('Old'), findsNothing);
    expect(find.text('Cindy'), findsOneWidget);
    final none = t.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('agent-brain-none')),
        matching: find.byType(Icon),
      ),
    );
    expect(none.icon, Icons.radio_button_checked);
  });

  testWidgets('opening agent mode clears the stale brain and says so', (
    t,
  ) async {
    settings.brain = (id: 'a-old', name: 'Old');
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentModePage(controller: w),
      ),
    );
    await t.pumpAndSettle();
    expect(settings.brain, isNull);
    expect(find.textContaining('已经归档，改用独立记忆'), findsWidgets);
    // Nothing was read from the archived agent.
    expect(find.textContaining('MEMORY.md'), findsNothing);
  });
}
