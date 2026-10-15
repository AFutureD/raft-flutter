import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:raft_ui/raft_ui.dart' show RaftIdleTimer;

import '../data/history_capacity.dart';
import '../data/message_history.dart';
import '../data/workspace_cache_codec.dart';
import 'message_history.dart' show HistoryOperationOrder;

/// Retention shares the message connection, permission purges and revision
/// fence. Shared B-tree pages are apportioned by encoded row/key weight;
/// [HistoryDiskUsage.databaseBytes] and WAL bytes are actual file sizes.
class SqliteHistoryCapacity implements HistoryCapacity {
  SqliteHistoryCapacity(
    this.db,
    this.order, {
    required this.ready,
    required this.advance,
    required this.now,
    required this.defaultBudget,
    this.automatic = true,
    this.pending,
  });
  final GeneratedDatabase db;
  final HistoryOperationOrder order;
  final Future<void> Function() ready;
  final Future<int> Function(MessageHistoryScope) advance;
  final DateTime Function() now;
  final int defaultBudget;
  final bool automatic;
  final Iterable<HistoryProtectedRows> Function()? pending;
  final _owners = <Object, Iterable<HistoryProtectedRows> Function()>{};
  final _pending = <HistoryAccount>{};
  final _dirty = <HistoryAccount, int>{};
  final _blocked = <HistoryAccount>{};
  final _unavailable = <HistoryAccount>{};
  final _maintenance = <HistoryAccount, Future<HistoryDiskUsage>>{};
  // Writes call changed() from a Drift transaction zone. A timer created in
  // that zone would later reuse its closed executor. Capture the store's
  // outer zone before any write transaction starts.
  final _backgroundZone = Zone.current;
  final _timer = RaftIdleTimer(yieldToAnimation: false);
  bool _closed = false;
  static const walLimit = 16 << 20;
  static const _scopeWhere =
      'origin=? AND principal=? AND server=? AND channel=?';

  List<Variable> _vars(Iterable<Object> values) => [
    for (final value in values)
      if (value is int) Variable(value) else Variable('$value'),
  ];
  Future<List<QueryRow>> _query(String sql, Iterable<Object> args) =>
      db.customSelect(sql, variables: _vars(args)).get();
  static String _weight(String p) =>
      '$p.byte_size+96+3*(length(cast($p.origin as blob))+'
      'length(cast($p.principal as blob))+length(cast($p.server as blob))+'
      'length(cast($p.channel as blob)))+2*length(cast($p.message_id as blob))+'
      '2*length($p.seq_key)';

  /// Cheap setup; the first indexed page is not held behind an old-row scan.
  Future<void> openNow() async {
    await db.customStatement('PRAGMA wal_autocheckpoint=256');
    await db.customStatement('PRAGMA journal_size_limit=$walLimit');
    await db.customStatement('''CREATE TABLE IF NOT EXISTS raft_history_sizes (
      origin TEXT NOT NULL, principal TEXT NOT NULL, payload INTEGER NOT NULL,
      weight INTEGER NOT NULL, rows INTEGER NOT NULL,
      PRIMARY KEY(origin,principal))''');
    await db.customStatement(
      '''CREATE TABLE IF NOT EXISTS raft_history_size_state (
      id INTEGER PRIMARY KEY, initialized INTEGER NOT NULL)''',
    );
    await db.customStatement('''INSERT OR IGNORE INTO raft_history_size_state
      VALUES(1,0)''');
    for (final op in ['insert', 'update', 'delete']) {
      final add = op != 'delete', subtract = op != 'insert';
      await db.customStatement(
        '''CREATE TRIGGER IF NOT EXISTS raft_history_size_$op
        AFTER ${op.toUpperCase()} ON raft_history_rows
        WHEN (SELECT initialized FROM raft_history_size_state WHERE id=1)=1
        BEGIN
        ${subtract ? '''UPDATE raft_history_sizes SET payload=payload-OLD.byte_size,
          weight=weight-(${_weight('OLD')}),rows=rows-(OLD.tombstone=0)
          WHERE origin=OLD.origin AND principal=OLD.principal;''' : ''}
        ${add ? '''INSERT INTO raft_history_sizes VALUES
          (NEW.origin,NEW.principal,NEW.byte_size,${_weight('NEW')},(NEW.tombstone=0))
          ON CONFLICT(origin,principal) DO UPDATE SET
          payload=payload+excluded.payload,weight=weight+excluded.weight,
          rows=rows+excluded.rows;''' : ''}
        ${subtract ? '''DELETE FROM raft_history_sizes WHERE origin=OLD.origin
          AND principal=OLD.principal AND weight<=0;''' : ''}
        END''',
      );
    }
    await db.customStatement(
      '''CREATE TEMP TABLE IF NOT EXISTS history_protected (
      server TEXT NOT NULL, channel TEXT NOT NULL, id TEXT NOT NULL,
      PRIMARY KEY(server,channel,id))''',
    );
    await db.customStatement(
      '''CREATE TEMP TABLE IF NOT EXISTS history_protected_scopes (
      server TEXT NOT NULL, channel TEXT NOT NULL, PRIMARY KEY(server,channel))''',
    );
  }

