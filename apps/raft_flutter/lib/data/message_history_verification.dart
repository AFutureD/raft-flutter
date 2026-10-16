import 'dart:async';

import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart' show RaftIdleTimer;
import 'package:raft_sync/raft_sync.dart' show mergeMessageProjection;

import 'history_read_policy.dart';
import 'history_gap_recovery.dart';
import 'message_history.dart';
import 'message_history_pages.dart';
import 'workspace_controller.dart';
import 'workspace_message_windows.dart';

/// Reconciles authorized saved ranges while preserving accepted projections.
class MessageHistoryVerification {
  static final _jobs = Expando<_HistoryVerificationJob>();

  /// One event-driven pass over saved ranges, including hidden conversations.
  /// Existing authorized pages supply the digest; no unsupported endpoint or
  /// wall-clock freshness can make a missed old edit appear verified.
  static void reconnect(WorkspaceController w) {
    HistoryGapRecovery.reconnect(w);
    final db = MessageHistoryPages.storage(w.cache);
    if (db == null ||
        !w.foreground ||
        !w.cacheWritable ||
        w.client.user == null ||
        w.client.serverId == null) {
      return;
    }
    final job = _jobs[w] ??= _HistoryVerificationJob();
    if (job.running) {
      job.again = true;
      return;
    }
    job.retry.cancel();
    job.running = true;
    db.reads.background(() async {
      var complete = false;
      try {
        do {
          job.again = false;
          complete = await _saved(w);
        } while (job.again &&
            w.cacheWritable &&
            w.foreground &&
            !db.reads.closed);
      } finally {
        job.running = false;
        if (identical(_jobs[w], job)) {
          if (complete || !w.cacheWritable || db.reads.closed) {
            job.retry.cancel();
            _jobs[w] = null;
          } else if (w.connected && w.foreground) {
            final seconds = 2 << job.attempt.clamp(0, 5);
            job.attempt++;
            job.zone.run(
              () => job.retry.start(
                Duration(seconds: seconds),
                () => reconnect(w),
              ),
            );
          }
        }
      }
    });
  }

  static void cancel(WorkspaceController w) {
    _jobs[w]?.retry.cancel();
    _jobs[w] = null;
  }

  static Future<bool> _saved(WorkspaceController w) async {
    final db = MessageHistoryPages.storage(w.cache)!;
    final user = w.client.user!.id,
        server = w.client.serverId!,
        origin = w.client.origin;
    final ticket = w.messageHistoryTicket(''), generation = w.ledger.generation;
    bool current() =>
        w.cacheWritable &&
        !db.reads.closed &&
        w.foreground &&
        w.client.user?.id == user &&
        w.client.serverId == server &&
        w.client.origin == origin &&
        w.ledger.generation == generation &&
        w.messageHistoryTicket('') == ticket;
    var complete = true;
    final ranges = await db.savedRanges(origin, user, server);
    for (final range in ranges) {
      if (!current()) return false;
      final known = range.$1;
      final scope = MessageHistoryPages.scope(
        w,
        known.channel,
        parent: known.parentChannel,
        parentMessage: known.parentMessage,
      );
      if (scope == null || scope.authority != known.authority) continue;
      final seal = w.messageHistoryTicket(scope.parentChannel);
      final request = w.messageWindows.request(
        allowed: () =>
            current() && seal == w.messageHistoryTicket(scope.parentChannel),
      );
      BigInt? before;
      while (request.current) {
        Map<String, dynamic>? response;
        if (!await _verify(
          w,
          request,
          scope,
          seal,
          before: before,
          reason: HistoryReadReason.reconnect,
          received: (page) => response = page,
        )) {
          complete = false;
          break;
        }
        final raw = response?['messages'];
        if (raw is! List ||
            raw.isEmpty ||
            response?['historyLimited'] == true) {
          break;
        }
        final oldest = raw
            .map((r) => BigInt.parse('${r['seq']}'))
            .reduce((a, b) => a < b ? a : b);
        if (raw.length < 50 ||
            oldest <= range.$2 ||
            before != null && oldest >= before) {
          break;
        }
        before = oldest;
      }
    }
    return complete && current();
  }

  static void tail(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryScope scope,
  ) {
    final storage = MessageHistoryPages.storage(w.cache);
    if (storage == null) return;
    final ticket = w.messageHistoryTicket(scope.parentChannel);
    storage.reads.background(
      () => _verify(w, request, scope, ticket, reason: HistoryReadReason.tail),
    );
  }

  static void schedule(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryPage page,
  ) {
    final db = MessageHistoryPages.storage(w.cache);
    if (db == null || !request.current || !w.foreground || !w.cacheWritable) {
      return;
    }
    final ticket = w.messageHistoryTicket(page.scope.parentChannel);
    final key = historyReadKey(page.scope, ticket, page.queryKey);
    if (!db.reads.claim(w, w.resumes.value, key, page.verifiedAt)) return;
    db.reads.background(() async {
      await _verify(
        w,
        request,
        page.scope,
        ticket,
        before: page.before,
        after: page.after,
        target: page.target,
        limit: page.limit,
        reason: HistoryReadReason.aged,
      );
    });
  }

