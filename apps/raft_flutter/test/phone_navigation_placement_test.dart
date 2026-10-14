import 'dart:async';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/chat_view.dart';
import 'package:raft_flutter/features/mobile_workspace_pages.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phone layout navigation placement: the bottom tab bar on ordinary tall
/// phones, the desktop left rail on wide / short windows (wide foldable inner
/// screens, landscape phones, 600-767 dp). The page stack, routes and dialogs
/// stay the phone ones; only the navigation chrome swaps.

class _Client extends RaftClient {
  _Client()
    : super(
        origin: 'https://public-fixture.invalid',
        sessionStore: MemorySessionStore(),
      ) {
    user = RaftRecord({'id': 'alice', 'displayName': 'Alice'});
  }
  final stream = StreamController<RaftEvent>.broadcast(sync: true);
  final channelRows = [
    for (var i = 0; i < 30; i++)
      RaftChannel({'id': 'c$i', 'name': 'design-$i', 'joined': true}),
  ];
  @override
  Stream<RaftEvent> get events => stream.stream;
  @override
  void connect() {}
  @override
  void joinChannel(String id) {}
  @override
  Future<List<RaftRecord>> servers() async => [
    RaftRecord({'id': 's', 'name': 'Fixture', 'role': 'owner'}),
  ];
  @override
  Future<List<RaftChannel>> channels({bool dm = false}) async =>
      dm ? [] : channelRows;
  @override
  Future<Map<String, dynamic>> messagePage(
    String id, {
    int limit = 50,
    BigInt? before,
    BigInt? after,
  }) async => {
    'messages': [
      for (var i = 1; i <= 40; i++)
        {
          'id': 'm$i',
          'channelId': id,
          'serverId': 's',
          'seq': '$i',
          'content': 'Public fixture message $i',
          'senderId': 'other',
          'senderType': 'user',
          'createdAt': '2026-10-08T00:00:${i.toString().padLeft(2, '0')}Z',
        },
    ],
    'threadSummariesByParentMessageId': {},
  };
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/agents') return [];
    if (path.startsWith('/channels/c') && !path.contains('/', 10)) {
      final id = path.split('/').last;
      return {'id': id, 'serverId': 's', 'name': id, 'joined': true};
    }
    if (path == '/channels/unread') {
      return {
        'channels': {'c0': 1},
      };
    }
    if (path.endsWith('/sidebar-order')) {
      return {'pinned': [], 'customSections': [], 'sectionPlacements': []};
    }
    if (path.endsWith('/setup-projection')) {
      return {'phase': 'complete', 'surface': 'complete', 'blocksChat': false};
    }
    if (path == '/auth/identities') {
      return {'passwordConfigured': true, 'identities': []};
    }
    if (path == '/auth/providers') return {'providers': []};
    return [];
  }

  @override
  Future<dynamic> post(String path, {dynamic data}) async {
    if (path.endsWith('/read')) {
      return {'maxReadSeq': '40', 'readStateVersion': '1'};
    }
    if (path == '/feature-flags/evaluate') return {'evaluations': []};
    return {};
  }
}

enum _Chrome { bottom, rail, desktop }

class _Case {
  const _Case(this.width, this.height, this.chrome);
  final double width, height;
  final _Chrome chrome;
  Size get size => Size(width, height);
  @override
  String toString() => '${width.round()}x${height.round()}';
}

const _cases = [
  _Case(390, 844, _Chrome.bottom),
  _Case(430, 932, _Chrome.bottom),
  _Case(440, 707, _Chrome.rail),
  _Case(528, 848, _Chrome.rail),
  _Case(707, 440, _Chrome.rail),
  _Case(600, 960, _Chrome.rail),
  _Case(669, 951, _Chrome.rail),
  _Case(704, 933, _Chrome.rail),
  _Case(760, 840, _Chrome.rail),
  _Case(767, 1000, _Chrome.rail),
  _Case(768, 1024, _Chrome.desktop),
];

final _bar = find.byKey(const Key('workspace-mobile-navigation'));
Finder _rail(String id) => find.byKey(ValueKey('rail-$id'));

/// The hit target a finger gets: the control, or its [RaftTouchTarget]
/// expansion (touch density extends the target without inflating layout).
Size _hit(WidgetTester tester, Finder f) {
  final size = tester.getSize(f);
  final inner = find.descendant(of: f, matching: find.byType(RaftTouchTarget));
  final outer = find.ancestor(of: f, matching: find.byType(RaftTouchTarget));
  final target = inner.evaluate().isNotEmpty ? inner : outer;
  if (target.evaluate().isEmpty) return size;
  final min = tester.widget<RaftTouchTarget>(target.first).minSize;
  return Size(
    size.width < min.width ? min.width : size.width,
    size.height < min.height ? min.height : size.height,
  );
}

