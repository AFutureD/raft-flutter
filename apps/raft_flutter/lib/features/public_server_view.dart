// The Public server page (Web pages/PublicServerPage.tsx): the read-only
// preview of a public server reached from `/s/<slug>` by someone who is not a
// member, signed out (sign in / create account) or signed in (Join as Guest).
// Data lifecycle follows the Web reducer: the server readback loads on mount
// (404 means unavailable), the first public channel (or the linked one) is
// selected, its latest 50 messages load on selection and older pages on
// demand, and a thread opens its own read-only panel.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/source_time_formatter.dart';
import '../platform/content_links.dart';
import 'management_support.dart';
import 'sender_avatar_projection.dart';

/// A message of the public readback (`PublicMessage`).
@immutable
class PublicServerMessage {
  const PublicServerMessage({
    required this.id,
    required this.senderType,
    required this.author,
    required this.content,
    required this.createdAt,
    required this.messageType,
    this.description,
    this.avatarUrl,
    this.threadId,
    this.replyCount = 0,
  });

  factory PublicServerMessage.fromJson(Map<String, dynamic> json) {
    final sender = managementMap(json['sender']);
    return PublicServerMessage(
      id: '${json['id']}',
      senderType: '${json['senderType']}',
      author: '${sender['displayName'] ?? ''}',
      description: sender['description'] as String?,
      avatarUrl: sender['avatarUrl'] as String?,
      messageType: '${json['messageType'] ?? 'chat'}',
      content: '${json['content'] ?? ''}',
      createdAt: DateTime.tryParse('${json['createdAt']}'),
      threadId: json['threadId'] as String?,
      replyCount: int.tryParse('${json['replyCount']}') ?? 0,
    );
  }
  final String id, senderType, author, content, messageType;
  final String? description, avatarUrl, threadId;
  final DateTime? createdAt;
  final int replyCount;

  /// `toReadOnlyMessage`: a display-local key; the public DTO exposes no
  /// authority-bearing identifier.
  String get senderKey => 'public:$senderType:$author:${avatarUrl ?? ''}';
}

/// What the page needs from the account when the visitor is signed in.
@immutable
class PublicServerAccount {
  const PublicServerAccount({required this.servers, required this.onSelect});

  /// The visitor's servers for the rail switcher.
  final List<RaftRecord> servers;

  /// Switch to one of [servers].
  final void Function(RaftRecord server) onSelect;
}

class PublicServerView extends StatefulWidget {
  const PublicServerView({
    super.key,
    required this.client,
    required this.slug,
    required this.onSignIn,
    required this.onRegister,
    required this.onUnavailable,
    this.initialChannelId,
    this.account,
    this.onJoined,
    this.appVersion,
    this.documentationUrl = 'https://docs.raft.build',
  });
  final RaftClient client;
  final String slug;

  /// Channel from a `/s/<slug>/channel/<id>` link; ignored unless public.
  final String? initialChannelId;
  final VoidCallback onSignIn, onRegister, onUnavailable;

  /// Set when signed in: Join as Guest replaces Sign in / Create account.
  final PublicServerAccount? account;

  /// After a guest join: reload the server list and open the server. A
  /// failure here never reads as a failed join (membership is durable).
  final Future<void> Function()? onJoined;
  final String? appVersion;
  final String documentationUrl;
  @override
  State<PublicServerView> createState() => _PublicServerViewState();
}

class _PublicServerViewState extends State<PublicServerView> {
  bool get authenticated => widget.account != null;
  Map<String, dynamic>? server;
  List<Map<String, dynamic>> channels = [];
  bool canJoin = false;
  String? selectedId;
  List<PublicServerMessage> messages = [];
  bool loadingMessages = false, hasOlder = false;
  String error = '';
  int serverRequest = 0, messageRequest = 0;

  bool settings = false;
  bool selectionNotice = false;
  final menu = RaftMenuController();

  // Thread panel.
  String? threadChannelId, threadParentId;
  List<PublicServerMessage> threadMessages = [];
  bool threadLoading = false, threadHasOlder = false;
  String threadError = '';
  int threadRequest = 0;

  // Join flow.
  bool joining = false;
  String joinError = '';

  String get base => '/public/servers/${Uri.encodeComponent(widget.slug)}';
  String tr(String s) => raftText(context, s);

  @override
  void initState() {
    super.initState();
    menu.addListener(menuChanged);
    unawaited(loadServer());
  }