  static void retained(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryPage fresh,
  ) {
    final db = MessageHistoryPages.storage(w.cache);
    if (db == null || !request.current || !w.foreground) return;
    final raw = (fresh.remotePage?['messages'] as List? ?? const []);
    if (raw.isEmpty || fresh['historyLimited'] == true) return;
    final first = raw
        .map((row) => BigInt.parse('${row['seq']}'))
        .reduce((a, b) => a < b ? a : b);
    final rows = w.messageWindows
        .rows(fresh.scope.channel)
        .where((row) => row.seq < first)
        .toList();
    if (rows.isEmpty) return;
    db.reads.background(() async {
      for (var end = rows.length; end > 0 && request.current; end -= 50) {
        final before = rows[end - 1].seq + BigInt.one;
        final local = await db.readPage(fresh.scope, before: before);
        final verified = await db.lastVerified(
          fresh.scope,
          historyQueryKey(before: before),
        );
        if (!request.current) return;
        schedule(
          w,
          request,
          MessageHistoryPage(
            {'messages': const <dynamic>[]},
            scope: fresh.scope,
            revision: fresh.revision,
            before: before,
            after: null,
            local: true,
            verifiedAt: verified ?? local?.verifiedAt,
          ),
        );
      }
    });
  }

  static void recheckContext(
    WorkspaceController w,
    MessageWindowRequest request,
    String id,
    String target,
  ) {
    final db = MessageHistoryPages.storage(w.cache);
    final scope = MessageHistoryPages.scope(w, id);
    if (db == null || scope == null || !request.current) return;
    db.reads.background(() async {
      final local = await db.readContext(scope, target);
      final verified = await db.lastVerified(
        scope,
        historyQueryKey(target: target),
      );
      if (!request.current) return;
      schedule(
        w,
        request,
        MessageHistoryPage(
          {'messages': const <dynamic>[]},
          scope: scope,
          revision: 0,
          before: null,
          after: null,
          local: true,
          focused: true,
          target: target,
          verifiedAt:
              verified ??
              (local is MessageHistoryPage ? local.verifiedAt : null),
        ),
      );
    });
  }

  /// Refreshes the visible saved rows and the latest page while preserving
  /// the existing timeline and context. Gap repair keeps its existing route.
  static Future<bool> refresh(WorkspaceController w) async {
    final db = MessageHistoryPages.storage(w.cache);
    if (db == null || !w.cacheWritable) return false;
    await w.syncVisibleScopes();
    var complete = true;
    for (final thread in [false, true]) {
      final id = thread ? w.threadChannelId : w.channel?.id;
      if (id == null) continue;
      final scope = MessageHistoryPages.scope(
        w,
        id,
        parent: thread ? w.threadParentChannelId : id,
        parentMessage: thread ? w.threadIdentity?.parentMessageId : null,
      );
      if (scope == null) continue;
      final ticket = w.messageHistoryTicket(scope.parentChannel);
      final request = w.messageWindows.request(
        thread: thread,
        allowed: () =>
            w.cacheWritable &&
            ticket == w.messageHistoryTicket(scope.parentChannel) &&
            w.messageWindows.notRevoked(id) &&
            w.messageWindows.notRevoked(scope.parentChannel) &&
            (thread ? w.threadChannelId == id : w.channel?.id == id),
      );
      final visible = w.messageWindows.rows(id);
      if (!await _verify(
        w,
        request,
        scope,
        ticket,
        reason: HistoryReadReason.manual,
      )) {
        complete = false;
      }
      for (var end = visible.length; end > 0 && request.current; end -= 50) {
        // Explicit refresh bypasses age and visit suppression. The shared
        // transport still coalesces an identical request already in flight.
        if (!await _verify(
          w,
          request,
          scope,
          ticket,
          before: visible[end - 1].seq + BigInt.one,
          reason: HistoryReadReason.manual,
        )) {
          complete = false;
        }
      }
    }
    return complete;
  }

