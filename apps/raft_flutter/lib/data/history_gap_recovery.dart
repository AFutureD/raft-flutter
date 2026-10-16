import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:raft_ui/raft_ui.dart' show RaftIdleTimer;

import 'history_gaps.dart';
import 'message_history.dart';
import 'history_read_policy.dart';
import 'history_range_reads.dart';
import 'message_history_verification.dart';
import 'message_history_pages.dart';
import 'workspace_controller.dart';

/// Event-driven repair for an actually presented conversation. Failed gaps
/// retry with bounded backoff while connected, or resume on reconnect.
class HistoryGapRecovery extends ChangeNotifier {
  HistoryGapRecovery._(this.w, this.thread);
  final WorkspaceController w;
  final bool thread;
  static final _owners = Expando<Map<bool, HistoryGapRecovery>>();
  static HistoryGapRecovery of(WorkspaceController w, bool thread) =>
      (_owners[w] ??= {}).putIfAbsent(
        thread,
        () => HistoryGapRecovery._(w, thread),
      );
  static void reconnect(WorkspaceController w) {
    for (final value in _owners[w]?.values ?? <HistoryGapRecovery>[]) {
      value._retry.cancel();
      value._attempt = 0;
      value._attempted.clear();
      value._failed.clear();
      value.refresh();
    }
  }

  final _views = <Object>{};
  final _attempted = <Object>{}, _failed = <String>{};
  final _gaps = <String, HistoryGap>{};
  HistoryGapQueries? _source;
  bool _running = false, _again = false, _closed = false;
  Object? _identity;
  int _attempt = 0;
  final _zone = Zone.current;
  final _retry = RaftIdleTimer(yieldToAnimation: false);
  bool contains(String id) => _gaps.containsKey(id);
  bool failed(String id) => _failed.contains(id);

  void start(Object view) {
    if (!_views.add(view) || _views.length > 1) return;
    _source = MessageHistoryPages.storage(w.deviceStore.cache)?.gaps;
    w.addListener(refresh);
    _source?.addListener(refresh);
    refresh();
  }

  void stop(Object view) {
    _views.remove(view);
    if (_views.isNotEmpty) return;
    _closed = true;
    HistoryRangeReads.of(w).restart();
    _retry.cancel();
    w.removeListener(refresh);
    _source?.removeListener(refresh);
    _owners[w]?.remove(thread);
    dispose();
  }

  void refresh() {
    if (_closed || _views.isEmpty) return;
    if (_running) {
      _again = true;
      return;
    }
    final db = MessageHistoryPages.storage(w.deviceStore.cache);
    if (db == null) return;
    _running = true;
    db.reads.background(() async {
      try {
        do {
          _again = false;
          await _scan(db);
        } while (_again && !_closed);
      } finally {
        _running = false;
      }
    });
  }

  Future<void> _scan(MessageHistoryStorage db) async {
    final id = thread ? w.threadChannelId : w.channel?.id;
    final visible = thread ? w.threadWindow?.visible : w.messageWindow?.visible;
    if (id == null || visible != true || !w.foreground || !w.deviceStore.writable) {
      if (_gaps.isNotEmpty && !_closed) {
        _gaps.clear();
        notifyListeners();
      }
      return;
    }
    final scope = MessageHistoryPages.scope(
      w,
      id,
      parent: thread ? w.threadParentChannelId : id,
      parentMessage: thread ? w.threadParentMessageId : null,
    );
    if (scope == null) return;
    final ticket = w.messageHistoryTicket(scope.parentChannel);
    final range = MessageHistoryVerification.ranges(w, scope);
    final identity = (
      scope.origin,
      scope.principal,
      scope.server,
      scope.channel,
      scope.authority,
      ticket,
      w.navigationRevision,
      range,
      thread ? w.threadGeneration : w.channelGeneration,
    );
    if (_identity != identity) {
      _identity = identity;
      _attempted.clear();
      _failed.clear();
      _retry.cancel();
      _attempt = 0;
    }
    final request = w.messageWindows.request(
      thread: thread,
      allowed: () =>
          w.deviceStore.writable &&
          ticket == w.messageHistoryTicket(scope.parentChannel) &&
          id == (thread ? w.threadChannelId : w.channel?.id),
    );
    bool current() =>
        !_closed && request.current && range.current && identity == _identity;
    final savedGaps = await db.gaps.readSaved(scope);
    final gaps = range.remaining(savedGaps);
    if (!current()) return;
    final changed = !setEquals(
      _gaps.keys.toSet(),
      gaps.map((g) => g.newerId).toSet(),
    );
    _gaps
      ..clear()
      ..addEntries(gaps.map((g) => MapEntry(g.newerId, g)));
    _failed.removeWhere((id) => !_gaps.containsKey(id));
    if (changed) notifyListeners();
    if (w.loadingOlder) return;
    final next = gaps.reversed
        .where((gap) => !_attempted.contains((identity, gap.before)))
        .firstOrNull;
    if (next == null) return;
    _attempted.add((identity, next.before));
    _failed.remove(next.newerId);
    notifyListeners();
    var success = false;
    w.loadingOlder = true;
    w.notifyListeners();
    try {
      final proof = await MessageHistoryVerification.readRange(
        w,
        request,
        scope,
        before: next.before,
        reason: HistoryReadReason.gap,
      );
      success = proof != null;
      if (proof != null && !proof.limited && proof.lower <= proof.upper) {
        // Merged coverage now prevents repeats; retain attempts only for an
        // unproven boundary, not one entry for every successful history page.
        _attempted.remove((identity, next.before));
      }
      if (success && current()) db.memory.direction(w, id, older: true);
    } finally {
      if (request.current) {
        w.loadingOlder = false;
        w.notifyListeners();
      }
    }
    if (!current()) return;
    if (!success) {
      _failed.add(next.newerId);
      notifyListeners();
      if (w.connected && w.foreground && !_retry.isActive) {
        final delay = Duration(seconds: 2 << _attempt.clamp(0, 5));
        _attempt++;
        _zone.run(
          () => _retry.start(delay, () {
            if (_closed || _identity != identity) return;
            _attempted.remove((identity, next.before));
            refresh();
          }),
        );
      }
    } else {
      _attempt = 0;
      _retry.cancel();
    }
    // Accepted coverage may leave a smaller interval. Verify its new boundary
    // rather than retrying the same failed request.
    _again = true;
  }
}
