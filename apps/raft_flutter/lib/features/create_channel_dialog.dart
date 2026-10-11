// Create-channel dialog: the Web CreateChannelDialog
// (packages/web/src/components/channel/CreateChannelDialog.tsx) — DialogCard
// with Name, Description (optional), Visibility (Public/Private segmented
// control), Members (optional) search + AGENTS/HUMANS picker, Cancel/Create.
import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import 'channel_form_fields.dart';

/// One selectable member row of the picker (an agent or a human).
@immutable
class ChannelMemberCandidate {
  const ChannelMemberCandidate({
    required this.kind,
    required this.id,
    required this.name,
    this.displayName,
    this.description,
    this.avatarUrl,
  });
  final String kind; // 'agent' | 'human'
  final String id, name;
  final String? displayName, description, avatarUrl;
  String get label =>
      (displayName?.trim().isNotEmpty ?? false) ? displayName! : name;
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        (displayName ?? '').toLowerCase().contains(q);
  }
}

/// Agents (not deleted) and server members other than the signed-in user,
/// from the same endpoints the Web stores load (`/agents`,
/// `/servers/:id/members`).
Future<List<ChannelMemberCandidate>> loadChannelMemberCandidates(
  WorkspaceController w,
) async {
  final serverId = w.server?.id;
  final values = await Future.wait([
    w.query('/agents'),
    if (serverId != null) w.query('/servers/$serverId/members'),
  ]);
  final me = w.client.user?.id;
  return [
    for (final a in (values[0] as List? ?? const []).whereType<Map>())
      if (a['deletedAt'] == null)
        ChannelMemberCandidate(
          kind: 'agent',
          id: '${a['id']}',
          name: '${a['name'] ?? ''}',
          displayName: a['displayName'] as String?,
          description: a['description'] as String?,
          avatarUrl: a['avatarUrl'] as String?,
        ),
    if (values.length > 1)
      for (final m in (values[1] as List? ?? const []).whereType<Map>())
        if ((m['userId'] ?? m['id']) != me)
          ChannelMemberCandidate(
            kind: 'human',
            id: '${m['userId'] ?? m['id']}',
            name: '${m['name'] ?? ''}',
            displayName: m['displayName'] as String?,
            description: m['description'] as String?,
            avatarUrl: m['avatarUrl'] as String?,
          ),
  ];
}

class CreateChannelDialog extends StatefulWidget {
  const CreateChannelDialog({
    super.key,
    required this.controller,
    this.prefilledName,
    this.prefilledDescription,
    this.prefilledVisibility = 'public',
    this.prefilledAgentIds = const [],
    this.prefilledHumanIds = const [],
    this.onCreated,
  });
  final WorkspaceController controller;
  final String? prefilledName, prefilledDescription;
  final String prefilledVisibility;
  final List<String> prefilledAgentIds, prefilledHumanIds;
  final Future<void> Function(RaftChannel channel)? onCreated;

  static Future<void> show(
    BuildContext context, {
    required WorkspaceController controller,
    Future<void> Function(RaftChannel channel)? onCreated,
  }) => showRaftModal<void>(
    context,
    builder: (_) =>
        CreateChannelDialog(controller: controller, onCreated: onCreated),
  );

  @override
  State<CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<CreateChannelDialog> {
  WorkspaceController get w => widget.controller;
  late final name = TextEditingController(text: widget.prefilledName ?? '');
  late final description = TextEditingController(
    text: widget.prefilledDescription ?? '',
  );
  final search = TextEditingController();
  late String visibility = widget.prefilledVisibility;
  late final Set<String> agentIds = {...widget.prefilledAgentIds};
  late final Set<String> humanIds = {...widget.prefilledHumanIds};
  List<ChannelMemberCandidate> candidates = const [];
  bool submitting = false, unarchiving = false;
  String? error;
  Map<String, dynamic>? archivedCollision;

  @override
  void initState() {
    super.initState();
    search.addListener(() => setState(() {}));
    loadChannelMemberCandidates(w).then((value) {
      if (mounted) setState(() => candidates = value);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    search.dispose();
    super.dispose();
  }

  void close() => Navigator.of(context).maybePop();

  Future<void> unarchiveCollision() async {
    final held = archivedCollision;
    if (held == null || unarchiving) return;
    setState(() => unarchiving = true);
    try {
      final result = await w.command(
        'POST',
        '/channels/${held['archivedChannelId']}/unarchive',
      );
      await w.refreshChannels();
      if (!mounted) return;
      Navigator.of(context).pop();
      await widget.onCreated?.call(
        RaftChannel(Map<String, dynamic>.from(result as Map)),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          archivedCollision = null;
          error = e is RaftApiException
              ? e.message
              : raftText(context, 'Failed to unarchive channel');
        });
      }
    } finally {
      if (mounted) setState(() => unarchiving = false);
    }
  }

  Future<void> submit() async {
    if (submitting) return;
    final trimmed = name.text.trim();
    // `validateNameReason` + `formatNameValidationError`.
    final invalid = channelNameError(context, trimmed);
    if (invalid != null) {
      setState(() {
        error = invalid;
        archivedCollision = null;
      });
      return;
    }
    setState(() {
      submitting = true;
      error = null;
      archivedCollision = null;
    });
    try {
      final result = await w.command(
        'POST',
        '/channels',
        data: {
          'name': trimmed,
          if (description.text.trim().isNotEmpty)
            'description': description.text.trim(),
          'visibility': visibility,
          'type': 'channel',
          'agentIds': [...agentIds],
          'userIds': [...humanIds],
        },
      );
      await w.refreshChannels();
      if (!mounted) return;
      Navigator.of(context).pop();
      await widget.onCreated?.call(
        RaftChannel(Map<String, dynamic>.from(result as Map)),
      );
    } catch (e) {
      if (mounted) {
        final details = e is RaftApiException ? e.details : const {};
        setState(() {
          if (details['code'] == 'archived_name_collision' &&
              details['archivedChannelId'] != null) {
            archivedCollision = Map<String, dynamic>.from(details);
          } else {
            error = e is RaftApiException
                ? e.message
                : raftText(context, 'Failed to create channel');
          }
        });
      }
    } finally {
      if (mounted) setState(() => submitting = false);
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
      ),
    );
    return RaftCreateChannelDialogView(
      name: name,
      description: description,
      search: search,
      visibility: visibility,
      onVisibilityChanged: (v) => setState(() => visibility = v),
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
        final id = key.substring(6);
        if (!set.remove(id)) set.add(id);
      }),
      onClose: close,
      onSubmit: submit,
      error: error,
      notice: archivedCollision == null
          ? null
          : RaftArchivedNameBanner(
              name: '${archivedCollision!['archivedChannelName']}',
              canUnarchive:
                  archivedCollision!['canUnarchiveArchivedChannel'] == true,
              busy: unarchiving,
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

final _channelNameRegex = RegExp(r'^\p{L}[\p{L}\p{N}_-]*$', unicode: true);

/// `validateNameReason` + `formatNameValidationError` for a channel name.
String? channelNameError(BuildContext context, String value) {
  final label = raftText(context, 'Channel name');
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return raftFormat(context, '{label} is required', {'label': label});
  }
  if (trimmed.runes.length > 32) {
    return raftFormat(context, '{label} must be at most {max} characters', {
      'label': label,
      'max': 32,
    });
  }
  if (!_channelNameRegex.hasMatch(trimmed)) {
    return raftText(
      context,
      'Start with a letter, then letters, numbers, - or _',
    );
  }
  return null;
}
