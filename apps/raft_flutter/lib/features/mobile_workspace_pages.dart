import 'package:flutter/material.dart';

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

/// Each platform route owns its live page widgets. History stores locations,
/// never rasterized frames; the workspace remains the data/navigation owner.
class MobileWorkspacePages extends StatefulWidget {
  const MobileWorkspacePages({
    super.key,
    required this.navigation,
    required this.onBack,
    required this.pageBuilder,
    this.storageBucket,
    this.enabled = true,
  });
  final WorkspaceNavigation navigation;
  final VoidCallback onBack;
  final Widget Function(BuildContext context, RaftLocation location)
  pageBuilder;
  final PageStorageBucket? storageBucket;
  final bool enabled;

  @override
  State<MobileWorkspacePages> createState() => _MobileWorkspacePagesState();
}

class _MobileWorkspacePagesState extends State<MobileWorkspacePages> {
  final navigator = GlobalKey<NavigatorState>();
  final pageStorage = PageStorageBucket();
  int nextInstance = 0;
  late List<_MobilePageEntry> entries = reconcile(const []);
  bool rootChanged = false;

  RaftLocation resolveLocation(String identity) {
    for (final location
        in widget.navigation.entries
            .take(widget.navigation.index + 1)
            .toList()
            .reversed) {
      if (identity.endsWith('::${mobilePageIdentity(location)}')) {
        return location;
      }
    }
    final base = _mobilePageBaseLocation(widget.navigation.location);
    if (identity.endsWith('::${mobilePageIdentity(base)}')) return base;
    return widget.navigation.mobileTabHome(widget.navigation.location);
  }

  List<_MobilePageEntry> reconcile(List<_MobilePageEntry> previous) => [
    for (final identity in mobilePageEntries(widget.navigation))
      _MobilePageEntry(
        identity,
        previous.where((entry) => entry.identity == identity).firstOrNull?.id ??
            '${nextInstance++}::$identity',
        resolveLocation(identity),
      ),
  ];

  @override
  void didUpdateWidget(MobileWorkspacePages oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = reconcile(entries);
    rootChanged =
        entries.first.identity != next.first.identity &&
        !entries.any(
          (entry) => next.any((item) => item.identity == entry.identity),
        );
    entries = next;
  }

  Widget page(BuildContext context, RaftLocation location) => PageStorage(
    bucket: widget.storageBucket ?? pageStorage,
    child: widget.pageBuilder(context, location),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return page(context, widget.navigation.location);
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
              allowSnapshotting: false,
              child: Builder(
                builder: (context) => page(context, entry.location),
              ),
            ),
        ],
        onDidRemovePage: (page) {
          if (page.key == ValueKey(entries.last.id)) widget.onBack();
        },
      ),
    );
  }
}

class _MobilePageEntry {
  const _MobilePageEntry(this.identity, this.id, this.location);
  final String identity, id;
  final RaftLocation location;
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