  @override
  void didUpdateWidget(PublicServerView old) {
    super.didUpdateWidget(old);
    if (old.slug != widget.slug || old.client != widget.client) {
      unawaited(loadServer());
    }
  }

  @override
  void dispose() {
    menu.removeListener(menuChanged);
    menu.dispose();
    super.dispose();
  }

  /// The anonymous rail logo answers with the sign-in notice instead of the
  /// server menu (`onAnonymousServerSelection`).
  void menuChanged() {
    if (menu.isOpen && !authenticated) {
      menu.close();
      setState(() => selectionNotice = true);
    }
  }

  Future<void> loadServer() async {
    final request = ++serverRequest;
    setState(() {
      server = null;
      channels = [];
      selectedId = null;
      messages = [];
      loadingMessages = false;
      hasOlder = false;
      error = '';
      threadChannelId = null;
    });
    try {
      final data = managementMap(await widget.client.get(base));
      if (!mounted || request != serverRequest) return;
      final list = managementRows(data['channels']);
      final linked = list
          .where((c) => c['id'] == widget.initialChannelId)
          .firstOrNull;
      setState(() {
        server = managementMap(data['server']);
        channels = list;
        canJoin = data['canJoinAsGuest'] == true;
        selectedId = '${(linked ?? list.firstOrNull)?['id'] ?? ''}'.isEmpty
            ? null
            : '${(linked ?? list.first)['id']}';
      });
      unawaited(loadMessages());
    } on RaftApiException catch (e) {
      if (!mounted || request != serverRequest) return;
      if (e.status == 404) {
        widget.onUnavailable();
        return;
      }
      setState(
        () => error = e.message.isNotEmpty
            ? e.message
            : tr('Failed to load this public server'),
      );
    } catch (_) {
      if (mounted && request == serverRequest) {
        setState(() => error = tr('Failed to load this public server'));
      }
    }
  }

  String messageFailure(Object e) => e is RaftApiException && e.status == 404
      ? tr('This server or channel is no longer public.')
      : e is RaftApiException && e.message.isNotEmpty
      ? e.message
      : tr('Failed to load public messages');

  Future<void> loadMessages() async {
    final id = selectedId;
    if (id == null) return;
    final request = ++messageRequest;
    setState(() {
      loadingMessages = true;
      error = '';
    });
    try {
      final data = managementMap(
        await widget.client.get('$base/channels/$id/messages'),
      );
      if (!mounted || request != messageRequest) return;
      final rows = managementRows(
        data['messages'],
      ).map(PublicServerMessage.fromJson).toList();
      setState(() {
        loadingMessages = false;
        messages = rows;
        hasOlder = rows.length == 50;
      });
    } catch (e) {
      if (mounted && request == messageRequest) {
        setState(() {
          loadingMessages = false;
          error = messageFailure(e);
        });
      }
    }
  }

