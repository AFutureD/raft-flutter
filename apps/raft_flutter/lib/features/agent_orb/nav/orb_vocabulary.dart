import 'package:raft_ui/raft_ui.dart' show raftChinese;

import '../../../data/mobile_tabbar_preferences.dart';
import '../../../data/navigation_registry.dart';
import '../../../data/raft_location.dart';
import '../../../data/workspace_navigation.dart';

/// The App's destinations: each place the model may go to by id, with its
/// display names (zh from the l10n catalog, en the App's own label), a
/// one-line description of what is there, and where it goes. There are no
/// synonym lists: the model is told what exists and chooses.
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
    required this.about,
    this.section,
    this.settingsPath = const [],
    this.channelTab,
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

  /// One line on what is there (Chinese), shown to the model.
  final String about;

  /// The code ids this destination answers for (`tab:chat`, `route:home`,
  /// `section:activity`, `settings:about`).
  final Set<String> covers;

  String get zhName => raftChinese[label] ?? label;

  /// The display names: Chinese, then English.
  List<String> get names => [zhName, label];

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
  RaftRoute route,
  String about, {
  String? section,
  List<String> settingsPath = const [],
  String? channelTab,
  Set<String> covers = const {},
}) => OrbDestination(
  id: id,
  label: label,
  route: route,
  about: about,
  section: section,
  settingsPath: settingsPath,
  channelTab: channelTab,
  covers: covers,
);

