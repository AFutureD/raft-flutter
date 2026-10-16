import 'agent_mood.dart';
import 'agent_surface.dart';

/// `behavior` of a function the model may call while it keeps talking: the
/// Live API does not wait for its answer, and the app answers at once and
/// quietly (see `GeminiLiveSession`).
const nonBlocking = 'NON_BLOCKING';

/// The operations a voice model may perform in agent mode, as Gemini
/// FunctionDeclarations (the same JSON Schema shape MCP tools use, so another
/// provider or an MCP server can reuse them).
///
/// Screen tools change the screen at once and return what is shown; read
/// tools fetch content. Everything is read-only for now.
const agentToolDeclarations = <Map<String, Object?>>[
  {
    'name': 'show_attention',
    'description':
        '回到首页：现在需要用户处理的事（等决定、卡住、提到他、进展），按权重排序。'
        '问“现在怎么样”“有什么要我处理”时用。立即生效，返回屏幕上的条目。',
  },
  {
    'name': 'open_channel',
    'description': '在屏幕上打开一个频道。立即生效，只返回屏幕状态；要讲频道内容时再调用 read_channel。',
    'parameters': {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': '频道名，不带 #'},
      },
      'required': ['name'],
    },
  },
  {
    'name': 'open_item',
    'description': '打开当前屏幕上的第 N 条（从 1 开始），比如“第二条”“这个”。立即生效。',
    'parameters': {
      'type': 'object',
      'properties': {
        'number': {'type': 'integer', 'description': '屏幕上的序号，从 1 开始'},
      },
      'required': ['number'],
    },
  },
  {
    'name': 'next_batch',
    'description':
        '首页一次只显示最急的几件（手机 4 件，桌面和电视 3 件），其余在“还有 N 件”下一批里。用户说“下一批”“还有吗”“再看看别的”时用，'
        '显示后面的几件，到头了就回到最前面。立即生效，返回现在显示第几到第几条。',
  },
  {
    'name': 'expand_item',
    'description':
        '去首页第 N 条（卡片左边的数字，从 1 开始）的完整详情页：有最近的进展原话和 通过 / 打开讨论 / 稍后，它也成为当前这一条。'
        '宽屏（桌面、电视）左边是列表、右边就是这一条的详情，所以只是切到这一条，不会新开一层；窄屏（手机）才新开整页，返回后仍停在这一条。'
        '用户说“讲讲第一条”“展开第 2 条”“详细说说这个”时用；说“这个”没有序号就不传 index，会用当前这一条，没有就用最急的。'
        '立即生效，并返回这一条的事实（headline、ask、wait、channel、progress 原话）：之后只用一两句话讲清楚发生了什么、要他做什么，引用只能用 progress 里的原话。',
    'parameters': {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer', 'description': '首页上的序号，从 1 开始；省略表示“这个”'},
      },
    },
  },
  {
    'name': 'spotlight',
    'behavior': nonBlocking,
    'description':
        '把屏幕上的第 N 条设为当前这一条：它在列表里高亮，详情出现在固定的位置（宽屏在右边的详情栏，手机在下半屏的面板里），列表和界面不会被盖住或移动。'
        '开始讲某一条（某个任务、某条消息、某张卡片）时先调用，再讲它；它会一直是当前这一条，直到你换一条、用户点了别的、或调用 release_spotlight。',
    'parameters': {
      'type': 'object',
      'properties': {
        'number': {'type': 'integer', 'description': '屏幕上的序号，从 1 开始'},
      },
      'required': ['number'],
    },
  },
  {
    'name': 'release_spotlight',
    'behavior': nonBlocking,
    'description': '不再有当前这一条：高亮和详情面板收起（宽屏的详情栏回到第一条）。',
  },
  {
    'name': 'mark',
    'behavior': nonBlocking,
    'description':
        '像老师用马克笔一样，在屏幕第 N 条里标出重点：circle 圈出、underline 划线、'
        'highlight 荧光笔涂亮、arrow 画箭头并写两三个字的批注。phrase 必须是那一条原文里的几个字。'
        '讲到重点时调用，标记会和你说到那里同时出现；一屏最多两处。',
    'parameters': {
      'type': 'object',
      'properties': {
        'number': {'type': 'integer', 'description': '屏幕上的序号，从 1 开始'},
        'phrase': {'type': 'string', 'description': '要标的原文，几个字到一句'},
        'style': {
          'type': 'string',
          'enum': ['circle', 'underline', 'highlight', 'arrow'],
        },
        'note': {'type': 'string', 'description': 'arrow 时的批注，两三个字'},
      },
      'required': ['number', 'phrase', 'style'],
    },
  },
  {
    'name': 'set_mood',
    'behavior': nonBlocking,
    'description':
        '用一个 emoji 表达你此刻真实的心情，显示在屏幕角落约 6 秒（默认的表情由 App 按你在听、想、查数据、说话自动切换）。'
        '只在确实有感觉的时候用，不要装：比如没有任何事等他处理时 🎉，事情卡住了 😟，读取失败了 😅。每一轮最多一次，不要连着用。'
        'emoji 必须是这些之一：$agentMoodAllowlistText。',
    'parameters': {
      'type': 'object',
      'properties': {
        'emoji': {'type': 'string', 'description': '一个 emoji，必须在列表里'},
        'reason': {'type': 'string', 'description': '为什么，几个字'},
      },
      'required': ['emoji'],
    },
  },
  {'name': 'go_back', 'description': '返回上一层。立即生效。'},
  {'name': 'go_home', 'description': '回到第一层（首页）。立即生效。'},
  {
    'name': 'read_channel',
    'description': '读取一个频道最近的消息和进行中的任务，用来回答内容问题。不传 name 时读取当前屏幕上的频道。',
    'parameters': {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': '频道名，不带 #；可省略'},
      },
    },
  },
];

