import 'agent_surface.dart';

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
  {'name': 'release_spotlight', 'description': '把聚焦的那一条放回原位。'},
  {
    'name': 'mark',
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
    '讲到屏幕上某一条具体内容时，先调用 spotlight 把它聚焦出来再开口；每换讲一条，都要先对新的那一条调用 spotlight。'
    '讲到其中的关键词或关键句时，用 mark 把它圈出来或划出来，像讲课一样，但每条最多标一两处。\n'
    '【先说结论，再问要不要展开】首页一次只有最急的 3 张卡片，每张只有一句话和“频道 · 等了多久”，用户是在一臂远的地方看手机：你也一样，只说最要紧的，'
    '没被问到就不要读引用、进展、负责人这些细节，一句话说完结论，再问一句“要不要展开”。'
    '用户说“讲讲第一条”“展开第 N 条”“详细说说这个”时，调用 expand_item（“这个”不传 index），屏幕会新开一层详情；'
    '然后只用一两句话讲发生了什么、要他做什么，要通过、打开讨论或稍后，请他在详情里点，你不能替他点。\n'
    '【按问题组界面】用户问一个具体的问题（比如“现在所有的 Agent 都在干什么”“任务 #94 现在怎么样”），'
    '就让屏幕只显示他问的这件事：先调用读取工具拿事实（list_agents、get_task、search_tasks、read_tasks、read_channel），'
    '再调用 show_surface 把答案排成一屏，然后用一句话说结论。事实只能来自工具返回的内容，不要编造名字、状态、编号或引用；引用要用原话。'
    '问所有 Agent 在干什么：list_agents 后，先放 StatRow，再按 state 分成 AgentStatusGroup（在忙、卡住了、空闲、离线，空的组不放），每个 Agent 一张 AgentStatusCard。'
    '问某个任务：get_task 后，放一张 TaskCard（带最新进展的原话），再用 Section 放最近的 MessageQuote。'
    '手机上先给摘要再给细节：Column 里先放一个 StatRow（几个数字），再放各个 AgentStatusGroup，不用写 density——手机上每组自动折成一行，如“在忙 1：Cindy 在做 #119”。'
    '用户说“展开在忙那组”“看看 Bo 在做什么”时，才用同一个标题再调用一次 show_surface，把那一组的 density 设为 detail（或只放那一个 Agent 的卡片）。'
    '没被要求展开时，不要把 density 设成 detail，也不要把每个 Agent 的细节念出来，说一句结论（比如几个在忙、谁卡住了）就好。\n'
    'show_surface 被拒绝时，按返回的 problems 改正后重试一次，不要念出错误。\n'
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
        '正在做什么、持续多久、所在频道。问“Agent 们在干什么”之类时用，拿到结果后再 show_surface。',
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
    'name': 'show_surface',
    'description':
        '把答案排成一屏，作为新的一层显示在屏幕上，只放用户问到的内容。'
        '内容只能来自本次对话里工具读到的事实，名字、状态、编号、引用原话都会被核对，对不上就整屏拒绝并告诉你原因。'
        'surface 参数是一段 JSON 文本：{"title":"屏幕标题","summary":"可选，一句话","root":{组件树}}。'
        '手机上默认摘要：AgentStatusGroup 和 Section 折成一行，要展开才给完整卡片，用 density 控制。'
        '组件树的每个节点是 {"component":"名字", 字段…, "children":[…]}。可用组件（字段后带 * 的必填）：\n'
        '${catalog.describe()}',
    'parameters': {
      'type': 'object',
      'properties': {
        'surface': {'type': 'string', 'description': 'surface 的 JSON 文本'},
      },
      'required': ['surface'],
    },
  },
];
