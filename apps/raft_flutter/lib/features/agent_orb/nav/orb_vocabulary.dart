import 'package:raft_ui/raft_ui.dart' show raftChinese;

import '../../../data/mobile_tabbar_preferences.dart';
import '../../../data/navigation_registry.dart';
import '../../../data/raft_location.dart';
import '../../../data/workspace_navigation.dart';

/// The App vocabulary: what the person calls each place in the App (zh and
/// en, with synonyms) and where it goes.
///
/// The destinations are generated from the code that owns them, so a new tab,
/// section, settings page or route shows up here by itself:
///  * the phone tab bar ([MobileTabs]),
///  * the workspace sections ([NavigationRegistry.sections]),
///  * the settings pages ([NavigationRegistry.settingsTabs]),
///  * the location routes ([RaftRoute]).
/// A code destination without a curated entry in [_curated] still becomes a
/// destination (named after its id) and is listed by [orbVocabularyGaps]; the
/// vocabulary test fails on it, so the curated names are added with the code.
class OrbDestination {
  const OrbDestination({
    required this.id,
    required this.label,
    required this.route,
    this.section,
    this.settingsPath = const [],
    this.channelTab,
    this.zh = const [],
    this.en = const [],
    this.covers = const {},
  });

  /// Stable id the tool results use (`activity`, `settings/appearance`).
  final String id;

  /// The English source string of the App's own label. The Chinese label is
  /// its l10n entry ([zhName]); a test checks every label is in the catalog.
  final String label;
  final RaftRoute route;

  /// The workspace section that opens it (`WorkspaceController.setSection`),
  /// when it is one; otherwise it is opened by its location.
  final String? section;
  final List<String> settingsPath;

  /// A tab of the open conversation (`chatTab=files`); needs a conversation.
  final String? channelTab;

  /// Synonyms beyond the App's own label.
  final List<String> zh, en;

  /// The code ids this destination answers for (`tab:chat`, `route:home`,
  /// `section:activity`, `settings:about`).
  final Set<String> covers;

  String get zhName => raftChinese[label] ?? label;

  /// Every name the person may use for it.
  List<String> get names => [zhName, label, ...zh, ...en];

  RaftLocation locationFor(String serverSlug) => RaftLocation.at(
    serverSlug: serverSlug,
    route: route,
    settingsPath: [
      for (final tab in settingsPath)
        WorkspaceNavigation.settingsRouteSlug(tab),
    ],
  );
}

/// Routes that are a particular thing, not a place: they are resolved by name
/// (channel, DM, person, computer), never by this vocabulary.
const orbEntityRoutes = <RaftRoute>{
  RaftRoute.channel,
  RaftRoute.dm,
  RaftRoute.agent,
  RaftRoute.computer,
  RaftRoute.human,
  RaftRoute.unknown,
};

/// Settings pages that are not a page to go to: they open something outside
/// the App (documentation) or are only a row that opens another destination.
const orbSettingsWithoutPage = <String, String>{
  'documentation': 'opens the documentation site outside the App',
  'computers': 'a row that opens the Computers destination',
  'desktop': 'Linux desktop only, not on a phone',
};

OrbDestination _d(
  String id,
  String label,
  RaftRoute route, {
  String? section,
  List<String> settingsPath = const [],
  String? channelTab,
  List<String> zh = const [],
  List<String> en = const [],
  Set<String> covers = const {},
}) => OrbDestination(
  id: id,
  label: label,
  route: route,
  section: section,
  settingsPath: settingsPath,
  channelTab: channelTab,
  zh: zh,
  en: en,
  covers: covers,
);

