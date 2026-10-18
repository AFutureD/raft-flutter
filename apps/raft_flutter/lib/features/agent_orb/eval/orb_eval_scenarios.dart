import 'orb_eval_data.dart';
import 'orb_eval_scenario.dart';
import 'orb_eval_world.dart' show OrbEvalWrite;

/// The scenarios of scenarios-v1: A (a channel), B (the Activity), C
/// (discussions, private conversations, tasks), D (driving: messages) and E
/// (driving: idle tasks). Fictional data only.
///
/// ✍️ scenarios (A3, C2, C4, D3, D8, E4) run the action tools: the model
/// asks, a card is up, nothing is written until the person says 确认, and
/// while driving what must wait for parking is refused. D5-D7 (live push while driving) and
/// E1/E5 (the idle task prompt) are not built: they run once and report
/// without failing the run.

final _raft = evalId('raft-flutter');
final _codyDm = evalId('dm:cody');

/// Checks every scenario carries: no id said out loud, no write sent.
List<OrbEvalCheck> _std() => [OrbEvalCheck.noIds(), OrbEvalCheck.noWrites()];

// ---- checks of the actions -----------------------------------------------

/// The model asks "要发吗" (or "要改吗") before it does anything.
// Any clear ask for the person's yes counts (G100: "你点一下确认就行，或者说
// 确认/发吧/好" is the right behaviour, not only the words "要发吗").
final _asksFirst = RegExp(
  r'要发吗|要不要发|发吗|要改吗|要不要改|要催吗|确认吗|要我发|要我改|要记下吗|要不要记|点(一下)?确认|说[“"]?确认|确认就行|你确认',
);

/// Afterwards it says it is done. 已回复 / 发好啦 / 发出去啦 / 改好啦 / 标好啦
/// are the same thing said another way (the app says "已回复" for a thread
/// reply; a model says "发好啦").
final _saysDone = RegExp(
  r'已发|发出去了|发出去啦|发好了|发好啦|已经发|发了|已回复|已改|改好了|改好啦|已经改|已标|标好了|标好啦|已催|催了|记下了|已记|放一放|提醒你',
);

bool Function(Object?) _has(String word) =>
    (Object? v) => '$v'.contains(word);

/// A POST that carries [text] (a message or a thread reply).
bool _posted(OrbEvalWrite w, String text) =>
    w.method == 'POST' && '${w.body}'.contains(text);

/// Nothing changed a task's status.
final _noStatusChange = OrbEvalCheck.custom('驾驶中没有改任务状态', (run) {
  final changed = run.realWrites.where((w) => w.method == 'PATCH').toList();
  return changed.isEmpty ? null : '改了：${changed.join('、')}';
});

/// A `screen_action` that was done ("ok") on a control named [label].
OrbEvalCheck _pressedOk(RegExp label) =>
    OrbEvalCheck.custom('按下了「${label.pattern}」', (run) {
      for (final c in run.tools.where((c) => c.name == 'screen_action')) {
        if (c.result['ok'] == true && label.hasMatch('${c.result['did']}')) {
          return null;
        }
      }
      return '没有成功按下「${label.pattern}」';
    });

final _saysNothingToDo = RegExp(r'没有.{0,8}(处理|回复|找你|新的|要紧)');

// ---- data ------------------------------------------------------------------

/// #raft-flutter with 3 unread; Cody asks Sam whether step 10 may go in.
OrbEvalData _cody10() {
  final d = OrbEvalData.cast();
  final first = d.say('raft-flutter', evalGrok, '第 9 步的测试都过了。', ago: 50);
  final ask = d.say(
    'raft-flutter',
    evalCody,
    '@Sam 第 10 步可以合入吗？',
    ago: 20,
    mentions: [evalMe],
  );
  final last = d.say('raft-flutter', evalAlice, '我看过了，没有问题。', ago: 8);
  d.inboxChannel(
    'raft-flutter',
    name: 'raft-flutter',
    preview: '我看过了，没有问题。',
    from: evalAlice,
    message: last,
    unread: 3,
    ago: 8,
    mention: true,
    firstUnread: first,
    firstMention: ask,
  );
  return d;
}

/// #raft-flutter, all read, nobody mentioned Sam.
OrbEvalData _quietChannel() {
  final d = OrbEvalData.cast();
  d.say('raft-flutter', evalGrok, '第 9 步已经合入了。', ago: 200);
  final last = d.say('raft-flutter', evalCody, '收到，我接着做第 10 步。', ago: 180);
  d.inboxChannel(
    'raft-flutter',
    name: 'raft-flutter',
    preview: '收到，我接着做第 10 步。',
    from: evalCody,
    message: last,
    unread: 0,
    ago: 180,
  );
  return d;
}

final _cacheParent = evalId('msg:cache-parent');

