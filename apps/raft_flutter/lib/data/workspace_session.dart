import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_sync/raft_sync.dart';

import 'attachment_image_repository.dart';
import 'burst_reads.dart';
import 'channel_revocation.dart';
import 'feature_flag_client_facts.dart';
import 'source_activity_unread_store.dart';
import 'user_error.dart';
import 'workspace_domain_ports.dart';
import 'workspace_entity_directory.dart';
import 'workspace_session_bindings.dart';
import 'workspace_session_context.dart';

/// Receiver-local session, directory, connection and feature-flag policy.
/// The composition root supplies separate typed ports; it is never retained as
/// an untyped controller or used to discover unrelated domain state.
class WorkspaceSession
    implements WorkspaceSessionEffectsPort, WorkspaceConnectionProgressPort {
  WorkspaceSession({
    required this.context,
    required this.transport,
    required this.device,
    required this.entries,
    required this.directory,
    required this.presentation,
    required this.messages,
    required this.drafts,
    required this.entities,
    required this.revocations,
    required this.quietFailure,
    required this.staleScope,
    required this.ownsClient,
  });
  final WorkspaceSessionContext context;
  final WorkspaceTransportPort transport;
  final WorkspaceDevicePort device;
  final WorkspaceSessionEntries entries;
  final WorkspaceSessionChannels directory;
  final WorkspaceSessionPresentation presentation;
  final WorkspaceSessionMessages messages;
  final WorkspaceSessionDrafts drafts;
  final WorkspaceSessionEntities entities;
  final WorkspaceSessionRevocations revocations;
  final bool Function(Object) quietFailure, staleScope;
  final bool ownsClient;

  List<RaftRecord> servers = [];
  RaftRecord? server;
  bool connected = false;
  bool syncCoreMessagesEnabled = false;
  @override
  bool syncCoreNotificationPrefsEnabled = false;
  bool remoteComputerUpgradeEnabled = false;
  bool agentMigrationEnabled = false, runtimeFormV2WebEnabled = false;
  int _messageFlagRequest = 0;
  // ignore: raft_lints/avoid_unreleased_resource -- The composition root disposes this notifier at the original ordered disposal stage.
  final resumes = ValueNotifier<int>(0);
  late final StreamSubscription<RaftEvent> subscription;
  bool _roomsJoinedPending = false, _connectedBefore = false;
  DateTime? _lastHeartbeat, _lastServerEvent;
  (int, BigInt)? _gapSyncedThrough;
  final _burstAt = BurstReads();
  int _membershipRevision = 0, _membershipRequest = 0;
  int planRevision = 0;
  static const remoteComputerUpgradeFlag = 'remote_computer_upgrade_v2';
  static const agentMigrationFlag = 'agent_migration_v0';
  static const runtimeFormV2WebFlag = 'runtime_form_v2_web';
  static const _burstFreshness = Duration(seconds: 15);
  static const _membershipResumeFreshness = Duration(seconds: 60);
  static const presenceEvents = {
    'agent:activity',
    'agent:seen',
    'agent:session',
    'machine:status',
    'machine:capabilities',
  };

  RaftClient get client => transport.client;
  WorkspaceEntityDirectory get entityDirectory => entities.entityDirectory;
  SourceActivityUnreadStore? get activityUnreadIfBound =>
      entities.activityUnreadIfBound;
  MessageLedger get ledger => messages.ledger;
  MessageSync get messageSync => messages.messageSync;
  ThreadRepliesSync get threadRepliesSync => messages.threadRepliesSync;
  NotificationPrefsSync get notificationPrefsSync =>
      directory.notificationPrefsSync;
  ReadStateLedger get readState => directory.readState;
  List<RaftChannel> get channels => directory.channels;
  set channels(List<RaftChannel> value) => directory.assignChannels(value);
  List<RaftChannel> get dms => directory.dms;
  set dms(List<RaftChannel> value) => directory.assignDms(value);
  set unread(Map<String, int> value) => directory.assignUnread(value);
  set sidebarOrder(Map<String, dynamic> value) =>
      directory.assignSidebarOrder(value);
  RaftChannel? get channel => presentation.channel;
  set channel(RaftChannel? value) => presentation.setSelectedChannel(value);
  String get section => presentation.section;
  set section(String value) => presentation.assignSection(value);
  set error(String? value) => presentation.assignError(value);
  set loading(bool value) => presentation.assignLoading(value);
  bool get mobileNavigation => presentation.mobileNavigation;
  int get navigationRevision => presentation.navigationRevision;
  int get channelGeneration => messages.channelGeneration;
  int get threadGeneration => messages.threadGeneration;
  bool canVisitSection(String value) => presentation.canVisitSection(value);
  @override
  (int, BigInt)? get gapSyncedThrough => _gapSyncedThrough;
  @override
  void assignGapSyncedThrough((int, BigInt)? value) =>
      _gapSyncedThrough = value;
  @override
  void patchServerRows(RaftRecord Function(RaftRecord) patch) {
    servers = servers.map(patch).toList();
    if (server != null) server = patch(server!);
  }

  void attachSubscription(void Function(RaftEvent) receive) {
    subscription = entries.sessionSource == null
        ? client.events.listen(receive)
        : const Stream<RaftEvent>.empty().listen((_) {});
  }

  WorkspaceEntityScope? entityScope() {
    final principal = client.user?.id;
    final serverId = client.serverId;
    if (context.disposed ||
        principal == null ||
        serverId == null ||
        server?.id != serverId) {
      return null;
    }
    return WorkspaceEntityScope(
      origin: client.origin,
      principal: principal,
      serverId: serverId,
      generation: client.generation,
      role: server?.string('role') ?? '',
      capabilities: {
        if (context.can('viewAgents')) WorkspaceEntityKind.agents,
        if (context.can('viewMachines')) WorkspaceEntityKind.computers,
        if (context.can('viewMembers')) WorkspaceEntityKind.members,
      },
    );
  }

  void entityAuthorityChanged() {
    if (context.disposed || !entities.ownsEntityDirectory) return;
    if (entityDirectory.synchronize() && entityDirectory.started) {
      // ignore: raft_lints/avoid_unreviewed_idle_work -- One-shot deferral out of a build or notification; the callback does not schedule another microtask itself.
      scheduleMicrotask(() {
        if (!context.disposed) unawaited(entityDirectory.preload());
      });
    }
  }

  AttachmentImageScope get attachmentImageScope => AttachmentImageScope(
    origin: client.origin,
    principal: client.user?.id ?? '',
    server: client.serverId ?? '',
    generation: client.generation,
    role: server?.string('role') ?? '',
  );

  String? panelCacheIdentity() {
    final principal = client.user?.id;
    final serverId = client.serverId;
    if (context.disposed ||
        principal == null ||
        serverId == null ||
        server?.id != serverId) {
      return null;
    }
    return jsonEncode([
      client.origin,
      principal,
      serverId,
      client.generation,
      server?.string('role'),
    ]);
  }

  String syncIdentity() => jsonEncode([
    client.origin,
    client.generation,
    client.serverId,
    client.user?.id,
    server?.string('role'),
  ]);

  @override
  void ensureSyncIdentity() {
    final next = syncIdentity();
    if (messages.replyIdentity == next) return;
    final hadIdentity = messages.replyIdentity != null;
    _messageFlagRequest++;
    messages.assignReplyIdentity(next);
    threadRepliesSync.reset();
    notificationPrefsSync.reset();
    syncCoreNotificationPrefsEnabled = false;
    if (hadIdentity) messages.clearReplySummaries();
  }

  /// Whether a member list change can change this principal's visibility of
  /// the channel (Source resource views fail closed on the same rule).
  bool membershipScoped(String id) {
    final known = [...channels, ...dms].where((c) => c.id == id).firstOrNull;
    if (known == null) return true;
    return const {'private', 'dm', 'joint', 'thread'}.contains(known.type);
  }

  Future<void> refreshMessageSyncFlag() async {
    ensureSyncIdentity();
    final request = ++_messageFlagRequest;
    final generation = client.generation, principal = client.user?.id;
    final identity = syncIdentity();
    final id = client.serverId;
    if (id == null || principal == null) return;
    try {
      final result = await client.post(
        '/feature-flags/evaluate',
        data: featureFlagEvaluateBody(
          keys: [
            'sync_core_messages_v0',
            notificationPrefsFlag,
            remoteComputerUpgradeFlag,
            agentMigrationFlag,
            runtimeFormV2WebFlag,
          ],
          serverId: id,
        ),
      );
      if (context.disposed ||
          request != _messageFlagRequest ||
          generation != client.generation ||
          principal != client.user?.id ||
          id != client.serverId ||
          identity != syncIdentity()) {
        return;
      }
      final enabled =
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) => f['key'] == 'sync_core_messages_v0' && f['enabled'] == true,
          );
      if (enabled != syncCoreMessagesEnabled) messageSync.reset();
      syncCoreMessagesEnabled = enabled;
      final prefsEnabled =
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) => f['key'] == notificationPrefsFlag && f['enabled'] == true,
          );
      if (prefsEnabled != syncCoreNotificationPrefsEnabled) {
        notificationPrefsSync.reset();
      }
      syncCoreNotificationPrefsEnabled = prefsEnabled;
      remoteComputerUpgradeEnabled =
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) =>
                f['key'] == remoteComputerUpgradeFlag && f['enabled'] == true,
          );
      bool evaluated(String key) =>
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) => f['key'] == key && f['enabled'] == true,
          );
      final migration = evaluated(agentMigrationFlag);
      final runtimeV2 = evaluated(runtimeFormV2WebFlag);
      final flagsChanged =
          migration != agentMigrationEnabled ||
          runtimeV2 != runtimeFormV2WebEnabled;
      agentMigrationEnabled = migration;
      runtimeFormV2WebEnabled = runtimeV2;
      if (flagsChanged) context.changed();
    } catch (_) {
      if (!context.disposed &&
          request == _messageFlagRequest &&
          identity == syncIdentity()) {
        syncCoreNotificationPrefsEnabled = false;
        notificationPrefsSync.reset();
        if (agentMigrationEnabled || runtimeFormV2WebEnabled) {
          agentMigrationEnabled = runtimeFormV2WebEnabled = false;
          context.changed();
        }
      }
      // Unknown capability never authorizes the gated preference path.
    }
  }

  Set<String> get revokedChannels => revocations.revokedChannels;

  Set<String> get revokedServers => revocations.revokedServers;

  void resetServerProjection() {
    messages.resetHistoryLimits();
    presentation.setSelectedChannel(null);
    directory.resetDirectoryAndUnreadProjection();
    messages.resetThreadProjection();
  }

  void revokeServer(String id) => context.transitions.revokeServer(id);

  void closeRevokedServerProjection() {
    server = null;
    sidebarOrder = {};
    error = null;
    _messageFlagRequest++;
    if (ownsClient) client.selectServer(null);
    loading = false;
    messages.closeServerLoading();
  }

  static bool isNotServerMember(Object failure) =>
      failure is RaftApiException &&
      failure.status == 403 &&
      failure.message == 'Not a member of this server';

  bool can(String capability, {RaftChannel? resource}) => raftCan(
    server?.string('role'),
    capability,
    channelCapabilities: resource?.json['channelCapabilities'] is Map
        ? Map<String, dynamic>.from(resource!.json['channelCapabilities'])
        : null,
  );

  Future<bool> loadServerDirectory({
    bool cachedFirst = false,
    void Function()? onCacheMiss,
  }) => _burstAt.directoryRead(() async {
    if (!ownsClient) {
      throw StateError('A borrowed editor cannot load the server directory.');
    }
    final generation = client.generation,
        principal = client.user?.id,
        request = ++_membershipRequest,
        revision = _membershipRevision;
    bool current() =>
        !context.disposed &&
        generation == client.generation &&
        principal == client.user?.id &&
        request == _membershipRequest &&
        revision == _membershipRevision;
    if (principal == null) return false;
    if (client.restoredOffline || cachedFirst) {
      final cached = await device.read('servers', '', server: '');
      if (!current()) return false;
      if (cached is List && cached.isNotEmpty) {
        servers = cached
            .map((row) => RaftRecord(Map<String, dynamic>.from(row)))
            .where((server) => !revokedServers.contains(server.id))
            .toList();
        context.changed();
        if (cachedFirst) unawaited(entries.revalidateServerDirectory());
        return true;
      }
    }
    onCacheMiss?.call();
    final accepted = await client.servers();
    if (!current()) return false;
    revokedServers.removeAll(accepted.map((server) => server.id));
    servers = accepted;
    await device.save(
      'servers',
      '',
      accepted.map((server) => server.json).toList(),
      server: '',
    );
    if (!current()) return false;
    context.changed();
    return true;
  });

  Future<List<RaftChannel>?> cachedChannelDirectory(String serverId) async {
    if (context.disposed || revokedServers.contains(serverId)) return null;
    final cached = await device.read('channels', '', server: serverId);
    if (cached is! Map ||
        context.disposed ||
        revokedServers.contains(serverId)) {
      return null;
    }
    try {
      return [
        for (final key in const ['channels', 'dms'])
          for (final row in cached[key] as List)
            RaftChannel(Map<String, dynamic>.from(row as Map)),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<void> revalidateServerDirectory() => _burstAt.directoryRead(() async {
    final principal = client.user?.id,
        request = ++_membershipRequest,
        revision = _membershipRevision;
    bool current() =>
        !context.disposed &&
        principal != null &&
        principal == client.user?.id &&
        request == _membershipRequest &&
        revision == _membershipRevision;
    await client.sessionValidated;
    if (!current() || client.restoredOffline) return;
    final List<RaftRecord> accepted;
    try {
      accepted = await client.accountServers();
    } catch (_) {
      return;
    }
    if (!current()) return;
    final ids = {for (final s in accepted) s.id};
    for (final held in [...servers]) {
      if (!ids.contains(held.id)) entries.revokeServer(held.id);
    }
    final selected = server;
    if (selected != null && !ids.contains(selected.id)) {
      entries.revokeServer(selected.id);
    }
    revokedServers.removeAll(ids);
    servers = accepted;
    device.save(
      'servers',
      '',
      accepted.map((s) => s.json).toList(),
      server: '',
    );
    final held = server;
    final fresh = held == null
        ? null
        : accepted.where((s) => s.id == held.id).firstOrNull;
    if (held != null && fresh != null) {
      final role = fresh.string('role');
      if (role != held.string('role')) {
        entries.applyMembershipRole({
          'userId': principal,
          'serverId': held.id,
          'role': role,
        });
        server = fresh;
        context.changed();
        await directory.refreshChannels();
        final open = channel;
        if (!context.disposed && open != null && server?.id == held.id) {
          unawaited(
            messages.selectChannel(
              open,
              navigate: false,
              preserveThread: true,
              autoRead: false,
            ),
          );
        }
        return;
      }
      if (jsonEncode(fresh.json) != jsonEncode(held.json)) server = fresh;
    }
    context.changed();
  });

  Future<void> bootstrap() async {
    final source = entries.sessionSource;
    if (source != null) {
      return source.bootstrap();
    }
    if (!ownsClient) {
      throw StateError('A borrowed editor cannot bootstrap a session.');
    }
    loading = true;
    error = null;
    context.changed();
    try {
      final cached = await device.read('servers', '', server: '');
      if (cached is List) {
        servers = cached
            .map((e) => RaftRecord(Map<String, dynamic>.from(e)))
            .where((s) => !revokedServers.contains(s.id))
            .toList();
      }
      context.changed();
      if (servers.isNotEmpty && client.restoredOffline) {
        await entries.selectServer(servers.first);
        return;
      }
      servers = await client.servers();
      revokedServers.removeAll(servers.map((s) => s.id));
      await device.save(
        'servers',
        '',
        servers.map((s) => s.json).toList(),
        server: '',
      );
      if (servers.isNotEmpty) await entries.selectServer(servers.first);
    } catch (e) {
      if (!staleScope(e)) error = userErrorText(e, where: 'load servers');
    } finally {
      loading = false;
      context.changed();
    }
  }

  void beginServerSelectionProjection(RaftRecord next) {
    server = next;
    // A workspace error belongs to the server where it was raised.
    error = null;
    _burstAt.clear();
    if (mobileNavigation) section = 'home';
    if (!canVisitSection(section)) section = 'chat';
    sidebarOrder = {};
    client.selectServer(next.id);
  }

  void resetServerSelectionState() {
    directory.resetRowAuthority();
    // The new server's socket connects for the first time.
    _connectedBefore = _roomsJoinedPending = false;
    _gapSyncedThrough = null;
    messages.resetNewer();
  }

  Future<void> selectServer(
    RaftRecord next, {
    void Function()? onHydrated,
    void Function()? onCacheMiss,
  }) async {
    // A live mobile page presents the source's session; the source selects.
    final source = entries.sessionSource;
    if (source != null) {
      return source.selectServer(
        next,
        onHydrated: onHydrated,
        onCacheMiss: onCacheMiss,
      );
    }
    if (!ownsClient) {
      throw StateError('A borrowed editor cannot select a server.');
    }
    if (revokedServers.contains(next.id)) return;
    final selection = context.transitions.selectServer(next);
    final selectionAtStart = channelGeneration,
        threadAtStart = threadGeneration,
        navigationAtStart = navigationRevision;
    context.changed();
    final generation = client.generation;
    final replyIdentity = syncIdentity();
    final cached = await device.read('channels', '');
    await selection.restoredEntities;
    await selection.restoredTranslations;
    if (generation != client.generation) return;
    if (cached is Map) {
      channels = (cached['channels'] as List)
          .map((e) => RaftChannel(Map<String, dynamic>.from(e)))
          .toList();
      dms = (cached['dms'] as List)
          .map((e) => RaftChannel(Map<String, dynamic>.from(e)))
          .toList();
      final last = await device.read('selection', '');
      final initial =
          [...channels, ...dms].where((c) => c.id == last).firstOrNull ??
          channels.where((c) => c.joined && !c.archived).firstOrNull;
      if (initial != null) {
        channel = initial;
        // A principal/role change before this point retires its summaries.
        final replyAuthority = replyIdentity == syncIdentity()
            ? messages.replyToken(initial.id)
            : '';
        final request = messages.hydrationRequest(
          allowed: () => generation == client.generation,
        );
        final page = await device.read('window', initial.id);
        if (generation != client.generation) return;
        if (messages.restoreCachedTail(
          initial.id,
          page,
          request,
          replyAuthority: replyAuthority,
          replace: true,
        )) {
          await drafts.restoreDraft(initial.id);
        }
      }
      context.changed();
    }
    final cachedFrontiers = await device.read('read-frontiers', '');
    if (generation != client.generation) return;
    readState.restore(
      cachedFrontiers,
      serverId: next.id,
      principalId: client.user!.id,
    );
    final cachedUnread = await device.read('unread', '');
    if (generation != client.generation) return;
    if (cachedUnread is Map) {
      unread = {
        for (final entry in cachedUnread.entries)
          if (entry.value is int && entry.value >= 0)
            '${entry.key}': entry.value,
      };
    }
    context.changed();
    if (cached is Map) {
      onHydrated?.call();
    } else {
      onCacheMiss?.call();
    }
    final readGeneration = readState.generation;
    List<List<RaftChannel>> values;
    try {
      values = await Future.wait([
        client.channels(),
        client.channels(dm: true),
      ]);
    } catch (e) {
      if (isNotServerMember(e) && generation == client.generation) {
        entries.revokeServer(next.id);
        await entries.recoverMembership();
        loading = false;
        context.changed();
        return;
      }
      if (generation == client.generation) {
        error = userErrorText(e, where: 'load channels');
        loading = false;
        context.changed();
      }
      return;
    }
    if (generation != client.generation) return;
    final accessible = [...values[0], ...values[1]].map((c) => c.id).toSet();
    for (final old in [...channels, ...dms]) {
      if (!accessible.contains(old.id)) revokeChannel(old.id);
    }
    channels = values[0];
    dms = values[1];
    // A cached selection adopts its fresh row. When the fresh row changes
    // the window authority, the cached rows are not shown under it: the
    // selection is revalidated below (or by the newer selection in flight).
    final held = channel;
    final freshHeld = held == null
        ? null
        : [...channels, ...dms].where((c) => c.id == held.id).firstOrNull;
    var heldAuthorityChanged = false;
    if (held != null && freshHeld != null && !identical(held, freshHeld)) {
      final before = messages.windowAuthority();
      channel = freshHeld;
      heldAuthorityChanged = before != messages.windowAuthority();
    }
    // The cache-painted workspace is already on screen: show the fresh lists
    // (and any revocation) now, not after the unread read below.
    context.changed();
    await device.save('channels', '', {
      'channels': channels.map((c) => c.json).toList(),
      'dms': dms.map((c) => c.json).toList(),
    });
    // The cache write yields: a sign-out meanwhile clears `client.user`.
    if (generation != client.generation) return;
    final principalId = client.user?.id;
    if (principalId == null) return;
    for (final c in [...channels, ...dms]) {
      readState.consumeSnapshot(
        c.json['readState'],
        serverId: next.id,
        principalId: principalId,
        scopeId: c.id,
        generationAtRequest: readGeneration,
      );
    }
    client.connect();
    await directory.refreshUnread();
    final joined = channels.where((c) => c.joined && !c.archived).toList();
    if (joined.isNotEmpty &&
        selectionAtStart == channelGeneration &&
        threadAtStart == threadGeneration) {
      final selected =
          joined.where((c) => c.id == channel?.id).firstOrNull ?? joined.first;
      if (mobileNavigation && section == 'home') {
        channel = selected;
        await drafts.restoreDraft(selected.id);
      } else {
        // A location the app root applied over the cache-painted workspace
        // (e.g. a remembered non-chat page) keeps its section.
        await messages.selectChannel(
          selected,
          navigate: navigationAtStart == navigationRevision,
        );
      }
    } else if (heldAuthorityChanged &&
        channel != null &&
        identical(channel, freshHeld)) {
      await messages.selectChannel(
        channel!,
        navigate: false,
        preserveThread: true,
        autoRead: false,
      );
    }
    context.changed();
  }

  void revokeChannel(String id) => context.transitions.revokeChannel(id);

  ChannelRevocationPlan planChannelRevocation(String id) =>
      messages.discoverRevocation(id);

  void roomsJoined() {
    SourceActivityUnreadStore.activateForRooms(entities);
    _roomsJoinedPending = false;
    unawaited(messages.resumeHistory());
    // A reconnect and a resume can both ask within a second; the tail read a
    // moment ago already covers them.
    if (due('gap', freshness: const Duration(seconds: 3))) {
      unawaited(messages.syncVisibleScopes());
    }
    if (due('channels')) unawaited(directory.refreshChannels());
    if (due('unread')) unawaited(directory.refreshUnread());
  }

  bool due(String name, {Duration freshness = _burstFreshness}) =>
      _burstAt.due(name, freshness);

  void heartbeat(dynamic payload) {
    _lastHeartbeat = DateTime.now();
    // A lost `rooms:joined`: the connection's first heartbeat stands in.
    if (_roomsJoinedPending) {
      roomsJoined();
      return;
    }
    final seq = payload is Map ? BigInt.tryParse('${payload['seq']}') : null;
    final synced = _gapSyncedThrough;
    if (seq == null ||
        seq <= ledger.watermark ||
        synced != null && synced.$1 == ledger.generation && seq <= synced.$2) {
      return;
    }
    unawaited(messages.syncVisibleScopes(through: seq));
  }

  void resumeLiveSession() {
    if (context.disposed || !ownsClient || client.serverId == null) return;
    // The Activity window and the cross-server summary are read at once, in
    // parallel with the resume handshake below (not after its reply).
    unawaited(activityUnreadIfBound?.refreshOnResume());
    resumes.value++;
    final now = DateTime.now();
    final heartbeat = _lastHeartbeat, inbound = _lastServerEvent;
    final silent =
        heartbeat != null &&
        inbound != null &&
        now.difference(heartbeat) > const Duration(seconds: 90) &&
        now.difference(inbound) > const Duration(seconds: 120);
    if (!client.connected || silent) {
      client.connect();
    } else {
      unawaited(messages.resumeHistory());
      if (due('gap', freshness: const Duration(seconds: 3))) {
        unawaited(messages.syncVisibleScopes());
      }
    }
    // Returning to the foreground (alt-tab on a desktop does it often): the
    // counts, sidebar and directory read less than 15 s ago are still fresh.
    if (due('unread')) unawaited(directory.refreshUnread());
    if (due('sidebar')) directory.loadSidebar();
    if (entityDirectory.started && due('authors')) {
      entityDirectory.revalidateAuthors();
    }
    // Another session of this account may have joined or created a server;
    // the server tells only that server's room, so this is the one moment the
    // directory is re-read. On a desktop the engine reports window focus as
    // inactive/resumed, so this also runs when the window regains focus.
    if (due('membership', freshness: _membershipResumeFreshness)) {
      unawaited(entries.recoverMembership(coalesce: true));
    }
  }

  void applyMembershipRole(dynamic payload) {
    if (payload is! Map ||
        payload['userId'] != client.user?.id ||
        payload['serverId'] is! String ||
        payload['role'] is! String) {
      return;
    }
    final id = payload['serverId'] as String, role = payload['role'] as String;
    if (!servers.any((s) => s.id == id) && server?.id != id) return;
    _membershipRevision++;
    _membershipRequest++;
    servers = [
      for (final s in servers)
        s.id == id ? RaftRecord({...s.json, 'role': role}) : s,
    ];
    if (server?.id == id) {
      if (server?.string('role') != role) {
        messages.invalidateAllReplyAuthority();
      }
      server = RaftRecord({...server!.json, 'role': role});
      ensureSyncIdentity();
      entries.refreshMessageSyncFlag();
      if (!canVisitSection(section)) section = 'chat';
    }
    device.save('servers', '', servers.map((s) => s.json).toList(), server: '');
    context.changed();
  }

  void consumeServerPlanUpdated(dynamic payload) {
    final id = payload is Map ? payload['serverId'] : null;
    final plan = payload is Map ? payload['plan'] : null;
    if (id is String && id.isNotEmpty && plan is String) {
      RaftRecord patch(RaftRecord value) =>
          value.id == id ? RaftRecord({...value.json, 'plan': plan}) : value;
      servers = servers.map(patch).toList();
      if (server != null) server = patch(server!);
      device.save(
        'servers',
        '',
        servers.map((s) => s.json).toList(),
        server: '',
      );
    } else {
      unawaited(entries.recoverMembership());
    }
    planRevision++;
    context.changed();
  }

  void applyServerAvatar(String serverId, String? avatarUrl) {
    if (entries.sessionSource != null) {
      unawaited(entries.recoverMembership());
      return;
    }
    if (context.disposed) return;
    RaftRecord patch(RaftRecord value) => value.id == serverId
        ? RaftRecord({...value.json, 'avatarUrl': avatarUrl})
        : value;
    servers = servers.map(patch).toList();
    if (server != null) server = patch(server!);
    device.save('servers', '', servers.map((s) => s.json).toList(), server: '');
    context.changed();
  }

  Future<void> recoverMembership({bool coalesce = false}) async {
    if (entries.sessionSource != null) {
      return entries.sessionSource!.recoverMembership();
    }
    if (!ownsClient || coalesce && _burstAt.directoryReading) return;
    final generation = client.generation,
        request = ++_membershipRequest,
        revision = _membershipRevision;
    try {
      final current = await client.servers();
      if (generation != client.generation ||
          context.disposed ||
          request != _membershipRequest ||
          revision != _membershipRevision) {
        return;
      }
      revokedServers.removeAll(current.map((s) => s.id));
      servers = current;
      await device.save(
        'servers',
        '',
        current.map((s) => s.json).toList(),
        server: '',
      );
      if (server != null && !current.any((s) => s.id == server!.id)) {
        entries.revokeServer(server!.id);
        await entries.flushCache();
      }
      if (server == null && current.isNotEmpty) {
        await entries.selectServer(current.first);
      }
      if (server != null) {
        server = current.where((s) => s.id == server!.id).firstOrNull;
        if (!canVisitSection(section)) section = 'chat';
      }
      context.changed();
    } catch (e) {
      // A refresh superseded by a newer one, or outrun by a server switch
      // (deleting the open server selects the next), is not a failure.
      if (!context.disposed &&
          !quietFailure(e) &&
          generation == client.generation &&
          request == _membershipRequest) {
        // ignore: raft_lints/avoid_imperative_notice_state -- Raised only for the latest membership request on the current client generation and not for rate-limited or stale-scope failures.
        presentation.setError(userErrorText(e, where: 'refresh servers'));
      }
    }
  }

  void event(RaftEvent event) {
    if (context.disposed) return;
    ensureSyncIdentity();
    if (!ownsClient &&
        !const {
          'message:new',
          'message:updated',
          'thread:updated',
          'reaction_viewer:updated',
          'channel:removed',
        }.contains(event.name)) {
      return;
    }
    _lastServerEvent = DateTime.now();
    // Presence patches are owned by the entity directory and the agent
    // presentations; no workspace state changes, so nothing is notified.
    if (presenceEvents.contains(event.name)) return;
    if (event.name == 'connected') {
      connected = true;
      // Source socketBridge reconnectSnapshot: server-level reads only. The
      // channel list, unread counts and the resume/gap sync wait for
      // `rooms:joined`, once the server has joined this socket's rooms.
      _roomsJoinedPending = true;
      _lastHeartbeat = _lastServerEvent;
      // A socket that flaps (a bad network reconnects every few seconds) must
      // not repeat the whole refresh burst each time: what was read less than
      // [_burstFreshness] ago is still fresh, and the resume sync below
      // brings messages up to date.
      if (due('membership')) entries.recoverMembership(coalesce: true);
      if (due('syncFlag')) entries.refreshMessageSyncFlag();
      if (due('sidebar')) directory.loadSidebar();
      // A reconnect refreshes agents and members in place; the first connect
      // reuses the reads the selection already started.
      if (_connectedBefore && entityDirectory.started && due('authors')) {
        entityDirectory.revalidateAuthors();
      }
      _connectedBefore = true;
    }
    if (event.name == 'rooms:joined') roomsJoined();
    if (event.name == 'heartbeat') {
      final joining = _roomsJoinedPending;
      heartbeat(event.payload);
      // A heartbeat only records liveness; a missed-push gap sync notifies
      // when its rows arrive.
      if (!joining) return;
    }
    if (event.name == 'disconnected' || event.name == 'connection:error') {
      connected = false;
    }
    if (event.name == 'server:membership-removed' &&
        event.payload is Map &&
        event.payload['serverId'] is String) {
      entries.revokeServer(event.payload['serverId']);
      entries.recoverMembership();
    }
    if (event.name == 'connection:error' &&
        event.payload is Map &&
        event.payload['notServerMember'] == true) {
      final id = client.serverId;
      if (id != null) entries.revokeServer(id);
      entries.recoverMembership();
    }
    if (event.name == 'server:member-updated') {
      entries.applyMembershipRole(event.payload);
      entries.recoverMembership();
      directory.refreshChannels();
    }
    if (event.name == 'channel:members-updated' ||
        event.name == 'channel:authority-updated' ||
        event.name == 'channel:removed') {
      final payload = event.payload;
      final id = payload is Map ? payload['channelId'] ?? payload['id'] : null;
      if (id is! String || id.isEmpty) {
        // Unknown scope: fail closed for every channel.
        messages.invalidateAllChannelReplies();
      } else if (event.name != 'channel:members-updated' ||
          membershipScoped(id)) {
        // Only the named channel's authority may have changed. A public
        // channel's member list never changes who can read it.
        messages.invalidateChannelReplies(id);
      }
    }
    if (event.name == 'channel:updated' ||
        event.name == 'channel:members-updated' ||
        event.name == 'dm:new' ||
        event.name == 'channel:authority-updated') {
      directory.channelRealtime(event.name, event.payload);
    }
    if (event.name == 'pinned:updated') directory.loadSidebar();
    if (event.name == 'thread:updated' && event.payload is Map) {
      messages.consumeThreadUpdate(Map<String, dynamic>.from(event.payload));
    }
    if (event.name == 'notification_prefs:updated') {
      directory.consumeNotificationPrefs(event.payload);
    }
    if (event.name == 'message_display_prefs:updated') {
      directory.consumeMessageDisplayPrefs(event.payload);
    }
    if (event.name == 'server:plan-updated') {
      consumeServerPlanUpdated(event.payload);
    }
    if (!messages.consumeMessageEvent(event)) return;
    if (event.name == 'sync:resume:response' && event.payload is Map) {
      unawaited(
        messages.resumeResponse(
          event.payload as Map,
          refreshUnread: () {
            if (due('unread', freshness: const Duration(seconds: 5))) {
              directory.refreshUnread();
            }
          },
        ),
      );
    }
    if (event.name == 'channel:removed') {
      final p = event.payload;
      if (p is Map && p['channelId'] is String) {
        final id = p['channelId'] as String;
        revokeChannel(id);
        directory.removeChannelRows(id);
        if (channel?.id == id) {
          channel = null;
          messages.closeThread();
        }
      }
    }
    if (event.name == 'read_state:updated' ||
        event.name == 'read_state:updated_bulk') {
      final payload = event.payload;
      if (payload is Map && client.serverId != null && client.user != null) {
        final updates = event.name.endsWith('_bulk')
            ? (payload['scopes'] as List? ?? [])
            : [payload];
        for (final update in updates) {
          if (update is Map) {
            final fact = {...update, 'serverId': payload['serverId']};
            final outcome = readState.consumeUpdate(
              fact,
              serverId: client.serverId!,
              principalId: client.user!.id,
            );
            if (outcome == 'accepted' && fact['scopeId'] is String) {
              directory.projectReadState(fact['scopeId'] as String);
              messages.applyReadStateHint(fact);
            }
          }
        }
      }
      directory.persistReadState();
    }
    if (event.name == 'reaction_viewer:updated' && client.serverId != null) {
      messages.acceptReactionViewer(event.payload, serverId: client.serverId!);
    }
    context.changed();
  }
}
