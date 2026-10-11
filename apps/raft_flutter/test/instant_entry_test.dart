import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/incoming_share_picker.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_flutter/platform/content_coordinator.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_ui/raft_ui.dart';

import 'app_global_server_selector_test.dart' show RootCache, RootFixture;
import 'workspace_source_location_contract_test.dart' show LocalNotifications;

// Time-to-first-meaningful-frame harness for the two entry points that must
// feel instant: an incoming Android share and a notification tap. Every
// network read is slow (it completes only after [apiDelay] of virtual time);
// a "frame" is one 16 ms pump. The numbers printed as `METRIC` are the
// before/after figures of the instant-entry change.
const apiDelay = Duration(seconds: 2);
const frameStep = Duration(milliseconds: 16);
const _origin = 'https://fixture.invalid';
const _memory = 'raft.server-surface.https%3A%2F%2Ffixture.invalid.alice';

/// Network reads a cold start makes before its first channel page.
const _startupReads = [
  'GET /auth/me',
  'GET /servers',
  'GET /channels',
  'GET /channels/dm',
  'GET /channels/unread',
  'GET /messages/channel/ca',
];

Map<String, dynamic> _row(String id, String channel, String text) => {
  'id': id,
  'channelId': channel,
  'seq': '1',
  'senderId': 'alice',
  'senderName': 'Alice',
  'content': text,
  'createdAt': '2026-10-10T00:00:00Z',
};

void _routes(RootFixture f) {
  f.overrides['GET /channels'] = (o) {
    final id = o.headers['X-Server-Id'];
    return [
      {
        'id': 'c$id',
        'name': 'general-$id',
        'type': 'channel',
        'serverId': id,
        'joined': true,
        'latestSeq': '1',
      },
      if (id == 'a')
        {
          'id': 'cx',
          'name': 'general-x',
          'type': 'channel',
          'serverId': 'a',
          'joined': true,
          'latestSeq': '1',
        },
    ];
  };
  f.overrides['GET /channels/cx'] = (_) => {
    'id': 'cx',
    'name': 'general-x',
    'type': 'channel',
    'serverId': 'a',
    'joined': true,
  };
  f.overrides['GET /messages/channel/cx'] = (_) => {
    'messages': [_row('mcx', 'cx', 'Accepted x')],
    'hasMore': false,
    'hasNewer': false,
  };
  f.overrides['GET /messages/context/mcx'] = (_) => {
    'messages': [_row('mcx', 'cx', 'Accepted x')],
    'targetMessageId': 'mcx',
    'hasOlder': false,
    'hasNewer': false,
  };
  f.overrides['POST /channels/cx/read'] = (_) => {};
  f.overrides['GET /channels/cx/members'] = (_) => [];
}

/// First process: open Alpha's two channels so their windows are on disk.
Future<RootCache> _firstProcess(WidgetTester t) async {
  final f = RootFixture();
  _routes(f);
  await f.mount(t, 'elegant-light', 1280);
  await t.tap(find.byKey(const ValueKey('global-server-a')));
  await f.flush(t);
  await t.tap(find.text('general-x').first);
  await f.flush(t);
  expect(find.text('Accepted x'), findsOneWidget);
  await f.workspace(t).flushCache();
  await f.close(t);
  return f.cache;
}

/// The scene's API gate: every wait opens it after [apiDelay] of virtual time.
Gate? activeGate;

/// Attachment copies that also finish after [apiDelay].
final copyGates = <Gate>[];

class Gate {
  Gate([this.holds = const {}]);

  /// Startup reads a cold start holds; they open together with the gate.
  final Map<String, Completer<dynamic>> holds;
  final done = Completer<void>();
  void open() {
    if (!done.isCompleted) done.complete();
    for (final held in holds.values) {
      if (!held.isCompleted) held.complete(null);
    }
  }
}

/// Wraps the current route so it answers only once [gate] opens.
void slow(RootFixture f, Gate gate, [Iterable<String>? keys]) {
  for (final key in keys ?? List.of(f.adapter.routes.keys)) {
    final route = f.adapter.routes[key];
    if (route == null) continue;
    f.adapter.routes[key] = (o) async {
      await gate.done.future;
      return route(o);
    };
  }
}