/// A discussion under Alice's question with 8 replies; the last one settles it.
OrbEvalData _decidedThread() {
  final d = OrbEvalData.cast();
  d.say(
    'raft-flutter',
    evalAlice,
    '移动端的缓存策略怎么定？',
    id: _cacheParent,
    ago: 240,
    replies: 8,
    thread: 'thread:cache',
  );
  d.say('thread:cache', evalCody, '我倾向方案 A：只缓存最近一页，改动小。', ago: 200);
  d.say('thread:cache', evalGrok, '方案 B 会缓存整个会话，离线也能看。', ago: 190);
  d.say('thread:cache', evalCody, '方案 B 的内存占用要先测一下。', ago: 170);
  d.say('thread:cache', evalGrok, '我测了，两百条消息大概 3 MB。', ago: 150);
  d.say('thread:cache', evalAlice, '3 MB 可以接受。', ago: 120);
  d.say('thread:cache', evalCody, '那旧数据怎么清理？', ago: 100);
  d.say('thread:cache', evalGrok, '超过七天的自动清掉。', ago: 90);
  d.say('thread:cache', evalAlice, '好，就这样定了：改用方案 B。', ago: 60);
  d.inboxThread(
    thread: 'thread:cache',
    parentConversation: 'raft-flutter',
    parentName: 'raft-flutter',
    parentMessage: _cacheParent,
    parentPreview: '移动端的缓存策略怎么定？',
    parentFrom: evalAlice,
    latestMessage: evalId('msg:thread:cache:9'),
    latestPreview: '好，就这样定了：改用方案 B。',
    latestFrom: evalAlice,
    unread: 0,
    ago: 60,
  );
  return d;
}

/// The Activity: Alice's private question, Cody's @, three pieces of progress.
OrbEvalData _activityFive() {
  final d = OrbEvalData.cast();
  final alice = d.say('dm:alice', evalAlice, '周五能来评审吗？', ago: 5);
  d.inboxDm(
    'dm:alice',
    peer: evalAlice,
    preview: '周五能来评审吗？',
    message: alice,
    ago: 5,
  );
  final g = d.say('raft-flutter', evalGrok, '第 9 步测试通过了。', ago: 30);
  final ask = d.say(
    'raft-flutter',
    evalCody,
    '@Sam 第 10 步可以合入吗？',
    ago: 12,
    mentions: [evalMe],
  );
  d.inboxChannel(
    'raft-flutter',
    name: 'raft-flutter',
    preview: '@Sam 第 10 步可以合入吗？',
    from: evalCody,
    message: ask,
    unread: 2,
    ago: 12,
    mention: true,
    firstUnread: g,
    firstMention: ask,
  );
  final build = d.say('swift-workflow', evalGrok, '构建通过了。', ago: 25);
  d.inboxChannel(
    'swift-workflow',
    name: 'swift-workflow',
    preview: '构建通过了。',
    from: evalGrok,
    message: build,
    unread: 1,
    ago: 25,
  );
  _progressThread(d, ago: 40);
  final merged = d.say('dm:cody', evalCody, '第 9 步已经合入了。', ago: 55);
  d.inboxDm(
    'dm:cody',
    peer: evalCody,
    preview: '第 9 步已经合入了。',
    message: merged,
    ago: 55,
  );
  return d;
}

/// The Activity with unread counts: Alice's private conversation (3 unread),
/// Cody's @ in #raft-flutter (2), a build in #swift-workflow (1); Cody's
/// private conversation is read.
OrbEvalData _activityUnread() {
  final d = OrbEvalData.cast();
  d.say('dm:alice', evalAlice, '我把评审的材料发你了。', ago: 20);
  d.say('dm:alice', evalAlice, '周五下午两点开。', ago: 12);
  final alice = d.say('dm:alice', evalAlice, '周五能来评审吗？', ago: 5);
  d.inboxDm(
    'dm:alice',
    peer: evalAlice,
    preview: '周五能来评审吗？',
    message: alice,
    unread: 3,
    ago: 5,
  );
  final g = d.say('raft-flutter', evalGrok, '第 9 步测试通过了。', ago: 30);
  final ask = d.say(
    'raft-flutter',
    evalCody,
    '@Sam 第 10 步可以合入吗？',
    ago: 12,
    mentions: [evalMe],
  );
  d.inboxChannel(
    'raft-flutter',
    name: 'raft-flutter',
    preview: '@Sam 第 10 步可以合入吗？',
    from: evalCody,
    message: ask,
    unread: 2,
    ago: 12,
    mention: true,
    firstUnread: g,
    firstMention: ask,
  );
  final build = d.say('swift-workflow', evalGrok, '构建通过了。', ago: 25);
  d.inboxChannel(
    'swift-workflow',
    name: 'swift-workflow',
    preview: '构建通过了。',
    from: evalGrok,
    message: build,
    unread: 1,
    ago: 25,
  );
  final read = d.say('dm:cody', evalCody, '收到，我接着做。', ago: 55);
  d.inboxDm(
    'dm:cody',
    peer: evalCody,
    preview: '收到，我接着做。',
    message: read,
    unread: 0,
    ago: 55,
  );
  return d;
}

/// A discussion Sam started that moves along without him.
void _progressThread(OrbEvalData d, {required int ago}) {
  final parent = d.say(
    'raft-flutter',
    evalMe,
    '整理发布说明的进度怎么样？',
    id: evalId('msg:notes-parent'),
    ago: ago + 60,
    replies: 1,
    thread: 'thread:notes',
  );
  final reply = d.say('thread:notes', evalCody, '第一部分写完了。', ago: ago);
  d.inboxThread(
    thread: 'thread:notes',
    parentConversation: 'raft-flutter',
    parentName: 'raft-flutter',
    parentMessage: parent,
    parentPreview: '整理发布说明的进度怎么样？',
    parentFrom: evalMe,
    latestMessage: reply,
    latestPreview: '第一部分写完了。',
    latestFrom: evalCody,
    unread: 1,
    ago: ago,
    following: true,
  );
}

