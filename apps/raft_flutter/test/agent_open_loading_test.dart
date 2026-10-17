import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// Opening a conversation by voice: the tool answers once the conversation's
/// first page is read (or says plainly that it is still loading), so the model
/// never mistakes a page that has not arrived for an empty channel. Fictional
/// data only.

class _Probe extends AgentScriptedModel {
  _Probe() : super(streamDelay: Duration.zero);
  Future<void> Function(AgentToolHandler call) script = (_) async {};

  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String line) say,
  ) async {
    await script(call);
    return true;
  }
}

/// The conversation's first page arrives when [page] completes.
class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => worldNow);
  final page = Completer<List<Map<String, dynamic>>>();

  @override
  Future<AgentAttention> attention() async => AgentAttention(
    items: [
      AgentAttentionItem(
        id: 'mention:ch-general',
        priority: AgentPriority.mention,
        headline: 'Zed 在 general 里问你：发布时间定了吗',
        ask: '回答',
        action: AgentAction.reply,
        reason: '点名找你',
        waitValue: 40,
        waitUnit: '分钟',
        at: worldNow,
        doer: 'Zed',
        channelId: 'ch-general',
        channelName: 'general',
        progress: const [],
      ),
    ],
  );

  @override
  Future<AgentConversationRead> conversation(
    String id, {
    int limit = 50,
    bool withTasks = true,
    String? parentChannelId,
    String? parentMessageId,
  }) async => AgentConversationRead(rows: await page.future);
}

Map<String, dynamic> _chat(String id, int seq, String who, String text) => {
  'id': id,
  'seq': '$seq',
  'channelId': 'ch-general',
  'senderType': 'user',
  'senderId': 'u-${who.toLowerCase()}',
  'senderName': who,
  'content': text,
  'messageType': 'chat',
  'createdAt': worldNow.subtract(Duration(minutes: 10 - seq)).toIso8601String(),
};

void main() {
  late ActivityClient client;
  late CapabilityWorld w;
  late _Data data;
  final probe = _Probe();

  setUp(() {
    AgentModeData.clearSession();
    FlutterSecureStorage.setMockInitialValues({});
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<void> pumpPage(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    data = _Data(w);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: false),
        home: AgentModePage(controller: w, data: data, model: probe),
      ),
    );
    await t.pumpAndSettle();
  }

  /// The model calls [tool]; returns what it was given once the call returns.
  Future<Completer<Map<String, Object?>>> call(
    WidgetTester t,
    String tool,
    Map<String, Object?> args,
  ) async {
    final result = Completer<Map<String, Object?>>();
    probe.script = (c) async => result.complete(await c(tool, args));
    if (find.byKey(const ValueKey('agent-input')).evaluate().isEmpty) {
      await t.tap(find.byKey(const ValueKey('agent-keyboard')));
      await t.pumpAndSettle();
    }
    await t.enterText(find.byKey(const ValueKey('agent-input')), '随便');
    await t.testTextInput.receiveAction(TextInputAction.send);
    // Frames only: the page is not settled while the first page is out.
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    return result;
  }

  test('the model is told a loading screen is not an empty one', () {
    final prompt = agentSystemPrompt(channels: '#general');
    expect(prompt, contains('loading 为 true'));
    expect(prompt, contains('不是空的'));
    for (final name in ['open_channel', 'open_item']) {
      final declared = agentToolDeclarations.firstWhere(
        (d) => d['name'] == name,
      );
      expect('${declared['description']}', contains('loading'));
      expect('${declared['description']}', contains('empty'));
    }
  });

  for (final tool in ['open_channel', 'open_item']) {
    final args = tool == 'open_channel'
        ? <String, Object?>{'name': 'general'}
        : <String, Object?>{'number': 1};

    group(tool, () {
      testWidgets('waits for the first page, then shows the messages', (
        t,
      ) async {
        await pumpPage(t);
        final result = await call(t, tool, args);
        expect(
          result.isCompleted,
          isFalse,
          reason: 'the page has not arrived: the tool has not answered',
        );

        data.page.complete([
          _chat('m1', 1, 'Zed', '发布定在周五下午'),
          _chat('m2', 2, 'Ada', '好，我来盯着'),
        ]);
        await t.pumpAndSettle();
        expect(result.isCompleted, isTrue);
        final given = await result.future;
        expect(given['error'], isNull);
        expect(given['loading'], isNot(true));
        expect(given['empty'], isNot(true));
        final snapshot = '${given['snapshot']}';
        expect(snapshot, contains('发布定在周五下午'));
        expect(snapshot, contains('好，我来盯着'));
        expect(snapshot, isNot(contains('还在读取')));
      });

      testWidgets('still loading after about five seconds: says so', (t) async {
        await pumpPage(t);
        final result = await call(t, tool, args);
        await t.pump(const Duration(seconds: 3));
        expect(result.isCompleted, isFalse);
        await t.pump(const Duration(seconds: 3));
        expect(result.isCompleted, isTrue);
        final given = await result.future;
        expect(given['loading'], isTrue);
        expect(given['empty'], isNot(true));
        final note = '${given['loadingNote']}';
        expect(note, contains('还在读取'));
        expect(note, contains('不要'));
        expect(note, contains('没有'));
        expect('${given['snapshot']}', contains('还在读取'));

        // The page arrives late: the next read of the screen has it.
        data.page.complete([_chat('m1', 1, 'Zed', '发布定在周五下午')]);
        await t.pumpAndSettle();
        final again = await call(t, 'read_screen', const {});
        await t.pumpAndSettle();
        final next = await again.future;
        expect(next['loading'], isNot(true));
        expect('${next['snapshot']}', contains('发布定在周五下午'));
      });

      testWidgets('a channel with no messages is empty, not loading', (
        t,
      ) async {
        await pumpPage(t);
        final result = await call(t, tool, args);
        data.page.complete(const []);
        await t.pumpAndSettle();
        final given = await result.future;
        expect(given['empty'], isTrue);
        expect(given['loading'], isNot(true));
        expect(given['loadingNote'], isNull);
        expect('${given['snapshot']}', isNot(contains('还在读取')));
      });

      testWidgets('a failed read is an error, not an empty channel', (t) async {
        await pumpPage(t);
        final result = await call(t, tool, args);
        data.page.completeError(StateError('offline'));
        await t.pumpAndSettle();
        final given = await result.future;
        expect(given['error'], isNotNull);
        expect(given['empty'], isNot(true));
      });
    });
  }
}
