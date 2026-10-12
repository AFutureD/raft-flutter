// Create joint (shared) channel dialog: the Web CreateJointChannelDialog
// (packages/web/src/components/channel/CreateJointChannelDialog.tsx) over the
// raft_ui RaftCreateJointChannelDialogView. The host (JointChannelsView) owns
// the guarded mutations; this dialog owns the form state and Web's error
// mapping (archived-name collision, free-server and server limits, billing gate).
import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import 'channel_form_fields.dart';
import 'create_channel_dialog.dart'
    show ChannelMemberCandidate, channelNameError;
import 'joint_channel_views.dart' show jointPeople;

/// `MAX_JOINT_CHANNEL_SERVERS` of @botiverse/raft-shared.
const maxJointChannelServers = 30;

class CreateJointChannelDialog extends StatefulWidget {
  const CreateJointChannelDialog({
    super.key,
    required this.agents,
    required this.users,
    required this.onCreate,
    required this.onUnarchive,
    this.freePlan = false,
    this.origin,
    this.onViewBilling,
  });
  final List<Map<String, dynamic>> agents, users;

  /// POST /channels with the Web payload; returns the created channel.
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> payload)
  onCreate;

  /// POST /channels/:id/unarchive for the archived-name collision.
  final Future<Map<String, dynamic>> Function(String channelId) onUnarchive;
  final bool freePlan;
  final String? origin;
  final VoidCallback? onViewBilling;

  @override
  State<CreateJointChannelDialog> createState() =>
      _CreateJointChannelDialogState();
}

class _CreateJointChannelDialogState extends State<CreateJointChannelDialog> {
  final name = TextEditingController(), description = TextEditingController();
  final search = TextEditingController();
  final drafts = [RaftJointInviteDraft('invite-1')];
  int nextInvite = 2;
  final agentIds = <String>{}, humanIds = <String>{};
  String? error;
  bool billingError = false, submitting = false;
  Map<String, dynamic>? archivedCollision;

  late final List<ChannelMemberCandidate> candidates = [
    for (final a in widget.agents)
      ChannelMemberCandidate(
        kind: 'agent',
        id: '${a['id']}',
        name: '${a['name'] ?? ''}',
        displayName: a['displayName'] as String?,
        description: a['description'] as String?,
        avatarUrl: a['avatarUrl'] as String?,
      ),
    for (final u in widget.users)
      ChannelMemberCandidate(
        kind: 'human',
        id: '${u['userId'] ?? u['id']}',
        name: '${u['name'] ?? u['userName'] ?? ''}',
        displayName: u['displayName'] as String?,
        description: u['description'] as String?,
        avatarUrl: u['avatarUrl'] as String?,
      ),
  ];