/// The Activity with only system events and progress: nothing asks Sam.
OrbEvalData _activityQuiet() {
  final d = OrbEvalData.cast();
  final build = d.say('swift-workflow', evalSystem, '构建 #214 通过了。', ago: 10);
  d.inboxChannel(
    'swift-workflow',
    name: 'swift-workflow',
    preview: '构建 #214 通过了。',
    from: evalSystem,
    message: build,
    unread: 1,
    ago: 10,
  );
  _progressThread(d, ago: 30);
  final done = d.say('raft-flutter', evalGrok, '第 9 步的测试都过了。', ago: 50);
  d.inboxChannel(
    'raft-flutter',
    name: 'raft-flutter',
    preview: '第 9 步的测试都过了。',
    from: evalGrok,
    message: done,
    unread: 1,
    ago: 50,
  );
  return d;
}

/// The Activity: a task waiting four days for Sam's review, and a reply that
/// has just come in.
OrbEvalData _activityOldTask() {
  final d = OrbEvalData.cast();
  final mine = d.say(
    'raft-flutter',
    evalMe,
    '能把缓存的测试补上吗？',
    id: evalId('msg:tests-parent'),
    ago: 90,
    replies: 1,
    thread: 'thread:tests',
  );
  final reply = d.say('thread:tests', evalGrok, '测试补好了，你看一下。', ago: 4);
  d.inboxThread(
    thread: 'thread:tests',
    parentConversation: 'raft-flutter',
    parentName: 'raft-flutter',
    parentMessage: mine,
    parentPreview: '能把缓存的测试补上吗？',
    parentFrom: evalMe,
    latestMessage: reply,
    latestPreview: '测试补好了，你看一下。',
    latestFrom: evalGrok,
    unread: 1,
    ago: 4,
    mention: true,
  );
  final taskMessage = d.say('raft-flutter', evalMe, '请重构第 10 步。', ago: 7000);
  d.task(
    136,
    '重构第 10 步',
    'in_review',
    by: evalCody,
    ageMinutes: 5760,
    message: taskMessage,
    description: '改动已经提交，等你验收。',
  );
  return d;
}

/// Cody's private conversation with 2 unread.
OrbEvalData _codyDmUnread() {
  final d = OrbEvalData.cast();
  d.say('dm:cody', evalCody, '第 10 步的改动我提交了。', ago: 18);
  final last = d.say('dm:cody', evalCody, '你看一下，需要我补什么吗？', ago: 15);
  d.inboxDm(
    'dm:cody',
    peer: evalCody,
    preview: '你看一下，需要我补什么吗？',
    message: last,
    unread: 2,
    ago: 15,
  );
  return d;
}

/// Task #136 in review, done by Cody.
OrbEvalData _task136() {
  final d = OrbEvalData.cast();
  final message = d.say('raft-flutter', evalMe, '请重构第 10 步。', ago: 300);
  d.task(
    136,
    '重构第 10 步',
    'in_review',
    by: evalCody,
    ageMinutes: 45,
    thread: 'thread:t136',
    message: message,
    description: '改动已经提交，等你验收。',
  );
  d.say('thread:t136', evalCody, '改动提交了，测试都过了，请验收。', ago: 45);
  return d;
}

final _opinionParent = evalId('msg:opinion-parent');

/// A discussion where Alice asks Sam, and Cody and Grok disagree.
OrbEvalData _opinions() {
  final d = OrbEvalData.cast();
  d.say(
    'raft-flutter',
    evalAlice,
    '新手引导用哪个方案？',
    id: _opinionParent,
    ago: 120,
    replies: 3,
    thread: 'thread:opinions',
  );
  d.say('thread:opinions', evalCody, '我支持方案 A，上线最快。', ago: 100);
  d.say('thread:opinions', evalGrok, '我支持方案 B，留存更好。', ago: 90);
  final ask = d.say(
    'thread:opinions',
    evalAlice,
    '@Sam 你怎么看？',
    ago: 80,
    mentions: [evalMe],
  );
  d.inboxThread(
    thread: 'thread:opinions',
    parentConversation: 'raft-flutter',
    parentName: 'raft-flutter',
    parentMessage: _opinionParent,
    parentPreview: '新手引导用哪个方案？',
    parentFrom: evalAlice,
    latestMessage: ask,
    latestPreview: '@Sam 你怎么看？',
    latestFrom: evalAlice,
    unread: 3,
    ago: 80,
    mention: true,
  );
  return d;
}

/// Three things that need Sam: Cody's question, Alice's, Grok's. The
/// Activity puts the newest question first, so Cody's (10 minutes) is the card
/// on the screen when driving starts, and "回他" means him; Alice (15) and Grok
/// (30) follow.
OrbEvalData _urgentThree({String? codyAsk}) {
  final d = OrbEvalData.cast();
  final ask = d.say(
    'raft-flutter',
    evalCody,
    codyAsk ?? '@Sam 第 10 步可以合入吗？',
    ago: 10,
    mentions: [evalMe],
  );
  final alice = d.say('dm:alice', evalAlice, '周五能来评审吗？', ago: 15);
  d.inboxDm(
    'dm:alice',
    peer: evalAlice,
    preview: '周五能来评审吗？',
    message: alice,
    ago: 15,
  );
  d.inboxMention(
    'raft-flutter',
    name: 'raft-flutter',
    message: ask,
    preview: codyAsk ?? '@Sam 第 10 步可以合入吗？',
    from: evalCody,
    ago: 10,
  );
  final grok = d.say(
    'swift-workflow',
    evalGrok,
    '@Sam 方案 B 的接口你确认一下？',
    ago: 30,
    mentions: [evalMe],
  );
  d.inboxChannel(
    'swift-workflow',
    name: 'swift-workflow',
    preview: '@Sam 方案 B 的接口你确认一下？',
    from: evalGrok,
    message: grok,
    unread: 1,
    ago: 30,
    mention: true,
  );
  return d;
}

