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
      final root = navigation.mobileRootTabOf(base) != null;
      result.add('${root ? 'root' : index}::${mobilePageIdentity(base)}');
    }
    final identity = mobilePageIdentity(location);
    final root = navigation.mobileRootTabOf(location) != null;
    if (root) result.clear();
    if (result.isNotEmpty && result.last.endsWith('::$identity')) continue;
    result.add('${root ? 'root' : index}::$identity');
  }
  // A cold detail still has a semantic back destination.
  if (!result.first.startsWith('root::')) {
    result.insert(
      0,
      'root::${mobilePageIdentity(navigation.mobileTabHome(entries.first))}',
    );
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
    var next = reconcile(mobilePageEntries(widget.navigation), entries);
    rootChanged =
        entries.first.identity != next.first.identity &&
        !entries.any(
          (entry) => next.any((item) => item.identity == entry.identity),
        );
    // A tab switch replaces the whole stack without animation. Keep the page
    // that already hosts the live workspace instead of minting a new one:
    // moving the live subtree to another page deactivates and reactivates
    // every element in it, rebuilding the entire workspace for nothing.
    if (rootChanged && next.length == 1) {
      next = [_MobilePageEntry(next.first.identity, active)];
    }
    if (next.last.id != active) frames[active]?.currentState?.freeze();
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

/// While a page route animates, the live workspace page is rendered from a
/// snapshot instead of being re-rasterized into the fade's offscreen layer on
/// every frame, and its semantics are not recomputed per frame. Both are
/// restored when the route settles. `--dart-define=RAFT_NAV_FADE_SNAPSHOTS=false`
/// and `RAFT_NAV_DEFER_SEMANTICS=false` restore the previous behavior (used to
/// measure each change separately with tool/performance/android_transitions.py).
const _fadeSnapshots = bool.fromEnvironment(
  'RAFT_NAV_FADE_SNAPSHOTS',
  defaultValue: true,
);
const _deferSemantics = bool.fromEnvironment(
  'RAFT_NAV_DEFER_SEMANTICS',
  defaultValue: true,
);

class _MobilePageFrameState extends State<_MobilePageFrame> {
  final boundary = GlobalKey();
  ui.Image? image;

  /// Snapshot standing in for the live page while its route animates.
  ui.Image? entering;
  ModalRoute<dynamic>? route;
  bool animating = false;
  bool captureScheduled = false;

  /// The page changed during this animation: it stays live until it settles.
  bool changedWhileAnimating = false;
  int captureAttempts = 0;

  bool get routeAnimating {
    final r = route;
    if (r == null) return false;
    return (r.animation?.status.isAnimating ?? false) ||
        (r.secondaryAnimation?.status.isAnimating ?? false);
  }

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context);
    if (!identical(next, route)) {
      _unlisten();
      route = next;
      route?.animation?.addStatusListener(_statusChanged);
      route?.secondaryAnimation?.addStatusListener(_statusChanged);
    }
    animating = routeAnimating;
  }

  void _unlisten() {
    route?.animation?.removeStatusListener(_statusChanged);
    route?.secondaryAnimation?.removeStatusListener(_statusChanged);
  }

  void _statusChanged(AnimationStatus _) {
    final now = routeAnimating;
    if (!mounted || now == animating) return;
    setState(() {
      animating = now;
      if (!now) {
        changedWhileAnimating = false;
        _releaseEntering();
      }
    });
  }

  void _releaseEntering() {
    final render = boundary.currentContext?.findRenderObject();
    if (render is _MobileFrameBoundaryRenderObject) {
      render.onContentChanged = null;
    }
    final old = entering;
    entering = null;
    captureAttempts = 0;
    if (old != null) {
      // The frame that stops showing it may still reference it.
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// After the first painted frame of the animation, replace the live page by
  /// its picture. The live subtree stays mounted, laid out and hit-testable
  /// (fully transparent), so taps still reach it during the transition.
  void _scheduleCapture() {
    // Only a page that is itself animating in (a push) is replaced by its
    // picture. A page revealed by a pop stays live: it is the one the user is
    // about to use and it moves less.
    if (!_fadeSnapshots ||
        !(route?.animation?.status.isAnimating ?? false) ||
        captureScheduled ||
        entering != null ||
        changedWhileAnimating ||
        captureAttempts >= 8) {
      return;
    }
    captureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      captureScheduled = false;
      if (!mounted || !animating || entering != null) return;
      if (widget.host.active != widget.id) return;
      captureAttempts++;
      final render = boundary.currentContext?.findRenderObject();
      final next = render is _MobileFrameBoundaryRenderObject
          ? render.captureLastFrame(
              math.min(MediaQuery.devicePixelRatioOf(context), 3),
            )
          : null;
      if (next == null) {
        // Nothing painted yet (the fade starts at zero opacity).
        setState(() {});
        return;
      }
      (render as _MobileFrameBoundaryRenderObject).onContentChanged =
          _contentChanged;
      setState(() => entering = next);
    });
  }

  /// The page changed after its picture was taken (late data, a realtime
  /// event, an animation): show the live page again at once, as without
  /// snapshots, rather than a stale picture for the rest of the animation.
  void _contentChanged() {
    final render = boundary.currentContext?.findRenderObject();
    if (render is _MobileFrameBoundaryRenderObject) {
      render.onContentChanged = null;
    }
    if (entering == null) return;
    changedWhileAnimating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && entering != null) setState(_releaseEntering);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _unlisten();
    widget.host.frames.remove(widget.id);
    image?.dispose();
    entering?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.host.changed,
    builder: (context, _) {
      if (widget.host.active != widget.id) {
        if (entering != null) _releaseEntering();
        // A page picture alone is one draw operation, which the fade can apply
        // its alpha to directly; behind a background box it needs an offscreen
        // layer per frame. The picture already contains the page background.
        if (_fadeSnapshots && image != null) {
          return ExcludeSemantics(
            child: RawImage(image: image, fit: BoxFit.fill),
          );
        }
        return ExcludeSemantics(
          child: ColoredBox(
            // ds-allow: Historical platform route fallback matches its Scaffold before a painted frame exists.
            color: Theme.of(context).scaffoldBackgroundColor,
            child: image == null
                ? const SizedBox.expand()
                : RawImage(image: image, fit: BoxFit.fill),
          ),
        );
      }
      if (animating) _scheduleCapture();
      final snapshot = entering;
      return ExcludeSemantics(
        excluding: _deferSemantics && animating,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (snapshot != null)
              RawImage(
                key: const ValueKey('entering-snapshot'),
                image: snapshot,
                fit: BoxFit.fill,
              ),
            Opacity(
              key: const ValueKey('live-page'),
              opacity: snapshot == null ? 1 : 0,
              child: _MobileFrameBoundary(
                key: boundary,
                child: KeyedSubtree(
                  key: widget.host.live,
                  child: PageStorage(
                    bucket: widget.host.pageStorage,
                    child: widget.host.widget.child,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _MobileFrameBoundary extends SingleChildRenderObjectWidget {
  const _MobileFrameBoundary({super.key, required super.child});
  @override
  _MobileFrameBoundaryRenderObject createRenderObject(BuildContext context) =>
      _MobileFrameBoundaryRenderObject();
}

class _MobileFrameBoundaryRenderObject extends RenderRepaintBoundary {
  /// Called when something inside needs painting. While a snapshot stands in
  /// for this page (it is not painted then), that means the page's content
  /// changed after the picture was taken.
  VoidCallback? onContentChanged;

  @override
  void markNeedsPaint() {
    super.markNeedsPaint();
    onContentChanged?.call();
  }

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