  Future<void> _sizesNow() async {
    final state = await _query(
      'SELECT initialized FROM raft_history_size_state WHERE id=1',
      [],
    );
    if (state.single.read<int>('initialized') == 1) return;
    await db.transaction(() async {
      await db.customStatement('DELETE FROM raft_history_sizes');
      await db.customStatement(
        '''INSERT INTO raft_history_sizes
        SELECT r.origin,r.principal,sum(r.byte_size),sum(${_weight('r')}),
          sum(r.tombstone=0) FROM raft_history_rows r GROUP BY r.origin,r.principal''',
      );
      await db.customStatement(
        'UPDATE raft_history_size_state SET initialized=1 WHERE id=1',
      );
    });
  }

  @override
  void protect(
    Object owner,
    Iterable<HistoryProtectedRows> Function() current,
  ) => _owners[owner] = current;
  @override
  void release(Object owner) => _owners.remove(owner);
  void close() {
    _closed = true;
    _timer.cancel();
    _pending.clear();
    _dirty.clear();
    _blocked.clear();
    _unavailable.clear();
    _maintenance.clear();
    _owners.clear();
  }

  void cancel(HistoryAccount account) {
    _pending.remove(account);
    _dirty.remove(account);
    _blocked.remove(account);
    _unavailable.remove(account);
    _maintenance.remove(account);
    if (_pending.isEmpty) _timer.cancel();
  }

  void admitNow(MessageHistoryScope scope, int addedBytes) {
    if (addedBytes > 0 &&
        _unavailable.contains(HistoryAccount(scope.origin, scope.principal))) {
      throw const HistoryStorageUnavailable();
    }
    if (addedBytes > 0 &&
        _blocked.contains(HistoryAccount(scope.origin, scope.principal))) {
      throw const HistoryCapacityExceeded();
    }
  }

  /// A bounded amount of new body data schedules measurement; no polling.
  void changed(MessageHistoryScope scope, int bytes) {
    if (_closed) return;
    final account = HistoryAccount(scope.origin, scope.principal);
    final previous = _dirty[account];
    final total = _dirty[account] = (previous ?? 0) + math.max(0, bytes);
    if (automatic && (previous == null || total >= (8 << 20))) {
      _pending.add(account);
      if (!_timer.isActive) _schedule();
    }
  }

  void _schedule() => _backgroundZone.run(
    () => _timer.start(const Duration(seconds: 1), _next),
  );

  void _next() async {
    if (_closed || _pending.isEmpty) return;
    final account = _pending.first;
    _pending.remove(account);
    try {
      await maintain(account);
    } catch (_) {
      // The accepted rows and drafts stay. A read/settings action can retry.
    }
    if (!_closed && _pending.isNotEmpty) {
      _timer.start(const Duration(seconds: 1), _next);
    }
  }

