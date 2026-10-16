import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/message_history_memory.dart';
import 'package:raft_flutter/data/message_history_positions.dart';
import 'package:raft_flutter/features/chat_view.dart';
import 'package:raft_flutter/platform/workspace_cache.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'history_memory_test.dart' show HistoryClient, receiver;
import 'history_memory_viewport_test.dart' show drainIo;

void main() {
  for (final thread in [false, true]) {
    for (final active in [true, false]) {
      test(
        '${thread ? 'thread' : 'chat'} latest-end keeps the newest ${active ? 500 : 50} bodies after older paging',
        () async {
          final db = DriftWorkspaceCache(
            NativeDatabase.memory(),
            automaticHistoryMaintenance: false,
          );
          final client = HistoryClient();
          final w = receiver(client, db);
          db.messageHistory.memory.unregister(w);
          try {
            await w.selectChannel(w.channels.single, autoRead: false);
            if (thread) {
              await w.openThreadIdentity(
                parentChannelId: 'chat',
                parentMessageId: 'chat-1000',
                initialThreadChannelId: 'thread',
                navigate: false,
              );
            }
            final id = thread ? 'thread' : 'chat';
            for (var n = 0; n < 19; n++) {
              await w.older(thread: thread);
            }
            await w.flushCache();
            MessageHistoryMemory.attach(w, db.messageHistory);
            db.messageHistory.memory.direction(w, id, older: true);
            // This is the position receipt emitted by a manual return to the
            // conversation's latest end, without the return-to-latest command.
            MessageHistoryPositions.save(w, id, null);
            if (!active) {
              w.foreground = false;
              w.notifyListeners();
            }
            await db.messageHistory.memory.maintain();
            final held = w.ledger.messages(id);
            expect(held.length, lessThanOrEqualTo(active ? 500 : 50));
            expect(held.last['id'], '$id-1000');
            if (active)
              expect(thread ? w.threadWindow!.hasNewer : w.hasNewer, isFalse);
          } finally {
            await w.flushCache();
            w.dispose();
            await client.arrivals.close();
            await db.close();
          }
        },
      );
    }
  }

  testWidgets(
    'manually dragging to the latest end keeps the displayed newest row through trimming',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (db, client, w) = (await tester.runAsync(() async {
        final db = DriftWorkspaceCache(
          NativeDatabase.memory(),
          automaticHistoryMaintenance: false,
        );
        final client = HistoryClient();
        final w = receiver(client, db);
        db.messageHistory.memory.unregister(w);
        await w.selectChannel(w.channels.single, autoRead: false);
        for (var n = 0; n < 19; n++) {
          await w.older();
        }
        await w.flushCache();
        return (db, client, w);
      }))!;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: raftTheme(RaftFamily.elegant),
            home: Scaffold(body: RaftChatView(controller: w)),
          ),
        );
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(RaftChatView));
        MessageHistoryMemory.attach(w, db.messageHistory);
        db.messageHistory.memory.direction(w, 'chat', older: true);
        final timeline = find.byKey(const ValueKey('current-timeline'));
        await tester.drag(timeline, const Offset(0, 450));
        await tester.pumpAndSettle();
        expect(state.atBottom, isFalse);
        await tester.drag(timeline, const Offset(0, -1400));
        await tester.pumpAndSettle();
        expect(state.atBottom, isTrue);
        state.saveReadingAnchor();
        MessageHistoryMemory.cancelSample(w, state);
        final row = find.byKey(const ValueKey('message-wrapper-chat-1000'));
        expect(row, findsOneWidget);
        final before = tester.getRect(row);
        await drainIo(tester, db.messageHistory.memory.maintain());
        await tester.pumpAndSettle();
        expect(w.messages.last.id, 'chat-1000');
        expect(w.hasNewer, isFalse);
        expect(tester.getRect(row).top, closeTo(before.top, 1));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await drainIo(tester, w.flushCache());
        w.dispose();
        await drainIo(tester, client.arrivals.close());
        await drainIo(tester, db.close());
      }
    },
  );
}
