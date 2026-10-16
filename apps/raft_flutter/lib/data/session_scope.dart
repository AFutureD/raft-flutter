import 'dart:async';

import 'package:raft_client/raft_client.dart';
import 'package:raft_sync/raft_sync.dart';

import 'attachment_media.dart';
import 'resource_snapshot_cache.dart';
import 'workspace_composer.dart';
import 'workspace_device_store.dart';
import 'workspace_message_windows.dart';

/// Existing domain owners and the receiver's remaining presentation hooks.
/// Getters stay lazy and keep each presentation's injection and source rules.
abstract interface class SessionScopeBinding {
  RaftClient get client;
  List<RaftRecord> get servers;
  WorkspaceComposer get composer;
  WorkspaceDeviceStore get deviceStore;
  WorkspaceMessageWindows get messageWindows;
  AttachmentMedia get attachmentMedia;
  ReadStateLedger get readState;
  ResourceSnapshotCache get resourceSnapshots;
  ReactionViewerLedger get reactionViewer;
  MessageSync get messageSync;
  Future<void> Function(String, String, String, String?)?
  get discardSharedScope;

  void resetServerProjection();
  void clearSessionPrefetch();
  void closeRevokedServerProjection();
  set syncCoreMessagesEnabled(bool value);
  void notifyListeners();
}

/// Fixed synchronous order; later domain slices replace their binding here.
enum ServerResetStage {
  projection,
  windows,
  readState,
  resources,
  prefetch,
  reactions,
  messages,
}

enum ServerRevocationStage {
  sharing,
  media,
  activeSelection,
  device,
  directory,
}

class ServerReset {
  const ServerReset(this.serverId);
  final String? serverId;
}

/// The identity used by queued work stays captured even if a callback switches.
class ServerRevocation {
  const ServerRevocation({
    required this.origin,
    required this.principal,
    required this.serverId,
    required this.generation,
  });
  final String origin, principal, serverId;
  final int generation;
}

/// Receiver-local revocation facts and ordered, synchronous domain transitions.
///
/// Shared clients may have independent editors. Each controller binds its own
/// scope to the domain objects it already owns or borrows; no global broadcast
/// or new socket subscription is created. Dispatch never awaits, catches a
/// listener exception, defers work, or coalesces separate commands.
class SessionScope {
  SessionScope(this.binding, {required bool ownsMedia}) {
    onReset(
      ServerResetStage.projection,
      (_) => binding.resetServerProjection(),
    );
    onReset(ServerResetStage.windows, (event) {
      binding.messageWindows.channelGeneration++;
      binding.messageWindows.threadGeneration++;
      binding.messageWindows.switchServer(event.serverId);
    });
    onReset(ServerResetStage.readState, (_) => binding.readState.reset());
    onReset(
      ServerResetStage.resources,
      (_) => binding.resourceSnapshots.clear(),
    );
    onReset(ServerResetStage.prefetch, (_) => binding.clearSessionPrefetch());
    onReset(ServerResetStage.reactions, (_) => binding.reactionViewer.reset());
    onReset(ServerResetStage.messages, (_) {
      binding.messageSync.reset();
      binding.syncCoreMessagesEnabled = false;
    });

    onServerRevoked(ServerRevocationStage.sharing, (event) {
      unawaited(
        binding.discardSharedScope?.call(
          event.origin,
          event.principal,
          event.serverId,
          null,
        ),
      );
    });
    onServerRevoked(ServerRevocationStage.media, (event) {
      if (ownsMedia) {
        binding.attachmentMedia.purgeIdentity(
          event.origin,
          event.principal,
          event.serverId,
        );
      }
    });
    onServerRevoked(ServerRevocationStage.activeSelection, (event) {
      // Check after the sharing/media callbacks, exactly as the old entrypoint.
      if (binding.client.serverId != event.serverId) return;
      binding.composer.clearOwnedBy(binding);
      resetServer(null);
      binding.closeRevokedServerProjection();
    });
    onServerRevoked(ServerRevocationStage.device, (event) {
      binding.deviceStore.revokeServer(
        event.origin,
        event.principal,
        event.serverId,
      );
    });
    onServerRevoked(ServerRevocationStage.directory, (_) {
      binding.deviceStore.write(
        'servers',
        '',
        binding.servers.map((s) => s.json).toList(),
        server: '',
      );
      binding.notifyListeners();
    });
  }

  final SessionScopeBinding binding;
  final revokedChannels = <String>{}, revokedServers = <String>{};
  final _resetHandlers = <ServerResetStage, List<void Function(ServerReset)>>{};
  final _revokeHandlers =
      <ServerRevocationStage, List<void Function(ServerRevocation)>>{};
  bool _closed = false;

  /// Register in a named phase. Removal affects subsequent dispatches.
  void Function() onReset(
    ServerResetStage stage,
    void Function(ServerReset) run,
  ) {
    if (_closed) throw StateError('Session scope is disposed.');
    final handlers = _resetHandlers.putIfAbsent(stage, () => []);
    handlers.add(run);
    return () => handlers.remove(run);
  }

  void Function() onServerRevoked(
    ServerRevocationStage stage,
    void Function(ServerRevocation) run,
  ) {
    if (_closed) throw StateError('Session scope is disposed.');
    final handlers = _revokeHandlers.putIfAbsent(stage, () => []);
    handlers.add(run);
    return () => handlers.remove(run);
  }

  /// Retire accepted windows and projections in the current call stack.
  void resetServer(String? id) {
    final event = ServerReset(id);
    final handlers = [
      for (final stage in ServerResetStage.values) ...?_resetHandlers[stage],
    ];
    for (final run in handlers) {
      run(event);
    }
  }

  void revokeServer(String id) {
    final principal = binding.client.user?.id;
    if (principal == null) return;
    revokedServers.add(id);
    binding.servers.removeWhere((s) => s.id == id);
    final event = ServerRevocation(
      origin: binding.client.origin,
      principal: principal,
      serverId: id,
      generation: binding.client.generation,
    );
    final handlers = [
      for (final stage in ServerRevocationStage.values)
        ...?_revokeHandlers[stage],
    ];
    for (final run in handlers) {
      run(event);
    }
  }

  /// Only this receiver's bindings are detached; borrowed owners stay alive.
  void dispose() {
    _closed = true;
    _resetHandlers.clear();
    _revokeHandlers.clear();
  }
}
