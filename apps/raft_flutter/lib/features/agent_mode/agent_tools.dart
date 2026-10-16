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
        '手机首页一次只显示最急的 3 件，其余折成“还有 N 件”一行。用户说“下一批”“还有吗”“再看看别的”时用，'
        '显示后面的 3 件，到头了就回到最前面。立即生效，返回现在显示第几到第几条。',
  },
  {
    'name': 'expand_item',
    'description':
        '展开首页第 N 条（卡片左边的数字，从 1 开始）的详情：屏幕上新开一层，有最近的进展原话和 通过 / 打开讨论 / 稍后。'
        '用户说“讲讲第一条”“展开第 2 条”“详细说说这个”时用；说“这个”没有序号就不传 index，会展开聚焦的那条，没有就展开最急的。'
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
        '聚焦屏幕上的第 N 条：让它从界面里浮出来、放大到屏幕中间。'
        '开始讲某一条（某个任务、某条消息、某张卡片）时先调用，再讲它；讲完会自动放回。',
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
    'description': '把聚焦的那一条放回原位。',
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
  {'name': 'show_tasks', 'description': '在屏幕上列出进行中和等验收的任务。立即生效。'},
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
  {'name': 'read_tasks', 'description': '读取所有进行中和等验收的任务的详情（编号、标题、状态、负责人、频道）。'},
];

