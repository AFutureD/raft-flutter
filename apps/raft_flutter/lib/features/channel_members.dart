// Channel members: the Web ChannelMembers "modal" presentation
// (packages/web/src/components/agent/ChannelMembers.tsx) — a header trigger
// (Users + participant count) opening a Modal Card `max-w-sm p-6` with the
// roster and the staged multi-select "Add Member" view (search, AGENTS /
// HUMANS candidates with CheckMarker + AvatarSlot compact-list, pinned
// "Create a New Agent" entry, "Add selected (N)").
import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import '../data/raft_location.dart';
import 'channel_form_fields.dart';
import 'create_channel_dialog.dart';

/// Agent activity for the compact-list badge: the row's `activity` when the
/// payload carries one, else `agentStatusFallbackActivity(status)`.
RaftAvatarPresence? channelMemberPresence(Map<String, dynamic> json) {
  final activity = json['activity'];
  final value = switch (activity) {
    'online' => RaftAvatarActivity.online,
    'thinking' => RaftAvatarActivity.thinking,
    'working' => RaftAvatarActivity.working,
    'error' => RaftAvatarActivity.error,
    'offline' => RaftAvatarActivity.offline,
    _ =>
      json['status'] == 'active'
          ? RaftAvatarActivity.online
          : RaftAvatarActivity.offline,
  };
  return RaftAvatarPresence(activity: value);
}

/// Header trigger: `Button size="sm" className="min-w-7 gap-1 px-1.5"` with
/// `Users size={14}` and the mono participant count.
class ChannelMembersButton extends StatefulWidget {
  const ChannelMembersButton({
    super.key,
    required this.controller,
    required this.channel,
  });
  final WorkspaceController controller;
  final RaftChannel channel;
  @override
  State<ChannelMembersButton> createState() => _ChannelMembersButtonState();
}

class _ChannelMembersButtonState extends State<ChannelMembersButton> {
  int? count;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final roster = await widget.controller.query(
        '/channels/${widget.channel.id}/members',
      );
      if (!mounted) return;
      setState(
        () => count =
            ((roster['humans'] as List?)?.length ?? 0) +
            ((roster['agents'] as List?)?.length ?? 0),
      );
    } catch (_) {
      if (mounted) setState(() => count = 0);
    }
  }

  @override
  Widget build(BuildContext context) => RaftMembersTrigger(
    key: const ValueKey('channel-members-open'),
    count: count,
    onPressed: () async {
      await ChannelMembers.show(
        context,
        controller: widget.controller,
        channel: widget.channel,
      );
      refresh();
    },
  );
}

class ChannelMembers extends StatefulWidget {
  const ChannelMembers({
    super.key,
    required this.controller,
    required this.channel,
    this.page = false,
    this.embedded = false,
    this.onClose,
    this.startInAdd = false,
  });
  final WorkspaceController controller;
  final RaftChannel channel;
  final bool page;

  /// The page is mounted inside the desktop settings drawer (Web `OverflowSheet
  /// bare`), so back from the roster returns to the drawer root.
  final bool embedded;
  final VoidCallback? onClose;

  /// The settings drawer's dashed add tile lands directly in the add view.
  final bool startInAdd;

  static Future<void> show(
    BuildContext context, {
    required WorkspaceController controller,
    required RaftChannel channel,
    bool startInAdd = false,
  }) async {
    if (controller.mobileNavigation) {
      if (!controller.can('viewChannel', resource: channel)) return;
      FocusManager.instance.primaryFocus?.unfocus();
      controller.navigation.navigate(
        controller.location.withQuery({
          'channelPage': '${RaftChannelPage.members.name}:${channel.id}',
        }),
      );
      controller.notifyListeners();
      return;
    }
    await showRaftModal<void>(
      context,
      builder: (_) => ChannelMembers(
        controller: controller,
        channel: channel,
        startInAdd: startInAdd,
      ),
    );
  }

  @override
  State<ChannelMembers> createState() => _ChannelMembersState();
}

class _ChannelMembersState extends State<ChannelMembers> {
  WorkspaceController get w => widget.controller;
  RaftChannel get channel =>
      [
        ...w.channels,
        ...w.dms,
      ].where((channel) => channel.id == widget.channel.id).firstOrNull ??
      widget.channel;
  List<Map<String, dynamic>> humans = [], agents = [];
  List<ChannelMemberCandidate> candidates = [];
  final Map<String, Map<String, dynamic>> agentRows = {};
  bool loading = true, adding = false;
  late bool addView = widget.startInAdd;
  String? error;
  final selected = <String>{};
  final search = TextEditingController();