  Future<int> _budgetNow(HistoryAccount a) async {
    final rows = await _query(
      "SELECT payload FROM workspace_cache WHERE origin=? AND principal=? AND server='' AND kind='history-budget' AND id=''",
      [a.origin, a.principal],
    );
    if (rows.isEmpty) return defaultBudget;
    final value = await decodeWorkspaceCache(
      rows.single.read<String>('payload'),
    );
    return value is int && historyBudgetTiers.contains(value)
        ? value
        : defaultBudget;
  }

  @override
  Future<void> setBudget(HistoryAccount a, int bytes) async {
    if (!historyBudgetTiers.contains(bytes)) {
      throw ArgumentError.value(bytes, 'bytes');
    }
    await order(() async {
      await ready();
      await db.customStatement(
        "INSERT INTO workspace_cache VALUES(?,?,'','history-budget','',?) ON CONFLICT(origin,principal,server,kind,id) DO UPDATE SET payload=excluded.payload",
        [a.origin, a.principal, '$bytes'],
      );
    });
    await maintain(a);
  }

  @override
  Future<bool> isKept(HistoryAccount a, String server, String channel) =>
      order(() async {
        await ready();
        return (await _query(
          "SELECT 1 FROM workspace_cache WHERE origin=? AND principal=? AND server=? AND kind='history-kept' AND id=?",
          [a.origin, a.principal, server, channel],
        )).isNotEmpty;
      });
  @override
  Future<void> keep(
    HistoryAccount a,
    String server,
    String channel,
    bool value,
  ) => order(() async {
    await ready();
    if (value) {
      await db.customStatement(
        "INSERT OR IGNORE INTO workspace_cache VALUES(?,?,?,'history-kept',?,'true')",
        [a.origin, a.principal, server, channel],
      );
    } else {
      await db.customStatement(
        "DELETE FROM workspace_cache WHERE origin=? AND principal=? AND server=? AND kind='history-kept' AND id=?",
        [a.origin, a.principal, server, channel],
      );
    }
  });

  @override
  Future<HistoryDiskUsage> usage(HistoryAccount a) => order(() async {
    await ready();
    return _usageNow(a);
  });

  Future<HistoryDiskUsage> _usageNow(
    HistoryAccount a, {
    bool protectedFull = false,
  }) async {
    await _sizesNow();
    final sizes = await _query('SELECT * FROM raft_history_sizes', []);
    var weight = 0, ownWeight = 0, rows = 0;
    for (final row in sizes) {
      weight += row.read<int>('weight');
      if (row.read<String>('origin') == a.origin &&
          row.read<String>('principal') == a.principal) {
        ownWeight = row.read<int>('weight');
        rows = row.read<int>('rows');
      }
    }
    final snapshots = await _query('''SELECT origin,principal,
      sum(length(cast(payload as blob))) AS bytes FROM workspace_cache
      WHERE kind IN ('window','thread-window','message-history','message-history-denied','history-anchor')
      GROUP BY origin,principal''', []);
    var snapshotWeight = 0, ownSnapshots = 0;
    for (final row in snapshots) {
      snapshotWeight += row.read<int>('bytes');
      if (row.read<String>('origin') == a.origin &&
          row.read<String>('principal') == a.principal) {
        ownSnapshots += row.read<int>('bytes');
      }
    }
    var allocated = 0, indexes = 0, workspace = 0, unused = 0;
    final allocation = await _query(
      'SELECT name,sum(pgsize) AS bytes,sum(unused) AS unused FROM dbstat GROUP BY name',
      [],
    );
    for (final row in allocation) {
      final name = row.read<String>('name'), bytes = row.read<int>('bytes');
      if (name.startsWith('raft_history_') ||
          name.startsWith('sqlite_autoindex_raft_history_')) {
        allocated += bytes;
        unused += row.read<int>('unused');
        if (name == 'raft_history_sequence' ||
            name == 'raft_history_lru' ||
            name.startsWith('sqlite_autoindex_')) {
          indexes += bytes;
        }
      } else if (name == 'workspace_cache' ||
          name == 'sqlite_autoindex_workspace_cache_1') {
        workspace += bytes;
      }
    }
    final allWorkspace = await _query(
      'SELECT coalesce(sum(length(cast(payload as blob))),0) AS n FROM workspace_cache',
      [],
    );
    final workspaceHistory =
        (workspace *
                snapshotWeight /
                math.max(1, allWorkspace.single.read<int>('n')))
            .ceil();
    allocated += workspaceHistory;
    final own = ownWeight + ownSnapshots, total = weight + snapshotWeight;
    int share(int value) => total == 0 ? 0 : (value * own / total).ceil();
    Future<int> pragma(String name) async =>
        (await _query('PRAGMA $name', [])).single.data.values.single as int;
    final free = await pragma('freelist_count') * await pragma('page_size');
    final databases = await _query('PRAGMA database_list', []);
    final path = databases
        .where((r) => r.read<String>('name') == 'main')
        .single
        .read<String>('file');
    var physical = await pragma('page_count') * await pragma('page_size'),
        wal = 0;
    if (path.isNotEmpty) {
      final file = File(path), log = File('$path-wal');
      physical = await file.length();
      if (await log.exists()) wal = await log.length();
    }
    final budget = await _budgetNow(a), walShare = share(wal);
    final reserve = own == 0
        ? 0
        : math.min(walLimit, budget == 0 ? walLimit : budget ~/ 64);
    return HistoryDiskUsage(
      budget: budget,
      accountBytes: share(allocated + free) + walShare,
      reservedWalBytes: math.max(0, reserve - walShare),
      databaseBytes: physical,
      walBytes: wal,
      indexBytes: share(indexes),
      freeBytes: free,
      rows: rows,
      reclaimableAccountBytes: share(free + unused),
      pendingCompaction: free > 0 || unused > allocated ~/ 5,
      protectedFull: protectedFull || _blocked.contains(a),
    );
  }

