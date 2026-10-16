import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_action_board.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_consent.dart';

import '../activity_incremental_refresh_test.dart' show ActivityClient;
import 'agent_capability_world.dart';

/// The fictional workspace plus the pieces an operation needs: the consent
/// ledger (the person's say-so), the board the confirm cards live on, and the
/// capability tools with sensitive operations enabled. Shared by the tests of
/// the operations added after phase 2.
class ActionHarness {
  ActionHarness({AgentCapabilityEnv? env}) {
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.ledger.switchServer('s1');
    ledger = AgentConsentLedger(now: () => clock, random: Random(2));
    board = AgentActionBoard(now: () => clock);
    tools = rebuild(env: env);
  }

  late final ActivityClient client;
  late final CapabilityWorld w;
  late final AgentConsentLedger ledger;
  late final AgentActionBoard board;
  late AgentCapabilityTools tools;
  var clock = worldNow;

  /// Capability tools on this world (with sensitive operations enabled).
  AgentCapabilityTools rebuild({AgentCapabilityEnv? env}) =>
      AgentCapabilityTools(
        workspace: w,
        env:
            env ??
            AgentCapabilityEnv(data: AgentModeData(w, now: () => worldNow)),
        actionRisks: const {
          AgentCapabilityRisk.change,
          AgentCapabilityRisk.sensitive,
        },
        userConsent: ledger,
        board: board,
        now: () => clock,
        random: Random(1),
      );

  Future<void> dispose() async {
    w.dispose();
    await client.dispose();
  }

  /// `act` on a capability: the preview (or the reason it cannot be made).
  Future<Map<String, Object?>> act(
    String capability, [
    Map<String, Object?> args = const {},
  ]) async => (await tools.run('act', {
    'capability': capability,
    'args': args,
  }))!;

  /// The person presses 确认 on the latest card, then the model confirms.
  Future<Map<String, Object?>> approve(Map<String, Object?> previewed) async {
    expect(
      previewed['status'],
      anyOf('needs_confirmation', 'needs_second_confirmation'),
      reason: '$previewed',
    );
    expect(ledger.cardTapped(ledger.active.last.cardId, yes: true), isTrue);
    return (await tools.run('confirm', {'token': previewed['confirmToken']}))!;
  }

  /// A sensitive operation: both presses, then done.
  Future<Map<String, Object?>> approveTwice(
    Map<String, Object?> previewed,
  ) async {
    final second = await approve(previewed);
    expect(second['status'], 'needs_second_confirmation', reason: '$second');
    return approve(second);
  }

  /// `act`, press 确认 once, confirm.
  Future<Map<String, Object?>> run(
    String capability, [
    Map<String, Object?> args = const {},
  ]) async => approve(await act(capability, args));

  /// The person says 撤销, then the model calls the undo tool.
  Future<Map<String, Object?>> undoSaid() async {
    ledger.userSaid('撤销');
    return (await tools.run('undo', {}))!;
  }

  List<String> changes(Map<String, Object?> r) =>
      ((r['preview'] as Map)['changes'] as List).cast<String>();

  /// Whether a confirm-card line has the shape `字段: 原值 → 新值`.
  static bool lineOk(String line) =>
      RegExp(r'^[^:：]+[:：].* → .*$').hasMatch(line);

  String summary(Map<String, Object?> r) =>
      '${(r['preview'] as Map)['summary']}';
}