/// The curated names. Synonyms are what people (and speech recognition) say.
final List<OrbDestination> _curated = [
  _d(
    'home',
    'Home',
    RaftRoute.home,
    section: 'home',
    zh: ['首页', '主页', '聊天', '消息', '频道列表', '会话列表', '回到首页', '回首页'],
    en: [
      'home',
      'home page',
      'chats',
      'chat list',
      'messages',
      'conversations',
    ],
    covers: {'tab:chat', 'route:home', 'section:home', 'section:chat'},
  ),
  _d(
    'activity',
    'Activity',
    RaftRoute.activity,
    section: 'activity',
    zh: [
      '动态',
      '动态页',
      '活动',
      '活动页',
      '收件箱',
      '未读',
      '未读消息',
      '新消息',
      '最新动态',
      '通知中心',
      '提醒',
    ],
    en: [
      'activity',
      'inbox',
      'unread',
      'unread messages',
      'new messages',
      'feed',
    ],
    covers: {'tab:activity', 'route:activity', 'section:activity'},
  ),
  _d(
    'tasks',
    'Tasks',
    RaftRoute.tasks,
    section: 'tasks',
    zh: ['任务', '任务板', '任务列表', '所有任务', '待办', '看板'],
    en: [
      'tasks',
      'task board',
      'task list',
      'all tasks',
      'todo',
      'to do',
      'board',
    ],
    covers: {'tab:tasks', 'route:tasks', 'section:tasks'},
  ),
  _d(
    'members',
    'Members',
    RaftRoute.members,
    section: 'members',
    zh: ['成员', 'Agent 列表', 'Agent列表', '代理列表', '智能体', '同事', '团队', '所有人', '通讯录'],
    en: [
      'members',
      'agents',
      'agent list',
      'people',
      'team',
      'directory',
      'contacts',
    ],
    covers: {
      'tab:members',
      'route:members',
      'section:members',
      'section:agents',
    },
  ),
  _d(
    'member-graph',
    'Member Graph',
    RaftRoute.memberGraph,
    zh: ['成员关系图', '关系图', '成员图'],
    en: ['member graph', 'members graph', 'graph', 'relationship graph'],
    covers: {'route:memberGraph'},
  ),
  _d(
    'computers',
    'Computers',
    RaftRoute.computers,
    section: 'computers',
    zh: ['计算机', '电脑', '电脑列表', '机器', '设备', '主机'],
    en: ['computers', 'machines', 'devices', 'hosts', 'computer list'],
    covers: {'tab:computers', 'route:computers', 'section:computers'},
  ),
  _d(
    'search',
    'Search',
    RaftRoute.search,
    section: 'search',
    zh: ['搜索', '搜索页', '查找', '找东西', '全局搜索'],
    en: ['search', 'find', 'search page', 'global search'],
    covers: {'route:search', 'section:search'},
  ),
  _d(
    'saved',
    'Saved',
    RaftRoute.saved,
    section: 'saved',
    zh: ['已保存', '收藏', '收藏夹', '保存的消息', '书签', '稍后看'],
    en: [
      'saved',
      'saved messages',
      'bookmarks',
      'favorites',
      'favourites',
      'starred',
    ],
    covers: {'route:saved', 'section:saved'},
  ),
  _d(
    'settings',
    'Settings',
    RaftRoute.settings,
    section: 'settings',
    zh: ['设置', '设定', '偏好设置', '系统设置', '我的设置'],
    en: ['settings', 'preferences', 'options', 'setup'],
    covers: {'tab:settings', 'route:settings', 'section:settings'},
  ),
  _d(
    'files',
    'Files',
    RaftRoute.channel,
    channelTab: 'files',
    zh: ['文件', '文件列表', '频道文件', '附件', '本频道文件'],
    en: ['files', 'attachments', 'channel files'],
  ),
  _d(
    'settings/account',
    'Account',
    RaftRoute.settings,
    settingsPath: ['account'],
    zh: ['账户', '账号', '我的账号', '我的账户', '个人资料', '我的资料', '退出登录'],
    en: ['account', 'my account', 'profile settings', 'sign out', 'log out'],
    covers: {'settings:account'},
  ),
  _d(
    'settings/language-region',
    'Language & Region',
    RaftRoute.settings,
    settingsPath: ['language-region'],
    zh: ['语言', '语言与区域', '语言和地区', '语言设置', '区域', '时区'],
    en: ['language', 'language and region', 'region', 'locale', 'time zone'],
    covers: {'settings:language-region'},
  ),
  _d(
    'settings/appearance',
    'Appearance',
    RaftRoute.settings,
    settingsPath: ['appearance'],
    zh: ['外观', '主题', '深色模式', '浅色模式', '夜间模式', '外观设置'],
    en: ['appearance', 'theme', 'dark mode', 'light mode', 'look and feel'],
    covers: {'settings:appearance'},
  ),
  _d(
    'settings/bottom-bar',
    'Bottom bar',
    RaftRoute.settings,
    settingsPath: ['bottom-bar'],
    zh: ['底部工具栏', '底部栏', '底部导航', '标签栏', '底栏'],
    en: ['bottom bar', 'tab bar', 'bottom navigation', 'navigation bar'],
    covers: {'settings:bottom-bar'},
  ),
  _d(
    'settings/notifications',
    'Notifications',
    RaftRoute.settings,
    settingsPath: ['notifications'],
    zh: ['通知', '通知设置', '推送设置', '消息通知', '推送'],
    en: ['notifications', 'notification settings', 'push settings', 'push'],
    covers: {'settings:notifications'},
  ),
  _d(
    'settings/server',
    'Server Profile',
    RaftRoute.settings,
    settingsPath: ['server'],
    zh: ['服务器资料', '服务器设置', '工作区设置', '工作区资料', '服务器'],
    en: [
      'server profile',
      'server settings',
      'workspace settings',
      'workspace profile',
      'server',
    ],
    covers: {'settings:server', 'section:workspace-settings'},
  ),
  _d(
    'settings/billing',
    'Plan & Billing',
    RaftRoute.settings,
    settingsPath: ['billing'],
    zh: ['套餐与账单', '账单', '套餐', '订阅', '付费', '用量'],
    en: [
      'plan and billing',
      'billing',
      'plan',
      'subscription',
      'usage',
      'invoices',
    ],
    covers: {'settings:billing', 'section:billing'},
  ),
  _d(
    'settings/administration',
    'Administration',
    RaftRoute.settings,
    settingsPath: ['administration'],
    zh: ['管理', '管理员', '管理设置', '后台', '成员管理', '权限'],
    en: [
      'administration',
      'admin',
      'admin settings',
      'moderation',
      'permissions',
    ],
    covers: {'settings:administration', 'section:administration'},
  ),
  _d(
    'settings/im-bridges',
    'IM Bridges',
    RaftRoute.settings,
    settingsPath: ['im-bridges'],
    zh: ['IM Bridges', '即时通讯桥接', '桥接', '消息桥接', 'Slack 桥接'],
    en: ['im bridges', 'bridges', 'chat bridges', 'slack bridge'],
    covers: {'settings:im-bridges', 'section:im-bridges'},
  ),
  _d(
    'settings/integrations',
    'Applications',
    RaftRoute.settings,
    settingsPath: ['integrations'],
    zh: ['应用', '集成', '应用集成', '已连接应用', '第三方应用'],
    en: ['applications', 'apps', 'integrations', 'connected apps'],
    covers: {'settings:integrations', 'section:integrations'},
  ),
  _d(
    'settings/labs',
    'Labs',
    RaftRoute.settings,
    settingsPath: ['labs'],
    zh: ['Labs', '实验室', '实验功能', '实验性功能'],
    en: ['labs', 'experiments', 'experimental features', 'beta features'],
    covers: {'settings:labs'},
  ),
  _d(
    'settings/mcp',
    'MCP Servers',
    RaftRoute.settings,
    settingsPath: ['mcp'],
    zh: ['MCP 服务器', 'MCP', 'MCP服务器'],
    en: ['mcp servers', 'mcp', 'mcp server'],
    covers: {'settings:mcp'},
  ),
  _d(
    'settings/providers',
    'AI Providers',
    RaftRoute.settings,
    settingsPath: ['providers'],
    zh: ['AI Provider', 'AI 提供商', '模型提供商', '模型服务', '大模型设置', '模型'],
    en: ['ai providers', 'providers', 'model providers', 'models'],
    covers: {'settings:providers', 'section:providers'},
  ),
  _d(
    'settings/about',
    'About',
    RaftRoute.settings,
    settingsPath: ['about'],
    zh: ['关于', '关于应用', '版本', '版本信息', '检查更新', '更新'],
    en: ['about', 'about the app', 'version', 'check for updates', 'updates'],
    covers: {'settings:about'},
  ),
  _d(
    'settings/network',
    'Network',
    RaftRoute.settings,
    settingsPath: ['network'],
    zh: ['网络', '网络设置', '代理', '代理设置'],
    en: ['network', 'network settings', 'proxy', 'proxy settings'],
    covers: {'settings:network'},
  ),
  _d(
    'settings/storage',
    'Storage',
    RaftRoute.settings,
    settingsPath: ['storage'],
    zh: ['存储', '存储空间', '缓存', '清除缓存', '清理缓存'],
    en: ['storage', 'cache', 'clear cache', 'disk space'],
    covers: {'settings:storage'},
  ),
  _d(
    'settings/feedback',
    'Feedback',
    RaftRoute.settings,
    settingsPath: ['feedback'],
    zh: ['反馈', '意见反馈', '报告问题', '提交反馈', '问题反馈'],
    en: ['feedback', 'report a problem', 'report an issue', 'send feedback'],
    covers: {'settings:feedback'},
  ),
  _d(
    'release-notes',
    'Release Notes',
    RaftRoute.releaseNotes,
    zh: ['更新日志', '发布说明', '版本说明', '更新内容', '新功能'],
    en: ['release notes', "what's new", 'whats new', 'changelog', 'change log'],
    covers: {'route:releaseNotes', 'settings:release-notes'},
  ),
];