  @override
  Future<HistoryDiskUsage> maintain(HistoryAccount a, {bool compact = false}) {
    final running = _maintenance[a];
    if (running != null) {
      return compact
          ? running.then((_) => maintain(a, compact: true))
          : running;
    }
    late final Future<HistoryDiskUsage> result;
    bool current() => !_closed && identical(_maintenance[a], result);
    result = _maintain(a, compact: compact, current: current).then(
      (value) {
        if (current()) _unavailable.remove(a);
        return value;
      },
      onError: (Object error, StackTrace stack) {
        if (current()) _unavailable.add(a);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _maintenance[a] = result;
    return result.whenComplete(() {
      if (identical(_maintenance[a], result)) _maintenance.remove(a);
    });
  }

  Future<HistoryDiskUsage> _maintain(
    HistoryAccount a, {
    required bool compact,
    required bool Function() current,
  }) async {
    void live() {
      if (!current()) throw StateError('History maintenance retired.');
    }

    var measured = await order(() async {
      await ready();
      live();
      await db.customSelect('PRAGMA wal_checkpoint(TRUNCATE)').get();
      return _usageNow(a);
    });
    final target =
        measured.budget != 0 && measured.retainedCharge > measured.budget
        ? measured.budget * 8 ~/ 10
        : 0;
    var blocked = false;
    for (
      var round = 0;
      round < 32 && target > 0 && measured.retainedCharge > target;
      round++
    ) {
      if (_closed) break;
      final dropped = await order(() async {
        await ready();
        live();
        return _evictNow(a);
      });
      if (dropped == 0) {
        blocked = true;
        break;
      }
      measured = await usage(a);
    }
    if (compact || target > 0 || measured.freeBytes > 0) {
      await order(() async {
        await ready();
        live();
        final mode = (await _query(
          'PRAGMA auto_vacuum',
          [],
        )).single.data.values.single;
        if (compact &&
            (mode == 0 ||
                measured.reclaimableAccountBytes >
                    measured.accountBytes ~/ 5)) {
          await db.customStatement('PRAGMA auto_vacuum=INCREMENTAL');
          await db.customStatement('VACUUM');
        } else if (mode != 0) {
          await db.customStatement('PRAGMA incremental_vacuum(4096)');
        }
        await db.customSelect('PRAGMA wal_checkpoint(TRUNCATE)').get();
      });
    }
    measured = await order(() => _usageNow(a));
    live();
    _dirty[a] = 0;
    // The 80% goal yields to protected records. Only an inability to stay
    // within the limit stops subsequent positive-size writes.
    blocked =
        blocked &&
        measured.budget != 0 &&
        measured.retainedCharge > measured.budget;
    if (blocked) {
      _blocked.add(a);
    } else {
      _blocked.remove(a);
    }
    measured = measured.withProtectedFull(blocked);
    if (!blocked &&
        measured.budget != 0 &&
        measured.retainedCharge > measured.budget &&
        !_closed) {
      _pending.add(a);
      if (!_timer.isActive) _schedule();
    }
    return measured;
  }

  Future<int> _evictNow(HistoryAccount a) async {
    await db.customStatement(
      '''CREATE INDEX IF NOT EXISTS raft_history_lru
      ON raft_history_rows(origin,principal,touched,server,channel,message_id)''',
    );
    return db.transaction(() async {
      await db.customStatement('DELETE FROM history_protected');
      await db.customStatement('DELETE FROM history_protected_scopes');
      final held = <(String, String, String)>{};
      final entire = <(String, String)>{};
      for (final read in [..._owners.values, ?pending]) {
        for (final scope in read()) {
          if (scope.account != a) continue;
          if (scope.wholeChannel) entire.add((scope.server, scope.channel));
          for (final id in scope.ids) {
            held.add((scope.server, scope.channel, id));
          }
        }
      }
      await db.batch((batch) {
        for (final key in held) {
          batch.customStatement('INSERT INTO history_protected VALUES(?,?,?)', [
            key.$1,
            key.$2,
            key.$3,
          ]);
        }
        for (final key in entire) {
          batch.customStatement(
            'INSERT INTO history_protected_scopes VALUES(?,?)',
            [key.$1, key.$2],
          );
        }
      });
      final candidates = await _query(
        '''SELECT r.server,r.channel,r.message_id,r.seq_key FROM raft_history_rows r
        WHERE r.origin=? AND r.principal=? AND r.tombstone=0
        AND NOT EXISTS (SELECT 1 FROM history_protected p WHERE p.server=r.server
          AND p.channel=r.channel AND p.id=r.message_id)
        AND NOT EXISTS (SELECT 1 FROM history_protected_scopes p WHERE p.server=r.server
          AND p.channel=r.channel)
        AND NOT EXISTS (SELECT 1 FROM workspace_cache k WHERE k.origin=r.origin
          AND k.principal=r.principal AND k.server=r.server
          AND k.kind='history-kept' AND k.id=r.channel)
        AND NOT EXISTS (SELECT 1 FROM workspace_cache d WHERE d.origin=r.origin
          AND d.principal=r.principal AND d.kind='draft'
          AND instr(d.payload,r.message_id)>0)
        ORDER BY r.touched,r.server,r.channel,r.message_id LIMIT 200''',
        [a.origin, a.principal],
      );
      final groups = <(String, String), List<QueryRow>>{};
      for (final row in candidates) {
        groups
            .putIfAbsent((
              row.read<String>('server'),
              row.read<String>('channel'),
            ), () => [])
            .add(row);
      }
      for (final entry in groups.entries) {
        final server = entry.key.$1, channel = entry.key.$2;
        final markers = await _query(
          "SELECT payload FROM workspace_cache WHERE origin=? AND principal=? AND server=? AND kind='message-history' AND id=?",
          [a.origin, a.principal, server, channel],
        );
        final marker = markers.isEmpty
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(
                await decodeWorkspaceCache(
                  markers.single.read<String>('payload'),
                ) as Map,
              );
        final scope = MessageHistoryScope(
          origin: a.origin,
          principal: a.principal,
          server: server,
          channel: channel,
          parentChannel: marker['parentChannelId'] as String? ?? channel,
          authority: marker['authority'] as String? ?? '',
        );
        final revision = await advance(scope);
        final ids = entry.value
            .map((r) => r.read<String>('message_id'))
            .toList();
        // Retain a lightweight eviction receipt. It fences older in-flight
        // responses, distinguishes a reclaimed page from a never-seen page,
        // and prevents rollback shadows from silently repopulating it.
        await db.customStatement(
          "UPDATE raft_history_rows SET tombstone=2,payload='{}',byte_size=0,revision=? WHERE $_scopeWhere AND message_id IN (${List.filled(ids.length, '?').join(',')})",
          [revision, ...scope.key, ...ids],
        );
        final sequences =
            entry.value.map((r) => r.read<String>('seq_key')).toList()..sort();
        await _invalidateNow(scope, sequences.first, sequences.last);
        await _shadowNow(scope, ids.toSet());
      }
      await db.customStatement('DELETE FROM history_protected');
      await db.customStatement('DELETE FROM history_protected_scopes');
      return candidates.length;
    });
  }

  Future<void> _invalidateNow(
    MessageHistoryScope scope,
    String lower,
    String upper,
  ) async {
    final prior = await _query(
      'SELECT lower_key,upper_key,verified FROM raft_history_ranges WHERE $_scopeWhere AND lower_key<=? ORDER BY lower_key DESC LIMIT 1',
      [...scope.key, lower],
    );
    final affected = [
      if (prior.isNotEmpty &&
          prior.single.read<String>('upper_key').compareTo(lower) >= 0)
        prior.single,
      ...await _query(
        'SELECT lower_key,upper_key,verified FROM raft_history_ranges WHERE $_scopeWhere AND lower_key>? AND lower_key<=?',
        [...scope.key, lower, upper],
      ),
    ];
    for (final range in affected) {
      final lo = range.read<String>('lower_key'),
          hi = range.read<String>('upper_key'),
          stamp = range.read<int>('verified');
      await db.customStatement(
        'DELETE FROM raft_history_ranges WHERE $_scopeWhere AND lower_key=? AND upper_key=?',
        [...scope.key, lo, hi],
      );
      Future<void> put(String first, String last) => db.customStatement(
        'INSERT INTO raft_history_ranges VALUES(?,?,?,?,?,?,?)',
        [...scope.key, first, last, stamp],
      );
      if (lo.compareTo(lower) < 0) {
        await put(lo, historySequenceKey(BigInt.parse(lower) - BigInt.one));
      }
      if (hi.compareTo(upper) > 0) {
        await put(historySequenceKey(BigInt.parse(upper) + BigInt.one), hi);
      }
    }
    await db.customStatement(
      'DELETE FROM raft_history_checks WHERE $_scopeWhere',
      scope.key,
    );
  }

  Future<void> _shadowNow(
    MessageHistoryScope scope,
    Set<String> removed,
  ) async {
    final shadows = await _query(
      "SELECT rowid,payload FROM workspace_cache WHERE origin=? AND principal=? AND server=? AND ((kind='window' AND id=?) OR (kind='thread-window' AND CASE WHEN json_valid(payload) THEN json_extract(payload,'\$.threadChannelId') END=?))",
      [
        scope.origin,
        scope.principal,
        scope.server,
        scope.channel,
        scope.channel,
      ],
    );
    for (final record in shadows) {
      final raw = await decodeWorkspaceCache(record.read<String>('payload'));
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['windowKind'] != 'tail' ||
          raw['authority'] != scope.authority ||
          raw['messages'] is! List) {
        continue;
      }
      final rows = (raw['messages'] as List)
          .where((r) => r is! Map || !removed.contains(r['id']))
          .toList();
      if (rows.length == (raw['messages'] as List).length) continue;
      final payload = await encodeWorkspaceCache({
        ...raw,
        'messages': rows,
        'hasMore': true,
      });
      await db.customStatement(
        'UPDATE workspace_cache SET payload=? WHERE rowid=?',
        [payload, record.read<int>('rowid')],
      );
    }
  }
}