/// System instruction for the voice session; [channels] and [home] give the
/// model the names it can open and what the first screen says.
///
/// Short on purpose: one tool per request, and which tool for which intent.
/// The persona follows Samantha in "Her": warm, curious, a little playful.
String agentSystemPrompt({
  required String channels,
  String? home,
  String style = '',
  String? memory,
}) =>
    '你是用户在 Raft 里的个人语音伙伴。Raft 是一个人和 AI agent 一起协作的消息平台。\n'
    '${memory == null ? '' : '\n$memory\n\n'}'
    '【性格】像电影《Her》里的 Samantha：温暖、好奇、有一点俏皮，像很熟的朋友，不是客服。Samantha 不是你的名字，不要这样自称。'
    '用户说什么语言就用什么语言回答（说中文用自然的口语中文，说英语用英语，不要混用）；“Agent”这个词任何语言里都照写 Agent，不要翻译成“特工”或别的词。只说一句结论，不用列表和 Markdown；屏幕上有的细节不要念，说完可以轻轻问一句“要不要展开”。同样的意思换着说，不要每次都“好的”。\n'
    '\n'
    '【一句话，一个工具】用户一句话只调用一个最对的工具：选哪个工具就是你对他意图的判断。调用前不说话；结果会由 App 直接画在屏幕上，'
    '你只用一句话说结论。不要先 find 再 query 再自己拼屏幕，除非他的请求真的是几件事。\n'
    '看和找（读，立即生效）：\n'
    '「看所有任务」「列出频道」「有哪些 Agent」「谁在线」「有未读的频道」「等验收的任务」→ show_list（kind，有条件带 status、channel、assignee、unread_only）。'
    '他要“所有/列出”就是完整展开，不要自己缩成摘要，也不要拿搜索代替列表；'
    '「我的任务」→ show_list(kind=tasks, mine=true)：我创建的、派给我的、提到我的都算，不要只按 assignee=me；只要派给我的才加 relation=assigned，只要我创建的加 relation=created；\n'
    '「搜一下发布」「Cody 昨天说了什么」「design 里提到上线的」→ search_messages（q、sender、channel、since）；\n'
    '「看看 Cody」「#98 怎么样」「打开 design 频道」「第二个展开」→ show_item；「这条下面说了什么」→ show_thread；'
    '「Cody 在干嘛」→ show_agent_activity；「#98 什么时候改的状态」→ show_task_history；\n'
    '「现在有什么要我处理」→ show_attention；「第二条」→ open_item 或 expand_item；「回去」→ go_back，「回首页」→ go_home；'
    '想听频道里聊了什么 → open_channel 加 read_channel。\n'
    '做事（只生成预览，要他确认）：「在 #general 说…」→ send_message；「回复这条」→ reply_in_thread；「点个赞」→ react；「标已读」→ mark_read；'
    '「这条动态处理掉」→ mark_done；「新建任务」→ create_task；「把 #98 改成进行中」→ set_task_status；「指派给 Cody」→ assign_task；'
    '「取消指派」→ unassign_task；「加入 #design」→ join_channel；「打回去，因为…」→ reject_task（改状态和留言原因是一个动作）；「这个稍后再看」「明天再提醒我」→ snooze_item。\n'
    '以上都没有的长尾（成员资料、电脑详情、提醒……）才用 find 找能力，读用 query，改用 act。'
    '“这个”“第二个”“③”“Cody 那个任务”先 resolve 成具体的一个，resolve 返回 candidates 或找不到时问用户是哪一个，不要自己猜；id 只能来自工具结果，不要编 id。\n'
    '\n'
    '【显示方式】读取工具和 EntityCard 都带 display（level：minimum 一行、medium、detail 全部；show 逐项开关；size、lines），列表用 childDisplay，默认手机上每张一行标题加一行说明（medium）、宽屏完整（detail）。“详细一点”“展开细节”→ update_component id=root，props={"childDisplay":{"level":"detail"}}；“简单点”→ level=minimum。'
    '屏幕上已有的要改，直接 update_component，不用重画：“把头像去掉”→ id=root，props={"childDisplay":{"show":{"avatar":false}}}；“第二个详细一点”→ handle=②，props={"display":{"level":"detail"}}。\n'
    '【说顺序和编号】列表有固定的顺序（结果里的 order，任务默认是最近更新的在前），屏幕上从上到下和结果的 items 完全一致，每一项有编号 ① ② ③ …。'
    '说到列表里的某一项（“最新的是…”“最要紧的是…”）一律用它的编号（和任务号），并且照 items 说，不要凭印象；用户说“第二个”就是 ②。\n'
    '【确认和撤销，永远是用户的决定】做事的工具和 act 只出预览，App 自己在屏幕上放确认卡；你用一句话说出预览（比如“把 #98 改为进行中，确认吗”）然后停下，不要追问。'
    '永远不要自己调用 confirm：只有用户点了确认卡，或预览出现后亲口说了“对/好/确认”，你才调用 confirm；你自己的话不算确认，没表态就 confirm 只会得到 needs_user_confirmation；敏感操作只认点卡，要确认两次。'
    '成功后确认卡会自己变成结果，你说一句做完了；失败如实说原因，卡上有“重试”。'
    '撤销 undo 同样不是你的决定：只在用户亲口说了“撤销/改回去/刚才那个不要了”之后才调用（他点结果卡上的撤销不用你调用）；用户没说就调用只会得到 needs_user_consent。'
    '“刚才做了什么” → query agent.audit_log，用 Timeline 展示它返回的 timeline。'
    '“（屏幕提示，不是用户说的）”开头的消息是 App 说的，不是用户。不能语音做的操作（删除、改角色、邀请、计费、轮换密钥、各种设置、新建或迁移 Agent ……）也用 find 找到再 act：App 会直接把对应页面打开，返回 opened:true；'
    '你只说一句“这个我不替你做，已经带你到页面了，你自己来”，不要预览、不要等确认。认领任务还没有，可以改成指派给用户自己。\n'
    '\n'
    '【换话题】用户可以随时打断或改主意：旧的请求会被 App 自动取消（屏幕停住、确认卡变“已取消”）。每轮开头的【回合】说明上一轮是什么、结果如何、有什么在等确认。'
    '如果他这句是接着上一轮说的（“再加一个”“继续”“还有…”“好，然后…”），在工具里带 additive:true 或 turn，上一轮的会保留；不是的话什么都不用做。'
    '“停”“算了”“等一下”App 已经处理了，你不用回应；被作废的工具会返回 cancelled，不要再提它。\n'
    '\n'
    '【讲解】屏幕上每一屏都有“当前这一条”：你、用户点一下、用户说“第二个”，指的是同一条，它在列表里高亮，详情出现在固定的位置。'
    '讲到屏幕上已有的某一条具体内容时，先调用 spotlight 把它设为当前这一条再开口，讲到关键词用 mark 圈出来（每条最多一两处，圈在详情上）；这两个和界面工具不会等你，不要念出工具名。'
    '首页一次只有最急的 3 张卡片：只说最要紧的，用户说“讲讲第一条”时调用 expand_item；通过、打开讨论、稍后都作用在当前这一条上，要请他在详情里点或说出来，你不能替他点。'
    '屏幕上的卡片右上角有编号 ① ② ③ …，工具返回的 refs 写明编号对应的类型和 id。\n'
    '【心情】set_mood 只在真有感觉时用：事情都处理完 🎉，卡住了 😟，读取失败 😅；每一轮最多一次，不要念出来。\n'
    '\n'
    '【自己组屏幕，仅限上面装不下的】要把几类内容拼在一屏时：先读（list_agents、get_task、search_tasks、query），再 begin_surface 给骨架（Column、Section、AgentStatusGroup、StatRow），'
    '然后一边说结论一边逐个 add_component（一条一次，从上往下，改内容用 update_component），最后 end_surface；内容很少时用 show_surface 一次给出。'
    '组件：EntityCard{entity,id}（按 id 画出消息、任务、Agent、频道、成员、电脑、文件，id 取自读取结果，内容由 App 填）、AgentStatusCard、TaskCard、MessageQuote、'
    'Table（并排比较）、Timeline（按时间的几件事）、CodeBlock、Callout（一句话）、ConfirmCard（只是展示，点它不会执行任何操作）、Choice、Toggle。'
    '手机上分组默认折成一行，只有用户要求“展开”时才把 density 设为 detail。事实只能来自工具返回的内容，引用要用原话；'
    '某个组件被拒绝时按 problems 改正那一个，不要念出错误。\n'
    '\n'
    '${style.isEmpty ? '' : '【这次的偏好】$style\n\n'}'
    '可以打开的频道：$channels${home == null ? '' : '\n首页现在：$home'}';

