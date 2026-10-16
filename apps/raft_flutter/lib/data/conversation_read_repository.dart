import 'dart:async';

import 'package:raft_client/raft_client.dart';
import 'package:raft_sync/raft_sync.dart';

import 'user_activity.dart';

/// Read cursors and unread projections for one workspace receiver.
///
/// A borrowed presentation keeps its own projections and local storage, but
/// reads the source's effective cursor through the supplied port. Controller
/// entrypoints retain source dispatch, visibility policy and event ordering.
class ConversationReadRepository {
  ConversationReadRepository(
    this.client, {
    required this._readState,
    required this._revokedChannels,
    required this._channelId,
    required this._threadChannelId,
    required this._mobileNavigation,
    required this._mayMarkRead,
    required this._markRead,
    required this._channelRows,
    required this._messages,
    required this._isContext,
    required this._hasNewer,
    required this._save,
    required this._changed,
    required this._prefetch,
  });

  final RaftClient client;
  final ReadStateLedger Function() _readState;
  final Set<String> Function() _revokedChannels;
  final String? Function() _channelId, _threadChannelId;
  final bool Function() _mobileNavigation, _hasNewer;
  final bool Function(String) _mayMarkRead, _isContext;
  final Future<void> Function(String) _markRead;
  final List<RaftChannel> Function() _channelRows;
  final List<Map<String, dynamic>> Function(String) _messages;
  final Future<void> Function(String, String, dynamic) _save;
  final void Function() _changed;
  final Future<void> Function() _prefetch;

  final localReadState = ReadStateLedger();
  Map<String, int> unread = {};
  Set<String> mentions = {}, newFlags = {};

  /// Latest activity from snapshots and live rows, including own messages.
  final Map<String, BigInt> latestActivity = {};

  /// Existing open-time receipt counter and per-receiver timeline position.
  /// Projection reset deliberately leaves both objects intact.
  final Map<String, int> readPosts = {};
  final scrolledAway = RaftTimelineBottoms();

  void persistReadState() {
    final serverId = client.serverId, principal = client.user?.id;
    if (serverId == null || principal == null) return;
    _save('read-frontiers', '', _readState().exportFor(serverId, principal));
    _save('unread', '', Map.of(unread));
  }

  void persistUnread() {
    if (client.serverId == null || client.user == null) return;
    _save('unread', '', Map.of(unread));
  }

  void receiveUnread(Map<String, dynamic> row) {
    final id = row['channelId'];
    if (id is! String || _revokedChannels().contains(id)) return;
    final seq = canonicalWireSeq(row['seq']);
    if (seq != null && seq > (latestActivity[id] ?? BigInt.zero)) {
      latestActivity[id] = seq;
    }
    if ((id == _channelId() || id == _threadChannelId()) &&
        _mayMarkRead(id) &&
        scrolledAway.readsLiveArrival(id, _mobileNavigation())) {
      unawaited(_markRead(id));
      return;
    }
    if (row['senderType'] == 'user' && row['senderId'] == client.user?.id) {
      return;
    }
    final known = _channelRows().where((c) => c.id == id).firstOrNull;
    final counted = known == null
        ? unread.containsKey(id)
        : known.type != 'channel' || known.joined;
    if (!counted) return;
    final serverId = client.serverId, principal = client.user?.id;
    final frontier = serverId == null || principal == null
        ? null
        : _readState().state(serverId, principal, id);
    if (seq != null &&
        frontier != null &&
        BigInt.from(frontier['maxReadSeq']) >= seq) {
      return;
    }
    unread = {...unread, id: (unread[id] ?? 0) + 1};
    if (_mentionsMember(row)) mentions = {...mentions, id};
    persistUnread();
    unawaited(_prefetch());
  }

  bool _mentionsMember(Map<String, dynamic> row) {
    final me = client.user?.id, list = row['mentions'];
    return me != null &&
        list is List &&
        list.any((m) => m is Map && m['type'] == 'user' && m['id'] == me);
  }

