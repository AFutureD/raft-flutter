import 'orb_tool_intents.dart';

/// The words of the orb's tools, in one shape.
///
/// A tool's description is made from an [OrbToolDoc] in a fixed order, so the
/// model finds what it chooses by first, and the parts do not drift apart:
///
///  1. what it does (a verb first; read-only or not),
///  2. 用于: what people say (from the intent table, [orbIntents]) and when,
///  3. 不用于: each tool it could be mistaken for, and which one to use then,
///  4. 限制: side effects, when it is not there,
///  5. 参数: only what the schema cannot say,
///  6. 返回: the fields that change the next step, and what is not there,
///  7. 怎么说: only the words bound to its fields (the general rules of speech
///     are the prompt's).
///
/// A "不用于" entry names the tool to use instead; when the state the tool is
/// given in has no such tool, the entry is left out ([orbToolDescription]'s
/// `available`), so a description never points at a tool the model does not
/// have. The prompt keeps the policy across tools (the order of choosing, the
/// confirm card, how to speak); what belongs to one tool is here.
class OrbToolDoc {
  const OrbToolDoc(
    this.does, {
    this.when,
    this.notFor = const [],
    this.limit,
    this.params,
    this.returns,
    this.say,
  });

  /// 1. What it does.
  final String does;

  /// 2. Beyond the phrasings of the intent table: when to use it.
  final String? when;

  /// 3. What it is not for.
  final List<OrbNot> notFor;

  /// 4.
  final String? limit;

  /// 5.
  final String? params;

  /// 6.
  final String? returns;

  /// 7.
  final String? say;
}

/// A thing a tool is not for. [tool] is the one to use instead; the entry is
/// left out where the state has no such tool.
class OrbNot {
  const OrbNot(this.text, [this.tool]);
  final String text;
  final String? tool;

  String get line => tool == null ? text : '$text（用 $tool）';
}

/// The one line every tool that asks for a change has: the confirm card (the
/// way it goes, and what the tool returns, is the prompt's 【确认】).
const orbCardLimit = '会出确认卡，不会马上执行（见【确认】）。';

/// Not while the car moves.
const _parked = '驾驶中不做，等停车。';

/// How long a description may be: reading and moving, changing, and the
/// small switches. (A guide for editing; a test holds to it.)
const orbReadDescriptionCap = 480;
const orbActionDescriptionCap = 300;
const orbSwitchDescriptionCap = 160;

/// The tools with the smaller cap.
const orbSwitchTools = {
  'orb_layer',
  'set_driving_mode',
  'driving_next',
  'driving_previous',
  'driving_back',
  'next_task',
  'cancel_action',
  'undo',
};

/// The tools that ask for a change, whose cap is [orbActionDescriptionCap].
const orbActionDocTools = {
  'reply',
  'send_message',
  'reply_in_thread',
  'react',
  'mark_read',
  'mark_done',
  'create_task',
  'set_task_status',
  'assign_task',
  'unassign_task',
  'join_channel',
  'reject_task',
  'snooze_item',
  'nudge_task',
  'act',
  'confirm',
};

int orbDescriptionCap(String tool) => orbSwitchTools.contains(tool)
    ? orbSwitchDescriptionCap
    : orbActionDocTools.contains(tool)
    ? orbActionDescriptionCap
    : orbReadDescriptionCap;