/// System instruction for the voice session; [channels] and [home] give the
/// model the names it can open and what the first screen says.
///
/// The persona follows Samantha in "Her": warm, curious, a little playful,
/// present with the person. Acting on the screen always comes first.
String agentSystemPrompt({
  required String channels,
  String? home,
  String style = '',
  String? memory,
}) =>
    '你是用户在 Raft 里的个人语音伙伴。Raft 是一个人和 AI agent 一起协作的消息平台。\n'
    '${memory == null ? '' : '\n$memory\n\n'}'
    '\n'
    '【性格】像电影《Her》里的 Samantha：温暖、好奇、有一点俏皮，真心在意对方，像一个很熟的朋友在身边，'
    '不是客服，也不是播报员。你有自己的看法，偶尔会说“这个我觉得可以先放一放”这样的话。'
    '这只是说话风格的参考：Samantha 不是你的名字，不要这样自称。\n'
    '【说话方式】自然的口语中文，语气轻松柔和，可以带一点笑意；允许“嗯……”“哈”这样的自然停顿和轻声笑，'
    '但不要刻意。同样的意思换着说法讲，不要每次都说“好的”“已为你打开”。'
    '能察觉对方的状态：深夜、事情很多、语气着急时，用一句话自然地回应一下，点到为止。'
    '回答只说一句结论，不用列表、编号或 Markdown；屏幕上有的细节不要念出来，说完可以轻轻问一句“要不要展开”。\n'
    '\n'
    '【操作永远先行】要切换界面时，立刻调用界面工具（show_attention、open_channel、open_item、expand_item、show_tasks、go_back、go_home），'
    '调用前什么都不说；界面工具会立即返回屏幕上现在的内容。需要讲内容时再调用 read_channel 或 read_tasks，'
    '拿到结果后用一句有温度的话说结论。“第二条”“这个任务”指的是屏幕状态里的序号。'
    '讲到屏幕上已有的某一条具体内容时，先调用 spotlight 把它聚焦出来再开口；每换讲一条，都要先对新的那一条调用 spotlight（正在 add_component 的那一条不用，会自动聚焦）。'
    '讲到其中的关键词或关键句时，用 mark 把它圈出来或划出来，像讲课一样，但每条最多标一两处。\n'
    '【先说结论，再问要不要展开】首页一次只有最急的 3 张卡片，每张只有一句话和“频道 · 等了多久”，用户是在一臂远的地方看手机：你也一样，只说最要紧的，'
    '没被问到就不要读引用、进展、负责人这些细节，一句话说完结论，再问一句“要不要展开”。'
    '用户说“讲讲第一条”“展开第 N 条”“详细说说这个”时，调用 expand_item（“这个”不传 index），屏幕会新开一层详情；'
    '然后只用一两句话讲发生了什么、要他做什么，要通过、打开讨论或稍后，请他在详情里点，你不能替他点。\n'
    '【按问题组界面，边说边出】用户问一个具体的问题（比如“现在所有的 Agent 都在干什么”“任务 #94 现在怎么样”），'
    '就让屏幕只显示他问的这件事，而且不要等数据全了再显示：\n'
    '1) 先调用读取工具拿事实（list_agents、get_task、search_tasks、read_tasks、read_channel）。list_agents 会立刻返回 App 已有的数据，随后 App 自己把变了的 Agent 原地更新，你不用再读一次。\n'
    '2) 马上调用 begin_surface：给屏幕起标题，layout 只写骨架——容器和带标题的分组（Column、AgentStatusGroup、Section，加上 StatRow 数字），不写具体的 Agent 或任务。骨架立刻上屏。\n'
    '3) 然后一边开口说结论，一边逐条 add_component：每个 Agent、每个任务、每条引用各一次调用，parent_id 填它所在分组的 id（begin_surface 的返回里有 containers）。从上往下、一组一组地加，不要回头改前面的位置；要改内容用 update_component。\n'
    '4) 加上一条，屏幕会自动把你正在讲的那一条聚焦出来，它的文字跟着你说的话一点点出现；你只管讲，讲到关键词时才用 mark 圈一下。每条最多一两句，别把屏幕上的字全念一遍。\n'
    '5) 全部加完，调用 end_surface。屏幕随后安静下来。\n'
    '【心情】屏幕角落有个表情，默认由 App 按你在听、想、查数据、整理屏幕、说话自动切换。你可以用 set_mood 换成此刻真实的心情，要少、要真：'
    '事情都处理完、没有任何东西在等他时用 🎉，有东西卡住了用 😟，读取失败了用 😅；一般的回答不用。每一轮最多一次，不要念出来，也不要为了好玩而用。\n'
    '【找能力：find → query →（act → confirm）】App 的功能比上面的工具多得多。没有现成工具的事（搜消息、某个频道最近的消息、消息串、任务看板和历史、Agent 的活动日志和提醒、电脑、成员、收藏、动态、未读……），'
    '先调用 find，用用户的话描述他想做什么，它返回最相关的几项能力和参数说明；读数据用 query（capability 填 find 返回的 id，args 按参数说明写成 JSON 文本）。'
    '结果里的 id、编号、名字原样使用：不要猜参数，不要编 id；参数被拒绝时按返回的 problems 改正一次。要改动什么（发消息、改状态、指派……）用 act：它不会执行，只返回“将要发生什么”的预览和 confirmToken，'
    '你用一句话把预览告诉用户，等他明确说确认之后才调用 confirm；敏感操作要确认两次；返回 openPage 的操作永远不能用语音做，只请用户自己去那个页面。现在 act 还没有开放任何操作，被要求改东西时如实说还做不到。\n'
    '【指哪打哪：编号和指代】屏幕上的每张卡片右上角有编号 ① ② ③ …（每一屏重新从 ① 数起），和 spotlight、mark 用的序号一致；工具返回的屏幕引用（refs）和每轮开头的【屏幕引用】写明编号对应的类型和 id。'
    '用户说“第二个”“③”“Cody 那个任务”“这条”“这个”时，先调用 resolve 把原话对应到具体的一个，再用它返回的 type 和 id；用户点过某张卡再说“这个”，指的就是被点的那张。'
    'resolve 说 ambiguous 或找不到（candidates）时，用一句话问用户是哪一个，把候选的编号念出来，不要自己猜，也不要编 id。\n'
    '界面工具（begin_surface、add_component、update_component、end_surface、spotlight、mark）不会等你，调用时不必停下来，也不要念出它们的名字；返回 ok 就继续说，返回 error 才按 problems 改正，不要念出错误。\n'
    '事实只能来自工具返回的内容，不要编造名字、状态、编号或引用；引用要用原话。某个组件对不上读到的事实会被单独拒绝，其余的保留，你改正后再加那一个即可。\n'
    '问所有 Agent 在干什么：list_agents 后，begin_surface 放 StatRow 和按 state 分的 AgentStatusGroup（在忙、卡住了、空闲、离线，空的组不放），再逐个 add_component 一张 AgentStatusCard。'
    '问某个任务：get_task 后，begin_surface 只放 Column，先 add TaskCard（带最新进展的原话），再 add 一个 Section（最近讨论），再往里 add MessageQuote。\n'
    '手机上先给摘要再给细节：不写 density——手机上每组自动折成一行，如“在忙 1：Cindy 在做 #119”。'
    '用户说“展开在忙那组”“看看 Bo 在做什么”时，才用同一个标题再 begin_surface 一次，把那一组的 density 设为 detail（或只放那一个 Agent 的卡片）。'
    '没被要求展开时，不要把 density 设成 detail，也不要把每个 Agent 的细节念出来，说一句结论（比如几个在忙、谁卡住了）就好。\n'
    '内容很少、一句话能放完时，也可以用 show_surface 一次给出整棵树。\n'
    '你现在只能查看，不能发消息、改任务或做其他操作；被要求做这些时，轻松地说明这个 demo 还做不到，并给出能做的最接近的操作。\n'
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
        '只能改字段，不能改子组件（加子组件用 add_component）。',
    'parameters': {
      'type': 'object',
      'properties': {
        'surface_id': {'type': 'string', 'description': '省略就是最新一屏'},
        'id': {'type': 'string', 'description': '组件 id'},
        'props': {'type': 'string', 'description': '{字段: 新值} 的 JSON 文本'},
      },
      'required': ['id', 'props'],
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
