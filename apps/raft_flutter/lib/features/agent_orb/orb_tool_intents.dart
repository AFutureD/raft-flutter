/// What people say to the orb, in one table.
///
/// Each intent belongs to the tool that answers it ([owner]) and lists the
/// ways it is said: the standard words, the casual ones, other verbs, other
/// objects, and the "unread / not seen / new" qualifiers. The "用于" line of a
/// tool's description is made from the intents it owns ([orbToolDescription]),
/// so a phrasing is written here once and nowhere else: not in the other
/// descriptions, not in the prompt. A new way of saying a thing is added to
/// its intent; an evaluation scenario can take its words from here too.
class OrbIntent {
  const OrbIntent(this.id, this.owner, this.phrasings);

  /// A name for the intent (for people reading this table and for tests).
  final String id;

  /// The tool that answers it.
  final String owner;

  /// What the person says.
  final List<String> phrasings;
}

/// The intents, grouped by the tool that owns them.
const orbIntents = <OrbIntent>[
  // Reading what is there.
  OrbIntent('needs_you', 'get_briefing', [
    '有什么要我处理的',
    '动态里有什么',
    '有什么新的',
    '我漏了什么',
  ]),
  OrbIntent('unread_digest', 'get_briefing', [
    '把没读的摘要拿出来看一下',
    '未读的念给我听',
    '没看的那些过一遍',
  ]),
  OrbIntent('conversation_status', 'get_briefing', ['这个频道怎么样了']),
  OrbIntent('this_page', 'describe_page', [
    '这页上有什么',
    '念念这里的内容',
    '读一下动态',
    '这些是什么',
  ]),
  OrbIntent('conversation_text', 'read_conversation', [
    '这个频道最近说了什么',
    'Alice 那条原文读一下',
    '这一串讨论说了什么',
    '这个频道没读的消息念一下',
  ]),
  OrbIntent('tasks_read', 'list_tasks', [
    '任务现在什么状态',
    '谁在做什么',
    '有哪些任务放了好几天',
    '什么在等我验收',
  ]),
  OrbIntent('task_one', 'task_detail', ['任务 138 怎么样了', '这个任务卡在哪']),

  // Going and doing on the screen.
  OrbIntent('go_page', 'navigate', [
    '打开动态',
    '去 RA flutter 频道',
    '看一下 Cody 的私信',
    '进任务 136',
  ]),
  OrbIntent('open_row', 'open_item', ['打开第一条', '打开 Alice 那条', '点进去']),
  OrbIntent('screen_do', 'screen_action', [
    '点那个按钮',
    '切到“文件”标签',
    '往输入框里填字',
    '往下滚',
  ]),
  OrbIntent('layer', 'orb_layer', ['打开面板', '看看记录', '收起来', '关掉面板']),

  // Driving.
  OrbIntent('driving_mode', 'set_driving_mode', [
    '我在开车',
    '开车模式',
    '停车了',
    '退出驾驶模式',
  ]),
  OrbIntent('driving_forward', 'driving_next', ['下一件', '下一个', '稍后再说这件', '还有吗']),
  OrbIntent('driving_before', 'driving_previous', ['上一件', '上一个']),
  OrbIntent('driving_back', 'driving_back', ['返回', '回到刚才那几个']),
  OrbIntent('driving_list', 'show_list', [
    '把未读的列一下',
    '点名我的有哪些',
    '我的任务列出来',
    'Cody 那边最近有什么',
  ]),
  OrbIntent('driving_tasks', 'next_task', ['下一个', '继续']),

  // Asking for a change (each makes a confirm card).
  OrbIntent('reply_person', 'reply', ['回复他', '回他说好的', '跟 Cody 说我晚点到']),
  OrbIntent('say_in_channel', 'send_message', [
    '在 design 频道说一声',
    '给 Cody 发一条消息',
  ]),
  OrbIntent('say_in_thread', 'reply_in_thread', ['在那条消息下面回一句']),
  OrbIntent('react', 'react', ['点赞', '给那条加个 👍', '回个笑脸']),
  OrbIntent('mark_read', 'mark_read', ['标成已读', '全部已读']),
  OrbIntent('mark_done', 'mark_done', ['这条处理完了', '标为已处理']),
  OrbIntent('snooze', 'snooze_item', ['稍后提醒我', '今晚再看', '明天早上提醒我', '三个小时后再说']),
  OrbIntent('task_new', 'create_task', ['新建一个任务', '给 Cody 建个任务']),
  OrbIntent('task_status', 'set_task_status', [
    '通过',
    '标成完成',
    '开始做 138',
    '关掉任务 138',
    '放回待办',
  ]),
  OrbIntent('task_assign', 'assign_task', ['把 138 交给 Cody', '指派给 Alice']),
  OrbIntent('task_unassign', 'unassign_task', ['清掉 138 的负责人', '138 先不用谁做了']),
  OrbIntent('channel_join', 'join_channel', ['加入 design 频道']),
  OrbIntent('task_reject', 'reject_task', ['打回去，说用例不全', '不通过，退回去']),
  OrbIntent('task_nudge', 'nudge_task', ['催一下 138', '问问 Cody 做到哪了']),

  // The card on the screen.
  OrbIntent('card_yes', 'confirm', ['确认', '发吧', '好']),
  OrbIntent('card_no', 'cancel_action', ['取消', '算了', '不发了']),
  OrbIntent('undo', 'undo', ['撤销', '改回去', '刚才那个不要了']),
];

/// What people say to [tool] (empty when it owns no intent).
List<String> orbPhrasingsOf(String tool) => [
  for (final i in orbIntents)
    if (i.owner == tool) ...i.phrasings,
];

/// [phrasings] as a "用于" line: “a”“b”“c”.
String orbQuoted(Iterable<String> phrasings) =>
    [for (final p in phrasings) '“$p”'].join();
