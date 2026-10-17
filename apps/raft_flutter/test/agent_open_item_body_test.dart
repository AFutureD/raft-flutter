import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// "Open item 31 and read me what it says": a row of the home carries only a
/// preview of its message, and the 31st row is far from the first page of
/// anything. The tools that open or expand an item give the model the whole
/// message (read by its id), or say plainly that it is still being read or
/// could not be read. Fictional data only.

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

/// A long message: prose, a code block and a last sentence that only the
/// whole text has.
final _body = [
  '发布前检查的结果如下：',
  for (var i = 1; i <= 40; i++) '第 $i 项：已核对，没有问题。',
  '```\nflutter test --no-pub\n全部通过 1083\n```',
  '最后一句：周五上午十点发布，请大家提前合入。',
].join('\n');

const _preview = '发布前检查的结果如下： 第 1 项：已核对，没有问题。 第 2 项：已核对，没有问题。…';

AgentAttentionItem _row(int n) => AgentAttentionItem(
  id: 'activity:channel:ch-general:$n',
  kind: AgentItemKind.activity,
  priority: AgentPriority.progress,
  headline: 'Zed：${n == 31 ? _preview : '第 $n 条的预览'}',
  ask: '查看',
  action: AgentAction.open,
  reason: '频道有新消息',
  at: worldNow.subtract(Duration(minutes: n)),
  waitValue: n,
  waitUnit: '分钟',
  doer: 'Zed',
  channelId: 'ch-general',
  channelName: 'general',
  unread: 1,
  excerpt: n == 31 ? _preview : '第 $n 条的预览',
  place: '#general',
  messageId: 'm$n',
  rowKind: 'channel',
  progress: [
    AgentProgressLine(
      who: 'Zed',
      time: '今天 11:${(60 - n).toString().padLeft(2, '0')}',
      text: n == 31 ? _preview : '第 $n 条的预览',
    ),
  ],
);

class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => worldNow);

  @override
  Future<AgentAttention> attention() async =>
      AgentAttention(items: [for (var n = 1; n <= 40; n++) _row(n)]);

  /// The rows of the newest page of the channel (by default one message that
  /// is not message 31), and how many times it was read.
  List<Map<String, dynamic>> pageRows = [_chat('m99', 99, 'Ada', '收到')];
  int reads = 0;

  @override
  Future<AgentConversationRead> conversation(
    String id, {
    int limit = 50,
    bool withTasks = true,
    String? parentChannelId,
    String? parentMessageId,
  }) async {
    reads++;
    return AgentConversationRead(rows: pageRows);
  }
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
  'createdAt': worldNow
      .subtract(Duration(minutes: 100 - seq))
      .toIso8601String(),
};

void main() {
  late ActivityClient client;
  late CapabilityWorld w;
  final probe = _Probe();
  late _Data data;

  setUp(() {
    AgentModeData.clearSession();
    FlutterSecureStorage.setMockInitialValues({});
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    // The message by its id, as the server's context read gives it.
    w.routes['/messages/context/m31'] = (_) => {
      'targetMessageId': 'm31',
      'messages': [
        {
          'id': 'm31',
          'seq': '31',
          'channelId': 'ch-general',
          'senderType': 'user',
          'senderId': 'u-zed',
          'senderName': 'Zed',
          'content': _body,
          'messageType': 'chat',
          'createdAt': worldNow.toIso8601String(),
        },
      ],
    };
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<void> pumpPage(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: false),
        home: AgentModePage(controller: w, data: data = _Data(w), model: probe),
      ),
    );
    await t.pumpAndSettle();
  }

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
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    return result;
  }

  Map<String, Object?> message(Map<String, Object?> given) =>
      (given['message'] as Map).cast<String, Object?>();

  for (final tool in ['open_item', 'expand_item']) {
    final args = tool == 'open_item'
        ? <String, Object?>{'number': 31}
        : <String, Object?>{'index': 31};

    group('$tool 31', () {
      testWidgets('gives the model the whole message, not the preview', (
        t,
      ) async {
        await pumpPage(t);
        final result = await call(t, tool, args);
        await t.pumpAndSettle();
        expect(result.isCompleted, isTrue);
        final given = await result.future;
        expect(given['error'], isNull);
        final m = message(given);
        expect(m['from'], 'Zed');
        expect(m['text'], _body, reason: 'the complete body, code block too');
        expect(m['complete'], isTrue);
        expect(given['messageNote'], isNull);
        expect(w.reads, contains('/messages/context/m31'));
      });

      testWidgets('waits for the message, then says it is still being read', (
        t,
      ) async {
        final gate = Completer<Object?>();
        w.routes['/messages/context/m31'] = (_) => gate.future;
        await pumpPage(t);
        final result = await call(t, tool, args);
        await t.pump(const Duration(seconds: 3));
        expect(result.isCompleted, isFalse);
        await t.pump(const Duration(seconds: 3));
        expect(result.isCompleted, isTrue);
        final given = await result.future;
        expect(given['message'], isNull);
        final note = '${given['messageNote']}';
        expect(note, contains('还在读取'));
        expect(note, contains('不是全文'));
      });

      testWidgets('a message that cannot be read is said so', (t) async {
        w.routes['/messages/context/m31'] = (_) => {'messages': []};
        await pumpPage(t);
        final result = await call(t, tool, args);
        await t.pumpAndSettle();
        final given = await result.future;
        expect(given['message'], isNull);
        final note = '${given['messageNote']}';
        expect(note, contains('没能读到'));
        expect(note, contains('不是全文'));
      });
    });
  }

  testWidgets('in a conversation, item 31 is that message, whole', (t) async {
    await pumpPage(t);
    data.pageRows = [
      for (var n = 1; n <= 40; n++)
        _chat('c$n', n, 'Zed', n == 31 ? _body : '第 $n 句'),
    ];
    final opened = await call(t, 'open_channel', {'name': 'general'});
    await t.pumpAndSettle();
    expect((await opened.future)['error'], isNull);
    expect(data.reads, 1);

    final result = await call(t, 'open_item', {'number': 31});
    await t.pumpAndSettle();
    final given = await result.future;
    expect(given['error'], isNull);
    expect(message(given)['text'], _body);
    expect(message(given)['complete'], isTrue);
    // The conversation was not opened again.
    expect(data.reads, 1);
    expect(find.text('第 3 层'), findsNothing);
  });

  testWidgets('an item that is not on the screen is not found', (t) async {
    await pumpPage(t);
    final result = await call(t, 'open_item', {'number': 41});
    await t.pumpAndSettle();
    final given = await result.future;
    expect(given['error'], contains('没有第 41 条'));
    expect(given['message'], isNull);
  });
}