  Future<void> loadOlder() async {
    final id = selectedId;
    if (id == null || messages.isEmpty) return;
    setState(() {
      loadingMessages = true;
      error = '';
    });
    try {
      final data = managementMap(
        await widget.client.get(
          '$base/channels/$id/messages',
          query: {'beforeMessageId': messages.first.id},
        ),
      );
      if (!mounted || selectedId != id) return;
      final rows = managementRows(
        data['messages'],
      ).map(PublicServerMessage.fromJson).toList();
      setState(() {
        loadingMessages = false;
        messages = [...rows, ...messages];
        hasOlder = rows.length == 50;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loadingMessages = false;
          error = messageFailure(e);
        });
      }
    }
  }

  void selectChannel(String id) {
    if (id == selectedId && !settings) return;
    setState(() {
      selectedId = id;
      messages = [];
      hasOlder = false;
      threadChannelId = null;
      settings = false;
    });
    unawaited(loadMessages());
  }

  Future<void> openThread(PublicServerMessage parent) async {
    final id = parent.threadId;
    if (id == null) return;
    final request = ++threadRequest;
    setState(() {
      threadChannelId = id;
      threadParentId = parent.id;
      threadMessages = [];
      threadError = '';
      threadHasOlder = false;
      threadLoading = true;
    });
    try {
      final data = managementMap(
        await widget.client.get(
          '$base/threads/${Uri.encodeComponent(id)}/messages',
          query: {'limit': 50},
        ),
      );
      if (!mounted || request != threadRequest) return;
      final rows = managementRows(
        data['messages'],
      ).map(PublicServerMessage.fromJson).toList();
      setState(() {
        threadMessages = rows;
        threadHasOlder = rows.length == 50;
      });
    } catch (e) {
      if (mounted && request == threadRequest) {
        setState(() => threadError = threadFailure(e));
      }
    } finally {
      if (mounted && request == threadRequest) {
        setState(() => threadLoading = false);
      }
    }
  }

  String threadFailure(Object e) => e is RaftApiException && e.status == 404
      ? tr('This server or channel is no longer public.')
      : e is RaftApiException && e.message.isNotEmpty
      ? e.message
      : tr("Couldn't load this thread");

  Future<void> loadOlderThread() async {
    final id = threadChannelId;
    if (id == null || threadLoading || threadMessages.isEmpty) return;
    final request = threadRequest;
    setState(() => threadLoading = true);
    try {
      final data = managementMap(
        await widget.client.get(
          '$base/threads/${Uri.encodeComponent(id)}/messages',
          query: {'limit': 50, 'beforeMessageId': threadMessages.first.id},
        ),
      );
      if (!mounted || request != threadRequest) return;
      final rows = managementRows(
        data['messages'],
      ).map(PublicServerMessage.fromJson).toList();
      setState(() {
        threadMessages = [...rows, ...threadMessages];
        threadHasOlder = rows.length == 50;
      });
    } catch (e) {
      if (mounted && request == threadRequest) {
        setState(() => threadError = threadFailure(e));
      }
    } finally {
      if (mounted && request == threadRequest) {
        setState(() => threadLoading = false);
      }
    }
  }

  void closeThread() {
    threadRequest++;
    setState(() => threadChannelId = null);
  }

  /// `joinAsGuest`: the confirm and agreement dialogs both end here. Returns
  /// the agreement the server asks to accept first (`agreement_required` /
  /// `agreement_changed`), null once joined; a failure rethrows.
  Future<Map<String, dynamic>?> joinAsGuest([String? agreementId]) async {
    setState(() {
      joining = true;
      joinError = '';
    });
    try {
      await widget.client.post(
        '$base/join-as-guest',
        data: {'agreementId': agreementId},
      );
    } on RaftApiException catch (e) {
      final body = e.details['agreement'];
      final code = e.details['code'] ?? e.message;
      if (mounted) {
        final asked =
            (code == 'agreement_required' || code == 'agreement_changed') &&
            body is Map;
        setState(() {
          joining = false;
          if (!asked) {
            joinError = e.message.isNotEmpty
                ? e.message
                : tr('Failed to join this public server');
          }
        });
        if (asked) return Map<String, dynamic>.from(body);
      }
      rethrow;
    }
    try {
      await widget.onJoined?.call();
    } catch (_) {
      // Membership is already durable: never invite an unsafe retry because
      // the local refresh or route transition failed.
      if (mounted) {
        setState(
          () => joinError = tr(
            'You joined this server. Refresh the page to open it.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => joining = false);
    }
    return null;
  }

  /// The Join as Guest confirm; an agreement answer continues in its dialog.
  Future<void> startJoin() async {
    Map<String, dynamic>? asked;
    await RaftConfirmDialog.show(
      context,
      RaftConfirmDialog(
        title: tr('Join this server?'),
        message: raftFormat(
          context,
          'You will join {server} as a Guest. You can keep reading without joining by cancelling.',
          {'server': '${server?['name'] ?? widget.slug}'},
        ),
        confirmLabel: tr('Join as Guest'),
        loadingLabel: tr('Joining…'),
        confirmVariant: RaftButtonRecipeVariant.accent,
        confirmKey: const ValueKey('public-join-confirm'),
        onConfirm: () async => asked = await joinAsGuest(),
      ),
    );
    if (asked != null && mounted) await showAgreement(asked!);
  }

  Future<void> showAgreement(Map<String, dynamic> first) async {
    var current = first;
    var submitting = false;
    String? failure;
    await showRaftModal<void>(
      context,
      builder: (modal) => StatefulBuilder(
        builder: (modal, update) => RaftPublicAgreementDialog(
          title: '${current['title']}',
          version: raftFormat(modal, 'Version {version}', {
            'version': current['version'],
          }),
          body: RaftAgreementBody(source: '${current['bodyMarkdown'] ?? ''}'),
          error: failure,
          submitting: submitting,
          onClose: () => Navigator.of(modal).pop(),
          onAgree: () async {
            update(() {
              submitting = true;
              failure = null;
            });
            try {
              final next = await joinAsGuest('${current['id']}');
              if (next == null) {
                if (modal.mounted) Navigator.of(modal).pop();
                return;
              }
              if (modal.mounted) {
                update(() {
                  current = next;
                  submitting = false;
                });
              }
            } catch (_) {
              if (modal.mounted) {
                update(() {
                  submitting = false;
                  failure = raftText(modal, 'Failed to join community server');
                });
              }
            }
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- build

  /// Web's public page formats with the browser's zone and clock: the
  /// account's time preferences are not applied to it.
  SourceTimeFormatter get timeFormatter => SourceTimeFormatter(
    locale: Localizations.localeOf(context).toLanguageTag(),
    systemTimeFormat: MediaQuery.alwaysUse24HourFormatOf(context)
        ? SourceTimeFormat.twentyFourHour
        : null,
    todayLabel: tr('Today'),
    yesterdayLabel: tr('Yesterday'),
  );

  /// `#channel` mentions of the public channels chip like Web's MessageItem
  /// (`channels={displayChannels}`); users and agents are not linkable here.
  List<RaftTextReference> get channelReferences => [
    for (final c in channels)
      RaftTextReference(
        text: '#${c['name']}',
        href: Uri(
          scheme: 'raft-ref',
          host: 'channel',
          pathSegments: ['${c['id']}'],
        ).toString(),
        identityBacked: true,
      ),
  ];

  /// `onReadOnlyNavigateChannel`: a channel chip selects that public channel.
  void openReference(String href) {
    final uri = Uri.tryParse(href);
    if (uri != null &&
        uri.scheme == 'raft-ref' &&
        uri.host == 'channel' &&
        uri.pathSegments.length == 1) {
      selectChannel(uri.pathSegments.single);
      return;
    }
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      unawaited(managementLaunch(href));
    }
  }

  Widget avatar(PublicServerMessage m) {
    final source = projectSenderAvatar(
      origin: widget.client.origin,
      senderId: m.senderKey,
      senderType: m.senderType,
      agents: const [],
      members: const [],
      carriedAvatarUrl: m.avatarUrl,
    );
    final kind = switch (source.kind) {
      'agent' => RaftAvatarKind.agent,
      'app' => RaftAvatarKind.app,
      _ => RaftAvatarKind.human,
    };
    const context = RaftMountedAvatarContext.panelHeader;
    final identity = switch (kind) {
      RaftAvatarKind.agent => RaftMountedAvatarIdentity.agent,
      RaftAvatarKind.app => RaftMountedAvatarIdentity.app,
      _ => RaftMountedAvatarIdentity.human,
    };
    return RaftAvatar(
      name: m.author,
      kind: kind,
      mountedContext: context,
      // Public agents carry no live state: the offline dot Web draws.
      presence: kind == RaftAvatarKind.agent
          ? const RaftAvatarPresence(activity: RaftAvatarActivity.offline)
          : null,
      content: RaftAvatarContent(
        name: m.author,
        kind: switch (kind) {
          RaftAvatarKind.agent => RaftAvatarContentKind.agent,
          RaftAvatarKind.app => RaftAvatarContentKind.app,
          _ => RaftAvatarContentKind.human,
        },
        uploadedUrl: source.uploadedUrl,
        gravatarUrl: source.gravatarUrl,
        pixelKey: source.pixelKey,
        fallback: RaftMountedAvatarFallback(
          avatarContext: context,
          gravatar: source.gravatarUrl != null,
          identity: identity,
        ),
      ),
    );
  }

  Widget row(
    PublicServerMessage m, {
    bool thread = false,
    bool parent = false,
    VoidCallback? onThread,
  }) {
    final formatter = timeFormatter;
    if (m.messageType == 'system') {
      return RaftSystemMessage(
        key: ValueKey('public-message-${m.id}'),
        content: m.content,
        timestamp: m.createdAt == null
            ? ''
            : formatter.messageTime(m.createdAt!),
      );
    }
    return RaftMessageTile(
      key: ValueKey('public-message-${m.id}'),
      rowContext: thread
          ? RaftMessageRowContext.thread
          : RaftMessageRowContext.main,
      author: m.author,
      avatar: avatar(m),
      subtitle: m.description,
      content: m.content,
      body: RaftMessageBody(
        mountedMessage: true,
        content: m.content,
        references: channelReferences,
        onLink: openReference,
      ),
      timestamp: m.createdAt == null ? '' : formatter.messageTime(m.createdAt!),
      threadRepliesBadge:
          !parent && !thread && m.threadId != null && m.replyCount > 0
          ? RaftThreadRepliesBadge(
              key: ValueKey('public-thread-open-${m.id}'),
              replyCount: m.replyCount,
              onPressed: onThread,
            )
          : null,
    );
  }

  Widget? get threadPanel {
    final id = threadChannelId;
    if (id == null) return null;
    final parent = messages.where((m) => m.id == threadParentId).firstOrNull;
    if (parent == null) return null;
    final channel = channels.where((c) => c['id'] == selectedId).firstOrNull;
    final wide = MediaQuery.sizeOf(context).width >= 1024;
    return RaftPublicThreadPanel(
      title: tr('Thread'),
      channelContext: raftFormat(context, ' — #{name}', {
        'name': channel?['name'],
      }),
      closeLabel: tr('Close thread'),
      onClose: closeThread,
      showClose: wide,
      parent: row(parent, parent: true),
      replies: [for (final m in threadMessages) row(m, thread: true)],
      loading: threadLoading,
      error: threadError.isEmpty ? null : threadError,
      emptyTitle: tr('No replies yet'),
      onLoadOlder: threadHasOlder ? loadOlderThread : null,
      loadOlderLabel: tr('Load older messages'),
    );
  }

  Widget channelPanel() {
    final channel = channels.where((c) => c['id'] == selectedId).firstOrNull;
    if (channel == null) {
      return RaftPublicEmptyMessage(
        'This server has no public channels right now.',
        hint: false,
      );
    }
    final description = channel['description'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RaftPublicChannelHeader(
          name: '${channel['name']}',
          description: description ?? '',
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(RaftSpace.x3),
            child: RaftConnectedAppsError(error),
          ),
        Expanded(
          child: messages.isEmpty
              ? loadingMessages
                    ? RaftPublicEmptyMessage('Loading…', hint: false)
                    : RaftPublicEmptyMessage(
                        'No messages have been posted here yet.',
                      )
              : ListView(
                  key: const ValueKey('public-server-message-timeline'),
                  children: [
                    if (hasOlder)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: RaftSpace.x3,
                        ),
                        child: Center(
                          child: RaftSettingsRecipeButton(
                            label: 'Load older messages',
                            size: RaftButtonRecipeSize.xs,
                            onPressed: loadingMessages ? null : loadOlder,
                          ),
                        ),
                      ),
                    for (final m in messages)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: RaftSpace.x3,
                        ),
                        child: RaftPublicMessageRow(
                          child: row(m, onThread: () => openThread(m)),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget settingsSurface() {
    final api = widget.client.origin;
    final web = ContentLinks.originFor(api);
    return Row(
      key: const ValueKey('public-server-settings-surface'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RaftPublicSettingsSidebar(
          title: tr('Settings'),
          child: RaftSettingsSidebarList(
            activeId: 'about',
            groups: [
              RaftSettingsNavGroup('Resources', [
                RaftSettingsNavEntry(
                  id: 'about',
                  label: tr('About'),
                  glyph: RaftGlyph.badgeInfo,
                  onTap: () {},
                ),
                RaftSettingsNavEntry(
                  id: 'documentation',
                  label: tr('Documentation'),
                  glyph: RaftGlyph.bookOpenText,
                  onTap: () =>
                      unawaited(managementLaunch(widget.documentationUrl)),
                ),
              ]),
            ],
          ),
        ),
        Expanded(
          child: RaftSettingsPanelFrame(
            header: RaftSettingsPanelHeader(
              title: tr('About'),
              glyph: RaftGlyph.badgeInfo,
              mobile: false,
            ),
            child: SingleChildScrollView(
              padding: RaftSettingsPanelFrame.contentInset,
              child: RaftSettingsAbout(
                version: widget.appVersion ?? 'development',
                mobileApp: RaftAboutMobileApp(
                  onAndroid: () => unawaited(
                    managementLaunch(
                      '$api/api/mobile-download?platform=android',
                    ),
                  ),
                  onIos: () => unawaited(
                    managementLaunch('$api/api/mobile-download?platform=ios'),
                  ),
                  qrUrl: '${web.origin}/download',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget rail() {
    final name = '${server?['name'] ?? widget.slug}';
    final account = widget.account;
    final initial = name.trim().isEmpty
        ? 'S'
        : name.trim().characters.first.toUpperCase();
    return RaftPublicRail(
      chatLabel: tr('Chat'),
      settingsLabel: tr('Settings'),
      chatSelected: !settings,
      settingsSelected: settings,
      onChat: () => setState(() => settings = false),
      onSettings: () => setState(() => settings = true),
      header: RaftServerSwitcher(
        controller: menu,
        workspaceName: name,
        label: tr('Switch workspace'),
        logo: RaftPublicServerLogo(
          initial: initial,
          avatarUrl: server?['avatarUrl'] as String?,
        ),
        rows: [
          if (account != null)
            for (final s in account.servers)
              RaftServerMenuRow(
                id: s.id,
                name: s.name,
                slug: s.string('slug'),
                avatarUrl: s.json['avatarUrl'] as String?,
                onSelected: () => account.onSelect(s),
              ),
        ],
        actions: const [],
      ),
      help: account == null
          ? null
          : RaftWorkspaceHelpMenu(
              key: const ValueKey('public-rail-help'),
              label: tr('Help'),
              heading: tr('Help & resources'),
              entries: [
                RaftMenuEntry(
                  label: tr('Raft Documentation'),
                  leading: const RaftIcon(RaftGlyph.bookOpenText, size: 14),
                  trailing: const RaftIcon(RaftGlyph.arrowUpRight, size: 14),
                  onPressed: () =>
                      unawaited(managementLaunch(widget.documentationUrl)),
                ),
                RaftMenuEntry(
                  label: tr('Mobile App'),
                  glyph: RaftGlyph.smartphone,
                  onPressed: () => setState(() => settings = true),
                ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (server == null && error.isEmpty) {
      return RaftPublicServerLoading(label: tr('Loading…'));
    }
    final name = '${server?['name'] ?? widget.slug}';
    final band = raftBreakpointWidth(context);
    final thread = settings ? null : threadPanel;
    final message = authenticated
        ? canJoin
              ? 'Join {server} as a Guest to be part of the discussion.'
              : "{server} is view only. You can read its public channels, but can't send messages here."
        : canJoin
        ? 'Sign in to join {server} and be part of the discussion.'
        : '{server} is view only. Create a Raft account to build a server of your own.';
    final actions = authenticated
        ? [
            if (canJoin)
              RaftPublicActionButton(
                key: const ValueKey('public-join-guest'),
                label: tr('Join as Guest'),
                glyph: RaftGlyph.userPlus,
                accent: true,
                onPressed: joining ? null : startJoin,
              ),
          ]
        : [
            RaftPublicActionButton(
              label: tr('Sign in'),
              glyph: RaftGlyph.logIn,
              accent: canJoin,
              onPressed: widget.onSignIn,
            ),
            RaftPublicActionButton(
              label: tr('Create account'),
              glyph: RaftGlyph.userPlus,
              accent: !canJoin,
              onPressed: widget.onRegister,
            ),
          ];
    final columns = settings
        ? settingsSurface()
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RaftPublicChannelSidebar(
                serverName: name,
                channels: [
                  for (final c in channels)
                    RaftPublicServerChannel(
                      id: '${c['id']}',
                      name: '${c['name']}',
                    ),
                ],
                selectedId: selectedId,
                onSelect: selectChannel,
                label: tr('Public channels'),
              ),
              Expanded(child: RaftPublicSurface(child: channelPanel())),
              if (thread != null && band >= 640)
                RaftPublicThreadColumn(child: thread),
            ],
          );
    return RaftPublicServerLayout(
      rail: band >= 768 && server != null ? rail() : null,
      columns: columns,
      threadOverlay: thread != null && band < 640 ? thread : null,
      banner: RaftPublicBottomBanner(
        message: raftFormat(context, message, {'server': name}),
        actions: actions,
      ),
      overlays: [
        if (selectionNotice)
          RaftPublicFloatingBanner(
            key: const ValueKey('public-server-selection-notice'),
            top: true,
            message: tr(
              'You are viewing public channels without signing in. Sign in or create an account to continue in Raft.',
            ),
            action: RaftSettingsRecipeButton(
              label: tr('Sign in'),
              size: RaftButtonRecipeSize.xs,
              onPressed: widget.onSignIn,
            ),
          ),
        if (joinError.isNotEmpty)
          RaftPublicFloatingBanner(
            key: const ValueKey('public-server-join-error'),
            top: false,
            warning: true,
            message: joinError,
          ),
      ],
    );
  }
}