/// Every request takes [latency] (a realistic mobile round trip), instead of
/// waiting for a gate: serial awaits then add up.
void latent(RootFixture f, Duration latency) {
  for (final key in List.of(f.adapter.routes.keys)) {
    final route = f.adapter.routes[key]!;
    f.adapter.routes[key] = (o) async {
      await Future<void>.delayed(latency);
      return route(o);
    };
  }
}

/// Frames until [done], opening [gate] once [apiDelay] of virtual time passed.
/// Returns the frame index at which [done] first held (0 = immediately).
Future<int> framesUntil(
  WidgetTester t,
  bool Function() done, {
  Gate? gate,
  int max = 400,
}) async {
  for (var frame = 0; frame <= max; frame++) {
    if (done()) return frame;
    if (frameStep * frame >= apiDelay) {
      (gate ?? activeGate)?.open();
      for (final copy in copyGates) {
        copy.open();
      }
    }
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await t.pump(frameStep);
  }
  return -1;
}

void metric(String name, int frames) => debugPrint(
  'METRIC $name: ${frames < 0 ? 'never' : '$frames frames (${frames * 16} ms)'}',
);

NativeSharing slowSharing(Directory dir, Gate gate) => NativeSharing(
  supported: false,
  incomingDirectory: () async => dir,
  readContent: (_) async* {
    await gate.done.future;
    yield Uint8List.fromList([1, 2, 3]);
  },
);

const _share = IncomingShare(
  text: 'Shared caption',
  files: [
    IncomingSharedFile('content://fixture/photo', 'photo.jpg', 'image/jpeg', 3),
  ],
);

String payload(RootFixture f, String uri) => jsonEncode({
  'origin': _origin,
  'principal': 'alice',
  'serverId': 'a',
  'uri': uri,
});

const _toX = 'raft://v1/servers/a/channels/cx/messages/mcx';

const _coldExtras = [
  'GET /channels/cx',
  'GET /messages/channel/cx',
  'GET /messages/context/mcx',
  'GET /servers/a/members',
  'GET /servers/b/members',
  'GET /channels/public',
];

bool pickerVisible() => find.byType(IncomingSharePicker).evaluate().isNotEmpty;
bool row(String key) =>
    find.byKey(ValueKey('incoming-target-$key')).evaluate().isNotEmpty;
bool text(String value) => find.text(value).evaluate().isNotEmpty;

/// Writes: anything but the app's own read receipts.
Iterable<String> sentAnything(RootFixture f) => f.adapter.calls
    .where(
      (c) =>
          c.method != 'GET' &&
          !c.path.endsWith('/read') &&
          c.path != '/feature-flags/evaluate',
    )
    .map((c) => '${c.method} ${c.path}');

const _revokedNotice = 'The selected destination is no longer available.';

/// A running app on a second process over the device cache of a first one.
/// Every read is slow: warm (settled workspace, then everything slowed) or
/// cold (the startup reads and the rest held until [gate] opens).
class Scene {
  Scene(this.f, this.w, this.gate, this.coordinator, this.notifications);
  final RootFixture f;
  final WorkspaceController w;
  final Gate gate;
  final NativeContentCoordinator? coordinator;
  final LocalNotifications? notifications;
}

Future<Scene> boot(
  WidgetTester t,
  Directory dir, {
  required bool cold,
  NativeSharing? sharing,
  bool coordinator = false,
  bool gated = true,
}) async {
  final cache = await _firstProcess(t);
  final holds = <String, Completer<dynamic>>{
    if (cold)
      for (final key in _startupReads) key: Completer<dynamic>(),
  };
  final gate = Gate(holds);
  final n = coordinator ? LocalNotifications() : null;
  final content = coordinator
      ? NativeContentCoordinator(notifications: n, links: const Stream.empty())
      : null;
  final f = RootFixture(
    cache: cache,
    sharing: sharing,
    contentOverride: content,
  );
  _routes(f);
  f.holds.addAll(holds);
  await f.mount(
    t,
    'elegant-light',
    412,
    cachedSession: true,
    settle: !cold,
    preferences: {'$_memory.last': 'alpha', '$_memory.a': '/s/alpha'},
  );
  if (cold) {
    slow(f, gate, _coldExtras);
    await t.pump(frameStep);
  } else {
    for (var i = 0; i < 3; i++) {
      await f.flush(t);
    }
    if (gated) slow(f, gate);
  }
  activeGate = gate;
  addTearDown(() {
    activeGate = null;
    copyGates.clear();
  });
  expect(find.byType(WorkspaceView), findsOneWidget);
  final w = f.workspace(t);
  addTearDown(() async {
    gate.open();
    if (content != null) await t.runAsync(content.dispose);
  });
  return Scene(f, w, gate, content, n);
}

