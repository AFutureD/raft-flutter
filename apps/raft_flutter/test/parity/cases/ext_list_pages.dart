// raft-flutter parity EXTENSION suite builders (tool/parity-ext): list-style
// pages that had no case (Search page states, Activity, Saved, Tasks, desktop
// notification center, channel / section / computer dialogs). NOT official cases;
// ids are `components.list-pages.<key>.<theme>`, dispatched on props.extCase /
// props.extKind exactly like tool/parity-ext/host/ListPagesCases.tsx.
//
// Data: tool/parity-ext/fixtures/listpages.json (fixtures['ext:listpages']), the
// same file the React render host imports; its `routes` + the case's `routeSet`
// answer the API reads on both providers.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/search_memory.dart';
import 'package:raft_flutter/features/resource_view.dart';
import 'package:raft_ui/raft_ui.dart';

import '../parity_harness.dart';
import 'ext_list_pages_keys.g.dart';
import 'home_tasks/fixture_workspace.dart';

const _serverId = 'visual-server';

Map<String, dynamic> _fx(ParityContext ctx) =>
    ctx.fixtures['ext:listpages'] as Map<String, dynamic>;

/// `routes` overlaid with the case's `routeSet` (the React provider's rule).
Map<String, dynamic> _routes(ParityContext ctx) => {
  ...Map<String, dynamic>.from(_fx(ctx)['routes'] as Map),
  ...?(_fx(ctx)['routeSets'] as Map?)?[ctx.props['routeSet']] as Map?,
};

/// The official fixture workspace answering the listpages routes first.
class _ListWorkspace extends ParityFixtureWorkspace {
  _ListWorkspace(super.client, super.ctx);

  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) async {
    final answer = _routes(ctx)['GET ${path.split('?').first}'];
    if (answer is Map && answer['\$pending'] == true) {
      return Completer<dynamic>().future;
    }
    if (answer is Map && answer['\$status'] != null) {
      final body = answer['\$body'];
      throw RaftApiException.response(
        'fixture error',
        status: answer['\$status'] as int,
        body: body is Map ? body : null,
      );
    }
    if (path == '/tasks/server' && answer is Map && answer['tasks'] is List) {
      final status = query?['status'];
      return {
        'tasks': [
          for (final t in answer['tasks'] as List)
            if (status == null || (t as Map)['status'] == status) t,
        ],
        'next_cursor': answer['next_cursor'],
      };
    }
    return answer ?? super.query(path, query: query);
  }

  @override
  Future<dynamic> command(String method, String path, {dynamic data}) async =>
      _routes(ctx)['$method $path'] ?? <String, dynamic>{};
}

_ListWorkspace _workspace(ParityContext ctx, String section) {
  final base = parityWorkspace(ctx, section: section);
  return _ListWorkspace(base.client, ctx)
    ..server = base.server
    ..channels = base.channels
    ..section = section;
}

/// Search memory preloaded with the case's history tags (`searchHistory`,
/// `|`-separated), under the scope key ResourceView reads.
SearchMemoryStore _memory(ParityContext ctx, _ListWorkspace w) {
  final storage = ParityMemorySearchStorage();
  final history = (ctx.props['searchHistory'] as String?)?.split('|');
  if (history != null) {
    final scope = SearchMemoryScope(
      w.client.origin,
      _serverId,
      w.client.user!.id,
    );
    storage.values[scope.key] = jsonEncode({
      'version': 1,
      'history': history,
      'usage': <String, dynamic>{},
      'state': const SearchStateSnapshot().toJson(),
    });
  }
  return SearchMemoryStore(storage: storage, clock: () => parityNow(ctx));
}

Widget _panel(ParityContext ctx) {
  final panel = ctx.props['panel'] as String;
  final w = _workspace(ctx, panel);
  final width = (ctx.props['w'] as num? ?? 342).toDouble();
  final height = (ctx.props['h'] as num? ?? 620).toDouble();
  final now = parityNow(ctx);
  final view = Scaffold(
    body: ResourceView(
      controller: w,
      section: panel,
      clock: () => now,
      onBack: () {},
      initialQuery: ctx.props['q'] as String?,
      searchMemory: _memory(ctx, w),
      restoreSearchState: false,
      onMessage: (_, _) async {},
    ),
  );
  return RaftDensityScope(
    density: ctx.props['platform'] == 'desktop' || panel == 'activity'
        ? RaftDensity.desktop
        : RaftDensity.touch,
    child: ctx.frame(
      width: width,
      height: height,
      padding: EdgeInsets.zero,
      child: view,
    ),
  );
}

Future<void> _tap(WidgetTester t, Finder f, [int ms = 300]) async {
  await t.tap(f.first);
  await t.pump(Duration(milliseconds: ms));
}

Future<void> _rightClick(WidgetTester t, Finder f) async {
  await t.tapAt(
    t.getCenter(f.first),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await t.pump(const Duration(milliseconds: 300));
}

/// Per-case interactions (the Flutter counterpart of the manifest's React
/// `capture.interactions`).
Future<void> _interact(WidgetTester t, ParityContext ctx) async {
  await t.pump(const Duration(milliseconds: 50));
  final key = ctx.props['extCase'] as String;
  // The Web page waits 850ms for its debounced reads before every step.
  await t.pump(const Duration(milliseconds: 850));
  switch (key) {
    case 'search.desktop-channel-filter':
      await _tap(t, find.text('Channel'), 250);
    case final k when k.endsWith('-filter-unread'):
      await _tap(t, find.text('Unread'));
    case final k when k.endsWith('-filter-mentions'):
      await _tap(t, find.text('Mentions'));
    case final k when k.startsWith('activity.') && k.endsWith('-context-menu'):
      await _rightClick(t, find.byType(RaftConversationCard));
    case final k when k.startsWith('saved.') && k.endsWith('-actions'):
      await _rightClick(t, find.byKey(const ValueKey('saved-msg-saved-visual-1')));
    case 'tasks.desktop-list':
      await _tap(t, find.text('List'));
    case 'tasks.desktop-status-menu':
      await _tap(t, find.text('List'));
      await _tap(t, find.byType(RaftTaskStatusEditor));
    case final k when k.contains('-filter-assignee'):
      await _tap(t, find.text('Assignee'));
    case final k when k.contains('-filter-creator'):
      await _tap(t, find.text('Creator'));
    case final k when k.contains('-filter-channels'):
      await _tap(t, find.text('Channel'));
  }
  await t.pump(const Duration(milliseconds: 600));
}

ParityCase _case() => ParityCase(
  widgets: const ['raft_flutter:ResourceView'],
  notes: 'Extension suite (not official).',
  settle: const Duration(milliseconds: 850),
  build: (ctx) => switch (ctx.props['extKind']) {
    'panel' => _panel(ctx),
    final kind => throw StateError('unknown list-pages kind $kind'),
  },
  interact: _interact,
);

/// Every extension list-pages case, keyed by id (3 themes each).
final Map<String, ParityCase> extListPageCases = {
  for (final key in extListPageKeys)
    for (final theme in const ['brutal', 'elegant', 'elegant-dark'])
      'components.list-pages.$key.$theme': _case(),
};
