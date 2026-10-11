// Add members dialog: the Web AddMembersDialog
// (packages/web/src/components/channel/AddMembersDialog.tsx) opened from a
// `channel:add_member` action card. The agent's list is a suggestion: members
// that already belong are dropped, every row can be removed, and only the
// effective selection is added (and reported back for the card's Done state).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import 'channel_form_fields.dart';
import 'create_channel_dialog.dart' show ChannelMemberCandidate;

/// The IDs the dialog really added.
typedef AddMembersResult = ({
  String channelId,
  String channelName,
  List<String> addedHumanIds,
  List<String> addedAgentIds,
});

class AddMembersDialog extends StatefulWidget {
  const AddMembersDialog({
    super.key,
    required this.controller,
    required this.channelId,
    this.prefilledHumanIds = const [],
    this.prefilledAgentIds = const [],
    this.draftHint,
    this.actionCardMessageId,
    this.actionCardConfirmationVersion,
    this.onSubmitStart,
    this.onSubmitError,
    this.onSubmitted,
  });
  final WorkspaceController controller;
  final String channelId;
  final List<String> prefilledHumanIds, prefilledAgentIds;

  /// Why the agent prepared this: quoted near the top.
  final String? draftHint;
  final String? actionCardMessageId;
  final Object? actionCardConfirmationVersion;

  /// Action-card funnel hooks: before the batch add (awaited) and on failure.
  final Future<void> Function()? onSubmitStart;
  final void Function(Object error)? onSubmitError;

  /// After the add succeeded (awaited), with the effective IDs.
  final Future<void> Function(AddMembersResult result)? onSubmitted;

  @override
  State<AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends State<AddMembersDialog> {
  WorkspaceController get w => widget.controller;
  RaftChannel? get channel => [
    ...w.channels,
    ...w.dms,
  ].where((c) => c.id == widget.channelId).firstOrNull;

  Set<String> existingHumans = {}, existingAgents = {};
  List<Map<String, dynamic>> members = [], agents = [];
  final selectedHumans = <String>{}, selectedAgents = <String>{};
  bool seeded = false, submitting = false;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final serverId = w.server?.id;
      final values = await Future.wait([
        w.query('/channels/${widget.channelId}/members'),
        if (serverId != null) w.query('/servers/$serverId/members'),
        w.query('/agents'),
      ]);
      if (!mounted) return;
      final roster = values[0];
      final peopleValue = serverId == null ? const [] : values[1];
      final agentValue = values.last;
      List<Map<String, dynamic>> rows(dynamic v, String key) => [
        for (final row
            in ((v is Map ? v[key] : v) as List? ?? const []).whereType<Map>())
          Map<String, dynamic>.from(row),
      ];
      setState(() {
        existingHumans = {
          for (final h in rows(roster, 'humans')) '${h['userId'] ?? h['id']}',
        };
        existingAgents = {for (final a in rows(roster, 'agents')) '${a['id']}'};
        members = rows(peopleValue, 'members');
        agents = rows(agentValue, 'agents');
        if (!seeded &&
            (candidateHumans.isNotEmpty || candidateAgents.isNotEmpty)) {
          // Seed once: every candidate starts selected.
          seeded = true;
          selectedHumans.addAll(
            candidateHumans.map((m) => '${m['userId'] ?? m['id']}'),
          );
          selectedAgents.addAll(candidateAgents.map((a) => '${a['id']}'));
        }
      });
    } catch (_) {
      // The Web hook swallows load failures; the list simply stays empty.
    }
  }

  /// Prefilled IDs that are not members yet and resolve to a known entry.
  List<Map<String, dynamic>> get candidateHumans => [
    for (final id in widget.prefilledHumanIds)
      if (!existingHumans.contains(id))
        ...members.where((m) => '${m['userId'] ?? m['id']}' == id).take(1),
  ];
  List<Map<String, dynamic>> get candidateAgents => [
    for (final id in widget.prefilledAgentIds)
      if (!existingAgents.contains(id))
        ...agents.where((a) => '${a['id']}' == id).take(1),
  ];

  bool get nothingToAdd => candidateHumans.isEmpty && candidateAgents.isEmpty;
  int get selectedCount => selectedHumans.length + selectedAgents.length;
  bool get canSubmit => !submitting && !nothingToAdd && selectedCount > 0;

  Future<void> submit() async {
    final target = channel;
    if (!canSubmit || target == null) return;
    setState(() {
      submitting = true;
      error = null;
    });
    final userIds = [...selectedHumans], agentIds = [...selectedAgents];
    try {
      await widget.onSubmitStart?.call();
      await w.command(
        'POST',
        '/channels/${widget.channelId}/members/batch',
        data: {
          'userIds': userIds,
          'agentIds': agentIds,
          if (widget.actionCardMessageId != null)
            'actionCardMessageId': widget.actionCardMessageId,
          if (widget.actionCardConfirmationVersion != null)
            'actionCardConfirmationVersion':
                widget.actionCardConfirmationVersion,
        },
      );
      // A concurrent add that made a row an idempotent member still satisfies
      // the action: report the selection, not a diff.
      await widget.onSubmitted?.call((
        channelId: target.id,
        channelName: target.name,
        addedHumanIds: userIds,
        addedAgentIds: agentIds,
      ));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      widget.onSubmitError?.call(e);
      if (mounted) {
        setState(() {
          error = e is RaftApiException && e.message.isNotEmpty
              ? e.message
              : raftText(context, 'Failed to add members.');
        });
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  RaftAddMemberRow row({
    required bool human,
    required String id,
    required Map<String, dynamic> data,
  }) {
    final candidate = ChannelMemberCandidate(
      kind: human ? 'human' : 'agent',
      id: id,
      name: '${data['name'] ?? ''}',
      displayName: data['displayName'] as String?,
      avatarUrl: data['avatarUrl'] as String?,
    );
    final description = data['description'] as String?;
    return RaftAddMemberRow(
      key: '${candidate.kind}:$id',
      name: candidate.label,
      human: human,
      secondary:
          description ??
          (human &&
                  candidate.displayName != null &&
                  candidate.displayName != candidate.name
              ? '@${candidate.name}'
              : null),
      avatar: ChannelCandidateAvatar(
        candidate: candidate,
        avatarContext: RaftMountedAvatarContext.compactList,
        origin: w.client.origin,
      ),
      removeLabel: raftFormat(context, 'Remove {name} from add list', {
        'name': candidate.label,
      }),
      onRemove: () => setState(() {
        (human ? selectedHumans : selectedAgents).remove(id);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = channel;
    return RaftAddMembersDialogView(
      channelName: target?.name,
      privateChannel: target?.type == 'private',
      draftHint: widget.draftHint,
      error: error,
      nothingToAdd: nothingToAdd,
      submitting: submitting,
      selectedCount: selectedCount,
      agentSection: candidateAgents.isNotEmpty,
      humanSection: candidateHumans.isNotEmpty,
      agents: [
        for (final a in candidateAgents)
          if (selectedAgents.contains('${a['id']}'))
            row(human: false, id: '${a['id']}', data: a),
      ],
      humans: [
        for (final m in candidateHumans)
          if (selectedHumans.contains('${m['userId'] ?? m['id']}'))
            row(human: true, id: '${m['userId'] ?? m['id']}', data: m),
      ],
      onClose: () => Navigator.of(context).maybePop(),
      onSubmit: submit,
    );
  }
}
