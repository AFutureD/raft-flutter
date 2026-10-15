import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_sync/raft_sync.dart';

import 'conversation_window.dart';
import 'workspace_sends.dart';

/// Accepted message windows for one workspace receiver. Transport, session
/// authorization and read-receipt execution remain with the caller.
class WorkspaceMessageWindows {
  WorkspaceMessageWindows({
    required this.authority,
    required this.presentation,
    required this.layout,
    required this.sends,
    required this.notRevoked,
  });
  final MessageWindowAuthority? Function(ConversationWindowScope) authority;
  final ConversationWindowSnapshot Function(bool thread) presentation;
  final (bool, bool) Function(ConversationWindowScope) layout;
  final WorkspaceSends sends;
  final bool Function(String) notRevoked;
  final _windows = <ConversationWindowScope, _ProjectedConversationWindow>{};
  bool _disposed = false;

  /// Session authorization stays a read port. The owner captures its own
  /// ledger and window epochs and checks both again at every write boundary.
  MessageWindowRequest request({
    bool? thread,
    required bool Function() allowed,
  }) => MessageWindowRequest._(this, (
    ledger.generation,
    thread == null
        ? null
        : (thread, thread ? threadGeneration : channelGeneration),
  ), allowed);

  bool _admits(MessageWindowRequest request) {
    final selected = request._stamp.$2;
    return !_disposed &&
        identical(request._owner, this) &&
        request.generation == ledger.generation &&
        (selected == null ||
            selected.$2 ==
                (selected.$1 ? threadGeneration : channelGeneration)) &&
        request._allowed();
  }

  bool _writable(MessageWindowRequest? request) =>
      !_disposed && (request == null || _admits(request));

  /// Accept canonical row versions and their visible membership together.
  /// A rejected operation cannot change either side of the window.
  void acceptRows(
    String id,
    Iterable<Map<String, dynamic>> rows, {
    Iterable<String>? visible,
    bool replace = false,
    MessageWindowRequest? request,
  }) {
    if (!_writable(request)) return;
    final accepted = rows.toList();
    ledger.ingest(
      accepted,
      expectedGeneration: request?.generation ?? ledger.generation,
    );
    reveal(
      id,
      visible ?? accepted.map((row) => row['id'] as String),
      replace: replace,
      request: request,
    );
  }

  void switchServer(String? id) {
    ledger.switchServer(id);
    visibleIds.clear();
    _accepted.clear();
    _diskOnly.clear();
    _threads.clear();
  }

  void revokeChannel(String id) => ledger.revokeChannel(id);
  void reveal(
    String id,
    Iterable<String> ids, {
    bool replace = false,
    MessageWindowRequest? request,
  }) {
    if (!_writable(request)) return;
    if (replace) {
      visibleIds[id] = ids.toSet();
    } else {
      visibleIds.putIfAbsent(id, () => {}).addAll(ids);
    }
  }

  BigInt newestVisibleSequence(String id) =>
      (visibleIds[id] ?? const <String>{})
          .map(
            (key) =>
                BigInt.tryParse('${ledger.message(id, key)?['seq']}') ??
                BigInt.zero,
          )
          .fold(BigInt.zero, (latest, seq) => seq > latest ? seq : latest);

  /// Retained canonical rows beyond the visible frontier fill a missed live
  /// event gap. The session decides when to revalidate it over the transport.
  bool fillWindowGap(String id, String liveId) {
    final visible = visibleIds[id];
    if (visible == null || visible.isEmpty) return false;
    final newest = newestVisibleSequence(id);
    if (newest == BigInt.zero) return false;
    var gap = false;
    for (final row in ledger.messages(id)) {
      final seq = BigInt.tryParse('${row['seq']}');
      if (seq != null &&
          seq > newest &&
          row['id'] != liveId &&
          !visible.contains(row['id'])) {
        visible.add(row['id'] as String);
        gap = true;
      }
    }
    return gap;
  }

  void hideWindow(String id) => visibleIds.remove(id);