  @override
  void initState() {
    super.initState();
    search.addListener(() => setState(() {}));
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final roster = await w.query('/channels/${channel.id}/members');
      final pool = await loadChannelMemberCandidates(w);
      final rawAgents = await w.query('/agents');
      if (!mounted) return;
      setState(() {
        humans = [
          for (final h in (roster['humans'] as List? ?? []).whereType<Map>())
            Map<String, dynamic>.from(h),
        ];
        agents = [
          for (final a in (roster['agents'] as List? ?? []).whereType<Map>())
            Map<String, dynamic>.from(a),
        ];
        for (final a in (rawAgents as List? ?? const []).whereType<Map>()) {
          agentRows['${a['id']}'] = Map<String, dynamic>.from(a);
        }
        final inChannel = {
          for (final h in humans) 'human:${h['userId'] ?? h['id']}',
          for (final a in agents) 'agent:${a['id']}',
        };
        // The add view also lists the signed-in user's server peers only.
        candidates = [
          for (final c in pool)
            if (!inChannel.contains('${c.kind}:${c.id}')) c,
        ];
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  bool get canAdd =>
      w.can('addChannelMembers', resource: channel) && !channel.archived;

  Future<void> confirmAdd() async {
    if (adding || selected.isEmpty || !canAdd) return;
    setState(() {
      adding = true;
      error = null;
    });
    try {
      await w.command(
        'POST',
        '/channels/${channel.id}/members/batch',
        data: {
          'userIds': [
            for (final k in selected)
              if (k.startsWith('human:')) k.substring(6),
          ],
          'agentIds': [
            for (final k in selected)
              if (k.startsWith('agent:')) k.substring(6),
          ],
        },
      );
      selected.clear();
      addView = false;
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = raftText(
            context,
            'Some selected members could not be added. They remain selected — press Add again to retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => adding = false);
    }
  }

  Future<void> remove(String kind, String id) async {
    if (channel.archived || !w.can('removeChannelMembers', resource: channel)) {
      return;
    }
    try {
      await w.command(
        'DELETE',
        '/channels/${channel.id}/members/${kind == 'agent' ? 'agent' : 'user'}/$id',
      );
      await load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void close() => widget.onClose != null
      ? widget.onClose!()
      : Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final origin = w.client.origin;
    final canRemove =
        w.can('removeChannelMembers', resource: channel) && !channel.archived;
    RaftMemberRowData row(String kind, Map<String, dynamic> m) {
      final id = '${kind == 'agent' ? m['id'] : (m['userId'] ?? m['id'])}';
      final candidate = ChannelMemberCandidate(
        kind: kind,
        id: id,
        name: '${m['name'] ?? ''}',
        displayName: m['displayName'] as String?,
        avatarUrl: m['avatarUrl'] as String?,
      );
      final presence = kind == 'agent' ? channelMemberPresence(m) : null;
      // `effectiveChannelRole ?? serverRole`: owner / admin inheritance and an
      // explicit channel grant share the one user-facing Channel Admin label
      // (MemberRoleTag); a plain member shows nothing.
      final serverRole = '${m['serverRole'] ?? m['role'] ?? 'member'}';
      final role =
          '${m['effectiveChannelRole'] ?? (kind == 'agent' ? serverRole : m['role'] ?? 'member')}';
      final description = '${m['description'] ?? ''}'.trim();
      return RaftMemberRowData(
        human: kind != 'agent',
        secondary: kind == 'agent' &&
                (presence?.activity == RaftAvatarActivity.working ||
                    presence?.activity == RaftAvatarActivity.thinking) &&
                '${m['activityDetail'] ?? ''}'.trim().isNotEmpty
            ? '${m['activityDetail']}'.trim()
            : kind == 'agent'
            ? raftText(
                context,
                switch (presence?.activity) {
                  RaftAvatarActivity.thinking => 'Thinking',
                  RaftAvatarActivity.working => 'Working',
                  RaftAvatarActivity.error => 'Error',
                  RaftAvatarActivity.offline => 'Offline',
                  _ => 'Online',
                },
              )
            : (description.isEmpty ? null : description),
        secondaryMono: kind == 'agent',
        roleLabel: switch (role) {
          'guest' => raftText(context, 'Guest'),
          'member' => null,
          _ => raftText(context, 'Channel Admin'),
        },
        guest: role == 'guest',
        label: candidate.label,
        avatar: ChannelCandidateAvatar(
          candidate: candidate,
          // ChannelMemberRow mounts AvatarSlot `members-row` (28px, presence
          // badge for agents); the modal list keeps the compact slot.
          avatarContext: widget.page
              ? RaftMountedAvatarContext.membersRow
              : RaftMountedAvatarContext.compactList,
          origin: origin,
          presence: widget.page ? presence : null,
        ),
        onRemove: canRemove ? () => remove(kind, id) : null,
      );
    }

    RaftPickerItem item(ChannelMemberCandidate c) => RaftPickerItem(
      key: '${c.kind}:${c.id}',
      label: c.label,
      description: c.description,
      avatar: ChannelCandidateAvatar(
        candidate: c,
        avatarContext: RaftMountedAvatarContext.compactList,
        origin: origin,
        presence: c.kind == 'agent' && agentRows[c.id] != null
            ? channelMemberPresence(agentRows[c.id]!)
            : null,
      ),
    );
    final query = search.text;
    final content = RaftChannelMembersModal(
      page: widget.page,
      onClose: close,
      search: search,
      channelName: channel.name,
      addView: addView,
      loading: loading,
      adding: adding,
      error: error,
      humans: [for (final h in humans) row('human', h)],
      agents: [for (final a in agents) row('agent', a)],
      onAdd: canAdd ? () => setState(() => addView = true) : null,
      onBack: () => setState(() {
        addView = false;
        selected.clear();
        search.clear();
      }),
      hasCandidates: candidates.isNotEmpty,
      candidateAgents: [
        for (final c in candidates)
          if (c.kind == 'agent' && c.matches(query)) item(c),
      ],
      candidateHumans: [
        for (final c in candidates)
          if (c.kind == 'human' && c.matches(query)) item(c),
      ],
      chips: [
        for (final key in selected)
          (
            key,
            candidates
                    .where((c) => '${c.kind}:${c.id}' == key)
                    .firstOrNull
                    ?.label ??
                key,
          ),
      ],
      isChecked: selected.contains,
      onToggle: (key) => setState(() {
        if (!selected.remove(key)) selected.add(key);
      }),
      canCreateAgent: w.can('createAgents'),
      onConfirm: confirmAdd,
    );
    return PopScope(
      canPop: !widget.page || (!addView && !widget.embedded),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !widget.page) return;
        if (addView) {
          setState(() {
            addView = false;
            selected.clear();
            search.clear();
          });
        } else if (widget.embedded) {
          close();
        }
      },
      child: content,
    );
  }
}
