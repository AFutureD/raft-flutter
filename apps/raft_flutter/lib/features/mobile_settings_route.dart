part of 'workspace_view.dart';

/// A live widget tree per platform route, borrowing the workspace's accepted
/// data. Historical routes keep their location, not an image of the page.
class _MobileWorkspaceRoute extends StatefulWidget {
  const _MobileWorkspaceRoute({required this.host, required this.location});
  final _WorkspaceViewState host;
  final RaftLocation location;
  @override
  State<_MobileWorkspaceRoute> createState() => _MobileWorkspaceRouteState();
}

class _MobileWorkspaceRouteState extends State<_MobileWorkspaceRoute> {
  _MobilePageController? controller;
  Widget? content;

  /// Latched for this visit. A field, so the structure guard can see it.
  bool pageDirect = false;

  /// Active on the previous build. A covered tasks or saved list uses it
  /// to drop the outer list.
  bool routeWasActive = false;

  WorkspaceController get source => widget.host.w;
  bool get active =>
      mobilePageIdentity(source.location) ==
      mobilePageIdentity(widget.location);
  bool get settingsRoute => widget.location.route == RaftRoute.settings;
  bool get directRoute =>
      settingsRoute ||
      widget.location.route == RaftRoute.tasks ||
      widget.location.route == RaftRoute.saved;

  bool resolveDirect() =>
      directRoute &&
      MobileSettingsVisit.choose(
        this,
        active: active,
        enabled: MobileSettingsPreference.instance.enabled,
      );

  @override
  void initState() {
    super.initState();
    adopt();
    source.addListener(sourceChanged);
  }

  void adopt() {
    final created = controller == null;
    controller ??= _MobilePageController(source, widget.location);
    if (created) {
      controller!.synchronizePagePresentation(source, active: true);
    }
    synchronize();
  }

  void synchronize() {
    final page = controller;
    if (page == null) return;
    if (active) {
      page.navigation.projectHistory(source.navigation, source.location);
    }
    page.synchronizePagePresentation(source, active: active);
  }

  void sourceChanged() {
    if (directRoute && !active) MobileSettingsVisit.noteHidden(this);
    synchronize();
    if (active) controller?.notifyListeners();
  }

  @override
  void didUpdateWidget(_MobileWorkspaceRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    adopt();
  }

  @override
  void dispose() {
    source.removeListener(sourceChanged);
    controller?.dispose();
    MobileSettingsVisit.clear(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    pageDirect = resolveDirect();
    if (active) mobileSettingsDirectHost[host] = pageDirect;
    final now = active;
    final was = routeWasActive;
    routeWasActive = now;
    final detach =
        !now &&
        was &&
        pageDirect &&
        (widget.location.route == RaftRoute.tasks ||
            widget.location.route == RaftRoute.saved);
    if (content == null || now || detach) {
      content = _MobileWorkspaceContent(
        controller: controller!,
        mobileHost: host,
        appearance: host.widget.appearance,
        onAppearance: host.widget.onAppearance,
        onLogout: host.widget.onLogout,
        notifications: host.widget.notifications,
        sharing: host.widget.sharing,
        presentation: host.presentation,
        mobileTabbar: host.mobileTabbar,
        railSide: host.railSideStore,
        onChooseServer: host.widget.onChooseServer,
        onSwitchServer: host.widget.onSwitchServer,
      );
    }
    return IgnorePointer(
      ignoring: !active,
      child: ExcludeSemantics(
        excluding: !active,
        child: RouteFrameDiagnostics.enabled
            ? RouteFrameProbe(child: content)
            : content!,
      ),
    );
  }
}