Future<void> settle(WidgetTester t, Scene s, [int frames = 12]) async {
  s.gate.open();
  for (var i = 0; i < frames; i++) {
    await s.f.flush(t);
  }
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('raft-instant-share-');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  for (final cold in [false, true]) {
    final mode = cold ? 'cold' : 'warm';
    testWidgets(
      'share $mode: picker and cached targets are visible within 2 frames while API and copy are slow, then the hand-off lands in the chosen channel',
      (t) async {
        final copy = Gate();
        copyGates.add(copy);
        final sharing = slowSharing(dir, copy);
        if (cold) sharing.receive(_share);
        final s = await boot(t, dir, cold: cold, sharing: sharing);
        final f = s.f;
        if (!cold) sharing.receive(_share);
        final frames = await framesUntil(t, pickerVisible, gate: null);
        metric('share $mode: picker visible', frames);
        expect(frames, inInclusiveRange(0, 2));
        expect(row('cx') && row('ca'), isTrue, reason: 'cached destinations');
        expect(
          find.byKey(const Key('incoming-share-preparing')),
          findsOneWidget,
        );
        // Per-item progress is shown while the copy is still pending.
        expect(find.text('Preparing 0 of 1 files'), findsOneWidget);
        // Let the page transition finish (the API and the copy stay pending).
        await t.pump(const Duration(milliseconds: 400));
        await t.tap(find.text('#general-x'));
        await t.pump();
        await t.tap(find.byKey(const Key('incoming-share-continue')));
        await t.pump();
        expect(
          t
              .widget<RaftButton>(
                find.byKey(const Key('incoming-share-continue')),
              )
              .busy,
          isTrue,
          reason: 'waiting for fresh authority and the copy',
        );
        expect(sentAnything(f), isEmpty);
        copy.open();
        s.gate.open();
        final landed = await framesUntil(
          t,
          () =>
              !pickerVisible() &&
              s.w.drafts['cx'] == 'Shared caption' &&
              s.w.uploads().isNotEmpty,
        );
        metric('share $mode: hand-off after API resolves', landed);
        expect(landed, greaterThanOrEqualTo(0));
        final w = s.w;
        expect(w.channel?.id, 'cx');
        expect(w.uploads().single.queued, isTrue);
        expect(w.error, isNull);
        await f.close(t);
      },
    );
  }

  testWidgets(
    'share: a cached destination the fresh directory drops is deselected and never added',
    (t) async {
      final copy = Gate();
      copyGates.add(copy);
      final sharing = slowSharing(dir, copy);
      final s = await boot(t, dir, cold: false, sharing: sharing);
      final openChannel = s.w.channel?.id;
      sharing.receive(_share);
      final f = s.f;
      f.adapter.routes['GET /channels'] = (o) async {
        await s.gate.done.future;
        return [
          {
            'id': 'ca',
            'name': 'general-a',
            'type': 'channel',
            'serverId': 'a',
            'joined': true,
          },
        ];
      };
      await framesUntil(t, pickerVisible);
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('#general-x'));
      await t.pump();
      await t.tap(find.byKey(const Key('incoming-share-continue')));
      await t.pump();
      copy.open();
      await settle(t, s);
      expect(pickerVisible(), isTrue, reason: 'hand-off was refused');
      expect(find.text(_revokedNotice), findsOneWidget);
      expect(row('cx'), isFalse);
      expect(row('ca'), isTrue);
      expect(
        t
            .widget<RaftButton>(
              find.byKey(const Key('incoming-share-continue')),
            )
            .onPressed,
        isNull,
      );
      final w = s.w;
      expect(w.drafts['cx'], isNull);
      expect(w.channel?.id, openChannel);
      expect(sentAnything(f), isEmpty);
      expect(f.adapter.calls.where((c) => c.path == '/channels/cx'), isEmpty);
      await t.pageBack();
      await f.close(t);
    },
  );

  testWidgets(
    'share: a server the account lost is dropped with its destinations before anything is added',
    (t) async {
      final copy = Gate();
      copyGates.add(copy);
      final sharing = slowSharing(dir, copy);
      final s = await boot(t, dir, cold: false, sharing: sharing);
      final openChannel = s.w.channel?.id;
      sharing.receive(_share);
      final f = s.f;
      f.adapter.routes['GET /servers'] = (o) async {
        await s.gate.done.future;
        return [f.servers[1]];
      };
      await framesUntil(t, pickerVisible);
      expect(row('cx'), isTrue);
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('#general-x'));
      await t.pump();
      await t.tap(find.byKey(const Key('incoming-share-continue')));
      await t.pump();
      copy.open();
      await settle(t, s);
      expect(pickerVisible(), isTrue);
      expect(row('cx'), isFalse);
      expect(row('cb'), isTrue, reason: 'redirected to the remaining server');
      expect(find.text(_revokedNotice), findsOneWidget);
      final w = s.w;
      expect(w.drafts['cx'], isNull);
      expect(w.channel?.id, openChannel);
      expect(sentAnything(f), isEmpty);
      await t.pageBack();
      await f.close(t);
    },
  );

  testWidgets('share: a failed copy closes the picker and reports the error', (
    t,
  ) async {
    final copy = Gate();
    copyGates.add(copy);
    final sharing = NativeSharing(
      supported: false,
      incomingDirectory: () async => dir,
      readContent: (_) async* {
        await copy.done.future;
        throw const FormatException('provider gone');
      },
    );
    final s = await boot(t, dir, cold: false, sharing: sharing);
    sharing.receive(_share);
    expect(await framesUntil(t, pickerVisible), inInclusiveRange(0, 2));
    copy.open();
    await settle(t, s, 6);
    expect(pickerVisible(), isFalse);
    expect(s.w.error, 'The shared content could not be added.');
    expect(dir.listSync(), isEmpty);
    await s.f.close(t);
  });

  for (final cold in [false, true]) {
    final mode = cold ? 'cold' : 'warm';
    testWidgets(
      'notification $mode: known channel opens within 2 frames while API is slow and settles on the message',
      (t) async {
        final s = await boot(t, dir, cold: cold, coordinator: true);
        final f = s.f;
        final before = cold ? null : f.workspace(t).navigation.index;
        s.notifications!.onTap!(payload(f, _toX));
        bool opened() =>
            find.byType(WorkspaceView).evaluate().isNotEmpty &&
            f.workspace(t).location.entityId == 'cx';
        final frames = await framesUntil(t, opened);
        metric('notification $mode: destination open', frames);
        expect(frames, inInclusiveRange(0, 2));
        final page = await framesUntil(t, () => text('general-x'));
        metric('notification $mode: channel page painted', page);
        expect(page, inInclusiveRange(0, 2));
        await settle(t, s);
        final w = f.workspace(t);
        expect(w.location.entityId, 'cx');
        expect(w.location.messageId, 'mcx');
        expect(text('Accepted x'), isTrue);
        expect(w.error, isNull);
        if (before != null) expect(w.navigation.index, before + 1);
        await f.close(t);
      },
    );
  }

  for (final cold in [false, true]) {
    final mode = cold ? 'cold' : 'warm';
    testWidgets(
      'notification $mode: a channel unknown to the device shows its loading shell within 2 frames and resolves',
      (t) async {
        final s = await boot(t, dir, cold: cold, coordinator: true);
        final f = s.f;
        f.adapter.routes['GET /channels/cnew'] = (o) async {
          await s.gate.done.future;
          return {
            'id': 'cnew',
            'name': 'fresh-room',
            'type': 'channel',
            'serverId': 'a',
            'joined': true,
          };
        };
        f.adapter.routes['GET /messages/channel/cnew'] = (o) async {
          await s.gate.done.future;
          return {
            'messages': [_row('mnew', 'cnew', 'Brand new')],
            'hasMore': false,
            'hasNewer': false,
          };
        };
        f.adapter.routes['GET /messages/context/mnew'] = (o) async {
          await s.gate.done.future;
          return {
            'messages': [_row('mnew', 'cnew', 'Brand new')],
            'targetMessageId': 'mnew',
            'hasOlder': false,
            'hasNewer': false,
          };
        };
        f.adapter.routes['POST /channels/cnew/read'] = (_) => {};
        f.adapter.routes['GET /channels/cnew/members'] = (_) => [];
        s.notifications!.onTap!(
          payload(f, 'raft://v1/servers/a/channels/cnew/messages/mnew'),
        );
        final frames = await framesUntil(
          t,
          () => find.byType(RaftChannelResolutionBody).evaluate().isNotEmpty,
        );
        metric('notification $mode: unknown channel shell', frames);
        expect(frames, inInclusiveRange(0, 2));
        expect(f.workspace(t).location.entityId, 'cnew');
        await settle(t, s);
        final w = f.workspace(t);
        expect(w.location.entityId, 'cnew');
        expect(w.channel?.id, 'cnew');
        expect(text('Brand new'), isTrue);
        expect(find.byType(RaftChannelResolutionBody), findsNothing);
        expect(w.error, isNull);
        await f.close(t);
      },
    );
  }

  for (final unknown in [false, true]) {
    final id = unknown ? 'cnew' : 'cx';
    testWidgets(
      'notification: ${unknown ? 'unknown' : 'known'} channel the server refuses is reverted and reported',
      (t) async {
        final s = await boot(t, dir, cold: false, coordinator: true);
        final f = s.f;
        for (final key in [
          'GET /channels/$id',
          'GET /messages/channel/$id',
          'GET /messages/context/m$id',
        ]) {
          f.adapter.routes[key] = (o) async {
            await s.gate.done.future;
            f.adapter.statuses[key] = 403;
            return {'error': 'Forbidden'};
          };
        }
        final w = f.workspace(t);
        final before = w.location, index = w.navigation.index;
        s.notifications!.onTap!(
          payload(f, 'raft://v1/servers/a/channels/$id/messages/m$id'),
        );
        expect(
          await framesUntil(t, () => f.workspace(t).location.entityId == id),
          inInclusiveRange(0, 2),
        );
        await settle(t, s);
        expect(w.location, before);
        expect(w.navigation.index, index);
        expect(w.error, contains('unavailable'));
        await f.close(t);
      },
    );
  }

  testWidgets(
    'notification: a workspace the account no longer belongs to is reverted and reported',
    (t) async {
      final s = await boot(t, dir, cold: false, coordinator: true);
      final f = s.f;
      f.adapter.routes['GET /servers'] = (o) async {
        await s.gate.done.future;
        return [f.servers[1]];
      };
      final w = f.workspace(t);
      final before = w.location, index = w.navigation.index;
      s.notifications!.onTap!(payload(f, _toX));
      expect(
        await framesUntil(t, () => f.workspace(t).location.entityId == 'cx'),
        inInclusiveRange(0, 2),
      );
      await settle(t, s);
      expect(w.location.entityId, isNot('cx'));
      expect(w.navigation.index, index);
      expect(w.location, before);
      expect(w.error, contains('unavailable'));
      await f.close(t);
    },
  );

  // Serial-await profile: each request costs one 300 ms round trip.
  testWidgets('latency profile: 300 ms per request and per copy', (t) async {
    const rtt = Duration(milliseconds: 300);
    final sharing = NativeSharing(
      supported: false,
      incomingDirectory: () async => dir,
      readContent: (_) async* {
        await Future<void>.delayed(rtt);
        yield Uint8List.fromList([1, 2, 3]);
      },
    );
    final s = await boot(
      t,
      dir,
      cold: false,
      sharing: sharing,
      coordinator: true,
      gated: false,
    );
    latent(s.f, rtt);
    sharing.receive(_share);
    metric(
      'latency 300 ms, share warm: picker visible',
      await framesUntil(t, pickerVisible),
    );
    metric(
      'latency 300 ms, share warm: target rows visible',
      await framesUntil(t, () => row('cx')),
    );
    await t.pageBack();
    await settle(t, s, 8);
    s.notifications!.onTap!(payload(s.f, _toX));
    metric(
      'latency 300 ms, notification warm: destination open',
      await framesUntil(t, () => s.w.location.entityId == 'cx'),
    );
    metric(
      'latency 300 ms, notification warm: loaded and settled',
      await framesUntil(
        t,
        () => !s.w.channelLoading && s.w.location.messageId == 'mcx',
      ),
    );
    await settle(t, s, 8);
    await t.pump(const Duration(seconds: 3));
    await s.f.close(t);
    await t.pump(const Duration(seconds: 3));
  });
}
