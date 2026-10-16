import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/workspace_cache.dart';

import 'history_capacity_test.dart' as f;

void main() {
  test('last release disk window and keep marker upgrade once without losing offline bodies', () async {
    // Initial: literal v2 disk schema and v1 window JSON used by the old release.
    // Event: the upgraded client opens and runs automatic maintenance.
    // Expected: all rows/draft survive; legacy keep becomes an automatic grace visit.
    final dir = await Directory.systemTemp.createTemp('raft-history-upgrade-');
    final file = File('${dir.path}/workspace.sqlite');
    String quote(String s) => "'${s.replaceAll("'", "''")}'";
    final window = jsonEncode({
      'version': 1,
      'windowKind': 'tail',
      'authority': 'member',
      'parentChannelId': 'chat',
      'messages': f.rows('chat', 1, 50),
      'hasMore': false,
      'historyLimited': false,
    });
    final sql =
        '''
PRAGMA user_version=2;
CREATE TABLE workspace_cache(origin TEXT NOT NULL,principal TEXT NOT NULL,server TEXT NOT NULL,kind TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(origin,principal,server,kind,id));
CREATE TABLE message_translations(origin TEXT NOT NULL,principal TEXT NOT NULL,server TEXT NOT NULL,message_id TEXT NOT NULL,channel_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(origin,principal,server,message_id));
INSERT INTO workspace_cache VALUES(${quote(f.account.origin)},'alice','one','window','chat',${quote(window)});
INSERT INTO workspace_cache VALUES(${quote(f.account.origin)},'alice','one','history-kept','chat','true');
INSERT INTO workspace_cache VALUES(${quote(f.account.origin)},'alice','one','draft','draft-only','{"text":"Unsent draft","channelId":"draft-only"}');
''';
    final result = await Process.run('/usr/bin/sqlite3', [file.path, sql]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    var cache = DriftWorkspaceCache(
      NativeDatabase(file),
      historyBudget: 128 << 10,
      historyHardLimitEnabled: false,
      automaticHistoryMaintenance: false,
    );
    addTearDown(() async {
      await cache.close();
      await dir.delete(recursive: true);
    });
    await cache.messageHistory.migrateLegacy(f.scope('chat'), limit: 4);
    await cache.messageHistory.capacity.maintain(f.account);
    expect(
      (await cache.messageHistory.readPage(f.scope('chat'), limit: 100))?.rows,
      hasLength(50),
    );
    expect(
      await f.count(
        cache,
        "SELECT count(*) FROM workspace_cache WHERE kind='history-kept'",
      ),
      0,
    );
    final migrated = await cache.read(
      f.account.origin,
      'alice',
      'one',
      'history-visited',
      'chat',
    );
    expect(migrated, isA<int>());
    await cache.close();
    cache = DriftWorkspaceCache(
      NativeDatabase(file),
      historyBudget: 128 << 10,
      historyHardLimitEnabled: false,
      automaticHistoryMaintenance: false,
    );
    await cache.messageHistory.capacity.maintain(f.account);
    expect(
      await cache.read(
        f.account.origin,
        'alice',
        'one',
        'history-visited',
        'chat',
      ),
      migrated,
    );
    expect(
      (await cache.messageHistory.readPage(f.scope('chat'), limit: 100))?.rows,
      hasLength(50),
    );
    expect(
      (await cache.read(
        f.account.origin,
        'alice',
        'one',
        'draft',
        'draft-only',
      ))['text'],
      'Unsent draft',
    );
  });

  test('process killed in a WAL transaction reopens the last coherent committed body', () async {
    // Initial: a real file has one committed message body.
    // Event: another SQLite process changes its body inside a transaction, then is killed.
    // Expected: crash recovery exposes the complete old body; an authorized retry can commit the new one.
    final dir = await Directory.systemTemp.createTemp('raft-history-kill-');
    final file = File('${dir.path}/workspace.sqlite');
    var cache = DriftWorkspaceCache(
      NativeDatabase(file),
      automaticHistoryMaintenance: false,
    );
    addTearDown(() async {
      await cache.close();
      await dir.delete(recursive: true);
    });
    await f.store(cache, f.scope('chat'), [
      {'id': 'chat-1', 'channelId': 'chat', 'seq': '1', 'content': 'Committed'},
    ]);
    await cache.close();
    final child = await Process.start('/usr/bin/sqlite3', [file.path]);
    final mutated = Completer<void>();
    final output = child.stdout.transform(utf8.decoder).listen((text) {
      if (text.contains('MUTATED')) mutated.complete();
    });
    final errors = child.stderr.transform(utf8.decoder).join();
    child.stdin.writeln('BEGIN IMMEDIATE;');
    child.stdin.writeln(
      "UPDATE raft_history_rows SET payload=json_set(payload,'\$.content','Uncommitted');",
    );
    child.stdin.writeln("SELECT 'MUTATED';");
    await child.stdin.flush();
    await mutated.future.timeout(const Duration(seconds: 10));
    expect(child.kill(ProcessSignal.sigkill), isTrue);
    await child.exitCode;
    await output.cancel();
    expect(await errors, isEmpty);
    cache = DriftWorkspaceCache(
      NativeDatabase(file),
      automaticHistoryMaintenance: false,
    );
    expect(
      ((await cache.messageHistory.readContext(
                f.scope('chat'),
                'chat-1',
                radius: 0,
              ))?['messages']
              as List?)
          ?.single['content'],
      'Committed',
    );
    await cache.messageHistory.acceptEvents(f.scope('chat'), [
      {
        'id': 'chat-1',
        'channelId': 'chat',
        'seq': '1',
        'content': 'Committed retry',
      },
    ]);
    expect(
      ((await cache.messageHistory.readContext(
                f.scope('chat'),
                'chat-1',
                radius: 0,
              ))?['messages']
              as List?)
          ?.single['content'],
      'Committed retry',
    );
  });

  for (final clock in [DateTime.utc(2000), DateTime.utc(2099)]) {
    test(
      'equal timestamps keep uint64 sequence ordering with device clock $clock',
      () async {
        // Initial: same server timestamp, sparse sequence values above JS safe integer.
        // Event: local clock is decades wrong and rows arrive in reverse order.
        // Expected: sequence order, never wall-clock order, controls history.
        final cache = DriftWorkspaceCache(
          NativeDatabase.memory(),
          historyClock: () => clock,
          automaticHistoryMaintenance: false,
        );
        addTearDown(cache.close);
        final values = [
          for (final seq in ['18446744073709551615', '9007199254740993'])
            {
              'id': seq,
              'channelId': 'chat',
              'seq': seq,
              'content': seq,
              'createdAt': '2026-10-15T00:00:00Z',
            },
        ];
        await f.store(cache, f.scope('chat'), values);
        expect(
          (await cache.messageHistory.readPage(f.scope('chat')))?.rows
              .map((r) => r['id']),
          values.reversed.map((r) => r['id']),
        );
      },
    );
  }
}