  void clearMention(String id) {
    if (mentions.contains(id)) mentions = {...mentions}..remove(id);
    if (newFlags.contains(id)) newFlags = {...newFlags}..remove(id);
  }

  void projectReadState(String id) {
    final serverId = client.serverId, principal = client.user?.id;
    if (serverId == null || principal == null || !unread.containsKey(id)) {
      return;
    }
    final state = _readState().state(serverId, principal, id);
    if (state == null) return;
    final maxRead = BigInt.from(state['maxReadSeq']);
    final rows = _messages(id);
    var latest = latestActivity[id];
    if (rows.isNotEmpty) {
      final last = RaftMessage(rows.last).seq;
      if (latest == null || last > latest) latest = last;
    }
    int? count;
    if (latest != null && maxRead >= latest) {
      count = 0;
    } else if (rows.isNotEmpty &&
        !_isContext(id) &&
        !(id == _channelId() && _hasNewer()) &&
        RaftMessage(rows.first).seq <= maxRead) {
      count = rows
          .where(
            (row) =>
                RaftMessage(row).seq > maxRead &&
                !(row['senderType'] == 'user' && row['senderId'] == principal),
          )
          .length;
    }
    if (count == null || unread[id] == count) return;
    unread = {...unread, id: count};
    if (count == 0) clearMention(id);
  }

  Future<void> refreshUnread() async {
    final requestGeneration = _readState().generation;
    final serverId = client.serverId, principal = client.user?.id;
    if (serverId == null || principal == null) return;
    try {
      final value = await client.get('/channels/unread', query: {'summary': 1});
      if (client.serverId != serverId || client.user?.id != principal) return;
      final counts = value is Map ? value['channels'] ?? value : {};
      if (counts is Map) {
        final next = <String, int>{};
        final nextMentions = <String>{};
        final nextNew = <String>{};
        for (final e in counts.entries) {
          final id = e.key.toString(), entry = e.value;
          if (entry is num) {
            next[id] = entry.toInt();
            continue;
          }
          if (entry is! Map) continue;
          final frontier = entry['readState'];
          final outcome = _readState().consumeSnapshot(
            frontier,
            serverId: serverId,
            principalId: principal,
            scopeId: id,
            generationAtRequest: requestGeneration,
            // RisingWave projects this endpoint asynchronously. An absent row
            // cannot erase a newer positive HTTP/socket acknowledgement.
            authoritativeAbsence: false,
          );
          final state = _readState().state(serverId, principal, id);
          final latest = frontier is Map && frontier['latestActivity'] is Map
              ? canonicalUint64(frontier['latestActivity']['seq'])
              : null;
          if (latest != null) latestActivity[id] = latest;
          final fullyRead =
              state != null &&
              latest != null &&
              BigInt.from(state['maxReadSeq']) >= latest;
          next[id] = fullyRead
              ? 0
              : outcome == 'corrupt'
              ? (unread[id] ?? 0)
              : ((entry['unreadCount'] ?? 0) as num).toInt();
          if (entry['hasMention'] == true && next[id]! > 0) {
            nextMentions.add(id);
          }
          if (entry['hasNew'] == true) nextNew.add(id);
        }
        unread = next;
        mentions = nextMentions;
        newFlags = nextNew;
        persistReadState();
      }
      _changed();
      unawaited(_prefetch());
    } catch (_) {
      /* Keep accepted counts through transient failures. */
    }
  }

  void markUnreadLocally(String id) {
    if ((unread[id] ?? 0) > 0) return;
    unread = {...unread, id: 1};
    _changed();
  }

  void applyThreadUnread(dynamic threadChannelId, dynamic summary) {
    if (threadChannelId is! String ||
        summary is! Map ||
        !unread.containsKey(threadChannelId) ||
        threadChannelId == _threadChannelId()) {
      return;
    }
    final count = summary['unreadCount'];
    if (count is! int || count < 0 || unread[threadChannelId] == count) return;
    unread = {...unread, threadChannelId: count};
    persistUnread();
  }
}
