import '../../../data/workspace_controller.dart';
import 'agent_capabilities.dart' show agentByRef;
import 'agent_capability.dart';
import 'capability_support.dart';
import 'fleet_capabilities.dart' show computerByRef;
import 'message_capabilities.dart' show senderByRef;

/// Everything the app does that must not be done by voice, or is too rare to
/// be worth a spoken flow: each is registered as [AgentCapabilityRisk.neverByVoice]
/// with the page that does it. `act` on one navigates the app to that page
/// (see `agent_pages.dart`) and the agent says so; nothing is previewed or
/// run. The model finds them like any capability, so "删除这个频道" gets "带
/// 你去频道设置页" instead of "做不到".
///
/// Routes are workspace routes without the server (`/s/<slug>` is put in
/// front); a test checks that every one names a page the app has.

final _channelArg = strArg('哪个频道（id 或名字）；不说就带到首页', max: 80);
final _agentArg = strArg('哪个 Agent（id 或名字）；不说就带到成员页', max: 80);
final _computerArg = strArg('哪台电脑（id 或名字）；不说就带到电脑列表', max: 80);
final _memberArg = strArg('哪位成员（名字）；不说就带到成员页', max: 80);

Future<String> _channelPage(
  WorkspaceController w,
  Map<String, Object?> args, {
  String page = 'settings',
}) async {
  final ref = text(args['channel']);
  if (ref == null) return '/';
  final c = channelByRef(w, ref);
  final id = Uri.encodeComponent(c.id);
  return c.type == 'dm' ? '/dm/$id' : '/channel/$id?channelPage=$page:$id';
}

Future<String> _agentPage(
  WorkspaceController w,
  Map<String, Object?> args,
) async {
  final ref = text(args['agent']);
  if (ref == null) return '/members';
  final a = await agentByRef(w, ref);
  return '/agent/${Uri.encodeComponent('${a['id']}')}';
}

Future<String> _computerPage(
  WorkspaceController w,
  Map<String, Object?> args,
) async {
  final ref = text(args['computer']);
  if (ref == null) return '/computers';
  final c = await computerByRef(w, ref);
  return '/computer/${Uri.encodeComponent('${c['id']}')}';
}

Future<String> _memberPage(
  WorkspaceController w,
  Map<String, Object?> args,
) async {
  final ref = text(args['member']);
  if (ref == null) return '/members';
  final s = await senderByRef(w, ref, type: 'user');
  return '/human/${Uri.encodeComponent(s.id)}';
}

AgentCapability _page({
  required String id,
  required String title,
  required List<String> keywords,
  required String route,
  required String parity,
  Map<String, Object?> params = const {},
  AgentCapabilityRoute? routeFor,
}) => AgentCapability(
  id: id,
  title: title,
  kind: AgentCapabilityKind.action,
  risk: AgentCapabilityRisk.neverByVoice,
  parity: parity,
  keywords: keywords,
  paramsSchema: objectSchema(params),
  resultSummary: 'status=open_page，openPage（已打开的页面）；用户在页面里自己做',
  openRoute: route,
  openRouteFor: routeFor,
  // Never reached: `act` takes the person to the page instead of running.
  run: (w, args, env) async =>
      throw const AgentCapabilityError('这类操作不能用语音做：只能带用户去对应的页面'),
);

Map<String, Object?> _on(String key, Map<String, Object?> spec) => {key: spec};