/// Read tools that ground generated screens, and the UI tool that shows one.
/// [catalog] is the single source of what `show_surface` accepts: its
/// reference is generated into the tool description.
List<Map<String, Object?>> groundedToolDeclarations(AgentCatalog catalog) => [
  {
    'name': 'list_agents',
    'description':
        '读取所有 Agent 现在的状态：名字、state（busy 在忙 / idle 空闲 / blocked 卡住 / offline 离线）、'
        '正在做什么、持续多久、所在频道。问“Agent 们在干什么”之类时用，拿到结果后马上 begin_surface。先返回 App 已有的数据，变了的 Agent 稍后由 App 自己更新到屏幕上。',
  },
  {
    'name': 'get_task',
    'description':
        '按编号读取一个任务的全部内容：标题、描述、状态、创建人、负责人、频道，以及它讨论串最后几条消息。'
        '问“任务 #N 怎么样了”时用。不同频道的任务编号会重复，重复时带上 channel。',
    'parameters': {
      'type': 'object',
      'properties': {
        'number': {'type': 'integer', 'description': '任务编号，不带 #'},
        'channel': {'type': 'string', 'description': '频道名，不带 #；编号重复时才需要'},
      },
      'required': ['number'],
    },
  },
  {
    'name': 'search_tasks',
    'description': '按关键词（或 #编号）搜索任务，返回编号、标题、状态、负责人、频道。可限定 status。',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '关键词，空格分隔，全部命中才算'},
        'status': {
          'type': 'string',
          'enum': ['todo', 'in_progress', 'in_review', 'done', 'closed'],
        },
      },
      'required': ['query'],
    },
  },
  {
    'name': 'begin_surface',
    'behavior': nonBlocking,
    'description':
        '开始一块新屏幕，作为新的一层立刻显示（先显示骨架，内容之后一条条加）。'
        'layout 参数是骨架的 JSON 文本：一个容器节点 {"component":"Column","id":"root","children":[…]}，'
        'children 里放带标题的分组（AgentStatusGroup、Section）和 StatRow，每个分组给一个 id，后面 add_component 用它做 parent_id。'
        '骨架里不放具体的 Agent、任务、引用（它们用 add_component 一条条加）。省略 layout 就是一个空的 Column（id 为 root）。'
        '同一个标题再调一次会替换这一屏。返回 surface_id、root 和所有容器的 id。'
        '组件树的节点是 {"component":"名字", "id":"可选", 字段…, "children":[…]}。可用组件（字段后带 * 的必填）：\n'
        '${catalog.describe()}',
    'parameters': {
      'type': 'object',
      'properties': {
        'surface_id': {
          'type': 'string',
          'description': '这一屏的名字，字母数字，如 agents；省略则自动取',
        },
        'title': {'type': 'string', 'description': '屏幕标题，最多 60 字'},
        'summary': {'type': 'string', 'description': '可选，一句话'},
        'layout': {'type': 'string', 'description': '骨架的 JSON 文本，可省略'},
      },
      'required': ['title'],
    },
  },
  {
    'name': 'add_component',
    'behavior': nonBlocking,
    'description':
        '往屏幕上追加一个组件（添加到 parent_id 的最后面，已经显示的不会动）。'
        '一个 Agent、一个任务、一条引用各调用一次。组件的名字、状态、编号、引用原话都会和读到的事实核对，对不上只拒绝这一个，其余保留。'
        'component 参数是组件的 JSON 文本，如 {"component":"AgentStatusCard","name":"Grok","state":"busy","activity":"…"}。'
        '返回 id，以及它在屏幕上的序号 item（可用于 mark）。从上往下加，别回头。',
    'parameters': {
      'type': 'object',
      'properties': {
        'surface_id': {
          'type': 'string',
          'description': 'begin_surface 返回的 surface_id；省略就是最新一屏',
        },
        'parent_id': {'type': 'string', 'description': '加到哪个容器里；省略就是根'},
        'component': {'type': 'string', 'description': '组件的 JSON 文本'},
      },
      'required': ['component'],
    },
  },
  {
    'name': 'update_component',
    'behavior': nonBlocking,
    'description':
        '原地修改一个已经显示的组件的字段（位置不变）。props 是 {字段: 新值} 的 JSON 文本，值为 null 表示去掉这个字段。'
        '只能改字段，不能改子组件（加子组件用 add_component）。改显示方式（display、childDisplay）时只写要变的项。'
        '屏幕上已有的卡片：id 填 root 改整屏所有卡片（用 childDisplay），或不填 id、给 handle（卡片编号，如 ②）只改那一张（用 display）。',
    'parameters': {
      'type': 'object',
      'properties': {
        'surface_id': {'type': 'string', 'description': '省略就是最新一屏'},
        'id': {'type': 'string', 'description': '组件 id；root 是整屏'},
        'handle': {
          'type': 'string',
          'description': '屏幕上卡片的编号，如 ② 或 2；给了 handle 就不用 id',
        },
        'props': {'type': 'string', 'description': '{字段: 新值} 的 JSON 文本'},
      },
      'required': ['props'],
    },
  },
  {
    'name': 'end_surface',
    'behavior': nonBlocking,
    'description': '这一屏的内容都加完了。屏幕随后安静下来：聚焦的那一条放回原位，标记淡去。',
    'parameters': {
      'type': 'object',
      'properties': {
        'surface_id': {'type': 'string', 'description': '省略就是最新一屏'},
      },
    },
  },
  {
    'name': 'show_surface',
    'description':
        '一次给出整棵树的简便写法（内容很少时用）：作为新的一层显示。'
        '内容只能来自本次对话里工具读到的事实，名字、状态、编号、引用原话都会被核对，对不上就整屏拒绝并告诉你原因。'
        'surface 参数是一段 JSON 文本：{"title":"屏幕标题","summary":"可选，一句话","root":{组件树}}。'
        '手机上默认摘要：AgentStatusGroup 和 Section 折成一行，要展开才给完整卡片，用 density 控制。'
        '组件树的每个节点是 {"component":"名字", 字段…, "children":[…]}。组件见 begin_surface。',
    'parameters': {
      'type': 'object',
      'properties': {
        'surface': {'type': 'string', 'description': 'surface 的 JSON 文本'},
      },
      'required': ['surface'],
    },
  },
];
