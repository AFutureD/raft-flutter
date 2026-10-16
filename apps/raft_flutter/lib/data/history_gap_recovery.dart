import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:raft_ui/raft_ui.dart' show RaftIdleTimer;

import 'history_gaps.dart';
import 'message_history.dart';
import 'message_history_navigation.dart';
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
  // Accepted wire coverage remains useful for the current online window even
  // when the hard admission guard deliberately declines new disk bodies.
  final _proofs = <(BigInt, BigInt)>[];
  final _wireEdges = <BigInt, String>{};
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
    _source = MessageHistoryPages.storage(w.cache)?.gaps;
    w.addListener(refresh);
    _source?.addListener(refresh);
    refresh();
  }

  void stop(Object view) {
    _views.remove(view);
    if (_views.isNotEmpty) return;
    _closed = true;
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
    final db = MessageHistoryPages.storage(w.cache);
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
    if (id == null || visible != true || !w.foreground || !w.cacheWritable) {
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
    final identity = (
      scope.origin,
      scope.principal,
      scope.server,
      scope.channel,
      scope.authority,
      ticket,
      w.navigationRevision,
      thread ? w.threadGeneration : w.channelGeneration,
    );
    if (_identity != identity) {
      _identity = identity;
      _proofs.clear();
      _wireEdges.clear();
      _attempted.clear();
      _failed.clear();
      _retry.cancel();
      _attempt = 0;
    }
    final request = w.messageWindows.request(
      thread: thread,
      allowed: () =>
          w.cacheWritable &&
          ticket == w.messageHistoryTicket(scope.parentChannel) &&
          id == (thread ? w.threadChannelId : w.channel?.id),
    );
    bool current() => !_closed && request.current && identity == _identity;
    final savedGaps = await db.gaps.readSaved(scope);
    if (savedGaps.isEmpty) {
      _proofs.clear();
      _wireEdges.clear();
    }
    final gaps = _remaining(savedGaps);
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
    final success = await MessageHistoryNavigation.page(
      w,
      thread: thread,
      newer: false,
      gapBefore: next.before,
      silent: true,
      requestFor: (_) => request,
      summaries: w.mergeThreadSummaries,
      proved: _proved,
    );
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

  void _proved(List<Map<String, dynamic>> rows, BigInt before) {
    final ordered = [...rows]
      ..sort(
        (a, b) =>
            BigInt.parse('${a['seq']}').compareTo(BigInt.parse('${b['seq']}')),
      );
    final first = ordered.isEmpty
        ? BigInt.zero
        : BigInt.parse('${ordered.first['seq']}');
    final lower = ordered.length < 50 ? BigInt.zero : first;
    _proofs.add((lower, before - BigInt.one));
    if (ordered.isNotEmpty) _wireEdges[first] = ordered.first['id'] as String;
    _proofs.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(BigInt, BigInt)>[];
    for (final proof in _proofs) {
      if (merged.isEmpty || merged.last.$2 + BigInt.one < proof.$1) {
        merged.add(proof);
      } else {
        final previous = merged.removeLast();
        merged.add((
          previous.$1,
          previous.$2 > proof.$2 ? previous.$2 : proof.$2,
        ));
      }
    }
    _proofs
      ..clear()
      ..addAll(merged);
    _wireEdges.removeWhere(
      (seq, _) => !_proofs.any((proof) => proof.$1 == seq),
    );
  }

  List<HistoryGap> _remaining(List<HistoryGap> gaps) {
    final result = <HistoryGap>[];
    for (final gap in gaps) {
      var intervals = [
        ((gap.older ?? BigInt.zero) + BigInt.one, gap.before - BigInt.one),
      ];
      for (final proof in _proofs) {
        intervals = [
          for (final span in intervals)
            if (proof.$2 < span.$1 || proof.$1 > span.$2)
              span
            else ...[
              if (span.$1 < proof.$1) (span.$1, proof.$1 - BigInt.one),
              if (span.$2 > proof.$2) (proof.$2 + BigInt.one, span.$2),
            ],
        ];
      }
      for (final span in intervals) {
        final before = span.$2 + BigInt.one;
        final id = before == gap.before ? gap.newerId : _wireEdges[before];
        if (id != null) {
          result.add(HistoryGap(id, before, older: span.$1 - BigInt.one));
        }
      }
    }
    return result;
  }
}
