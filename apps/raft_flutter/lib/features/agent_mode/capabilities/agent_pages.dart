import '../../../data/navigation_registry.dart';
import '../../../data/raft_location.dart';
import '../../../data/workspace_controller.dart';
import '../../../data/workspace_navigation.dart';

/// Taking the person to the page that does what must not be done by voice.
///
/// A capability names its page as a workspace route without the server
/// (`/settings/billing`, `/computer/<id>`); [resolveAgentPage] turns it into
/// the app's own [RaftLocation] for the server in view, refusing a route the
/// app has no page for. [openAgentPage] then navigates the workspace there,
/// the way the settings rows and the sidebar do.

/// Where a route went.
class AgentPageResult {
  const AgentPageResult.opened(this.location) : opened = true, problem = null;
  const AgentPageResult.refused(this.problem) : opened = false, location = null;

  final bool opened;
  final RaftLocation? location;

  /// Why the page was not opened, for the person.
  final String? problem;
}

/// The location of [route] on the server [slug], or null when it names no
/// page the app has (an unknown settings tab, a malformed path).
RaftLocation? resolveAgentPageRoute(String slug, String route) {
  if (!route.startsWith('/') || slug.isEmpty) return null;
  final RaftLocation location;
  try {
    location = RaftLocation.parse('/s/$slug$route');
  } on Object {
    return null;
  }
  if (location.route == RaftRoute.unknown) return null;
  if (location.route == RaftRoute.settings &&
      location.settingsPath.isNotEmpty &&
      !NavigationRegistry.knowsSettingsTab(
        WorkspaceNavigation.settingsTab(location.settingsPath.first),
      )) {
    return null;
  }
  return location;
}

/// The section name `canVisitSection` asks about for [location], when the
/// page is gated by a permission.
String? _gatedSection(RaftLocation location) {
  switch (location.route) {
    case RaftRoute.computers || RaftRoute.computer:
      return 'computers';
    case RaftRoute.members || RaftRoute.memberGraph:
      return 'members';
    case RaftRoute.settings:
      if (location.settingsPath.isEmpty) return null;
      return switch (WorkspaceNavigation.settingsTab(
        location.settingsPath.first,
      )) {
        'server' => 'workspace-settings',
        'integrations' => 'integrations',
        'im-bridges' => 'im-bridges',
        'administration' => 'administration',
        'billing' => 'billing',
        'providers' => 'providers',
        _ => null,
      };
    default:
      return null;
  }
}

/// The slug of the server in view, as the app's own location carries it.
String agentServerSlug(WorkspaceController w) => w.location.serverSlug;

/// Opens [route] in the app, or says why not. Navigates the workspace (the
/// page the person lands on is the app's own); it changes nothing else.
AgentPageResult openAgentPage(WorkspaceController w, String route) {
  final location = resolveAgentPageRoute(agentServerSlug(w), route);
  if (location == null) {
    return AgentPageResult.refused('App 里没有这个页面（$route）');
  }
  final gate = _gatedSection(location);
  if (gate != null && !w.canVisitSection(gate)) {
    return const AgentPageResult.refused('你的角色看不到这个页面，需要服务器管理员来做');
  }
  w.navigation.navigate(location);
  w.notifyListeners();
  return AgentPageResult.opened(location);
}
