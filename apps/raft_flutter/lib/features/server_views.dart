import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import '../platform/content_links.dart';
import 'public_visibility_view.dart';

class WorkspaceActions {
  static Future<void> create(
    BuildContext context,
    WorkspaceController w,
  ) async {
    await showDialog(
      context: context,
      builder: (_) => RaftFormDialog(
        title: 'Create workspace',
        submitLabel: 'Create',
        fields: [
          const RaftFormField('name', 'Workspace name', required: true),
          RaftFormField(
            'slug',
            'Workspace address',
            required: true,
            help: 'Lowercase letters, numbers and hyphens.',
            validator: (v) => RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(v)
                ? null
                : 'Use lowercase letters, numbers and hyphens.',
          ),
        ],
        onSubmit: (values) async {
          final created = await w.client.post('/servers', data: values);
          await w.recoverMembership();
          final next = w.servers
              .where((s) => s.id == created['id'])
              .firstOrNull;
          if (next != null) await w.selectServer(next);
        },
      ),
    );
  }

  static Future<void> join(BuildContext context, WorkspaceController w) async {
    await showDialog(
      context: context,
      builder: (dialogContext) => RaftFormDialog(
        title: 'Join workspace',
        submitLabel: 'Review invitation',
        fields: [
          RaftFormField(
            'token',
            'Invitation link or code',
            required: true,
            obscure: true,
          ),
        ],
        onSubmit: (values) async {
          final input = values['token']!, uri = Uri.tryParse(values['token']!);
          final token = uri != null && uri.hasScheme
              ? (uri.queryParameters['invite'] ??
                    uri.queryParameters['token'] ??
                    (uri.pathSegments.length >= 2 &&
                            uri.pathSegments.first == 'join'
                        ? uri.pathSegments.last
                        : ''))
              : input;
          if (token.isEmpty) {
            throw const RaftApiException(
              'Enter a valid invitation link or code.',
            );
          }
          final info = await w.client.get(
            '/auth/invite-info',
            query: {'token': token},
          );
          if (!dialogContext.mounted) return;
          final agreement = info['agreement'];
          String? joinedId;
          final accepted = await showDialog<bool>(
            context: dialogContext,
            builder: (_) => RaftFormDialog(
              title: raftFormat(context, 'Join {workspace}?', {
                'workspace': info['serverName'],
              }),
              description: agreement is Map
                  ? '${agreement['title']} · Version ${agreement['version']}\n\n${agreement['bodyMarkdown']}'
                  : 'You have been invited to this workspace${info['inviterName'] == null ? '' : ' by ${info['inviterName']}'}.',
              fields: [],
              submitLabel: agreement == null
                  ? 'Join workspace'
                  : 'Agree and join',
              onSubmit: (_) async {
                final result = await w.client.post(
                  '/auth/accept-invite',
                  data: {
                    'token': token,
                    if (agreement is Map) 'agreementId': agreement['id'],
                  },
                );
                joinedId = result['serverId'];
              },
            ),
          );
          if (accepted != true) {
            throw const RaftApiException(
              'The invitation has not been accepted.',
            );
          }
          await w.recoverMembership();
          final next = w.servers.where((s) => s.id == joinedId).firstOrNull;
          if (next != null) await w.selectServer(next);
        },
      ),
    );
  }

  static Future<void> leave(
    BuildContext context,
    WorkspaceController w, {
    bool delete = false,
  }) async {
    final server = w.server;
    if (server == null) return;
    await showDialog(
      context: context,
      builder: (_) => RaftFormDialog(
        title: delete ? 'Delete workspace?' : 'Leave workspace?',
        description: delete
            ? raftFormat(
                context,
                'Delete {workspace}, its channels and messages. This cannot be undone.',
                {'workspace': server.name},
              )
            : raftFormat(
                context,
                'Leave {workspace}. A new invitation is required to return.',
                {'workspace': server.name},
              ),
        fields: [
          RaftFormField(
            'confirm',
            'Type workspace name',
            required: true,
            validator: (v) => v == server.name
                ? null
                : raftFormat(context, 'The name must match {name}.', {
                    'name': server.name,
                  }),
          ),
        ],
        submitLabel: delete ? 'Delete' : 'Leave',
        destructive: delete,
        onSubmit: (_) async {
          await w.client.exitServer(server.id, delete: delete);
          w.revokeServer(server.id);
          await w.recoverMembership();
        },
      ),
    );
  }
}

