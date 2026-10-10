// raft-flutter parity EXTENSION suite builders (tool/parity-ext): the
// account-level announcement modal. Ids
// `components.announcements.<platform>.<kind>.<theme>`, dispatched on
// props.ann like tool/parity-ext/host/AnnouncementCases.tsx.
//
// Mounts the real [AnnouncementHost] over a white page: the fixture client
// answers `GET /announcements/active` with the case's announcement
// (fixtures/announcements.json) and the server setup projection with
// `phase: null`, so the host presents it exactly as on workspace entry.
// Element cases crop `capture.androidKey` (the card); overlay cases capture
// the viewport.
import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/announcement_host.dart';

import '../parity_harness.dart';
import 'screens/screen_fixture.dart';

WorkspaceController _workspace(ParityContext ctx) {
  final fx = ctx.fixtures['ext:announcements'] as Map<String, dynamic>;
  final announcement = (fx['announcements'] as Map)[ctx.props['ann']];
  final wire = ScreenWire(ctx.fixtureData);
  final serverId = wire.server()['id'] as String;
  final client = ScreenFixtureClient(
    (method, path, query) => switch ((method, path)) {
      ('GET', '/announcements/active') => {
        'announcements': [announcement],
      },
      ('GET', _) when path == '/servers/$serverId/setup-projection' => {
        'phase': null,
      },
      _ => wire.common(method, path, query),
    },
    user: wire.me(),
    server: serverId,
  );
  final w = WorkspaceController(client);
  final server = RaftRecord(wire.server());
  w
    ..servers = [server]
    ..server = server;
  return w;
}

ParityCase _case() => ParityCase(
  widgets: const [
    'raft_ui:RaftAnnouncementModal',
    'raft_ui:RaftAnnouncementCard',
    'raft_ui:RaftAnnouncementMarkdown',
  ],
  notes: 'Extension suite (not official).',
  settle: const Duration(milliseconds: 300),
  build: (ctx) => AnnouncementHost(
    controller: _workspace(ctx),
    deployment: 'production',
    child: const SizedBox.expand(child: ColoredBox(color: Colors.white)),
  ),
);

const _kinds = {
  'desktop': [
    'single',
    'multi-first',
    'multi-middle',
    'multi-last',
    'rich',
    'long',
    'long-title',
    'overlay',
  ],
  'mobile': ['single', 'multi-middle', 'rich', 'long', 'overlay'],
};

/// Every extension announcement case, keyed by id (3 themes each).
final Map<String, ParityCase> extAnnouncementCases = {
  for (final MapEntry(key: platform, value: kinds) in _kinds.entries)
    for (final kind in kinds)
      for (final theme in const ['brutal', 'elegant', 'elegant-dark'])
        'components.announcements.$platform.$kind.$theme': _case(),
};
