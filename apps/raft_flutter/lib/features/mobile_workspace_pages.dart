import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/raft_location.dart';
import '../data/workspace_navigation.dart';

/// The underlying destination of a cold task/channel-management page.
RaftLocation _mobilePageBaseLocation(RaftLocation location) =>
    location.withQuery({'task': null, 'legacyTask': null, 'channelPage': null});

/// Focus/search edits stay on a page; task and channel-management identities
/// own platform pages while retaining the workspace's existing data owners.
String mobilePageIdentity(RaftLocation location) {
  return [
    location.uri.path,
    location.query('open') ?? '',
    location.query('thread') ?? '',
    location.query('profile') ?? '',
    location.query('task') ?? '',
    location.query('legacyTask') ?? '',
    location.query('channelPage') ?? '',
  ].join('|');
}

/// Back follows visual pages, consuming focus/query entries within that page.
/// The workspace still owns and validates every history step.
RaftLocation backMobilePage(WorkspaceNavigation navigation) {
  final identity = mobilePageIdentity(navigation.location);
  final limit = navigation.entries.length + 1;
  for (var step = 0; step < limit; step++) {
    final before = navigation.location.uri;
    final index = navigation.index;
    final next = navigation.back();
    if (mobilePageIdentity(next) != identity ||
        next.uri == before && navigation.index == index) {
      return next;
    }
  }
  return navigation.location;
}

/// Project the accepted history into a single-column stack. Tab roots start a
/// new visual stack; focus/query edits do not manufacture pages.
List<String> mobilePageEntries(WorkspaceNavigation navigation) {
  final result = <String>[];
  final entries = navigation.entries.take(navigation.index + 1).toList();
  if (entries.isEmpty || entries.last != navigation.location) {
    entries.add(navigation.location);
  }
  for (var index = 0; index < entries.length; index++) {
    final location = entries[index];
    final base = _mobilePageBaseLocation(location);
    if (result.isEmpty && base != location) {
      final root = WorkspaceNavigation(initial: base).mobileRootTab != null;
      result.add('${root ? 'root' : index}::${mobilePageIdentity(base)}');
    }
    final identity = mobilePageIdentity(location);
    final root = WorkspaceNavigation(initial: location).mobileRootTab != null;
    if (root) result.clear();
    if (result.isNotEmpty && result.last.endsWith('::$identity')) continue;
    result.add('${root ? 'root' : index}::$identity');
  }
  // A cold detail still has a semantic back destination.
  if (!result.first.startsWith('root::')) {
    result.insert(0, 'root::${mobilePageIdentity(entries.first.tabHome())}');
  }
  return result.length > 8 ? result.sublist(result.length - 8) : result;
}

/// Platform routes for the existing workspace history. Only the active page
/// owns the live controller tree; historical routes hold their last painted
/// frame so a transition cannot show the newly selected channel on the old page.
/// Frames are presentation-only, never persisted, and scoped to authority.
class MobileWorkspacePages extends StatefulWidget {
  const MobileWorkspacePages({
    super.key,
    required this.navigation,
    required this.onBack,
    required this.child,
    this.enabled = true,
  });
  final WorkspaceNavigation navigation;
  final VoidCallback onBack;
  final Widget child;
  final bool enabled;

  @override
  State<MobileWorkspacePages> createState() => _MobileWorkspacePagesState();
}

class _MobileWorkspacePagesState extends State<MobileWorkspacePages> {
  final navigator = GlobalKey<NavigatorState>();
  final live = GlobalKey();
  // Route-owned buckets disappear on Back and tab switches. Keep only UI
  // positions for this authority-bound workspace, below each platform route.
  final pageStorage = PageStorageBucket();
  final changed = ValueNotifier<int>(0);
  final frames = <String, GlobalKey<_MobilePageFrameState>>{};
  int nextInstance = 0;
  late List<_MobilePageEntry> entries = reconcile(
    mobilePageEntries(widget.navigation),
    const [],
  );
  bool rootChanged = false;
  String get active => entries.last.id;

  // A removed route can still be animating out when its business location is
  // reopened. That new route needs its own frame key; retained routes keep
  // their instances, including the synthetic root on a cold-detail Back.
  List<_MobilePageEntry> reconcile(
    List<String> identities,
    List<_MobilePageEntry> previous,
  ) => [
    for (final identity in identities)
      previous.where((entry) => entry.identity == identity).firstOrNull ??
          _MobilePageEntry(identity, '${nextInstance++}::$identity'),
  ];

  @override
  void didUpdateWidget(MobileWorkspacePages oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = reconcile(mobilePageEntries(widget.navigation), entries);
    if (next.last.id != active) frames[active]?.currentState?.freeze();
    rootChanged =
        entries.first.identity != next.first.identity &&
        !entries.any(
          (entry) => next.any((item) => item.identity == entry.identity),
        );
    entries = next;
    changed.value++;
  }