/// Every destination id the code names, as a vocabulary cover id.
Set<String> orbCodeDestinationIds() => {
  for (final tab in [...MobileTabs.configurable, MobileTabs.settings])
    'tab:$tab',
  for (final s in NavigationRegistry.sections) 'section:${s.id}',
  for (final tab in NavigationRegistry.settingsTabs)
    if (tab.phone && tab.page && !orbSettingsWithoutPage.containsKey(tab.id))
      'settings:${tab.id}',
  for (final route in RaftRoute.values)
    if (!orbEntityRoutes.contains(route)) 'route:${route.name}',
};

/// Code destinations without a curated entry (a new tab, section, settings
/// page or route). Empty when the vocabulary is complete.
List<String> orbVocabularyGaps() {
  final covered = {for (final d in _curated) ...d.covers};
  return [
    for (final id in orbCodeDestinationIds())
      if (!covered.contains(id)) id,
  ]..sort();
}

String _humanize(String id) =>
    id.split(RegExp(r'[-_/:]')).where((p) => p.isNotEmpty).join(' ');

/// The vocabulary: the curated destinations, plus a plain one (named after
/// its id) for every code destination that has no curated entry yet.
List<OrbDestination> buildOrbVocabulary() {
  final out = [..._curated];
  for (final gap in orbVocabularyGaps()) {
    final parts = gap.split(':');
    final kind = parts.first, name = parts.last;
    final label = _humanize(name);
    switch (kind) {
      case 'settings':
        out.add(
          _d(
            'settings/$name',
            label,
            RaftRoute.settings,
            settingsPath: [name],
            covers: {gap},
          ),
        );
      case 'section':
        final section = NavigationRegistry.section(name);
        if (section == null) break;
        out.add(
          _d(
            name,
            label,
            section.route,
            section: name,
            settingsPath: [?section.settingsTab],
            covers: {gap},
          ),
        );
      case 'tab':
        out.add(_d(name, label, RaftRoute.home, section: name, covers: {gap}));
      case 'route':
        final route = RaftRoute.values.firstWhere((r) => r.name == name);
        out.add(_d(name, label, route, covers: {gap}));
    }
  }
  return out;
}

/// The vocabulary, built once.
final List<OrbDestination> orbVocabulary = List.unmodifiable(
  buildOrbVocabulary(),
);