/// SettingsPanel.tsx ServerTabContent for the fixture capabilities:
/// ProfileSection + DangerZoneSection. (PublicVisibilitySection and
/// ArchivedChannelsSection render nothing without public visibility /
/// archived channels.) Invitations live under Administration and the
/// workspace push mode under Notifications.
class ServerSettingsView extends StatefulWidget {
  const ServerSettingsView({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  State<ServerSettingsView> createState() => _ServerSettingsViewState();
}

class _ServerSettingsViewState extends State<ServerSettingsView> {
  WorkspaceController get w => widget.controller;
  final name = TextEditingController();
  String? savedName, error;
  bool saving = false, saved = false;
  Timer? savedReset;

  @override
  void initState() {
    super.initState();
    name.text = savedName = w.server?.name ?? '';
  }

  @override
  void didUpdateWidget(covariant ServerSettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = w.server?.name ?? '';
    if (current != savedName) name.text = savedName = current;
  }

  @override
  void dispose() {
    savedReset?.cancel();
    name.dispose();
    super.dispose();
  }

  bool get dirty =>
      name.text.trim().isNotEmpty && name.text.trim() != w.server?.name;

  Future<void> save() async {
    final id = w.server?.id;
    if (id == null || !dirty || saving) return;
    setState(() {
      error = null;
      saved = false;
      saving = true;
    });
    try {
      await w.command(
        'PATCH',
        '/servers/$id',
        data: {'name': name.text.trim()},
      );
      await w.recoverMembership();
      if (!mounted) return;
      savedName = name.text.trim();
      setState(() => saved = true);
      savedReset?.cancel();
      savedReset = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => saved = false);
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> confirmDelete() async {
    final server = w.server;
    if (server == null) return;
    final matches = ValueNotifier(false);
    final ok = await RaftConfirmDialog.show(
      context,
      RaftConfirmDialog(
        title: 'Delete Server',
        confirmLabel: 'Delete Server',
        confirmKey: const Key('server-delete-confirm-button'),
        content: _DeleteServerConfirm(
          name: server.name,
          slug: server.string('slug'),
          matches: matches,
        ),
        confirmEnabled: matches,
      ),
    );
    matches.dispose();
    if (ok == true) await exitServer(delete: true);
  }

  Future<void> confirmLeave() async {
    final server = w.server;
    if (server == null) return;
    final ok = await RaftConfirmDialog.show(
      context,
      RaftConfirmDialog(
        title: 'Leave Server',
        message: raftFormat(
          context,
          "You'll lose access to {serverName} and all of its channels. You can be re-invited later.",
          {'serverName': server.name},
        ),
        confirmLabel: 'Leave Server',
        // confirmColor="bg-brutal-orange" -> warning tone.
        confirmVariant: RaftButtonRecipeVariant.warning,
        confirmKey: const Key('server-leave-confirm-button'),
      ),
    );
    if (ok == true) await exitServer(delete: false);
  }

  Future<void> exitServer({required bool delete}) async {
    final server = w.server;
    if (server == null) return;
    await w.client.exitServer(server.id, delete: delete);
    w.revokeServer(server.id);
    await w.recoverMembership();
  }

  @override
  Widget build(BuildContext context) {
    final server = w.server;
    if (server == null) return const SizedBox.shrink();
    final t = RaftTokens.of(context);
    final canEdit = w.can('editServerSettings');
    final role = server.string('role');
    final canLeave = role == 'admin' || role == 'member' || role == 'guest';
    final slug = server.string('slug');
    final initial = (server.name.trim().isEmpty ? 'S' : server.name.trim())
        .substring(0, 1)
        .toUpperCase();
    return ListView(
      primary: false,
      padding: raftScrollPadding(context, RaftSettingsPanelFrame.contentInset),
      children: [
        const RaftSettingsSectionHeader(
          label: 'Profile',
          glyph: RaftGlyph.building2,
        ),
        RaftSettingsProfileCard(
          avatar: RaftServerProfileTile(initial: initial),
          title: server.name,
          subtitle: '/$slug',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RaftSettingsField(
                label: 'Name',
                child: canEdit
                    ? RaftRecipeInput(
                        fieldKey: const Key('server-profile-name-input'),
                        controller: name,
                        onChanged: (_) => setState(() => saved = false),
                        onSubmitted: (_) => save(),
                      )
                    : RaftSettingsReadonlyValue(
                        key: const Key('server-profile-name-readonly'),
                        value: server.name,
                      ),
              ),
              const SizedBox(height: RaftSpace.x3),
              RaftSettingsField(
                label: 'Slug',
                // SlugInput readOnly: `border-line-strong bg-layer-inset
                // shadow-none theme-brutal:border-black/30
                // theme-brutal:bg-gray-50`, input `text-sm
                // text-foreground-muted theme-brutal:text-black/60`.
                child: RaftSettingsPrefixedInput(
                  prefix: '/',
                  value: slug,
                  readOnly: true,
                  flat: true,
                  rootColor: RaftSettingsText(t).readonlyGroupFill,
                  rootBorderColor: RaftSettingsText(t).readonlyGroupBorder,
                  textColor: RaftSettingsText(t).muted,
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: RaftSpace.x3),
                Text(error!, style: RaftSettingsText(t).alert),
              ],
              if (canEdit) ...[
                const SizedBox(height: RaftSpace.x3),
                Align(
                  alignment: Alignment.centerLeft,
                  child: RaftSettingsRecipeButton(
                    key: const Key('server-profile-save-button'),
                    label: saving
                        ? 'Saving...'
                        : saved
                        ? 'Saved'
                        : 'Save Profile',
                    glyph: saved && !saving ? RaftGlyph.check : null,
                    glyphSize: 14,
                    variant: RaftButtonRecipeVariant.accent,
                    size: RaftButtonRecipeSize.sm,
                    onPressed: dirty && !saving ? save : null,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: RaftSpace.x6),
        // PublicVisibilitySection (owner, public_server_v0); its own
        // `mb-6` follows it.
        PublicVisibilitySection(
          controller: w,
          webOrigin: ContentLinks.originFor(w.client.origin).origin,
        ),
        const RaftSettingsSectionHeader(
          label: 'Danger Zone',
          glyph: RaftGlyph.triangleAlert,
        ),
        if (canLeave) ...[
          RaftSettingsActionCard(
            title: 'Leave Server',
            description: "You will lose access to this server's channels and DMs. You can rejoin if invited again.",
            action: RaftSettingsRecipeButton(
              key: const Key('server-danger-leave-button'),
              label: 'Leave Server',
              variant: RaftButtonRecipeVariant.warning,
              onPressed: confirmLeave,
            ),
          ),
          const SizedBox(height: RaftSpace.x3),
        ],
        if (role == 'owner')
          RaftSettingsActionCard(
            key: const Key('server-danger-delete-card'),
            stacked: true,
            title: 'Delete Server',
            description: 'Permanently remove this server and all its data. This cannot be undone.',
            action: RaftSettingsRecipeButton(
              key: const Key('server-danger-delete-button'),
              label: 'Delete Server',
              glyph: RaftGlyph.trash2,
              glyphSize: 14,
              variant: RaftButtonRecipeVariant.danger,
              expand: true,
              onPressed: confirmDelete,
            ),
          ),
        const SizedBox(height: RaftSpace.x6),
      ],
    );
  }
}

/// DangerZoneSection delete confirmation body: `space-y-4`, warning copy
/// with the bold server name, then "Type `slug` to confirm:" over SlugInput.
class _DeleteServerConfirm extends StatefulWidget {
  const _DeleteServerConfirm({
    required this.name,
    required this.slug,
    required this.matches,
  });
  final String name, slug;
  final ValueNotifier<bool> matches;
  @override
  State<_DeleteServerConfirm> createState() => _DeleteServerConfirmState();
}

class _DeleteServerConfirmState extends State<_DeleteServerConfirm> {
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final text = RaftSettingsText(t);
    // `<span className="font-bold">` inside the dialog copy.
    final bold = RaftConfirmDialog.messageStyle(t)
        .merge(text.title)
        .copyWith(
          fontSize: RaftConfirmDialog.messageStyle(t).fontSize,
          height: RaftConfirmDialog.messageStyle(t).height,
          color: RaftConfirmDialog.messageStyle(t).color,
        );
    // `text-sm text-foreground-muted theme-brutal:text-black/60 mb-2`
    final prompt = text.bodyMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: raftText(context, 'This will permanently delete '),
              ),
              TextSpan(text: widget.name, style: bold),
              TextSpan(
                text: raftText(
                  context,
                  ' and all its data (agents, channels, messages). This cannot be undone.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: RaftSpace.x4),
        Text.rich(
          // CSS gives the inline mono span the paragraph's 20px line box.
          strutStyle: StrutStyle.fromTextStyle(prompt, forceStrutHeight: true),
          TextSpan(
            style: prompt,
            children: [
              TextSpan(text: raftText(context, 'Type ')),
              TextSpan(text: widget.slug, style: text.monoBold),
              TextSpan(text: raftText(context, ' to confirm:')),
            ],
          ),
        ),
        const SizedBox(height: RaftSpace.x2),
        RaftSettingsPrefixedInput(
          key: const Key('server-delete-slug-input'),
          prefix: '/',
          placeholder: widget.slug,
          mono: true,
          // Inherits the confirm copy's `text-foreground-muted`.
          textColor: RaftConfirmDialog.messageStyle(t).color,
          onChanged: (v) => widget.matches.value = v == widget.slug,
        ),
      ],
    );
  }
}

/// Workspace push mode and invitations (Administration).
class MembersView extends StatefulWidget {
  const MembersView({
    super.key,
    required this.controller,
    this.mobileRoot = false,
    this.onOpenProfile,
  });
  final WorkspaceController controller;
  final bool mobileRoot;
  final ValueChanged<String>? onOpenProfile;
  @override
  State<MembersView> createState() => _MembersViewState();
}

class _MembersViewState extends State<MembersView> {
  WorkspaceController get w => widget.controller;
  List<Map<String, dynamic>> members = [];
  bool loading = true;
  String? error;
  StreamSubscription<RaftEvent>? events;
  @override
  void initState() {
    super.initState();
    load();
    events = w.client.events.listen((event) {
      if (event.name.startsWith('server:member')) load();
    });
  }

  @override
  void dispose() {
    events?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final generation = w.client.generation;
    try {
      final result = await w.query('/servers/${w.server!.id}/members');
      if (mounted && generation == w.client.generation) {
        setState(
          () =>
              members = [for (final p in result) Map<String, dynamic>.from(p)],
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> profile(Map<String, dynamic> member) async {
    if (widget.onOpenProfile != null) {
      final id = member['userId'] ?? member['id'];
      if (id is String && w.can('viewMembers')) widget.onOpenProfile!(id);
      return;
    }
    try {
      final value = await w.query(
        '/servers/${w.server!.id}/members/${member['userId'] ?? member['id']}/profile',
      );
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${value['displayName'] ?? value['name']}'),
          content: SelectableText(
            '${value['description'] ?? ''}\n\n${value['email'] ?? ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(raftText(context, 'Close')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> change(Map<String, dynamic> member, String role) async {
    final id = member['userId'] ?? member['id'],
        server = w.server!.id,
        name = '${member['displayName'] ?? member['name']}';
    await showDialog(
      context: context,
      builder: (_) => RaftFormDialog(
        title: role == 'remove'
            ? raftFormat(context, 'Remove {name}?', {'name': name})
            : raftText(context, 'Change role?'),
        description: role == 'remove'
            ? raftFormat(
                context,
                'Remove this member from {workspace}. They will lose workspace access.',
                {'workspace': w.server!.name},
              )
            : raftFormat(context, 'Make {name} a {role} in {workspace}.', {
                'name': name,
                'role': raftText(
                  context,
                  '${role[0].toUpperCase()}${role.substring(1)}',
                ),
                'workspace': w.server!.name,
              }),
        fields: [],
        submitLabel: role == 'remove' ? 'Remove' : 'Confirm',
        destructive: role == 'remove',
        onSubmit: (_) async {
          await w.command(
            role == 'remove' ? 'DELETE' : 'PATCH',
            '/servers/$server/members/$id',
            data: role == 'remove' ? null : {'role': role},
          );
        },
      ),
    );
    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (widget.mobileRoot)
        RaftMobileRootHeader(
          title: 'Members',
          actions: [
            RaftIconButton(
              tooltip: 'Refresh members',
              onPressed: load,
              glyph: RaftGlyph.refreshCw,
            ),
          ],
        ),
      Expanded(
        child: loading
            ? Center(child: CircularProgressIndicator())
            : ListView(
                padding: raftScrollPadding(context, const EdgeInsets.all(24)),
                children: [
                  if (!widget.mobileRoot)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            raftText(context, 'Members'),
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                        RaftTooltip(
                          message: raftText(context, 'Refresh members'),
                          child: IconButton(
                            onPressed: load,
                            icon: const Icon(Icons.refresh),
                          ),
                        ),
                      ],
                    ),
                  if (error != null)
                    Semantics(liveRegion: true, child: Text(error!)),
                  for (final member in members)
                    ListTile(
                      leading: RaftAvatar(
                        name: '${member['displayName'] ?? member['name']}',
                      ),
                      title: Text('${member['displayName'] ?? member['name']}'),
                      subtitle: Text(
                        '${member['role']} · ${member['email'] ?? ''}',
                      ),
                      onTap: () => profile(member),
                      trailing:
                          w.can('changeMemberRoles') || w.can('removeMembers')
                          ? RaftTooltip(
                              message: raftText(context, 'Member actions'),
                              child: PopupMenuButton<String>(
                                onSelected: (role) => change(member, role),
                                itemBuilder: (_) => [
                                  if (w.can('changeMemberRoles')) ...[
                                    for (final role
                                        in w.server!.string('role') == 'owner'
                                            ? [
                                                'owner',
                                                'admin',
                                                'member',
                                                'guest',
                                              ]
                                            : ['member', 'guest'])
                                      PopupMenuItem(
                                        value: role,
                                        child: Text(
                                          raftFormat(context, 'Make {role}', {
                                            'role': raftText(
                                              context,
                                              '${role[0].toUpperCase()}${role.substring(1)}',
                                            ),
                                          }),
                                        ),
                                      ),
                                  ],
                                  if (w.can('removeMembers') &&
                                      member['userId'] != w.client.user!.id)
                                    PopupMenuItem(
                                      value: 'remove',
                                      child: Text(
                                        raftText(context, 'Remove member'),
                                      ),
                                    ),
                                ],
                              ),
                            )
                          : null,
                    ),
                ],
              ),
      ),
    ],
  );
}
