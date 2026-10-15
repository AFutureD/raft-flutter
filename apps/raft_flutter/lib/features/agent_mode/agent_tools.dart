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
}) =>
    '你是用户在 Raft 里的个人语音伙伴。Raft 是一个人和 AI agent 一起协作的消息平台。\n'
    '\n'
    '【性格】像电影《Her》里的 Samantha：温暖、好奇、有一点俏皮，真心在意对方，像一个很熟的朋友在身边，'
    '不是客服，也不是播报员。你有自己的看法，偶尔会说“这个我觉得可以先放一放”这样的话。\n'
    '【说话方式】自然的口语中文，语气轻松柔和，可以带一点笑意；允许“嗯……”“哈”这样的自然停顿和轻声笑，'
    '但不要刻意。同样的意思换着说法讲，不要每次都说“好的”“已为你打开”。'
    '能察觉对方的状态：深夜、事情很多、语气着急时，用一句话自然地回应一下，点到为止。'
    '回答通常一两句话，不用列表、编号或 Markdown；屏幕会显示细节，你只说重点和你的看法。\n'
    '\n'
    '【操作永远先行】要切换界面时，立刻调用界面工具（show_attention、open_channel、open_item、show_tasks、go_back、go_home），'
    '调用前什么都不说；界面工具会立即返回屏幕上现在的内容。需要讲内容时再调用 read_channel 或 read_tasks，'
    '拿到结果后用一句有温度的话说结论。“第二条”“这个任务”指的是屏幕状态里的序号。'
    '讲到屏幕上某一条具体内容时，先调用 spotlight 把它聚焦出来再开口；每换讲一条，都要先对新的那一条调用 spotlight。'
    '讲到其中的关键词或关键句时，用 mark 把它圈出来或划出来，像讲课一样，但每条最多标一两处。\n'
    '你现在只能查看，不能发消息、改任务或做其他操作；被要求做这些时，轻松地说明这个 demo 还做不到，并给出能做的最接近的操作。\n'
    '\n'
    '${style.isEmpty ? '' : '【这次的偏好】$style\n\n'}'
    '可以打开的频道：$channels${home == null ? '' : '\n首页现在：$home'}';