  static Future<bool> _verify(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryScope scope,
    Object ticket, {
    BigInt? before,
    BigInt? after,
    String? target,
    int limit = 50,
    required HistoryReadReason reason,
    void Function(Map<String, dynamic>)? received,
  }) async {
    final db = MessageHistoryPages.storage(w.cache);
    if (db == null) return false;
    bool current() =>
        request.current &&
        w.cacheWritable &&
        !db.reads.closed &&
        ticket == w.messageHistoryTicket(scope.parentChannel) &&
        w.messageWindows.notRevoked(scope.channel) &&
        w.messageWindows.notRevoked(scope.parentChannel);
    if (!current()) return false;
    final initial = {
      for (final row in w.ledger.messages(scope.channel))
        row['id'] as String: row,
    };
    final shown = w.messageWindows.rows(scope.channel);
    final lower = shown.isEmpty ? null : shown.first.seq;
    final upper = shown.isEmpty ? null : shown.last.seq;
    try {
      final page = await MessageHistoryPages.load(
        cache: w.cache,
        scope: scope,
        current: current,
        held: () => w.ledger.messages(scope.channel),
        ticket: ticket,
        before: before,
        after: after,
        target: target,
        focused: target != null,
        limit: limit,
        localFirst: false,
        reason: reason,
        remote: () async => target == null
            ? w.client.messagePage(
                scope.channel,
                before: before,
                after: after,
                limit: limit,
              )
            : Map<String, dynamic>.from(
                await w.client.get(
                  '/messages/context/$target',
                  query: {'channelId': scope.channel},
                ),
              ),
      );
      if (!current() || page is! MessageHistoryPage) return false;
      await db.acceptPage(page);
      if (!current()) return false;
      received?.call(page.remotePage ?? page);
      w.mergeThreadSummaries(
        scope.channel,
        (page.remotePage ?? page)['threadSummariesByParentMessageId'],
      );
      final raw = (page.remotePage?['messages'] as List? ?? const []);
      final ids = {...initial.keys, for (final row in raw) row['id'] as String};
      final stored = await db.projections(scope, ids);
      if (!current()) return false;
      final accepted = <Map<String, dynamic>>[];
      final limited = page['historyLimited'] == true;
      final allowed = {for (final row in raw) row['id'] as String};
      for (final id in ids) {
        final pending = db.receiver.pendingUpdate(scope, id);
        if (db.receiver.hasRow(scope, id) && pending == null ||
            !identical(initial[id], w.ledger.message(scope.channel, id))) {
          continue;
        }
        if (stored.containsKey(id) && stored[id] == null ||
            limited && !allowed.contains(id)) {
          w.ledger.remove(scope.channel, id);
          w.visibleIds[scope.channel]?.remove(id);
          continue;
        }
        final row = stored[id];
        if (row == null) continue;
        final seq = BigInt.parse('${row['seq']}');
        if (initial.containsKey(id) ||
            lower != null && upper != null && seq >= lower && seq <= upper) {
          accepted.add(
            pending == null ? row : mergeMessageProjection(row, pending),
          );
        }
      }
      w.messageWindows.acceptRows(
        request,
        scope.channel,
        accepted,
        authoritative: true,
        visible: accepted
            .where(
              (row) =>
                  w.visibleIds[scope.channel]?.contains(row['id']) == true ||
                  !initial.containsKey(row['id']) &&
                      lower != null &&
                      upper != null &&
                      BigInt.parse('${row['seq']}') >= lower &&
                      BigInt.parse('${row['seq']}') <= upper,
            )
            .map((row) => row['id'] as String),
      );
      w.messageSync.replaceBodies(scope.channel, accepted);
      final sequences = raw.map((row) => BigInt.parse('${row['seq']}')).toList()
        ..sort();
      final coversOldest =
          after == null &&
          (sequences.isEmpty || lower == null || sequences.first <= lower);
      final boundary = coversOldest && target == null
          ? await db.readPage(scope, before: before, limit: limit)
          : null;
      if (!current()) return false;
      final more = limited
          ? false
          : target != null && coversOldest
          ? page['hasOlder'] as bool?
          : boundary?.hasMore;
      if (w.threadChannelId == scope.channel) {
        w.threadHistoryLimited = limited;
        if (more != null) w.threadHasMore = more;
      } else if (w.channel?.id == scope.channel) {
        w.historyLimited = limited;
        if (more != null) w.hasMore = more;
      }
      w.notifyListeners();
      await w.saveHistoryWindow(
        scope.channel,
        thread: w.threadChannelId == scope.channel,
      );
      return current();
    } on RaftApiException catch (error) {
      if (!current()) return false;
      if (target != null && error.status == 404) {
        // A missing target is not proof that its entire channel is revoked.
        // A complete page around its saved seq can confirm the deletion.
        final held = initial[target],
            sequence = BigInt.tryParse('${initial[target]?['seq']}');
        if (held != null && sequence != null) {
          return _verify(
            w,
            request,
            scope,
            ticket,
            before: sequence + BigInt.one,
            reason: reason,
          );
        }
      } else if (error.status == 403 || error.status == 404) {
        w.rejectHistoryRead(scope.channel);
        await w.flushCache();
      }
      db.reads.count(HistoryReadReason.failed);
      return false;
    } catch (_) {
      // A transient read failure leaves the accepted local range on screen.
      if (current()) db.reads.count(HistoryReadReason.failed);
      return false;
    }
  }
}

class _HistoryVerificationJob {
  bool again = false, running = false;
  int attempt = 0;
  final zone = Zone.current;
  final retry = RaftIdleTimer(yieldToAnimation: false);
}
