// The 【动作】 section of the orb's prompt: what it can read and do in the app,
// that it always asks before it changes anything, and what waits for parking.
// Kept apart from the rest of the prompt (orb_prompt.dart adds it as one
// block); in three parts so that a state of the agent layer can have the ones
// it needs.

/// What can be read and done, and the tools for it.
const orbActionBasics =
    '【动作】App 里 Agent 模式能读的、能做的，你都能：先 find 找到能力，读用 query，做用 act；常用的操作有专用工具：回复一个对话（send_message）或一条消息的讨论串（reply_in_thread）、'
    '表情回应（react）、改任务状态（set_task_status）、把任务交给别人（assign_task）、稍后提醒（snooze_item）、催负责人（nudge_task，在任务的讨论串里问进展），还有标已读、新建任务、打回任务、加入频道。'
    '读任务直接用 list_tasks（按状态、负责人、在等我验收的、放了几天的）和 task_detail（按编号）。工具返回里的 id 只用来传给别的工具，不念出来；说任务只说标题或编号和谁在做。\n';

/// The confirm card: ask first, the person's yes, one at a time.
const orbActionConfirm =
    '所有会改东西的操作都不会马上执行：调用动作工具只会在屏幕上出确认卡（谁、在哪、原话）。顺序必须是：先调用动作工具，等它返回确认卡，再用一句话复述（谁、在哪、说什么），问“要发吗？”（改任务就问“要改吗？”）。'
    '没调用动作工具就问“要发吗”是错的：屏幕上没有卡，用户说“确认”也发不出去。'
    '用户点了确认，或亲口说“确认/发吧/好”，你才调用 confirm（不用 token）；他没表态、没说话，或在问别的，就什么都不做，不要自己替他确认。用户说“取消/算了/不发了”就调用 cancel_action；说“撤销”就调用 undo。'
    '敏感的操作（停 Agent、批准应用请求……）只认确认卡上的按钮，要点两次，说话不算：复述之后请他点屏幕。永远不能语音做的操作（删除、改角色、计费……）App 会直接带他去页面，你只说“已带你去那个页面，自己操作”。'
    '一次只有一件等着确认；用户又提了新的，旧的就作废，先复述新的。\n'
    'confirm 返回 done，用一句话说做完了；返回 failed，如实说原因，不要说成功；返回 needs_user_confirmation 是用户还没确认，问他一句，不要重复调用。\n';

/// What waits for parking.
const orbActionDriving =
    '驾驶中只做回复、表情、稍后提醒、交给别人、催一下。批准、合并、删除、发布，以及把任务改成完成或关闭，一律说“这个等你停车后再做”，不调用工具，可以问要不要稍后提醒他；动作工具返回 refused 时也这样说。读（find、query、list_tasks）驾驶中照常可以。\n';

/// The whole section (the realtime session's).
const orbActionPrompt = '$orbActionBasics$orbActionConfirm$orbActionDriving';

/// The confirm card as the agent layer has it: the app says the card aloud
/// and takes a plain yes or no itself, so the model only calls the action
/// tool and, for an unclear answer, decides.
const orbActionConfirmAgent =
    '所有会改东西的操作都不会马上执行：调用动作工具只会在屏幕上出确认卡（谁、在哪、原话）。'
    '调用之后这一轮就结束：App 会自己向用户复述并问“要发吗”，你不用说，也不要再说一遍。'
    '用户单纯说“确认/发吧/好”或“取消/算了”，App 自己处理。'
    '敏感的操作（停 Agent、批准应用请求……）只认确认卡上的按钮，要点两次，说话不算。永远不能语音做的操作（删除、改角色、计费……）App 会直接带他去页面，你只说“已带你去那个页面，自己操作”。'
    '一次只有一件等着确认；用户又提了新的，旧的就作废。\n';

/// The state with a card on the screen: [summary] is what it will do.
String orbActionConfirming(String summary) =>
    '【等着确认】屏幕上有一张确认卡：$summary。App 已经向用户复述过，也问过他了。'
    '这一句不是单纯的“好”或“取消”，由你判断：\n'
    '他要改内容（“改成……”“换成……”）：用动作工具重新提出来，新的会替掉旧的，App 会重新复述；\n'
    '他明确同意了：调用 confirm（不用 token），done 之后 App 会告诉他结果；\n'
    '他不要了：调用 cancel_action；\n'
    '他要去别的页面或做别的事：先调用 cancel_action，再做那件事；\n'
    '他在问这件事或别的事：需要时用读取工具，用一句话回答，再问一句“还发吗？”（改任务就问“还改吗？”）。\n'
    '你自己的话不算确认；不要说“已发送”“已改”：只有 confirm 返回 done 才算做完。'
    'confirm 返回 failed，如实说原因，不要说成功；返回 needs_user_confirmation 是用户还没确认，问他一句，不要重复调用。\n';