  /// The session reducer feeds canonical events through MessageLedger's epoch
  /// checks. Window responses additionally admit membership here with a ticket.
  final ledger = MessageLedger();
  final visibleIds = <String, Set<String>>{};
  final _accepted = <String, AcceptedMessageWindow>{};
  final _threads = <String, CachedMessageThread>{};
  final _diskOnly = <String>{};
  final _anchors = <String, ReadingAnchor>{};
  final _presentedRows = Expando<RaftMessage>('presented rows');
  final _requests = <Object, Future<String?>?>{};
  int channelGeneration = 0, threadGeneration = 0;

  Map<String, AcceptedMessageWindow> get accepted =>
      UnmodifiableMapView(_accepted);
  Map<String, CachedMessageThread> get threads => UnmodifiableMapView(_threads);
  RaftMessage presented(Map<String, dynamic> row) =>
      _presentedRows[row] ??= RaftMessage(row);

  void rememberWindow(
    String id,
    String authority,
    bool more,
    String token, {
    required bool historyLimited,
    Iterable<Map<String, dynamic>>? rows,
    bool replace = false,
    MessageWindowRequest? request,
  }) {
    if (!_writable(request)) return;
    if (rows != null) acceptRows(id, rows, replace: replace, request: request);
    _accepted[id] = AcceptedMessageWindow(
      authority,
      more,
      token,
      historyLimited,
      _accepted[id]?._contextNewer,
    );
  }

  void discardWindow(String id) {
    hideWindow(id);
    forgetWindow(id);
    revalidated(id);
  }

  void forgetWindow(String id) => _accepted.remove(id);
  bool historyLimit(String? id) => _accepted[id]?.historyLimited == true;
  bool isContext(String id) => _accepted[id]?._contextNewer != null;
  bool contextHasNewer(String? id) => _accepted[id]?._contextNewer == true;
  bool _setContext(String id, bool? newer) {
    final held = _accepted[id], prior = _accepted[id]?._contextNewer;
    held?._contextNewer = newer;
    return prior != null;
  }

  void markContext(String id, bool newer, {MessageWindowRequest? request}) {
    if (_writable(request)) _setContext(id, newer);
  }

  bool leaveContext(String id, {MessageWindowRequest? request}) =>
      _writable(request) && _setContext(id, null);

  ({String channelId, MessageWindowRequest request, bool retainRows})?
  _pendingContext;
  void beginContextVisit(
    String id,
    MessageWindowRequest request, {
    required bool retainRows,
  }) {
    if (_admits(request)) {
      _pendingContext = (
        channelId: id,
        request: request,
        retainRows: retainRows,
      );
    }
  }

  String? get pendingContextChannelId =>
      _pendingContext?.request.current == true
      ? _pendingContext!.channelId
      : null;
  bool get contextRetainsRows => _pendingContext?.retainRows ?? false;
  void finishContextVisit({MessageWindowRequest? request}) {
    if (request == null || identical(_pendingContext?.request, request)) {
      _pendingContext = null;
    }
  }

  /// Only an accepted in-memory tail under current session facts follows live
  /// rows. Disk-only and context windows are revalidated when opened.
  bool retainsLiveTail(String id) {
    final held = _accepted[id];
    final facts = authority((channelId: id, parentMessageId: null));
    return held != null &&
        !isContext(id) &&
        !isDiskOnly(id) &&
        (visibleIds[id]?.isNotEmpty ?? false) &&
        held.authority == facts?.$4 &&
        held.token == facts?.$3;
  }

  bool isDiskOnly(String? id) => _diskOnly.contains(id);
  void markDiskOnly(String id, {MessageWindowRequest? request}) {
    if (_writable(request)) _diskOnly.add(id);
  }

  void revalidated(String? id, {MessageWindowRequest? request}) {
    if (_writable(request)) _diskOnly.remove(id);
  }

  CachedMessageThread? matchingThread(
    String channelId,
    String parentId,
    String? token,
    String? authority,
  ) {
    final held = _threads[parentId];
    return held != null &&
            held.parentChannelId == channelId &&
            held.token == token &&
            held.authority == authority &&
            held.generation == ledger.generation &&
            notRevoked(held.threadChannelId)
        ? held
        : null;
  }