const orbToolDocs = <String, OrbToolDoc>{
  // ---- reading ------------------------------------------------------------
  'get_briefing': OrbToolDoc(
    '读出一份简报：动态（或某个频道、私信、讨论）里有什么在等用户，包括没读的和要他处理的。只读。',
    notFor: [
      OrbNot('只说去某处、没提内容', 'navigate'),
      OrbNot('要某条消息的原文', 'read_conversation'),
      OrbNot('要一个任务的详情', 'task_detail'),
    ],
    limit:
        '刚用 navigate 到了动态、频道、私信、讨论：返回里已带同一份简报，不要再调。'
        '再次调用只返回自上次以来新的；要全部设 full。',
    returns:
        'overview 总览；needsYou 每件有 who、where、title、unread（这一条的未读数）、since、ask、suggestedAction；'
        'progress 有进展的事；routineCount 常规条数；shown 卡片是否已打开。',
    say: '先说 overview，再逐件说 who、where、title、unread、ask，一件说完停；常规的只说条数。',
  ),
  'describe_page': OrbToolDoc(
    '读当前页面的内容，和屏幕上是同一份数据（不是截图）。只读，不改已读状态。',
    notFor: [
      OrbNot('去别的页面', 'navigate'),
      OrbNot('要听没读的、要处理的摘要', 'get_briefing'),
      OrbNot('一个对话的消息原文', 'read_conversation'),
    ],
    returns:
        '动态每条有 id、kind、who（真实名字；系统事件没有 who，不要说“有人”）、where、time、unread、why、preview（只是预览，要原文就用 read_conversation，conversation 填条目的 id）；'
        '对话页是看得到的消息；任务页是状态、负责人、标题；其他页是路由、标题、文字摘要；screen 是页面上能做的操作。'
        'loading 为 true 是还在加载，不是空；empty 为 true 才是空。',
    say: '读动态：按页面上的顺序逐条说谁、在哪、说了什么，不拿简报代替，不去念任务。',
  ),
  'read_conversation': OrbToolDoc(
    '读一个频道、私信或讨论的消息原文。只读：不改已读状态，不换页面。',
    notFor: [
      OrbNot('动态里有什么要处理、没读的摘要', 'get_briefing'),
      OrbNot('读当前页面', 'describe_page'),
      OrbNot('带用户去那个频道', 'navigate'),
    ],
    params:
        'conversation 是频道名、私信对象名或频道、讨论的 id，省略是当前这个；读讨论串把 describe_page 里那条消息的 thread:… 原样填入，不要用 find 或 query。'
        'since=last_read 只要上次读到之后的（未读），recent（默认）是最近几条。',
    returns: '每条有发送人名字、全文（太长标 truncated）、时间、回复数。',
  ),
  'list_tasks': OrbToolDoc(
    '读任务列表，默认是没做完的（进行中、等验收、待办），最近动过的在前。只读，立即返回。',
    notFor: [OrbNot('一个任务的详情', 'task_detail')],
    returns:
        '每个任务有 number（编号）、title、statusText、assignee、channel、idle（多久没动）、waitsFor；summary 是各状态的条数。返回里没有 id：'
        '说任务只说标题或“任务 138”，要做动作就把 number 传给动作工具。',
  ),
  'task_detail': OrbToolDoc(
    '按任务编号读一个任务：标题、描述、状态、谁在做、谁建的、频道、多久没动、在等什么，以及讨论串最后几条。只读。',
    notFor: [OrbNot('一批任务的状态', 'list_tasks')],
    params: '不同频道的编号会重复：返回里说有几个频道，就问用户是哪个，再带 channel 重读。',
    returns: '返回里没有 id。',
  ),
  'list_targets': OrbToolDoc(
    '列出可以去的具体对象和它们的 id：频道、私信、成员和 Agent、最近的讨论。只读。',
    when: '用户点名的频道、人或讨论不在提示的列表里时，先调它，再用里面的 id 去',
    notFor: [OrbNot('读消息', 'read_conversation'), OrbNot('读任务', 'list_tasks')],
    returns:
        '频道有 id、name、joined、unread；私信有 id、对方名字、person_id；成员有 id、name、type；讨论有 id、父消息摘要、所在频道。'
        '每类有上限，被截掉的数量在 xxxOmitted 里。',
  ),

  // ---- moving the app -----------------------------------------------------
  'navigate': OrbToolDoc(
    '带用户去 App 里的一个地方：页面、频道、私信、某人的资料、讨论、任务。只管“去”，不管“读”。',
    notFor: [
      OrbNot('听或看没读的、新的、要处理的内容', 'get_briefing'),
      OrbNot('读当前页', 'describe_page'),
      OrbNot('对话的原文', 'read_conversation'),
      OrbNot('打开动态里的第 N 条', 'open_item'),
    ],
    params: '一次一个目的地，自己选。id 来自 list_targets 或提示里的频道列表；实在找不到（听错了）才把原话放进 target，可再给 kind。',
    returns:
        'page（同 describe_page）；到动态、频道、私信、讨论还带 briefing（同 get_briefing）。'
        'loading 为 true 是没读到，不是空；page.empty 才是空。'
        'candidates：几个都像，念 title 让用户选，用所选的 use 重调。error 带 valid：照 valid 改一次。',
  ),
  'open_item': OrbToolDoc(
    '打开动态里的某一条，就像用户点了那一行：进到它的讨论、频道或私信。',
    notFor: [OrbNot('只读不打开', 'read_conversation'), OrbNot('去某个频道', 'navigate')],
    params: 'n 是 describe_page 动态条目里的 n（从 1 开始）；或给条目的 id。驾驶中屏幕上是列表时，n 是列表里的第几个，打开的是它的详情。',
    returns:
        'opened、title、route、screen。要说内容再调 describe_page 或 read_conversation。',
  ),
  'screen_action': OrbToolDoc(
    '在当前页面上做一件事，就像用户点了屏幕：点按钮、切标签、打开一行、往输入框填字、滚动。',
    notFor: [OrbNot('去另一个页面或频道', 'navigate'), OrbNot('回复、改任务这类有专用工具的事', 'act')],
    limit:
        '先读再做：id 和 do 里的动作来自最近一次读屏幕的结果（navigate、open_item、describe_page 返回的 screen）。'
        '发送、删除、批准、合并这类有后果的控件会出确认卡。',
    params: 'setText 把 text 填进输入框，不会发送。',
    returns: '{ok, snapshot}：snapshot 是做完以后的屏幕。error 带 snapshot 是屏幕变了：照新的 snapshot 再选一次（只重试一次）。念控件的名字，不念 id。',
  ),
  'orb_layer': OrbToolDoc(
    '打开或收起悬浮球的全屏对话层（对话记录、打字）。立即生效。',
    notFor: [OrbNot('去 App 里的页面', 'navigate')],
  ),

  // ---- driving ------------------------------------------------------------
  'set_driving_mode': OrbToolDoc(
    '进入或退出驾驶模式：进入后对话层一直开着，一次只说一件事。立即生效。',
    notFor: [OrbNot('只是提到在路上，没有要开模式')],
  ),
  'driving_next': OrbToolDoc(
    '驾驶模式下，屏幕换到简报里的下一件；屏幕是列表时翻下一页，是详情时换下一个。',
    notFor: [OrbNot('逐个处理任务时的下一个', 'next_task')],
    returns: 'index、total、item（这一件，说完就停）、done（true 只说“就这些”和常规条数）。',
  ),
  'driving_previous': OrbToolDoc(
    '驾驶模式下，屏幕回到前一件；详情上是前一个。',
    notFor: [OrbNot('往后翻', 'driving_next'), OrbNot('退出列表或详情', 'driving_back')],
    returns: 'item 就是这一件，说完就停。',
  ),
  'driving_back': OrbToolDoc(
    '驾驶模式下，屏幕退回前一个画面：详情回到列表，列表回到上一页或卡片。',
    notFor: [OrbNot('回到上一件卡片', 'driving_previous')],
    returns: '返回里的 screenSay 是 App 要说的话。',
  ),
  'show_list': OrbToolDoc(
    '驾驶模式下，在屏幕上列出一批卡片：未读的、点名用户的、用户的任务、某个频道或某个人最近的消息；每页 4 张。',
    notFor: [
      OrbNot('只想听一遍简报', 'get_briefing'),
      OrbNot('要消息的原文', 'read_conversation'),
      OrbNot('逐个处理任务', 'next_task'),
    ],
    limit: '只在驾驶模式下可用；新列表盖住现在的画面，“返回”回到原来的。',
    params: 'kind 选来源；channel、person 要给 target（频道名、人名）。',
    returns: 'total 总数，rows 是屏幕上这一页，page/pages；列表上说“第 N 个”用 open_item 的 n。',
    say: '只说总数和最前面的一两条，其余让他看屏幕。',
  ),
  'next_task': OrbToolDoc(
    '驾驶中逐个处理任务（用户说“全部处理掉”之后），换到队列里的下一个任务。',
    notFor: [OrbNot('翻简报里的下一件', 'driving_next')],
    returns: 'current（这个任务，只对它提一个动作）、index、total；done 为 true 只说“就这些”。',
  ),

  // ---- asking for a change ------------------------------------------------
  'reply': OrbToolDoc(
    '回复一个人。text 是要发的话。',
    notFor: [OrbNot('改任务状态、催任务', 'set_task_status')],
    limit: orbCardLimit,
    params:
        'to 一般省略：省略（或“他/她”）就是现在这件事里的那个人（驾驶中是卡片上那一件，在私信里是对方，在动态里是最要紧的那件）；'
        '填人名回复那个人；填 #频道名才发到那个频道。不用自己找消息，不要念 id，也不要为了回复先调 find 或 query。',
  ),
  'send_message': OrbToolDoc(
    '在一个频道或私信里发一条新消息；要 @谁就在 text 里写 @名字。',
    notFor: [
      OrbNot('回复某条消息的讨论串', 'reply_in_thread'),
      OrbNot('回复现在这件事里的那个人', 'reply'),
    ],
    limit: orbCardLimit,
  ),
  'reply_in_thread': OrbToolDoc(
    '在某条消息的讨论串里回复。',
    notFor: [OrbNot('发新消息', 'send_message')],
    limit: orbCardLimit,
    params: 'message 是那条消息的 id，取自 read_conversation 或 describe_page 返回的消息；只传给工具，不要念出来。',
  ),
  'react': OrbToolDoc(
    '给一条消息加表情反应；“点赞”就是 👍。',
    notFor: [OrbNot('发一句话', 'send_message')],
    limit: orbCardLimit,
    params: 'message 取自 read_conversation 或 describe_page。',
  ),
  'mark_read': OrbToolDoc(
    '把一个频道或私信标为已读，或把动态全部标为已读。',
    notFor: [OrbNot('动态里的一条处理完了', 'mark_done'), OrbNot('稍后再看', 'snooze_item')],
    limit: '$orbCardLimit$_parked',
  ),
  'mark_done': OrbToolDoc(
    '把动态里的一个会话或讨论串标为已处理，从动态里移走；讨论串要同时给 thread。',
    notFor: [OrbNot('只是读过了', 'mark_read'), OrbNot('稍后再看', 'snooze_item')],
    limit: '$orbCardLimit$_parked',
  ),
  'snooze_item': OrbToolDoc(
    '稍后再提醒用户看一件事：先从动态里拿掉，到点再提醒。',
    notFor: [OrbNot('已经处理完了', 'mark_done'), OrbNot('只是读过了', 'mark_read')],
    limit: orbCardLimit,
    params: 'item 省略就是屏幕上这一件（驾驶中）。when 是 later 3 小时后 / tonight 今晚 / tomorrow 明天早上 / next_week 下周一。',
  ),
  'create_task': OrbToolDoc(
    '在一个频道里新建一个任务，可同时指派负责人。',
    notFor: [OrbNot('只是发一句话', 'send_message')],
    limit: '$orbCardLimit$_parked',
  ),
  'set_task_status': OrbToolDoc(
    '改一个任务的状态。“通过”就是 done。',
    notFor: [
      OrbNot('打回去并说明原因', 'reject_task'),
      OrbNot('换负责人', 'assign_task'),
      OrbNot('催进展', 'nudge_task'),
      OrbNot('只想知道状态', 'list_tasks'),
    ],
    limit: '$orbCardLimit$_parked',
  ),
  'assign_task': OrbToolDoc(
    '把一个任务交给某个成员或 Agent（会换掉现在的负责人）。',
    notFor: [
      OrbNot('清掉负责人', 'unassign_task'),
      OrbNot('改状态', 'set_task_status'),
      OrbNot('催负责人', 'nudge_task'),
    ],
    limit: orbCardLimit,
  ),
  'unassign_task': OrbToolDoc(
    '清掉一个任务的负责人。',
    notFor: [OrbNot('换成另一个人', 'assign_task')],
    limit: '$orbCardLimit$_parked',
  ),
  'join_channel': OrbToolDoc(
    '加入一个公开频道。',
    notFor: [OrbNot('只是去看那个频道', 'navigate')],
    limit: '$orbCardLimit$_parked',
  ),
  'reject_task': OrbToolDoc(
    '把任务打回去（改回进行中或待办），并在讨论串里留言说明原因，一步完成。',
    notFor: [
      OrbNot('不用留言、只改状态', 'set_task_status'),
      OrbNot('催进展', 'nudge_task'),
    ],
    limit: '$orbCardLimit$_parked',
  ),
  'nudge_task': OrbToolDoc(
    '催一下任务的负责人：在任务的讨论串里 @他问进展。',
    notFor: [OrbNot('打回去', 'reject_task'), OrbNot('换人', 'assign_task')],
    limit: orbCardLimit,
    params: 'text 可省略（默认问“现在到哪了”）。',
  ),

  // ---- the general door ---------------------------------------------------
  'find': OrbToolDoc(
    '按用户的意思找 App 里能做的事：返回最相关的至多 5 项能力（id、一句话说明、查询还是操作、风险、参数说明）。只读。',
    when: '要读数据或要做什么，而上面没有现成的工具时，先调它，再按返回的参数说明用 query',
    notFor: [OrbNot('任务列表、任务详情', 'list_tasks')],
  ),
  'query': OrbToolDoc(
    '执行一项“查询”能力（只读，立即返回）。频道、成员、Agent、电脑、消息、任务、动态、审批、日志……App 里能读的都在这里。',
    when: '先 find 拿到能力 id',
    notFor: [OrbNot('任务', 'list_tasks'), OrbNot('对话的消息', 'read_conversation')],
    params: 'capability 填 find 返回的 id；args 是参数的 JSON 文本，按 find 的参数说明写。',
    returns: '返回里的 id 只用来传给别的工具，不念出来；说名字、标题和编号。读到的才是事实。',
  ),
  'act': OrbToolDoc(
    '申请一项“操作”能力：其余操作的入口。',
    when: '上面没有专用工具的操作，先 find',
    notFor: [OrbNot('回复、改任务状态、催任务、表情、稍后提醒这类有专用工具的操作', 'reply')],
    limit:
        '$orbCardLimit永远不能语音做的操作（删除、改角色、计费……）没有确认卡：App 带用户去那个页面，你只说“已带你去那个页面，自己操作”。',
  ),

  // ---- the card on the screen ---------------------------------------------
  'confirm': OrbToolDoc(
    '执行屏幕上等着确认的那一项。一次只有一项，不需要 token。',
    when: '只在用户点了确认，或亲口说了以上的话之后',
    notFor: [
      OrbNot('用户没有表态：你自己的话不算确认，调用只会返回 needs_user_confirmation，这时问他一句，不要重复调用'),
    ],
    returns:
        'done 就说做完了；failed 就如实说原因；needs_second_confirmation 是敏感操作，请他再点一次确认卡。',
  ),
  'cancel_action': OrbToolDoc(
    '丢掉屏幕上等着确认的那一项，什么都不做。没有参数。',
    notFor: [OrbNot('撤销已经做完的事', 'undo')],
  ),
  'undo': OrbToolDoc(
    '撤销刚刚执行完的操作（改状态、表情、指派、停 Agent 等能撤销的）。执行后 30 秒内有效。',
    notFor: [OrbNot('丢掉还在等确认的那一项', 'cancel_action')],
    limit: '你自己不能决定撤销：用户没说过，会返回 needs_user_consent，什么都不做。',
  ),
};

