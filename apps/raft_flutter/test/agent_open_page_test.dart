import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_consent.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_pages.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/open_page_capabilities.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_reference_table.dart';
import 'package:raft_flutter/features/agent_mode/runtime/agent_runtime.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// What must not be done by voice: each is a never-by-voice capability that
/// names a page the app really has, and `act` takes the person there.
void main() {
  late CapabilityWorld w;
  late ActivityClient client;
  late AgentConsentLedger ledger;
  late AgentCapabilityTools tools;
  final opened = <RaftLocation>[];

  setUp(() {
    opened.clear();
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    ledger = AgentConsentLedger(random: Random(2));
    tools = AgentCapabilityTools(
      workspace: w,
      env: AgentCapabilityEnv(data: AgentModeData(w, now: () => worldNow)),
      actionRisks: AgentCapabilityRisk.values.toSet(),
      userConsent: ledger,
      onPageOpened: opened.add,
      random: Random(1),
    );
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  final pages = openPageCapabilities;

  test('the gap list is registered, all never by voice with a route', () {
    expect(pages.length, greaterThanOrEqualTo(28));
    for (final c in pages) {
      expect(c.kind, AgentCapabilityKind.action, reason: c.id);
      expect(c.risk, AgentCapabilityRisk.neverByVoice, reason: c.id);
      expect(c.openRoute, startsWith('/'), reason: c.id);
      expect(c.prepareUndo, isNull, reason: c.id);
      expect(
        agentStandardCapabilities[c.id],
        same(c),
        reason: '${c.id} is in the registry',
      );
    }
    expect(
      pages.map((c) => c.id),
      containsAll([
        'channels.archive',
        'channels.delete',
        'channels.leave',
        'server.leave',
        'members.change_role',
        'server.invite',
        'billing.manage',
        'computers.rotate_key',
        'computers.upgrade',
        'computers.cleanup',
        'providers.manage',
        'apps.marketplace',
        'mcp.manage',
        'slack.bridge',
        'settings.appearance',
        'settings.language',
        'settings.notifications',
        'server.profile',
        'agents.create',
        'agents.delete',
        'agents.migrate',
        'agents.settings',
      ]),
    );
  });

  test('every static route is a page of the app', () {
    for (final c in pages) {
      final location = resolveAgentPageRoute('acme', c.openRoute!);
      expect(location, isNotNull, reason: '${c.id} ${c.openRoute}');
      expect(location!.route, isNot(RaftRoute.unknown), reason: c.id);
      expect(location.serverSlug, 'acme');
    }
  });

  test('every route built from arguments is a page of the app', () async {
    w.routes['/servers/s1/members'] = (_) => [
      {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
    ];
    final args = <String, Map<String, Object?>>{
      'channel': {'channel': 'general'},
      'agent': {'agent': 'cody'},
      'computer': {'computer': 'Studio'},
      'member': {'member': 'Ada'},
    };
    var withRoute = 0;
    for (final c in pages.where((c) => c.openRouteFor != null)) {
      final key = (c.paramsSchema['properties'] as Map).keys.single as String;
      final route = await c.openRouteFor!(w, args[key]!);
      final location = resolveAgentPageRoute('acme', route);
      expect(location, isNotNull, reason: '${c.id} $route');
      expect(location!.route, isNot(RaftRoute.unknown), reason: route);
      withRoute++;
    }
    expect(withRoute, greaterThanOrEqualTo(10));
    // The pages that matter: a channel's settings, a computer, an agent.
    expect(
      await pages
          .firstWhere((c) => c.id == 'channels.delete')
          .openRouteFor!(w, {'channel': 'general'}),
      '/channel/ch-general?channelPage=settings:ch-general',
    );
    expect(
      await pages
          .firstWhere((c) => c.id == 'computers.rotate_key')
          .openRouteFor!(w, {'computer': 'Studio'}),
      '/computer/m1',
    );
  });

  test('a route the app has no page for is refused', () {
    expect(resolveAgentPageRoute('acme', '/settings/nope'), isNull);
    expect(resolveAgentPageRoute('acme', '/nowhere/x'), isNull);
    expect(resolveAgentPageRoute('acme', 'settings'), isNull);
    expect(resolveAgentPageRoute('', '/members'), isNull);
    final billing = resolveAgentPageRoute('acme', '/settings/billing')!;
    expect(billing.route, RaftRoute.settings);
    expect(billing.settingsPath, ['billing']);
    // Applications and MCP use the Web slugs.
    expect(
      resolveAgentPageRoute('acme', '/settings/mcp-servers')!.settingsPath,
      ['mcp-servers'],
    );
  });

  group('act on one', () {
    test('opens the page, previews nothing, runs nothing', () async {
      final r = await tools.run('act', {'capability': 'billing.manage'});
      expect(r!['status'], 'open_page');
      expect(r['opened'], isTrue);
      expect(r['openPage'], '/settings/billing');
      expect(r.containsKey('confirmToken'), isFalse);
      expect(ledger.active, isEmpty);
      expect(w.commands, isEmpty);
      // The workspace is now on that page.
      expect(w.location.route, RaftRoute.settings);
      expect(w.location.settingsPath, ['billing']);
      expect(opened.single.settingsPath, ['billing']);
      // And the agent is told to say so.
      expect(r['message'], contains('已经把页面打开了'));
    });

    test('goes to the thing the person named', () async {
      final r = await tools.run('act', {
        'capability': 'channels.delete',
        'args': {'channel': 'general'},
      });
      expect(r!['opened'], isTrue);
      expect(r['openPage'], '/channel/ch-general?channelPage=settings:ch-general');
      expect(w.location.route, RaftRoute.channel);
      expect(w.location.entityId, 'ch-general');
      expect(w.location.channelPage?.kind, RaftChannelPage.settings);
      expect(w.location.channelPage?.channelId, 'ch-general');
      expect(w.commands, isEmpty, reason: 'nothing is deleted');

      final c = await tools.run('act', {
        'capability': 'computers.rotate_key',
        'args': '{"computer":"Studio"}',
      });
      expect(c!['openPage'], '/computer/m1');
      expect(w.location.route, RaftRoute.computer);
      expect(w.location.entityId, 'm1');
    });

    test('a name that fits nothing still opens the list, and says so', () async {
      final r = await tools.run('act', {
        'capability': 'channels.leave',
        'args': {'channel': 'nonexistent'},
      });
      expect(r!['opened'], isTrue);
      expect(r['openPage'], '/');
      expect(r['note'], contains('没有叫“nonexistent”'));
      final bad = await tools.run('act', {
        'capability': 'computers.delete',
        'args': {'computer': 'Nowhere'},
      });
      expect(bad!['openPage'], '/computers');
      expect(bad['note'], isNotNull);
    });

    test('a page the role cannot see is not opened, and says why', () async {
      w.server = RaftRecord({'id': 's1', 'role': 'member'});
      final before = w.location.toString();
      final r = await tools.run('act', {'capability': 'billing.manage'});
      expect(r!['status'], 'open_page');
      expect(r['opened'], isFalse);
      expect(r['error'], contains('看不到'));
      expect(w.location.toString(), before);
      expect(opened, isEmpty);
    });

    test('it is in the audit log, and cannot be queried or confirmed', () async {
      await tools.run('act', {'capability': 'settings.appearance'});
      final entry = tools.audit.entries.single;
      expect(entry.capability, 'settings.appearance');
      expect(entry.ok, isTrue);
      expect(entry.result, '已打开 /settings/appearance');
      final q = await tools.run('query', {'capability': 'settings.appearance'});
      expect(q!['error'], contains('是操作不是查询'));
    });

    test('find offers the page for what people ask', () async {
      for (final (said, id) in [
        ('把这个频道删掉', 'channels.delete'),
        ('帮我邀请一个新同事', 'server.invite'),
        ('这个月花了多少钱', 'billing.manage'),
        ('切到深色模式', 'settings.appearance'),
        ('把 Cody 迁到另一台电脑', 'agents.migrate'),
        ('轮换一下电脑的 API Key', 'computers.rotate_key'),
        ('装一个应用', 'apps.marketplace'),
        ('连接 Slack', 'slack.bridge'),
      ]) {
        final r = await tools.run('find', {'intent': said});
        final ids = [for (final m in r!['matches'] as List) (m as Map)['id']];
        expect(ids.take(3), contains(id), reason: said);
      }
    });
  });

  group('in the runtime', () {
    late AgentRuntime rt;
    var left = 0;
    setUp(() {
      left = 0;
      w.ledger.switchServer('s1');
      rt = AgentRuntime(
        workspace: w,
        data: AgentModeData(w, now: () => worldNow),
        surfaces: AgentSurfaceHost(
          begin: (_) => const {},
          changed: (draft, {added}) => const {},
          isOpen: (_) => false,
        ),
        references: () => AgentReferenceTable.empty,
        modelLink: _Link(),
        onLeave: () => left++,
        leaveDelay: Duration.zero,
      );
    });
    tearDown(() => rt.dispose());

    test('agent mode steps aside once the model has said it', () async {
      final r = await rt.runTool('act', {'capability': 'server.invite'});
      expect(r['opened'], isTrue);
      expect(w.location.route, RaftRoute.members);
      expect(left, 0, reason: 'not before the model has spoken');
      rt.modelTurnComplete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(left, 1);
      // Only once.
      rt.modelTurnComplete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(left, 1);
    });

    test('a refused page keeps agent mode open', () async {
      w.server = RaftRecord({'id': 's1', 'role': 'member'});
      final r = await rt.runTool('act', {'capability': 'billing.manage'});
      expect(r['opened'], isFalse);
      rt.modelTurnComplete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(left, 0);
    });

    test('sensitive operations are allowed here, never-by-voice never run', () {
      expect(rt.capabilities.actionRisks, contains(AgentCapabilityRisk.sensitive));
      expect(
        rt.capabilities.actionRisks,
        isNot(contains(AgentCapabilityRisk.neverByVoice)),
      );
    });
  });
}

class _Link implements AgentModelLink {
  final told = <String>[];
  @override
  Future<bool> tell(String note) async {
    told.add(note);
    return true;
  }

  @override
  void stopSpeaking() {}
}