  @override
  void initState() {
    super.initState();
    search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    search.dispose();
    for (final draft in drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  /// A submit error describes the invite list it was submitted with; once the
  /// list changes it is stale.
  void clearSubmitError() {
    if (error != null || billingError) {
      setState(() {
        error = null;
        billingError = false;
      });
    }
  }

  void addServer() {
    if (drafts.length >= maxJointChannelServers - 1) return;
    setState(() {
      error = null;
      billingError = false;
      drafts.add(RaftJointInviteDraft('invite-${nextInvite++}'));
    });
  }

  void removeServer(String id) {
    if (drafts.length <= 1) return;
    setState(() {
      error = null;
      billingError = false;
      drafts.removeWhere((d) {
        final match = d.id == id;
        if (match) d.dispose();
        return match;
      });
    });
  }

  Future<void> submit() async {
    if (submitting) return;
    final trimmed = name.text.trim();
    setState(() {
      error = null;
      billingError = false;
      archivedCollision = null;
    });
    final nameError = channelNameError(context, trimmed);
    if (nameError != null) {
      setState(() => error = nameError);
      return;
    }
    final invites = [
      for (final draft in drafts)
        {
          'targetServerSlug': draft.slug.text.trim(),
          'invitedPeople': jointPeople(draft.people.text),
        },
    ];
    final incomplete = invites.firstWhere(
      (i) =>
          (i['targetServerSlug'] as String).isEmpty ||
          (i['invitedPeople'] as List).isEmpty,
      orElse: () => const {},
    );
    if (incomplete.isNotEmpty) {
      setState(
        () => error = raftText(
          context,
          incomplete['targetServerSlug'] == ''
              ? 'Invite server slug is required'
              : 'At least one invited person is required',
        ),
      );
      return;
    }
    setState(() => submitting = true);
    try {
      final channel = await widget.onCreate({
        'name': trimmed,
        if (description.text.trim().isNotEmpty)
          'description': description.text.trim(),
        'visibility': 'joint',
        'agentIds': [...agentIds],
        'userIds': [...humanIds],
        'jointInvites': invites,
      });
      if (mounted) Navigator.of(context).pop(channel);
    } catch (e) {
      if (!mounted) return;
      final details = e is RaftApiException ? e.details : const {};
      setState(() {
        submitting = false;
        if (details['code'] == 'archived_name_collision' &&
            details['archivedChannelId'] != null &&
            details['archivedChannelName'] != null &&
            details['archivedChannelType'] == 'joint') {
          archivedCollision = Map<String, dynamic>.from(details);
        } else if (details['code'] == 'joint_free_server_limit') {
          error = raftText(
            context,
            'This Joint Channel already has 2 free servers. Upgrade either side to Pro, or have a free server leave, to continue (30 servers max).',
          );
          billingError = true;
        } else if (details['code'] == 'joint_server_limit') {
          error = raftFormat(
            context,
            'Joint Channels are limited to {max} servers. To request a higher limit, send feedback from Settings.',
            {'max': maxJointChannelServers},
          );
        } else {
          final body = e is RaftApiException && e.message.isNotEmpty
              ? e.message
              : raftText(context, 'Failed to create joint channel');
          error = body;
          billingError = body.contains('requires the Pro plan');
        }
      });
    }
  }

  Future<void> unarchiveCollision() async {
    final held = archivedCollision;
    if (held == null || submitting) return;
    setState(() => submitting = true);
    try {
      final channel = await widget.onUnarchive('${held['archivedChannelId']}');
      if (mounted) Navigator.of(context).pop(channel);
    } catch (e) {
      if (mounted) {
        setState(() {
          submitting = false;
          error = e is RaftApiException && e.message.isNotEmpty
              ? e.message
              : raftText(context, 'Failed to unarchive channel');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    RaftPickerItem item(ChannelMemberCandidate c) => RaftPickerItem(
      key: '${c.kind}:${c.id}',
      label: c.label,
      description: c.description,
      avatar: ChannelCandidateAvatar(
        candidate: c,
        avatarContext: RaftMountedAvatarContext.sidebarList,
        humanPlaceholder: true,
        origin: widget.origin,
      ),
    );
    return RaftCreateJointChannelDialogView(
      name: name,
      description: description,
      search: search,
      drafts: drafts,
      maxServers: maxJointChannelServers,
      freeAllowance: widget.freePlan,
      onAddServer: addServer,
      onRemoveServer: removeServer,
      onInviteChanged: clearSubmitError,
      agents: [
        for (final c in candidates)
          if (c.kind == 'agent' && c.matches(search.text)) item(c),
      ],
      humans: [
        for (final c in candidates)
          if (c.kind == 'human' && c.matches(search.text)) item(c),
      ],
      hasCandidates: candidates.isNotEmpty,
      isSelected: (key) => key.startsWith('agent:')
          ? agentIds.contains(key.substring(6))
          : humanIds.contains(key.substring(6)),
      onToggle: (key) => setState(() {
        final set = key.startsWith('agent:') ? agentIds : humanIds;
        final id = key.substring(key.indexOf(':') + 1);
        if (!set.remove(id)) set.add(id);
      }),
      onClose: () => Navigator.of(context).maybePop(),
      onSubmit: submit,
      error: error,
      onViewBilling: billingError && widget.onViewBilling != null
          ? () {
              Navigator.of(context).pop();
              widget.onViewBilling!();
            }
          : null,
      notice: archivedCollision == null
          ? null
          : RaftArchivedNameBanner(
              name: '${archivedCollision!['archivedChannelName']}',
              canUnarchive:
                  archivedCollision!['canUnarchiveArchivedChannel'] == true,
              busy: submitting,
              showHint: false,
              onUnarchive: unarchiveCollision,
              onChangeName: () => setState(() {
                archivedCollision = null;
                name.clear();
              }),
            ),
      submitting: submitting,
    );
  }
}