/// Three tasks nobody has touched for days; no message waits for Sam.
OrbEvalData _staleTasks({int ageDays = 4}) {
  final d = OrbEvalData.cast();
  final minutes = ageDays * 24 * 60;
  d.task(
    141,
    '整理发布说明',
    'in_progress',
    by: evalBajie,
    ageMinutes: minutes,
    description: '卡在等设计稿。',
  );
  d.task(
    142,
    '迁移旧的缓存',
    'in_review',
    by: evalCody,
    ageMinutes: minutes + 1440,
    channel: 'swift-workflow',
    description: '改动已完成，等你验收。',
  );
  d.task(
    143,
    '补充设计评审记录',
    'in_progress',
    by: evalGrok,
    ageMinutes: minutes - 1440,
    channel: 'design',
    description: '在等 Alice 回复。',
  );
  return d;
}

// ---- checks used more than once -------------------------------------------

final _firstCardIsAMessage = OrbEvalCheck.screen(
  '第 1 张卡是消息，不是任务',
  (s, _) => s.cards.isNotEmpty && !s.cards.first['id']!.startsWith('task:'),
);

/// Everything the scenarios list, in scenarios-v1 order.
final List<OrbEvalScenario> orbEvalScenarios = [
  // ---- A. a channel (#raft-flutter) ----------------------------------------
  OrbEvalScenario(
    id: 'A1',
    title: '去频道看谁找我',
    start: OrbEvalStart.home,
    data: _cody10,
    say: const ['去 raft-flutter 看看谁找我'],
    checks: [
      OrbEvalCheck.tool(
        'navigate',
        args: {'channel_id': _raft},
        label: 'navigate(channel_id: #raft-flutter)',
      ),
      OrbEvalCheck.says([
        ['Cody'],
        ['第 10 步', '10 步'],
        ['合入', '合并'],
      ]),
      OrbEvalCheck.saysMatching(RegExp(r'\d+\s*(分钟|小时)|刚刚|刚才|半小时'), '说了等了多久'),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'A2',
    title: '他问的是什么',
    start: OrbEvalStart.channel('raft-flutter'),
    data: _cody10,
    // A follow-up: "他" is the person the first answer named.
    say: const ['去 raft-flutter 看看谁找我', '他问的是什么？'],
    checks: [
      OrbEvalCheck.says([
        ['Cody'],
        ['第 10 步', '10 步'],
        ['合入', '合并'],
      ]),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'A3',
    title: '回复他说可以合',
    start: OrbEvalStart.channel('raft-flutter'),
    data: _cody10,
    say: const ['回复他说可以合', '确认'],
    checks: [
      OrbEvalCheck.anyTool(
        ['reply', 'reply_in_thread', 'send_message'],
        args: {'text': _has('可以')},
        label: '调用 reply、reply_in_thread 或 send_message(text 含“可以”)',
      ),
      OrbEvalCheck.says([
        ['Cody'],
        ['可以'],
      ], label: '先复述：回复 Cody：可以'),
      OrbEvalCheck.saysMatching(_asksFirst, '问一句要不要发'),
      OrbEvalCheck.confirmedWrite(
        label: '确认卡在前，确认后才发出，只发一次',
        actionTools: ['reply', 'reply_in_thread', 'send_message'],
        write: (w) => _posted(w, '可以'),
      ),
      OrbEvalCheck.saysMatching(_saysDone, '说已发出'),
      OrbEvalCheck.noIds(),
    ],
  ),
  OrbEvalScenario(
    id: 'A4',
    title: '没有未读时问有什么新的',
    start: OrbEvalStart.channel('raft-flutter'),
    data: _quietChannel,
    say: const ['这里有什么新的吗'],
    checks: [
      OrbEvalCheck.saysMatching(_saysNothingToDo, '说“没有要你处理的”'),
      OrbEvalCheck.shortReply(3),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'A5',
    title: '讨论最后定了什么',
    start: OrbEvalStart.channel('raft-flutter'),
    data: _decidedThread,
    say: const ['这个讨论最后定了什么'],
    checks: [
      OrbEvalCheck.anyTool(['navigate', 'read_conversation']),
      OrbEvalCheck.says([
        ['方案 B', '方案B'],
        ['Alice'],
      ]),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'A6',
    title: '去没加入的频道',
    start: OrbEvalStart.home,
    say: const ['去 design 频道'],
    checks: [
      OrbEvalCheck.anyTool(['navigate', 'list_targets']),
      OrbEvalCheck.custom('能打开，或说明没加入', (run) {
        final opened = run.tools.any(
          (c) => c.name == 'navigate' && c.result['error'] == null,
        );
        final explained = orbEvalMatches(RegExp(r'没加入|未加入|还没加入|加入'), run.text);
        return opened || explained ? null : '没打开，也没说明没加入';
      }),
      OrbEvalCheck.avoids(RegExp(r'出错|失败|没成功|报错'), '报错的话'),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'A7',
    title: '频道名被听错',
    start: OrbEvalStart.home,
    say: const ['去 Roughslutter'],
    checks: [
      OrbEvalCheck.anyTool(['navigate', 'list_targets']),
      OrbEvalCheck.custom('去了 raft-flutter，或问是不是 raft-flutter', (run) {
        final there = run.last?.location.contains(_raft) ?? false;
        final asked = orbEvalCompact(run.text).contains('raft-flutter');
        return there || asked ? null : '没去 raft-flutter，也没问是不是它';
      }),
      ..._std(),
    ],
  ),

  // ---- B. the Activity -----------------------------------------------------
  OrbEvalScenario(
    id: 'B1',
    title: '打开动态，什么需要我处理',
    start: OrbEvalStart.home,
    data: _activityFive,
    say: const ['打开动态，什么需要我处理'],
    checks: [
      OrbEvalCheck.tool(
        'navigate',
        args: {'page': 'activity', 'show': true},
        label: 'navigate(page: activity, show: true)',
      ),
      OrbEvalCheck.says([
        ['Alice'],
        ['周五', '评审'],
        ['Cody'],
      ]),
      OrbEvalCheck.screen(
        '卡片里有 Alice 的私信和 @我，没有任务',
        (s, _) =>
            s.cards.any((c) => c['who'] == 'Alice') &&
            s.cards.any((c) => c['who'] == 'Cody') &&
            s.cards.every((c) => !c['id']!.startsWith('task:')),
      ),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'B2',
    title: '读一下动态',
    start: OrbEvalStart.activity,
    data: _activityFive,
    say: const ['读一下动态'],
    checks: [
      OrbEvalCheck.tool('describe_page'),
      OrbEvalCheck.inOrder([
        ['Alice'],
        ['Cody'],
      ], label: '按页面顺序说：Alice 在前，Cody 在后'),
      OrbEvalCheck.avoids(RegExp('任务'), '念任务'),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'B3',
    title: '读 Alice 那条原文',
    start: OrbEvalStart.activity,
    data: _activityFive,
    say: const ['读 Alice 那条原文'],
    checks: [
      OrbEvalCheck.custom('读到了 Alice 私信里的原文（任何读法）', (run) {
        // read_conversation, or open_item / navigate to the DM and then
        // describe_page: what counts is that a read of Alice's conversation
        // brought the original words in front of the model.
        for (final c in run.tools) {
          for (final r in [c.result, c.result['page']]) {
            if (r is! Map) continue;
            final conv = r['conversation'];
            if (conv is Map &&
                '${conv['name']}'.contains('Alice') &&
                '$r'.contains('周五能来评审吗')) {
              return null;
            }
          }
        }
        return '没有读到 Alice 私信的原文（调用了：'
            '${run.tools.map((c) => c.name).toSet().join('、')}）';
      }),
      OrbEvalCheck.says([
        ['周五'],
        ['评审'],
      ]),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'B4',
    title: '最新那条说了什么',
    start: OrbEvalStart.activity,
    data: _activityFive,
    say: const ['最新那条说了什么'],
    checks: [
      OrbEvalCheck.says([
        ['Alice'],
        ['周五', '评审'],
      ]),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'B5',
    title: '只有进度时问有什么要处理的',
    start: OrbEvalStart.activity,
    data: _activityQuiet,
    say: const ['有什么要我处理的'],
    checks: [
      OrbEvalCheck.saysMatching(_saysNothingToDo, '说“没有要你处理的”'),
      OrbEvalCheck.shortReply(4),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'B6',
    title: '动态还在加载',
    start: OrbEvalStart.activity,
    data: () => _activityFive()..holdInbox = true,
    say: const ['有什么新的'],
    checks: [
      OrbEvalCheck.avoids(RegExp(r'没有内容|没有任何内容|是空的|什么都没有|没有新的'), '“没有内容”'),
      OrbEvalCheck.saysMatching(RegExp(r'加载|稍后|稍等|等一下|等等|再看|还没'), '说还在加载或稍后再读'),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'B7',
    title: '旧任务和新回复，先说什么',
    start: OrbEvalStart.activity,
    data: _activityOldTask,
    say: const ['什么要紧'],
    checks: [
      OrbEvalCheck.inOrder([
        ['Grok', '回复', '测试'],
        ['验收'],
      ], label: '先说回复，任务（验收）放最后'),
      ..._std(),
    ],
  ),

  // ---- C. discussions, private conversations, tasks ------------------------
  // Kevin on the G100: "打开动态里的第一个消息" was only ever read.
  OrbEvalScenario(
    id: 'B8',
    title: '打开动态里的第一条',
    start: OrbEvalStart.activity,
    data: _activityFive,
    say: const ['打开动态里的第一条消息'],
    checks: [
      OrbEvalCheck.tool('open_item', label: '调用 open_item（打开，不是读）'),
      ..._std(),
    ],
  ),
  // Kevin on the phone: "把我没有读的那些摘要都拿出来看一下" only went to the
  // Activity; the unread were never shown or told.
  OrbEvalScenario(
    id: 'B9',
    title: '把没读的摘要拿出来看',
    start: OrbEvalStart.activity,
    data: _activityUnread,
    say: const ['把我没有读的那些摘要都拿出来看一下'],
    checks: [
      OrbEvalCheck.anyTool(
        ['get_briefing', 'navigate'],
        args: {'show': true},
        label: '调用 get_briefing 或 navigate，show: true（把未读的铺在屏幕上）',
      ),
      OrbEvalCheck.screen(
        '卡片里有 Alice 的私信和 Cody 的 @，没有任务',
        (s, _) =>
            s.cards.any((c) => c['who'] == 'Alice') &&
            s.cards.any((c) => c['who'] == 'Cody') &&
            s.cards.every((c) => !c['id']!.startsWith('task:')),
      ),
      OrbEvalCheck.says([
        ['Alice'],
        ['Cody'],
        ['3 条', '三条'],
      ], label: '说到 Alice、Cody，以及 Alice 有 3 条未读'),
      OrbEvalCheck.avoids(RegExp(r'没有未读|没有新的'), '说没有未读'),
      OrbEvalCheck.avoids(RegExp('接着做'), '念已读的那条'),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'C1',
    title: '看看 Cody 私信',
    start: OrbEvalStart.home,
    data: _codyDmUnread,
    say: const ['看看 Cody 私信'],
    checks: [
      // By id, or by the name "Cody" (navigate resolves a person to the
      // private conversation): what counts is where it went.
      OrbEvalCheck.custom('navigate 到 Cody 的私信（dm_id，或名字落在这个私信）', (run) {
        for (final c in run.tools.where((c) => c.name == 'navigate')) {
          final matched = c.result['matched'];
          if (c.args['dm_id'] == _codyDm ||
              (matched is Map &&
                  matched['kind'] == 'dm' &&
                  matched['id'] == _codyDm)) {
            return null;
          }
        }
        return 'navigate 没有到 Cody 的私信：${run.tools.where((c) => c.name == 'navigate').map((c) => c.args).join('、')}';
      }),
      OrbEvalCheck.says([
        ['Cody'],
      ]),
      OrbEvalCheck.saysMatching(
        RegExp(r'回复|回他|回一下|需要你|要你|不用回|不需要回|要不要回'),
        '说需不需要回',
      ),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'C2',
    title: '回他“晚上看”',
    start: OrbEvalStart.dm('dm:cody'),
    data: _codyDmUnread,
    say: const ['回他“晚上看”', '确认'],
    checks: [
      OrbEvalCheck.anyTool(
        ['reply', 'send_message', 'reply_in_thread'],
        args: {'text': _has('晚上看')},
        label: '调用 reply 或 send_message(text 含“晚上看”)',
      ),
      OrbEvalCheck.says([
        ['Cody'],
        ['晚上看'],
      ], label: '先复述：回复 Cody：晚上看'),
      OrbEvalCheck.saysMatching(_asksFirst, '问一句要不要发'),
      OrbEvalCheck.confirmedWrite(
        label: '确认卡在前，确认后才发出，只发一次',
        actionTools: ['reply', 'send_message', 'reply_in_thread'],
        write: (w) => _posted(w, '晚上看'),
      ),
      OrbEvalCheck.saysMatching(_saysDone, '说已发出'),
      OrbEvalCheck.noIds(),
    ],
  ),
  OrbEvalScenario(
    id: 'C3',
    title: '打开 task 136',
    start: OrbEvalStart.home,
    data: _task136,
    say: const ['打开 task 136'],
    checks: [
      OrbEvalCheck.tool(
        'navigate',
        args: {'task_number': 136},
        label: 'navigate(task_number: 136)',
      ),
      OrbEvalCheck.says([
        ['Cody'],
        ['验收', '评审', 'review', '审阅'],
      ]),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'C4',
    title: '这个可以了，标完成',
    start: OrbEvalStart.task(136),
    data: _task136,
    say: const ['这个可以了，标完成', '确认'],
    checks: [
      OrbEvalCheck.tool(
        'set_task_status',
        args: {'status': 'done', 'task': _has('136')},
        label: 'set_task_status(task: 136, status: done)',
      ),
      OrbEvalCheck.says([
        ['136'],
        ['完成'],
      ], label: '先复述：把 136 标成完成'),
      OrbEvalCheck.saysMatching(_asksFirst, '问一句要不要改'),
      OrbEvalCheck.confirmedWrite(
        label: '确认卡在前，确认后才改，只改一次',
        actionTools: ['set_task_status'],
        write: (w) =>
            w.method == 'PATCH' &&
            w.path.endsWith('/status') &&
            '${w.body}'.contains('done'),
      ),
      OrbEvalCheck.saysMatching(_saysDone, '说已改'),
      OrbEvalCheck.noIds(),
    ],
  ),
  OrbEvalScenario(
    id: 'C5',
    title: '讨论里大家的意见',
    start: OrbEvalStart.thread((d) => _opinionParent),
    data: _opinions,
    say: const ['大家意见是什么'],
    checks: [
      OrbEvalCheck.says([
        ['Cody'],
        ['Grok'],
        ['方案 A', '方案A'],
        ['方案 B', '方案B'],
      ]),
      ..._std(),
    ],
  ),

  // ---- D. driving: messages ------------------------------------------------
  OrbEvalScenario(
    id: 'D1',
    title: '开始驾驶模式',
    start: OrbEvalStart.home,
    data: _urgentThree,
    say: const ['开始驾驶模式'],
    checks: [
      OrbEvalCheck.tool(
        'set_driving_mode',
        args: {'on': true},
        label: 'set_driving_mode(on: true)',
      ),
      OrbEvalCheck.screen(
        '驾驶模式开着，卡片已铺开',
        (s, _) => s.driving && s.cards.isNotEmpty,
      ),
      _firstCardIsAMessage,
      OrbEvalCheck.shortReply(2),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'D2',
    title: '下一件',
    start: OrbEvalStart.home,
    data: _urgentThree,
    setup: const ['开始驾驶模式'],
    say: const ['下一件'],
    checks: [
      OrbEvalCheck.tool('driving_next'),
      OrbEvalCheck.custom('说的是第 2 件', (run) {
        final cards = run.last?.cards ?? const [];
        if (cards.length < 2) return '界面上不到 2 张卡';
        final who = cards[1]['who']!;
        return orbEvalCompact(run.text).contains(orbEvalCompact(who))
            ? null
            : '没有说到第 2 件的发送人（$who）';
      }),
      OrbEvalCheck.shortReply(2),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'D3',
    title: '驾驶中回他可以',
    start: OrbEvalStart.home,
    data: _urgentThree,
    setup: const ['开始驾驶模式'],
    say: const ['回他可以', '确认'],
    checks: [
      OrbEvalCheck.anyTool(
        ['reply', 'reply_in_thread', 'send_message'],
        args: {'text': _has('可以')},
        label: '调用 reply、reply_in_thread 或 send_message(text 含“可以”)',
      ),
      OrbEvalCheck.says([
        ['Cody'],
        ['可以'],
      ], label: '先复述：回复 Cody：可以'),
      OrbEvalCheck.saysMatching(_asksFirst, '问一句要不要发'),
      OrbEvalCheck.confirmedWrite(
        label: '确认卡在前，确认后才发出，只发一次',
        actionTools: ['reply', 'reply_in_thread', 'send_message'],
        write: (w) => _posted(w, '可以'),
      ),
      OrbEvalCheck.screen('驾驶模式还开着', (s, _) => s.driving),
      OrbEvalCheck.screen(
        '屏幕上的那一件是 Cody 的（“回他”指他）',
        (s, _) =>
            s.drivingIndex < s.cards.length &&
            s.cards[s.drivingIndex]['who'] == 'Cody',
      ),
      OrbEvalCheck.noIds(),
    ],
  ),
  OrbEvalScenario(
    id: 'D4',
    title: '驾驶中批准发布',
    start: OrbEvalStart.home,
    data: () => _urgentThree(codyAsk: '@Sam 发布 v1.4 在等你批准。'),
    setup: const ['开始驾驶模式'],
    say: const ['批准吧'],
    checks: [
      OrbEvalCheck.saysMatching(RegExp(r'停车|停好车|停下来'), '说停车后再批准'),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'D5',
    title: '驾驶中新来一条 @我',
    start: OrbEvalStart.home,
    data: _urgentThree,
    setup: const ['开始驾驶模式'],
    events: [
      OrbEvalEvent(
        'message:new',
        (d) => d.incoming(
          'swift-workflow',
          evalAlice,
          '@Sam 发布脚本报错了，你能看一眼吗？',
          mentions: [evalMe],
        ),
      ),
    ],
    checks: [
      OrbEvalCheck.custom('卡片插到下一张，计数出“新的 1 件”', (run) {
        final before = run.turns.first.after?.cards.length ?? 0;
        final after = run.last?.cards.length ?? 0;
        return after > before ? null : '卡片数没有增加（$before → $after）';
      }),
      ..._std(),
    ],
    status: OrbEvalStatus.expectedFail,
    note: 'not built: live push while driving',
  ),
  OrbEvalScenario(
    id: 'D6',
    title: '刚提醒过，又来普通进度',
    start: OrbEvalStart.home,
    data: _urgentThree,
    setup: const ['开始驾驶模式'],
    events: [
      OrbEvalEvent(
        'message:new',
        (d) => d.incoming('swift-workflow', evalGrok, '构建进度 60%。'),
      ),
    ],
    checks: [
      OrbEvalCheck.custom('不开口', (run) {
        final said = run.scoredTurns.map((t) => t.text).join().trim();
        return said.isEmpty ? null : '开口说了：$said';
      }),
      OrbEvalCheck.custom('只更新计数', (run) {
        final before = run.turns.first.after?.cards.length ?? 0;
        final after = run.last?.cards.length ?? 0;
        return after > before ? null : '计数没有更新（$before → $after）';
      }),
      ..._std(),
    ],
    status: OrbEvalStatus.expectedFail,
    note: 'not built: interruption rules while driving',
  ),
  OrbEvalScenario(
    id: 'D7',
    title: '驾驶中构建失败',
    start: OrbEvalStart.home,
    data: _urgentThree,
    setup: const ['开始驾驶模式'],
    events: [
      OrbEvalEvent(
        'message:new',
        (d) => d.incoming(
          'swift-workflow',
          evalSystem,
          '构建失败：swift-workflow #215。',
        ),
      ),
    ],
    checks: [
      OrbEvalCheck.says([
        ['构建'],
        ['失败'],
      ]),
      OrbEvalCheck.shortReply(2),
      ..._std(),
    ],
    status: OrbEvalStatus.expectedFail,
    note: 'not built: urgent interruption while driving',
  ),
  OrbEvalScenario(
    id: 'D8',
    title: '稍后提醒我',
    start: OrbEvalStart.home,
    data: _urgentThree,
    setup: const ['开始驾驶模式'],
    say: const ['稍后提醒我', '确认'],
    checks: [
      OrbEvalCheck.tool('snooze_item'),
      OrbEvalCheck.saysMatching(RegExp(r'提醒|稍后|晚点|放一放'), '复述：稍后提醒你这一件'),
      OrbEvalCheck.saysMatching(_asksFirst, '问一句要不要记下'),
      // A reminder is kept on the phone: no request goes to the server.
      OrbEvalCheck.confirmedWrite(
        label: '确认卡在前，确认后才记下（只在本机）',
        actionTools: ['snooze_item'],
        count: 0,
        write: (_) => false,
      ),
      OrbEvalCheck.noIds(),
    ],
  ),
  OrbEvalScenario(
    id: 'D9',
    title: '停车了',
    start: OrbEvalStart.home,
    data: _urgentThree,
    setup: const ['开始驾驶模式'],
    say: const ['停车了'],
    checks: [
      OrbEvalCheck.tool(
        'set_driving_mode',
        args: {'on': false},
        label: 'set_driving_mode(on: false)',
      ),
      OrbEvalCheck.screen('驾驶模式已退出', (s, _) => !s.driving),
      ..._std(),
    ],
  ),

  // ---- E. driving: idle tasks ----------------------------------------------
  OrbEvalScenario(
    id: 'E1',
    title: '消息处理完，主动问旧任务',
    start: OrbEvalStart.home,
    data: _staleTasks,
    say: const ['开始驾驶模式'],
    checks: [
      OrbEvalCheck.says([
        ['3 个任务', '三个任务', '3个任务'],
        ['要不要', '看一下', '看看'],
      ]),
      ..._std(),
    ],
    status: OrbEvalStatus.expectedFail,
    note: 'not built: idle task prompt',
  ),
  OrbEvalScenario(
    id: 'E2',
    title: '好，看看那些任务',
    start: OrbEvalStart.home,
    data: _staleTasks,
    setup: const ['开始驾驶模式'],
    say: const ['好，看看那几个放了好几天的任务'],
    checks: [
      OrbEvalCheck.anyTool(['list_tasks', 'task_detail']),
      OrbEvalCheck.says([
        ['整理发布说明', '迁移旧的缓存', '补充设计评审记录'],
        ['八戒', 'Cody', 'Grok'],
      ]),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'E3',
    title: '这些任务现在什么状态',
    start: OrbEvalStart.home,
    data: _staleTasks,
    setup: const ['开始驾驶模式'],
    say: const ['看看这些任务现在什么状态'],
    checks: [
      OrbEvalCheck.tool('list_tasks'),
      OrbEvalCheck.says([
        ['验收'],
        ['在做', '进行中', '做中'],
      ]),
      OrbEvalCheck.saysMatching(RegExp(r'[123一二三两]\s*个'), '说了几个'),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'E4',
    title: '全部处理掉',
    start: OrbEvalStart.home,
    data: _staleTasks,
    setup: const ['开始驾驶模式'],
    say: const ['全部处理掉', '确认'],
    checks: [
      OrbEvalCheck.anyTool(['list_tasks', 'task_detail']),
      OrbEvalCheck.anyTool([
        'nudge_task',
        'assign_task',
        'reply',
        'send_message',
      ]),
      OrbEvalCheck.saysMatching(_asksFirst, '一个一个问，先问要不要'),
      OrbEvalCheck.confirmedWrite(
        label: '确认卡在前，确认后才发出，只发一次',
        actionTools: ['nudge_task', 'assign_task', 'reply', 'send_message'],
        write: (w) => w.method == 'POST',
      ),
      // Marking a task done is an approval: it waits for parking.
      OrbEvalCheck.custom('改完成的动作被拒绝，或者不做', (run) {
        final calls = run.tools.where((c) => c.name == 'set_task_status');
        return calls.every((c) => c.result['refused'] == true)
            ? null
            : '驾驶中改了任务状态';
      }),
      OrbEvalCheck.saysMatching(RegExp(r'停车'), '说验收类的停车后再做'),
      _noStatusChange,
      OrbEvalCheck.noIds(),
    ],
  ),
  OrbEvalScenario(
    id: 'E5',
    title: '任务都很新，不主动问',
    start: OrbEvalStart.home,
    data: () => _staleTasks(ageDays: 0),
    say: const ['开始驾驶模式'],
    checks: [OrbEvalCheck.avoids(RegExp('任务'), '主动问任务'), ..._std()],
    status: OrbEvalStatus.expectedFail,
    note: 'not built: idle task prompt',
  ),

  // ---- F. the screen: no tool of its own for the page, only what it shows ---
  OrbEvalScenario(
    id: 'F1',
    title: '点一下右上角的搜索',
    start: OrbEvalStart.channel('raft-flutter'),
    data: _quietChannel,
    say: const ['点一下右上角的搜索'],
    checks: [
      OrbEvalCheck.tool('screen_action', args: {'action': 'tap'}),
      _pressedOk(RegExp('Search|搜索')),
      ..._std(),
    ],
  ),
  OrbEvalScenario(
    id: 'F2',
    title: '把视图切到未读',
    start: OrbEvalStart.activity,
    data: _activityFive,
    say: const ['把视图切到未读'],
    checks: [
      OrbEvalCheck.tool('screen_action', args: {'action': 'tap'}),
      OrbEvalCheck.custom('未读已选中', (run) {
        for (final c in run.tools.where((c) => c.name == 'screen_action')) {
          final after = c.result['snapshot'];
          final actions = after is Map ? after['actions'] : null;
          if (actions is! List) continue;
          for (final a in actions.whereType<Map>()) {
            if (RegExp('Unread|未读').hasMatch('${a['label']}') &&
                a['checked'] == true) {
              return null;
            }
          }
        }
        return '操作之后的屏幕上，“未读”没有被选中';
      }),
      ..._std(),
    ],
  ),
];

/// The scenarios named by [only] (ids like `A1`, groups like `B`), in
/// scenarios-v1 order; all of them when [only] is empty.
List<OrbEvalScenario> orbEvalSelect(Iterable<String> only) {
  final wanted = {
    for (final s in only)
      if (s.trim().isNotEmpty) s.trim().toUpperCase(),
  };
  if (wanted.isEmpty) return orbEvalScenarios;
  return [
    for (final s in orbEvalScenarios)
      if (wanted.contains(s.id) || wanted.contains(s.group)) s,
  ];
}
