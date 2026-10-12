import 'page_layout.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import 'agent_metadata_projection.dart' show nonEmptyOr;
import 'management_support.dart';

/// Web components/agentMigration/state.ts migrationPhase: null for a state
/// this client does not know.
String? migrationPhase(String? state) => switch (state) {
  'provisioning' ||
  'prep' ||
  'ready' ||
  'in_transit' ||
  'arriving' ||
  'starting' ||
  'cancel_requested_pre_flip' ||
  'cancel_requested_post_flip' => 'active',
  'canceled_pre_flip' || 'canceled_post_flip' => 'canceled',
  'completed' => 'completed',
  'aborted' || 'failed' => 'failed',
  _ => null,
};

/// Web MigrationProgressPanel status word; an unknown state reads as its
/// words ("in_transit_v2" -> "In transit v2") instead of the raw enum.
String migrationStatusLabel(String? state) {
  if (state != null && state.startsWith('cancel_requested_')) {
    return 'Canceling';
  }
  switch (migrationPhase(state)) {
    case 'completed':
      return 'Complete';
    case 'canceled':
      return 'Canceled';
    case 'failed':
      return 'Needs attention';
    case 'active':
      return 'In progress';
  }
  final words = (state ?? '').replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  if (words.isEmpty) return 'Unknown';
  return words[0].toUpperCase() + words.substring(1);
}

/// Web agent.detail.migrationAborted* copy for an `aborted` migration.
String migrationAbortText(
  String? reason, {
  String source = 'the source computer',
  String target = 'the target computer',
}) => switch (reason) {
  'prep-deadline' =>
    'Preparing the workspace on $source stopped making progress before the deadline. $source may have gone offline, or packing stalled. Make sure $source is online, then try again.',
  'transfer-deadline' =>
    'The workspace transfer did not finish before the deadline. Make sure both Computers stay online and the target has enough free disk space, then try again.',
  'arrival-deadline' =>
    'The target Computer $target did not finish installing the workspace before the deadline. Make sure the target is running and has enough free disk space, then try again.',
  _ =>
    'The migration stopped before it completed. Review the technical reason, then try again.',
};

class AgentMigrationView extends StatefulWidget {
  const AgentMigrationView({
    super.key,
    required this.controller,
    required this.agentId,
  });
  final WorkspaceController controller;
  final String agentId;
  @override
  State<AgentMigrationView> createState() => _AgentMigrationState();
}