  void cacheThread(
    String parentId,
    CachedMessageThread value, {
    MessageWindowRequest? request,
  }) {
    if (_writable(request)) _threads[parentId] = value;
  }

  void cacheThreadParent(
    String parentId,
    RaftMessage? parent, {
    MessageWindowRequest? request,
  }) {
    if (!_writable(request)) return;
    if (_threads[parentId] case final held?) {
      _threads[parentId] = (
        parentChannelId: held.parentChannelId,
        threadChannelId: held.threadChannelId,
        token: held.token,
        authority: held.authority,
        generation: held.generation,
        hasMore: held.hasMore,
        historyLimited: held.historyLimited,
        parent: parent,
      );
    }
  }

  void forgetThread(String id) => _threads.remove(id);
  void clearThreads() => _threads.clear();
  void invalidateParentThreads(String id) =>
      _threads.removeWhere((_, thread) => thread.parentChannelId == id);
  void revokeThreads(String id) => _threads.removeWhere(
    (_, thread) => thread.parentChannelId == id || thread.threadChannelId == id,
  );

  void saveReadingAnchor(String id, ReadingAnchor anchor) =>
      _anchors[id] = anchor;
  ReadingAnchor? takeReadingAnchor(String id) {
    final anchor = _anchors.remove(id);
    return anchor != null && anchor.fresh ? anchor : null;
  }

  bool beginTailRevalidation(String id) {
    final key = ('tail', id);
    if (_requests.containsKey(key)) return false;
    _requests[key] = null;
    return true;
  }

  void endTailRevalidation(String id) => _requests.remove(('tail', id));
  Future<String?> createThread(Future<String?> Function() create) async {
    final key = ('thread', threadGeneration);
    final held = _requests[key];
    if (held != null) return held;
    final request = _requests[key] = create();
    try {
      return await request;
    } finally {
      if (identical(_requests[key], request)) _requests.remove(key);
    }
  }

  ConversationWindow? channel(String? id) =>
      id == null ? null : _open((channelId: id, parentMessageId: null));
  ConversationWindow? thread(
    String? parentChannelId,
    String? parentMessageId,
  ) => parentChannelId == null || parentMessageId == null
      ? null
      : _open((channelId: parentChannelId, parentMessageId: parentMessageId));

  ConversationWindow? _open(ConversationWindowScope scope) {
    if (_disposed) return null;
    final token = authority(scope);
    if (token == null) return null;
    var window = _windows[scope];
    if (window != null && window.token != token) {
      _windows.remove(scope);
      window.retire();
      window = null;
    }
    return window ??= _windows[scope] = _ProjectedConversationWindow(
      scope,
      token,
      _read(scope),
      this,
    );
  }

  /// Called after existing state mutations; only changed windows publish.
  void synchronize() {
    if (_disposed) return;
    for (final entry in _windows.entries.toList()) {
      final window = entry.value;
      if (authority(entry.key) != window.token) {
        _windows.remove(entry.key);
        window.retire();
      } else {
        window.refresh(_read(entry.key));
      }
    }
  }

  bool _current(ConversationWindowScope scope, Object token) =>
      !_disposed && authority(scope) == token;
  List<RaftMessage> rows(String? id) => id == null
      ? []
      : ledger
            .messages(id)
            .where((row) => visibleIds[id]?.contains(row['id']) ?? false)
            .map(presented)
            .toList();
  bool containsVisible(String id, String messageId) =>
      (visibleIds[id]?.contains(messageId) ?? false) &&
      ledger.contains(id, messageId);