const _railIds = [
  'workspace',
  'search',
  'chat',
  'activity',
  'tasks',
  'members',
  'computers',
  'settings',
];

class _Rig {
  _Rig(
    this.tester,
    this.family, {
    this.rtl = false,
    this.textScale = 1.0,
    required this.size,
    this.padding = const FakeViewPadding(top: 24, bottom: 24),
    this.displayFeatures = const [],
  });
  final List<DisplayFeature> displayFeatures;
  final WidgetTester tester;
  final RaftFamily family;
  final bool rtl;
  final double textScale;
  Size size;
  final FakeViewPadding padding;
  late final _Client c;
  late final WorkspaceController w;

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> resize(Size next) async {
    size = next;
    tester.view.physicalSize = next;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> start() async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    tester.view.displayFeatures = displayFeatures;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    c = _Client()..selectServer('s');
    w = WorkspaceController(c, mobileNavigation: size.width < 768);
    await tester.runAsync(w.bootstrap);
    addTearDown(() async {
      w.dispose();
      await c.stream.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(family),
        builder: (context, child) => Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: child!,
        ),
        home: WorkspaceView(
          controller: w,
          appearance: RaftAppearance(mode: ThemeMode.light, light: family),
          onAppearance: (_) async {},
          onLogout: () async {},
        ),
      ),
    );
    await settle();
  }

  Future<void> tapRail(String id) async {
    await tester.tap(_rail(id));
    await settle();
  }
}