class _AgentMigrationState extends ManagementState<AgentMigrationView> {
  @override
  WorkspaceController get w => widget.controller;
  Map<String, dynamic> agent = {}, migration = {};
  List<Map<String, dynamic>> machines = [];
  String get base => '/agents/${widget.agentId}';
  bool get manager =>
      w.can('migrateAgents') ||
      agent['creatorType'] == 'user' && agent['creatorId'] == w.client.user?.id;
  static const cancellable = {
    'provisioning',
    'prep',
    'ready',
    'in_transit',
    'arriving',
    'starting',
  };
  static const terminal = {
    'completed',
    'aborted',
    'failed',
    'canceled_pre_flip',
    'canceled_post_flip',
  };
  StreamSubscription<RaftEvent>? _events;
  @override
  void initState() {
    super.initState();
    startManagement();
    _events = w.client.events.listen((e) {
      // Web realtime.ts: a migration update for this agent (or a reconnect)
      // refetches the latest migration.
      final p = e.payload;
      if (e.name == 'connected' ||
          e.name == 'agent:migration-updated' &&
              p is Map &&
              p['agentId'] == widget.agentId) {
        if (mounted) reload();
      }
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  @override
  String get snapshotKey => 'agent-migration:${widget.agentId}';
  @override
  Map<String, Object?> captureSnapshot() => {
    'agent': agent,
    'migration': migration,
    'machines': machines,
  };
  @override
  bool restoreSnapshot(Map<String, Object?> fields) {
    agent = fields['agent'] as Map<String, dynamic>;
    migration = fields['migration'] as Map<String, dynamic>;
    machines = fields['machines'] as List<Map<String, dynamic>>;
    return true;
  }

  @override
  void clearData() {
    agent = {};
    migration = {};
    machines = [];
  }

  @override
  Future<void> loadData(int request, int generation) async {
    if (w.server == null) return;
    final responses = await Future.wait([
      w.query(base),
      w.query('$base/migration'),
      w.query('/servers/${w.server!.id}/machines'),
    ]);
    if (!accepts(generation, request)) return;
    agent = managementMap(responses[0]);
    migration = managementMap(managementMap(responses[1])['migration']);
    machines = managementRows(managementMap(responses[2])['machines']);
  }

  Future<void> move() async {
    if (!manager || agent['runtime'] == 'external') return;
    final targets = machines
        .where(
          (m) =>
              m['id'] != agent['machineId'] &&
              m['status'] == 'online',
        )
        .toList();
    if (targets.isEmpty) {
      setState(
        () => error =
            'Connect another compatible computer before moving this agent.',
      );
      return;
    }
    await form(
      'Move agent',
      [
        RaftFormField(
          'target',
          'Target computer',
          required: true,
          choices: {for (final m in targets) '${m['id']}': '${m['name']}'},
        ),
      ],
      (values) async {
        await w.command(
          'POST',
          '$base/migrate',
          data: {'targetComputer': values['target']},
        );
      },
      description: 'The source agent will stop while its workspace moves. Check progress for completion.',
      submit: 'Move',
    );
    await reload();
  }

  Future<void> assign() async {
    if (!manager) return;
    await form(
      'Assign computer',
      [
        RaftFormField(
          'machine',
          'Computer',
          initial: '${agent['machineId'] ?? ''}',
          choices: {
            '': 'Unassigned',
            for (final m in machines) '${m['id']}': '${m['name']}',
          },
        ),
      ],
      (values) async {
        await w.command(
          'POST',
          '$base/assign-machine',
          data: {
            'machineId': values['machine']!.isEmpty ? null : values['machine'],
          },
        );
      },
      description: 'Change the computer assignment. This does not transfer the existing workspace files.',
    );
    await reload();
  }

  Future<void> cancel() async {
    final ref = migration['migrationRef'], revision = migration['revision'];
    if (!manager ||
        !cancellable.contains(migration['state']) ||
        ref is! String ||
        revision is! int ||
        revision < 1) {
      return;
    }
    await form(
      'Cancel migration?',
      [],
      (values) async {
        await w.command(
          'POST',
          '$base/migration/cancel',
          data: {'migrationRef': ref, 'expectedRevision': revision},
        );
      },
      description: 'Request a coordinated cancellation. The computers must acknowledge it before the migration is safely stopped.',
      submit: 'Cancel migration',
      destructive: true,
    );
    await reload();
  }

  String computerName(dynamic id) =>
      machines.where((m) => m['id'] == id).firstOrNull?['name']?.toString() ??
      id?.toString() ??
      'Unassigned';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: raftPageAppBar(
      context,
      title: raftText(context, 'Agent migration'),
      actions: [
        RaftTooltip(
          message: raftText(context, 'Refresh'),
          child: IconButton(
            onPressed: busy ? null : reload,
            icon: const Icon(Icons.refresh),
          ),
        ),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: raftScrollPadding(context, const EdgeInsets.all(24)),
            children: [
              if (error != null)
                Semantics(liveRegion: true, child: Text(error!)),
              if (agent.isNotEmpty) ...[
                Text(
                  nonEmptyOr(agent['displayName'], agent['name']),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  '${raftText(context, 'Computer')}: ${computerName(agent['machineId'])}',
                ),
              ],
              if (migration.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  '${raftText(context, 'Migration status')}: ${raftText(context, migrationStatusLabel(migration['state'] as String?))}',
                ),
                Text(
                  '${computerName(migration['sourceMachineId'])} → ${computerName(migration['targetMachineId'])}',
                ),
                if (migration['state'] == 'aborted')
                  Text(
                    raftText(
                      context,
                      migrationAbortText(
                        migration['abortReason'] as String?,
                        source: computerName(migration['sourceMachineId']),
                        target: computerName(migration['targetMachineId']),
                      ),
                    ),
                  ),
                if (migration['abortReason'] is String)
                  Text('${migration['abortReason']}'),
                if (migration['failureReason'] != null)
                  Text('${migration['failureReason']}'),
                if (migration['cancelErrorMessage'] != null)
                  Text('${migration['cancelErrorMessage']}'),
                if (migration['cancelNeedsAttention'] == true)
                  Text(
                    raftText(
                      context,
                      'Cancellation needs attention. Refresh after reconnecting both computers.',
                    ),
                  ),
                if (migration['migrationRef'] is String)
                  SelectableText('${migration['migrationRef']}'),
                if (manager &&
                    cancellable.contains(migration['state']) &&
                    migration['revision'] is int)
                  TextButton(
                    onPressed: busy ? null : () => run(cancel),
                    child: Text(raftText(context, 'Cancel migration')),
                  ),
              ],
              if (manager &&
                  error == null &&
                  (migration.isEmpty ||
                      terminal.contains(migration['state']))) ...[
                const SizedBox(height: 20),
                RaftButton(
                  label: raftText(context, 'Move agent'),
                  onPressed: busy ? null : () => run(move),
                ),
                TextButton(
                  onPressed: busy ? null : () => run(assign),
                  child: Text(raftText(context, 'Assign computer')),
                ),
              ],
            ],
          ),
  );
}