  @override
  void dispose() {
    changed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return KeyedSubtree(
        key: live,
        child: PageStorage(bucket: pageStorage, child: widget.child),
      );
    }
    // Android broadcasts predictive-back events to every route observer. A
    // nested route is still "current" in its Navigator under a root preview;
    // only the visible parent route may let this stack accept the gesture.
    final parentCurrent = ModalRoute.isCurrentOf(context) ?? true;
    return NavigatorPopHandler<void>(
      onPopWithResult: (_) => navigator.currentState?.maybePop(),
      child: Navigator(
        key: navigator,
        transitionDelegate: _MobileTransitionDelegate(
          skip: rootChanged || MediaQuery.disableAnimationsOf(context),
        ),
        pages: [
          for (final entry in entries)
            MaterialPage<void>(
              key: ValueKey(entry.id),
              canPop: parentCurrent,
              child: _MobilePageFrame(
                key: frames.putIfAbsent(
                  entry.id,
                  () => GlobalKey<_MobilePageFrameState>(),
                ),
                host: this,
                id: entry.id,
              ),
            ),
        ],
        onDidRemovePage: (page) {
          // Programmatic history changes already selected a different page.
          if (page.key == ValueKey(active)) widget.onBack();
        },
      ),
    );
  }
}

class _MobilePageEntry {
  const _MobilePageEntry(this.identity, this.id);
  final String identity, id;
}

class _MobilePageFrame extends StatefulWidget {
  const _MobilePageFrame({super.key, required this.host, required this.id});
  final _MobileWorkspacePagesState host;
  final String id;
  @override
  State<_MobilePageFrame> createState() => _MobilePageFrameState();
}

class _MobilePageFrameState extends State<_MobilePageFrame> {
  final boundary = GlobalKey();
  ui.Image? image;

  void freeze() {
    final render = boundary.currentContext?.findRenderObject();
    if (render is _MobileFrameBoundaryRenderObject) {
      final next = render.captureLastFrame(
        math.min(MediaQuery.devicePixelRatioOf(context), 2),
      );
      if (next == null) return;
      image?.dispose();
      image = next;
    }
  }

  @override
  void dispose() {
    widget.host.frames.remove(widget.id);
    image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.host.changed,
    builder: (context, _) => widget.host.active == widget.id
        ? _MobileFrameBoundary(
            key: boundary,
            child: KeyedSubtree(
              key: widget.host.live,
              child: PageStorage(
                bucket: widget.host.pageStorage,
                child: widget.host.widget.child,
              ),
            ),
          )
        : ExcludeSemantics(
            child: ColoredBox(
              // ds-allow: Historical platform route fallback matches its Scaffold before a painted frame exists.
              color: Theme.of(context).scaffoldBackgroundColor,
              child: image == null
                  ? const SizedBox.expand()
                  : RawImage(image: image, fit: BoxFit.fill),
            ),
          ),
  );
}

class _MobileFrameBoundary extends SingleChildRenderObjectWidget {
  const _MobileFrameBoundary({super.key, required super.child});
  @override
  _MobileFrameBoundaryRenderObject createRenderObject(BuildContext context) =>
      _MobileFrameBoundaryRenderObject();
}

class _MobileFrameBoundaryRenderObject extends RenderRepaintBoundary {
  ui.Image? captureLastFrame(double ratio) {
    if (!hasSize || size.isEmpty || layer is! OffsetLayer) return null;
    final previous = layer! as OffsetLayer;
    if (!previous.supportsRasterization()) return null;
    return previous.toImageSync(Offset.zero & size, pixelRatio: ratio);
  }
}

/// Tab roots and reduced-motion navigation switch immediately. Hierarchical
/// pushes/pops use Flutter's default platform transition delegate.
class _MobileTransitionDelegate extends DefaultTransitionDelegate<void> {
  const _MobileTransitionDelegate({required this.skip});
  final bool skip;
  @override
  Iterable<RouteTransitionRecord> resolve({
    required List<RouteTransitionRecord> newPageRouteHistory,
    required Map<RouteTransitionRecord?, RouteTransitionRecord>
    locationToExitingPageRoute,
    required Map<RouteTransitionRecord?, List<RouteTransitionRecord>>
    pageRouteToPagelessRoutes,
  }) {
    if (!skip) {
      return super.resolve(
        newPageRouteHistory: newPageRouteHistory,
        locationToExitingPageRoute: locationToExitingPageRoute,
        pageRouteToPagelessRoutes: pageRouteToPagelessRoutes,
      );
    }
    for (final entry in newPageRouteHistory) {
      if (entry.isWaitingForEnteringDecision) {
        entry.markForAdd();
      }
    }
    for (final entry in locationToExitingPageRoute.values) {
      if (entry.isWaitingForExitingDecision) entry.markForComplete();
      for (final pageless
          in pageRouteToPagelessRoutes[entry] ?? <RouteTransitionRecord>[]) {
        if (pageless.isWaitingForExitingDecision) pageless.markForComplete();
      }
    }
    return [...newPageRouteHistory, ...locationToExitingPageRoute.values];
  }
}