void main() {
  for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
    group('placement matrix $family', () {
      for (final c in _cases) {
        testWidgets('$c LTR 1.0x', (tester) async {
          final r = _Rig(tester, family, size: c.size);
          await r.start();
          expect(tester.takeException(), isNull);
          switch (c.chrome) {
            case _Chrome.bottom:
              expect(_bar, findsOneWidget);
              expect(_rail('chat'), findsNothing);
              expect(_rail('settings'), findsNothing);
            case _Chrome.rail:
              expect(_bar, findsNothing);
              for (final id in _railIds) {
                expect(_rail(id), findsOneWidget, reason: 'rail-$id');
              }
              // Leading edge, clear of the content region.
              final rect = tester.getRect(
                find.byKey(const Key('workspace-sidebar')),
              );
              final railRect = tester.getRect(_rail('chat'));
              expect(railRect.left, greaterThanOrEqualTo(0));
              expect(railRect.right, lessThanOrEqualTo(rect.left + .5));
              for (final id in _railIds) {
                final size = _hit(tester, _rail(id));
                expect(
                  size.shortestSide,
                  greaterThanOrEqualTo(48),
                  reason: 'rail-$id hit target',
                );
              }
            case _Chrome.desktop:
              expect(_bar, findsNothing);
              expect(_rail('chat'), findsOneWidget);
          }
        });
      }

      for (final c in [_cases[0], _cases[2], _cases[4], _cases[9]]) {
        testWidgets('$c RTL 2.0x text', (tester) async {
          final r = _Rig(
            tester,
            family,
            size: c.size,
            rtl: true,
            textScale: 2.0,
          );
          await r.start();
          expect(tester.takeException(), isNull);
          if (c.chrome == _Chrome.rail) {
            expect(_bar, findsNothing);
            // The rail sits on the leading (right) edge.
            final rail = tester.getRect(find.byType(RaftWorkspaceRail));
            expect(rail.right, c.width);
            expect(rail.left, greaterThan(c.width / 2));
            expect(
              tester.getRect(find.byKey(const Key('workspace-sidebar'))).right,
              lessThanOrEqualTo(rail.left + .5),
            );
            for (final id in _railIds) {
              expect(
                _hit(tester, _rail(id)).shortestSide,
                greaterThanOrEqualTo(48),
                reason: 'rail-$id at 2.0x',
              );
            }
          } else {
            expect(_bar, findsOneWidget);
          }
        });
      }
    });
  }

  group('rail behaviour', () {
    for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
      testWidgets('$family rail routes through the phone navigation', (
        tester,
      ) async {
        final r = _Rig(tester, family, size: const Size(440, 707));
        await r.start();
        expect(r.w.location.route, RaftRoute.home);
        await r.tapRail('tasks');
        expect(r.w.location.route, RaftRoute.tasks);
        // A root tab: the rail stays; the chat entry now carries the unread
        // attention dot the desktop rail shows for an inactive Chat.
        expect(_rail('chat'), findsOneWidget);
        expect(find.byType(RaftRailAttention), findsWidgets);
        await r.tapRail('activity');
        expect(r.w.location.route, RaftRoute.activity);
        expect(_rail('chat'), findsOneWidget);
        await r.tapRail('members');
        expect(r.w.location.route, RaftRoute.members);
        await r.tapRail('computers');
        expect(r.w.location.route, RaftRoute.computers);
        expect(_rail('chat'), findsOneWidget);
        // Its header sits beside the rail, not above it: the rail starts at
        // the top of the safe area like on every other root page.
        expect(
          tester.getRect(find.byType(RaftWorkspaceRail)).top,
          closeTo(24, .5),
        );
        expect(find.byKey(const Key('mobile-detail-back')), findsNothing);
        // Settings: the rail stays and the Bottom bar row is not offered
        // (and neither is the bottom-bar-only Computers shortcut).
        await r.tapRail('settings');
        expect(r.w.location.route, RaftRoute.settings);
        expect(
          find.byKey(const ValueKey('workspace-settings-nav-appearance')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('workspace-settings-nav-bottom-bar')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('workspace-settings-nav-computers')),
          findsNothing,
        );
        await r.tapRail('chat');
        expect(r.w.location.route, RaftRoute.home);
        // Search is the Home list's pushed page: a full-width page.
        await r.tapRail('search');
        expect(r.w.location.route, RaftRoute.search);
        expect(_rail('chat'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$family short landscape rail scrolls to every entry', (
        tester,
      ) async {
        final r = _Rig(tester, family, size: const Size(707, 440));
        await r.start();
        final rail = find.descendant(
          of: find.byType(RaftWorkspaceRail),
          matching: find.byType(Scrollable),
        );
        for (final id in ['computers', 'settings']) {
          await tester.scrollUntilVisible(_rail(id), 60, scrollable: rail);
          await tester.pump();
          expect(
            tester.getRect(_rail(id)).bottom,
            lessThanOrEqualTo(440),
            reason: 'rail-$id on screen',
          );
        }
        await tester.tap(_rail('settings'));
        await r.settle();
        expect(r.w.location.route, RaftRoute.settings);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$family bottom bar keeps its Settings Bottom bar row', (
        tester,
      ) async {
        final r = _Rig(tester, family, size: const Size(390, 844));
        await r.start();
        await tester.tap(find.byKey(const Key('mobile-tab-settings')));
        await r.settle();
        expect(
          find.byKey(const ValueKey('workspace-settings-nav-bottom-bar')),
          findsOneWidget,
        );
      });

      testWidgets('$family live-activity-free rail keeps the system inset', (
        tester,
      ) async {
        // Landscape with a side cutout / navigation bar: the rail paints under
        // the inset and keeps its buttons clear of it; the content starts after
        // the rail.
        final r = _Rig(
          tester,
          family,
          size: const Size(707, 440),
          padding: const FakeViewPadding(left: 40, top: 0, bottom: 20),
        );
        await r.start();
        expect(tester.takeException(), isNull);
        final chat = tester.getRect(_rail('chat'));
        expect(chat.left, greaterThanOrEqualTo(40));
        expect(
          _hit(tester, _rail('chat')).shortestSide,
          greaterThanOrEqualTo(48),
        );
        final list = tester.getRect(find.byKey(const Key('workspace-sidebar')));
        expect(list.left, greaterThan(chat.right - 1));
      });
    }
  });

  group('placement switch keeps the page', () {
    for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
      testWidgets('$family Home list keeps its element and scroll offset', (
        tester,
      ) async {
        final r = _Rig(tester, family, size: const Size(390, 844));
        await r.start();
        final list = find.byKey(const Key('workspace-sidebar'));
        final element = identityHashCode(tester.element(list));
        await tester.drag(list, const Offset(0, -400));
        await r.settle();
        double offset() => tester
            .state<ScrollableState>(
              find.descendant(of: list, matching: find.byType(Scrollable)),
            )
            .position
            .pixels;
        final before = offset();
        expect(before, greaterThan(100));
        final pages = identityHashCode(
          tester.state(find.byType(MobileWorkspacePages)),
        );
        for (final next in [
          const Size(707, 440),
          const Size(390, 844),
          const Size(440, 707),
          const Size(430, 932),
        ]) {
          await r.resize(next);
          expect(tester.takeException(), isNull, reason: '$next');
          expect(
            _bar.evaluate().isNotEmpty,
            next.width < 600 && next.height / next.width >= 1.75,
            reason: '$next bar',
          );
          expect(identityHashCode(tester.element(list)), element);
          expect(
            identityHashCode(tester.state(find.byType(MobileWorkspacePages))),
            pages,
          );
          expect(offset(), closeTo(before, .5), reason: '$next offset');
        }
      });

      testWidgets('$family channel page keeps scroll offset and draft', (
        tester,
      ) async {
        final r = _Rig(tester, family, size: const Size(440, 707));
        await r.start();
        await r.w.selectChannel(r.w.channels.first);
        await r.settle();
        final composer = find.descendant(
          of: find.byType(RaftComposer),
          matching: find.byType(EditableText),
        );
        await tester.enterText(composer.first, 'half-written reply');
        await tester.pump();
        final scrollables = find.descendant(
          of: find.byType(RaftChatView),
          matching: find.byType(Scrollable),
        );
        // The message timeline is the tallest scrollable of the page.
        final timeline = scrollables
            .evaluate()
            .map((e) => find.byElementPredicate((x) => x == e))
            .reduce(
              (a, b) =>
                  tester.getSize(a).height >= tester.getSize(b).height ? a : b,
            );
        double offset() =>
            tester.state<ScrollableState>(timeline).position.pixels;
        final initial = offset();
        await tester.drag(timeline, const Offset(0, 500));
        await r.settle();
        final before = offset();
        expect(
          (before - initial).abs(),
          greaterThan(50),
          reason: 'the drag scrolled the timeline',
        );
        final editor = identityHashCode(tester.element(composer.first));
        final page = identityHashCode(
          tester.element(find.byType(RaftChatView).first),
        );
        final location = r.w.location.uri;
        for (final next in [
          const Size(707, 440),
          const Size(390, 844),
          const Size(669, 951),
          const Size(440, 707),
        ]) {
          await r.resize(next);
          expect(tester.takeException(), isNull, reason: '$next');
          expect(r.w.location.uri, location, reason: '$next stays on page');
          expect(identityHashCode(tester.element(composer.first)), editor);
          expect(
            identityHashCode(tester.element(find.byType(RaftChatView).first)),
            page,
          );
          expect(
            tester.widget<EditableText>(composer.first).controller.text,
            'half-written reply',
            reason: '$next draft',
          );
          expect(offset(), closeTo(before, .5), reason: '$next offset');
        }
      });
    }
  });

  group('display features (fold / hinge)', () {
    for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
      testWidgets('$family a vertical hinge mid-window: rail stays leading, '
          'clear of the hinge; placement is size based', (tester) async {
        // A 4:3 wide foldable half-opened: the hinge splits 760 dp in two.
        const hinge = Rect.fromLTRB(375, 0, 385, 840);
        final r = _Rig(
          tester,
          family,
          size: const Size(760, 840),
          displayFeatures: [
            DisplayFeature(
              bounds: hinge,
              type: DisplayFeatureType.hinge,
              state: DisplayFeatureState.postureHalfOpened,
            ),
          ],
        );
        await r.start();
        expect(tester.takeException(), isNull);
        expect(_bar, findsNothing);
        final rail = tester.getRect(find.byType(RaftWorkspaceRail));
        expect(rail.left, 0);
        expect(rail.overlaps(hinge), isFalse, reason: 'rail clear of hinge');
        for (final id in _railIds) {
          expect(
            tester.getRect(_rail(id)).overlaps(hinge),
            isFalse,
            reason: 'rail-$id clear of hinge',
          );
        }
        debugPrint(
          '$family hinge $hinge: rail ${rail.left}..${rail.right}, '
          'content starts at '
          '${tester.getRect(find.byKey(const Key('workspace-sidebar'))).left}',
        );
      });

      testWidgets('$family a separating fold inside the rail strip keeps the '
          'bottom bar', (tester) async {
        final r = _Rig(
          tester,
          family,
          size: const Size(760, 840),
          displayFeatures: [
            DisplayFeature(
              bounds: const Rect.fromLTRB(20, 0, 30, 840),
              type: DisplayFeatureType.hinge,
              state: DisplayFeatureState.postureHalfOpened,
            ),
          ],
        );
        await r.start();
        expect(_bar, findsOneWidget);
        expect(_rail('chat'), findsNothing);
      });

      testWidgets('$family a flat fold or cutout never changes placement', (
        tester,
      ) async {
        final r = _Rig(
          tester,
          family,
          size: const Size(440, 707),
          displayFeatures: [
            DisplayFeature(
              bounds: const Rect.fromLTRB(20, 0, 30, 707),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureFlat,
            ),
            DisplayFeature(
              bounds: const Rect.fromLTRB(0, 0, 40, 40),
              type: DisplayFeatureType.cutout,
              state: DisplayFeatureState.unknown,
            ),
          ],
        );
        await r.start();
        expect(_bar, findsNothing);
        expect(_rail('chat'), findsOneWidget);
      });
    }
  });
}