/// The description of [name], made from its [OrbToolDoc] and the intents it
/// owns. With [available] (the tools the state has), an entry that points at
/// a tool outside it is left out.
String orbToolDescription(String name, {Set<String>? available}) {
  final doc = orbToolDocs[name];
  if (doc == null) throw ArgumentError('no words for the tool $name');
  final said = orbPhrasingsOf(name);
  final uses = [
    if (said.isNotEmpty) orbQuoted(said),
    if (doc.when != null) doc.when!,
  ];
  final nots = [
    for (final n in doc.notFor)
      if (n.tool == null || available == null || available.contains(n.tool))
        n.line,
  ];
  return [
    doc.does,
    if (uses.isNotEmpty) '用于：${uses.join('；')}。',
    if (nots.isNotEmpty) '不用于：${nots.join('；')}。',
    if (doc.limit != null) '限制：${doc.limit}',
    if (doc.params != null) '参数：${doc.params}',
    if (doc.returns != null) '返回：${doc.returns}',
    if (doc.say != null) '怎么说：${doc.say}',
  ].join('\n');
}

/// [declaration] with its description made for the tools [available]: the
/// ones the tool has no words for are left as they are.
Map<String, Object?> orbDescribeFor(
  Map<String, Object?> declaration,
  Set<String> available,
) {
  final name = '${declaration['name']}';
  if (declaration['description'] is! String || !orbToolDocs.containsKey(name)) {
    return declaration;
  }
  return {
    ...declaration,
    'description': orbToolDescription(name, available: available),
  };
}