  ConversationWindowSnapshot _read(ConversationWindowScope scope) {
    final main = scope.parentMessageId == null, active = layout(scope).$1;
    final facts = authority(scope);
    final held = scope.parentMessageId == null
        ? null
        : matchingThread(
            scope.channelId,
            scope.parentMessageId!,
            facts?.$3,
            facts?.$4,
          );
    final flags = active ? presentation(!main) : null;
    final id = main
        ? scope.channelId
        : active
        ? flags!.channelId
        : held?.threadChannelId;
    final pending =
        main && active && pendingContextChannelId == scope.channelId;
    final acceptedRows = pending && !contextRetainsRows
        ? <RaftMessage>[]
        : rows(id);
    final newer = main && (active ? flags!.hasNewer : contextHasNewer(id));
    final timeline = main && (newer || pending)
        ? acceptedRows
        : sends
              .project(
                acceptedRows,
                main ? scope.channelId : 'thread:${scope.parentMessageId}',
              )
              .map((row) => presented(row.json))
              .toList();
    return ConversationWindowSnapshot(
      channelId: id,
      rows: acceptedRows,
      timeline: timeline,
      parent: main
          ? null
          : active
          ? flags!.parent
          : held?.parent,
      loading: flags?.loading ?? false,
      loadingOlder: flags?.loadingOlder ?? false,
      parentLoading: flags?.parentLoading ?? false,
      resolving: flags?.resolving ?? false,
      error: flags?.error,
      hasMore:
          flags?.hasMore ??
          (main ? _accepted[id]?.hasMore == true : held?.hasMore == true),
      hasNewer: newer,
      historyLimited:
          flags?.historyLimited ??
          (main ? historyLimit(id) : held?.historyLimited == true),
      highlightedMessageId: flags?.highlightedMessageId,
      contextLoadError: flags?.contextLoadError,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final window in _windows.values) {
      window.retire(notify: false);
    }
    _windows.clear();
  }
}

class _ProjectedConversationWindow extends ConversationWindow
    with ChangeNotifier {
  _ProjectedConversationWindow(
    this.scope,
    this.token,
    this._snapshot,
    this._owner,
  );
  @override
  final ConversationWindowScope scope;
  final Object token;
  ConversationWindowSnapshot _snapshot;
  final WorkspaceMessageWindows _owner;
  static final _empty = ConversationWindowSnapshot(retired: true);

  @override
  Listenable get changes => this;
  @override
  ConversationWindowSnapshot get snapshot =>
      _snapshot.retired || !_owner._current(scope, token) ? _empty : _snapshot;
  @override
  bool get visible =>
      !_snapshot.retired &&
      _owner._current(scope, token) &&
      _owner.layout(scope).$2;

  void refresh(ConversationWindowSnapshot next) {
    if (_snapshot.retired || _snapshot.samePresentation(next)) return;
    _snapshot = next;
    notifyListeners();
  }

  void retire({bool notify = true}) {
    if (_snapshot.retired) return;
    _snapshot = _empty;
    if (notify) notifyListeners();
    dispose();
  }
}

/// One accepted window owns its boundary facts together, rather than keeping
/// parallel maps whose membership can diverge. A null contextNewer is a tail.
class AcceptedMessageWindow {
  AcceptedMessageWindow(
    this.authority,
    this.hasMore,
    this.token,
    this.historyLimited,
    this._contextNewer,
  );
  final String authority, token;
  final bool hasMore, historyLimited;
  bool? _contextNewer;
}

/// Immutable cached thread identity and boundary metadata, keyed by its parent.
typedef CachedMessageThread = ({
  String parentChannelId,
  String threadChannelId,
  String token,
  String? authority,
  int generation,
  bool hasMore,
  bool historyLimited,
  RaftMessage? parent,
});

/// A message row and the distance of its top below the timeline's top edge.
class ReadingAnchor {
  ReadingAnchor(this.messageKey, this.top) : _saved = Stopwatch()..start();
  final String messageKey;
  final double top;
  final Stopwatch _saved;
  static const lifetime = Duration(seconds: 3);
  bool get fresh => _saved.elapsed <= lifetime;
}

/// A window request cannot outlive its receiver, accepted ledger generation or
/// selected window epoch. Session/navigation permission facts are checked live.
class MessageWindowRequest {
  MessageWindowRequest._(this._owner, this._stamp, this._allowed);
  final WorkspaceMessageWindows _owner;
  final (int, (bool, int)?) _stamp;
  final bool Function() _allowed;
  int get generation => _stamp.$1;
  bool get current => _owner._admits(this);
}

/// Existing session/navigation, canonical generation, reply token, resource
/// permission and server permission facts. No Controller is retained here.
typedef MessageWindowAuthority = (String, int, String, String, String);