final openPageCapabilities = <AgentCapability>[
  // ---- channels --------------------------------------------------------
  _page(
    id: 'channels.archive',
    title: '归档或取消归档频道（不能语音做：带用户去频道设置页，他自己操作）',
    keywords: const ['归档频道', '取消归档', '把频道归档', '频道归档', 'archive channel'],
    route: '/',
    parity: 'POST /channels/:id/archive',
    params: _on('channel', _channelArg),
    routeFor: _channelPage,
  ),
  _page(
    id: 'channels.delete',
    title: '永久删除频道（不能语音做：带用户去频道设置页，他自己操作）',
    keywords: const ['删除频道', '删掉频道', '把频道删了', '永久删除频道', 'delete channel'],
    route: '/',
    parity: 'DELETE /channels/:id',
    params: _on('channel', _channelArg),
    routeFor: _channelPage,
  ),
  _page(
    id: 'channels.leave',
    title: '离开一个频道（不能语音做：带用户去频道设置页，他自己操作）',
    keywords: const ['离开频道', '退出频道', '退群', '不想在这个频道了', 'leave channel'],
    route: '/',
    parity: 'POST /channels/:id/leave',
    params: _on('channel', _channelArg),
    routeFor: _channelPage,
  ),
  _page(
    id: 'channels.edit',
    title: '改频道名字或简介（带用户去频道设置页，他自己改）',
    keywords: const ['改频道名', '频道改名', '改频道简介', '频道描述', '重命名频道', '频道设置'],
    route: '/',
    parity: 'PATCH /channels/:id',
    params: _on('channel', _channelArg),
    routeFor: _channelPage,
  ),
  _page(
    id: 'channels.remove_member',
    title: '把人移出频道，或设置 / 取消频道管理员（不能语音做：带用户去频道成员页）',
    keywords: const [
      '移出频道',
      '踢出频道',
      '把他移出去',
      '频道管理员',
      '设为频道管理员',
      '移除频道成员',
      '频道成员管理',
    ],
    route: '/',
    parity: 'DELETE /channels/:id/members/user/:id',
    params: _on('channel', _channelArg),
    routeFor: (w, a) => _channelPage(w, a, page: 'members'),
  ),
  // ---- server and members ---------------------------------------------
  _page(
    id: 'server.leave',
    title: '离开服务器（不能语音做：带用户去服务器设置页的“危险区”）',
    keywords: const ['离开服务器', '退出服务器', '不在这个服务器了', 'leave server'],
    route: '/settings/server',
    parity: 'POST /servers/:id/leave',
  ),
  _page(
    id: 'server.delete',
    title: '删除整个服务器（不能语音做：带用户去服务器设置页的“危险区”，要输入服务器标识确认）',
    keywords: const ['删除服务器', '删掉服务器', '解散服务器', 'delete server'],
    route: '/settings/server',
    parity: 'DELETE /servers/:id',
  ),
  _page(
    id: 'server.profile',
    title: '改服务器资料：名字、头像、公开可见性、入服协议、翻译和数据分析开关、隐藏 #all（带用户去服务器设置页）',
    keywords: const [
      '服务器设置',
      '改服务器名字',
      '服务器头像',
      '服务器资料',
      '服务器公开',
      '公开可见性',
      '入服协议',
      '隐藏all频道',
      '翻译总开关',
      '访客开关',
    ],
    route: '/settings/server',
    parity: 'PATCH /servers/:id',
  ),
  _page(
    id: 'server.invite',
    title: '邀请人加入服务器：发邮件邀请或生成邀请链接，选角色，撤销邀请（带用户去成员页）',
    keywords: const [
      '邀请成员',
      '邀请加入服务器',
      '发邀请',
      '邀请链接',
      '拉人进服务器',
      '撤销邀请',
      'invite',
    ],
    route: '/members',
    parity: 'POST /servers/:id/invites',
  ),
  _page(
    id: 'members.change_role',
    title:
        '改成员在服务器里的角色（owner / admin / member / guest），或把人移出服务器（不能语音做：带用户去成员页）',
    keywords: const [
      '设为管理员',
      '改角色',
      '成员角色',
      '升为管理员',
      '降为普通成员',
      '移出服务器',
      '踢出服务器',
      '移除成员',
      '管理员权限',
    ],
    route: '/members',
    parity: 'PATCH /servers/:id/members/:id',
    params: _on('member', _memberArg),
    routeFor: _memberPage,
  ),
  _page(
    id: 'billing.manage',
    title: '套餐与计费：看账单、改座位、升级或取消订阅、账单门户（不能语音做：带用户去计费页）',
    keywords: const [
      '套餐',
      '计费',
      '账单',
      '付款',
      '订阅',
      '座位',
      '升级套餐',
      '取消订阅',
      '续费',
      'billing',
      '这个月花了多少',
    ],
    route: '/settings/billing',
    parity: 'POST /billing/checkout',
  ),
  // ---- settings -----------------------------------------------------------
  _page(
    id: 'settings.appearance',
    title: '外观设置：浅色 / 深色、主题、字号、显示 Agent 模型、导航栏位置（带用户去外观设置页）',
    keywords: const [
      '深色模式',
      '浅色模式',
      '切到深色',
      '字大一点',
      '字号',
      '主题',
      '外观',
      '夜间模式',
      '调字体',
    ],
    route: '/settings/appearance',
    parity: 'ui:tabs.appearance',
  ),
  _page(
    id: 'settings.language',
    title: '语言与区域：界面语言、时区、12 / 24 小时（带用户去语言设置页）',
    keywords: const ['切换语言', '改成英文', '改成中文', '界面语言', '时区', '24小时制', '语言设置'],
    route: '/settings/language-region',
    parity: 'ui:tabs.language-region',
  ),
  _page(
    id: 'settings.notifications',
    title: '通知设置：推送开关、本服务器静音、桌面通知（带用户去通知设置页）',
    keywords: const [
      '通知设置',
      '关掉推送',
      '别推送',
      '免打扰',
      '静音服务器',
      '推送开关',
      '桌面通知',
      '明天早上别推送',
    ],
    route: '/settings/notifications',
    parity: 'PATCH /servers/:id/notification-settings',
  ),
  _page(
    id: 'settings.account',
    title: '账号：改名字、头像、密码，社交账号连接，退出登录（带用户去账号设置页）',
    keywords: const ['账号设置', '改密码', '改昵称', '改头像', '退出登录', '登出', '绑定账号'],
    route: '/settings/account',
    parity: 'PATCH /auth/me',
  ),
  _page(
    id: 'settings.labs',
    title: 'Labs 实验功能的开关（带用户去 Labs 页）',
    keywords: const ['实验功能', 'labs', '内测功能', '打开实验功能'],
    route: '/settings/labs',
    parity: 'PUT /servers/:id/labs/:id',
  ),
  _page(
    id: 'providers.manage',
    title: 'AI 提供商：添加、编辑、验证 Key、删除（不能语音做：带用户去 AI 提供商页）',
    keywords: const [
      'AI提供商',
      '模型提供商',
      '提供商',
      'API Key',
      'key还有效吗',
      '添加模型',
      '验证key',
      'provider',
    ],
    route: '/settings/providers',
    parity: 'POST /provider-connections',
  ),
  _page(
    id: 'apps.marketplace',
    title: '应用市场与我的应用：安装、卸载、注册应用、重置密钥、Webhook（不能语音做：带用户去应用页）',
    keywords: const [
      '装应用',
      '安装应用',
      '卸载应用',
      '应用市场',
      '集成',
      '注册应用',
      '应用密钥',
      'webhook',
      'marketplace',
    ],
    route: '/settings/applications',
    parity: 'POST /integrations/marketplace/:id/install',
  ),
  _page(
    id: 'mcp.manage',
    title: 'MCP 服务器：添加、修改、删除、授权、测试（不能语音做：带用户去 MCP 页）',
    keywords: const ['MCP', 'mcp服务器', '添加mcp', '工具服务器', '测试mcp'],
    route: '/settings/mcp-servers',
    parity: 'POST /mcp/servers',
  ),
  _page(
    id: 'slack.bridge',
    title: 'Slack 等 IM 桥：授权、预检、频道配对、启用、断开（不能语音做：带用户去 IM 桥页）',
    keywords: const [
      'slack',
      'Slack桥',
      'IM桥',
      '连接slack',
      '断开slack',
      '频道配对',
      '聊天桥',
    ],
    route: '/settings/im-bridges',
    parity: 'POST /slack-bridge/provisioning/connect',
  ),
  // ---- computers --------------------------------------------------------
  _page(
    id: 'computers.delete',
    title: '删除一台电脑（不能语音做：带用户去电脑详情页）',
    keywords: const ['删除电脑', '删掉电脑', '移除电脑', '断开电脑'],
    route: '/computers',
    parity: 'DELETE /servers/:id/machines/:id',
    params: _on('computer', _computerArg),
    routeFor: _computerPage,
  ),
  _page(
    id: 'computers.upgrade',
    title: '升级或重启一台电脑上的 Computer 程序（不能语音做：带用户去电脑详情页）',
    keywords: const [
      '升级电脑',
      '电脑升级',
      '重启电脑',
      '重启computer',
      '更新computer',
      '升级K8',
      'upgrade computer',
    ],
    route: '/computers',
    parity: 'POST /servers/:id/machines/:id/computer/upgrade',
    params: _on('computer', _computerArg),
    routeFor: _computerPage,
  ),
  _page(
    id: 'computers.rotate_key',
    title: '轮换一台电脑的 API Key（旧 Key 立刻失效；不能语音做：带用户去电脑详情页）',
    keywords: const [
      '轮换key',
      '换key',
      '电脑密钥',
      '重置电脑key',
      '换电脑api key',
      'rotate key',
    ],
    route: '/computers',
    parity: 'POST /servers/:id/machines/:id/rotate-key',
    params: _on('computer', _computerArg),
    routeFor: _computerPage,
  ),
  _page(
    id: 'computers.cleanup',
    title: '清理一台电脑上没用的 Agent 工作区目录（会删文件；不能语音做：带用户去电脑详情页）',
    keywords: const ['清理工作区', '清理电脑', '清理没用的工作区', '扫描工作区', '删除工作区', '清理磁盘'],
    route: '/computers',
    parity: 'DELETE /servers/:id/machines/:id/workspaces/:id',
    params: _on('computer', _computerArg),
    routeFor: _computerPage,
  ),
  _page(
    id: 'computers.add',
    title: '添加一台新电脑（要在那台机器上运行安装命令；带用户去电脑列表页）',
    keywords: const ['添加电脑', '加一台电脑', '新电脑', '接入电脑', '安装命令'],
    route: '/computers',
    parity: 'POST /servers/:id/machines',
  ),
  // ---- agents -----------------------------------------------------------
  _page(
    id: 'agents.create',
    title: '新建一个 Agent（选电脑、运行时、模型；带用户去成员页的创建入口）',
    keywords: const [
      '新建agent',
      '创建agent',
      '建一个agent',
      '添加agent',
      '加个agent',
      '新agent',
    ],
    route: '/members',
    parity: 'POST /agents',
  ),
  _page(
    id: 'agents.delete',
    title: '删除或归档一个 Agent（不能语音做：带用户去 Agent 详情页）',
    keywords: const ['删除agent', '删掉agent', '归档agent', '移除agent', '不要这个agent了'],
    route: '/members',
    parity: 'DELETE /agents/:id',
    params: _on('agent', _agentArg),
    routeFor: _agentPage,
  ),
  _page(
    id: 'agents.migrate',
    title: '把 Agent 迁到另一台电脑（不能语音做：带用户去 Agent 详情页）',
    keywords: const ['迁移agent', 'agent迁到', '换一台电脑', '迁到另一台', '迁移到别的电脑'],
    route: '/members',
    parity: 'POST /agents/:id/migrate',
    params: _on('agent', _agentArg),
    routeFor: _agentPage,
  ),
  _page(
    id: 'agents.settings',
    title: '改 Agent 的模型、推理强度、模式、名字、头像、简介，或完全重置它的工作区（带用户去 Agent 详情页）',
    keywords: const [
      '改模型',
      '换模型',
      '推理强度',
      'agent设置',
      '改agent名字',
      'agent头像',
      '运行时设置',
      '完全重置',
      '重置工作区',
      '外部agent令牌',
    ],
    route: '/members',
    parity: 'PATCH /agents/:id',
    params: _on('agent', _agentArg),
    routeFor: _agentPage,
  ),
];