/// The curated destinations: what is there, in one line. The model picks one
/// by id from the `navigate` declaration, so the line is what it reasons on.
final List<OrbDestination> _curated = [
  _d(
    'home',
    'Home',
    RaftRoute.home,
    '频道和私信列表，按最近活动排序',
    section: 'home',
    covers: {'tab:chat', 'route:home', 'section:home', 'section:chat'},
  ),
  _d(
    'activity',
    'Activity',
    RaftRoute.activity,
    '最新消息：点名你的、回复你的、你关注的讨论、私信',
    section: 'activity',
    covers: {'tab:activity', 'route:activity', 'section:activity'},
  ),
  _d(
    'tasks',
    'Tasks',
    RaftRoute.tasks,
    '所有频道的任务板，按状态分组',
    section: 'tasks',
    covers: {'tab:tasks', 'route:tasks', 'section:tasks'},
  ),
  _d(
    'members',
    'Members',
    RaftRoute.members,
    '工作区的成员和 Agent 列表',
    section: 'members',
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
    '成员之间的关系图',
    covers: {'route:memberGraph'},
  ),
  _d(
    'computers',
    'Computers',
    RaftRoute.computers,
    '接入工作区、运行 Agent 的电脑',
    section: 'computers',
    covers: {'tab:computers', 'route:computers', 'section:computers'},
  ),
  _d(
    'search',
    'Search',
    RaftRoute.search,
    '全局搜索消息、频道和成员',
    section: 'search',
    covers: {'route:search', 'section:search'},
  ),
  _d(
    'saved',
    'Saved',
    RaftRoute.saved,
    '收藏、已保存的消息',
    section: 'saved',
    covers: {'route:saved', 'section:saved'},
  ),
  _d(
    'settings',
    'Settings',
    RaftRoute.settings,
    '设置入口，列出下面所有设置页',
    section: 'settings',
    covers: {'tab:settings', 'route:settings', 'section:settings'},
  ),
  _d(
    'files',
    'Files',
    RaftRoute.channel,
    '当前打开的频道或私信里的文件（要先在一个对话里）',
    channelTab: 'files',
  ),
  _d(
    'settings/account',
    'Account',
    RaftRoute.settings,
    '我的账户、个人资料、退出登录',
    settingsPath: ['account'],
    covers: {'settings:account'},
  ),
  _d(
    'settings/language-region',
    'Language & Region',
    RaftRoute.settings,
    'App 语言、区域、时区',
    settingsPath: ['language-region'],
    covers: {'settings:language-region'},
  ),
  _d(
    'settings/appearance',
    'Appearance',
    RaftRoute.settings,
    '主题、深色或浅色模式、外观',
    settingsPath: ['appearance'],
    covers: {'settings:appearance'},
  ),
  _d(
    'settings/bottom-bar',
    'Bottom bar',
    RaftRoute.settings,
    '自定义底部标签栏放哪些入口',
    settingsPath: ['bottom-bar'],
    covers: {'settings:bottom-bar'},
  ),
  _d(
    'settings/notifications',
    'Notifications',
    RaftRoute.settings,
    '推送通知的开关和设置',
    settingsPath: ['notifications'],
    covers: {'settings:notifications'},
  ),
  _d(
    'settings/server',
    'Server Profile',
    RaftRoute.settings,
    '工作区（服务器）的名称、头像和资料',
    settingsPath: ['server'],
    covers: {'settings:server', 'section:workspace-settings'},
  ),
  _d(
    'settings/billing',
    'Plan & Billing',
    RaftRoute.settings,
    '套餐、账单、订阅、用量',
    settingsPath: ['billing'],
    covers: {'settings:billing', 'section:billing'},
  ),
  _d(
    'settings/administration',
    'Administration',
    RaftRoute.settings,
    '管理员设置：成员管理和权限',
    settingsPath: ['administration'],
    covers: {'settings:administration', 'section:administration'},
  ),
  _d(
    'settings/im-bridges',
    'IM Bridges',
    RaftRoute.settings,
    '和 Slack 等即时通讯工具的桥接',
    settingsPath: ['im-bridges'],
    covers: {'settings:im-bridges', 'section:im-bridges'},
  ),
  _d(
    'settings/integrations',
    'Applications',
    RaftRoute.settings,
    '已连接的第三方应用和集成',
    settingsPath: ['integrations'],
    covers: {'settings:integrations', 'section:integrations'},
  ),
  _d(
    'settings/labs',
    'Labs',
    RaftRoute.settings,
    '实验性功能的开关',
    settingsPath: ['labs'],
    covers: {'settings:labs'},
  ),
  _d(
    'settings/mcp',
    'MCP Servers',
    RaftRoute.settings,
    'MCP 服务器的配置',
    settingsPath: ['mcp'],
    covers: {'settings:mcp'},
  ),
  _d(
    'settings/providers',
    'AI Providers',
    RaftRoute.settings,
    'AI 模型提供商和密钥',
    settingsPath: ['providers'],
    covers: {'settings:providers', 'section:providers'},
  ),
  _d(
    'settings/about',
    'About',
    RaftRoute.settings,
    '版本信息、检查更新',
    settingsPath: ['about'],
    covers: {'settings:about'},
  ),
  _d(
    'settings/network',
    'Network',
    RaftRoute.settings,
    '网络和代理设置',
    settingsPath: ['network'],
    covers: {'settings:network'},
  ),
  _d(
    'settings/storage',
    'Storage',
    RaftRoute.settings,
    '本机存储空间、清除缓存',
    settingsPath: ['storage'],
    covers: {'settings:storage'},
  ),
  _d(
    'settings/feedback',
    'Feedback',
    RaftRoute.settings,
    '报告问题、提交反馈',
    settingsPath: ['feedback'],
    covers: {'settings:feedback'},
  ),
  _d(
    'release-notes',
    'Release Notes',
    RaftRoute.releaseNotes,
    '更新日志：新版本有什么新功能',
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
            '',
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
            '',
            section: name,
            settingsPath: [?section.settingsTab],
            covers: {gap},
          ),
        );
      case 'tab':
        out.add(
          _d(name, label, RaftRoute.home, '', section: name, covers: {gap}),
        );
      case 'route':
        final route = RaftRoute.values.firstWhere((r) => r.name == name);
        out.add(_d(name, label, route, '', covers: {gap}));
    }
  }
  return out;
}

/// The vocabulary, built once.
final List<OrbDestination> orbVocabulary = List.unmodifiable(
  buildOrbVocabulary(),
);
