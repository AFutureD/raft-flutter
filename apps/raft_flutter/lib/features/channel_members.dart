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
import 'fleet_views.dart';
import 'member_profile_view.dart';

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
          // The drawer's dashed + tile lands straight in the add view.
          if (startInAdd) 'channelPageAdd': '1',
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

  /// `useServerFeatureFlag(channel_manager_role_actions_v0)`: the hover
  /// `Make admin` / `Demote` actions only exist behind it.
  bool roleActionsEnabled = false;
  String? roleChanging;

  /// The members page's profile stack top (`kind:id`): a row opens its member's
  /// profile as the page's second level (`ProfilePanel presentation="embedded"`).
  ({String kind, String id})? profile;

  @override
  void initState() {
    super.initState();
    search.addListener(() => setState(() {}));
    load();
    loadRoleActionsFlag();
  }

  Future<void> loadRoleActionsFlag() async {
    final server = w.server?.id;
    if (server == null) return;
    try {
      final result = await w.command(
        'POST',
        '/feature-flags/evaluate',
        data: {
          'keys': ['channel_manager_role_actions_v0'],
          'serverId': server,
          'platform': 'web',
        },
      );
      final on =
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) =>
                f['key'] == 'channel_manager_role_actions_v0' &&
                f['enabled'] == true,
          );
      if (mounted && on != roleActionsEnabled) {
        setState(() => roleActionsEnabled = on);
      }
    } catch (_) {}
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

  /// `useChannelMemberRemoval`: stage the target, then the destructive
  /// ConfirmDialog runs the same DELETE.
  Future<void> requestRemove(String kind, String id, String name) async {
    if (channel.archived || !w.can('removeChannelMembers', resource: channel)) {
      return;
    }
    await RaftConfirmDialog.show(
      context,
      RaftConfirmDialog(
        surfaceKey: const ValueKey('channel-member-remove-dialog'),
        title: raftText(context, 'Remove Member'),
        message: raftFormat(
          context,
          '{name} will stop receiving ordinary delivery from #{channel} and cannot send messages until they rejoin. Existing followed threads are not automatically unfollowed; followed public threads can still notify them until they unfollow or manage those threads. Private content remains gated by current access.',
          {'name': name, 'channel': channel.name},
        ),
        confirmLabel: raftText(context, 'Remove'),
        loadingLabel: raftText(context, 'Removing…'),
        actionSize: RaftButtonRecipeSize.xs,
        onConfirm: () => removeNow(kind, id),
      ),
    );
  }

  Future<void> removeNow(String kind, String id) async {
    await w.command(
      'DELETE',
      '/channels/${channel.id}/members/${kind == 'agent' ? 'agent' : 'user'}/$id',
    );
    await load();
  }

  /// `changeMemberRole`: PATCH the member's channel role, then reload.
  Future<void> changeRole(String kind, String id, String role) async {
    final key = '$kind:$id';
    setState(() {
      error = null;
      roleChanging = key;
    });
    try {
      await w.command(
        'PATCH',
        '/channels/${channel.id}/members/${kind == 'agent' ? 'agent' : 'user'}/$id/role',
        data: {'role': role},
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = raftText(
            context,
            "Could not update this member's channel role. Try again.",
          ),
        );
      }
    } finally {
      if (mounted) setState(() => roleChanging = null);
    }
  }

  bool get isAllChannel => channel.name == 'all' && channel.type == 'channel';

  /// `renderMemberActions` role action: shown behind the flag for a member
  /// whose channel role the viewer may change (`canChangeChannelRole`), or to
  /// explain why a server owner/admin cannot be demoted.
  ({String nextRole, bool protectedDemote})? _roleAction(
    String kind,
    String id,
    Map<String, dynamic> m,
    String effectiveRole,
    String serverRole,
  ) {
    final effective = m['effectiveChannelRole'] ??
        (serverRole == 'owner' ||
                serverRole == 'admin' ||
                m['channelRole'] == 'admin'
            ? 'admin'
            : 'member');
    final protectedServerAdmin = serverRole == 'owner' || serverRole == 'admin';
    final self = id == w.client.user?.id;
    final canExplain =
        !channel.archived &&
        !isAllChannel &&
        channel.json['channelCapabilities'] is Map &&
        (channel.json['channelCapabilities'] as Map)['changeChannelMemberRoles'] ==
            true &&
        !self &&
        protectedServerAdmin &&
        effective != 'member';
    final canChange =
        !channel.archived && !isAllChannel && m['canChangeChannelRole'] == true;
    if (!roleActionsEnabled || !(canChange || canExplain)) return null;
    return (
      nextRole: effective == 'member' ? 'admin' : 'member',
      protectedDemote: canExplain,
    );
  }

  Future<void> protectedDemote(String name) => RaftConfirmDialog.show(
    context,
    RaftConfirmDialog(
      title: raftText(context, "Can't demote server admins"),
      message: raftFormat(
        context,
        '{name} is a server owner or admin, so they remain a Channel Admin in every channel. Change their server role in Server Administration first.',
        {'name': name},
      ),
      confirmLabel: raftText(context, 'OK'),
      confirmVariant: RaftButtonRecipeVariant.outline,
      showCancel: false,
    ),
  );

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
      final roleAction = _roleAction(kind, id, m, role, serverRole);
      return RaftMemberRowData(
        testId: 'member-page-row-$kind-$id',
        human: kind != 'agent',
        secondary:
            kind == 'agent' &&
                (presence?.activity == RaftAvatarActivity.working ||
                    presence?.activity == RaftAvatarActivity.thinking) &&
                '${m['activityDetail'] ?? ''}'.trim().isNotEmpty
            ? '${m['activityDetail']}'.trim()
            : kind == 'agent'
            ? raftText(context, switch (presence?.activity) {
                RaftAvatarActivity.thinking => 'Thinking',
                RaftAvatarActivity.working => 'Working',
                RaftAvatarActivity.error => 'Error',
                RaftAvatarActivity.offline => 'Offline',
                _ => 'Online',
              })
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
        onTap: widget.page
            ? () => setState(() => profile = (kind: kind, id: id))
            : null,
        onRemove: canRemove && !isAllChannel
            ? () => requestRemove(
                kind,
                id,
                '${m['displayName'] ?? m['name'] ?? ''}',
              )
            : null,
        roleActionLabel: roleAction == null
            ? null
            : raftText(
                context,
                roleAction.nextRole == 'admin' ? 'Make admin' : 'Demote',
              ),
        roleActionSemantics: roleAction == null
            ? null
            : raftFormat(
                context,
                roleAction.nextRole == 'admin'
                    ? 'Make {name} a channel admin'
                    : 'Remove channel admin from {name}',
                {'name': '${m['name'] ?? ''}'},
              ),
        roleActionDisabled: roleChanging == '$kind:$id',
        onRoleAction: roleAction == null
            ? null
            : () => roleAction.protectedDemote
                  ? protectedDemote('${m['displayName'] ?? m['name'] ?? ''}')
                  : changeRole(kind, id, roleAction.nextRole),
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
    final open = profile;
    if (widget.page && open != null) {
      void back() => setState(() => profile = null);
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (_, _) => back(),
        child: open.kind == 'human'
            ? MemberProfileView(
                key: ValueKey('member-page-profile-${open.id}'),
                controller: w,
                userId: open.id,
                onClose: back,
                onBack: back,
              )
            : FleetDetail(
                key: ValueKey('member-page-profile-${open.id}'),
                controller: w,
                computers: false,
                initial: agentRows[open.id] ?? {'id': open.id},
                onClose: back,
              ),
      );
    }
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
