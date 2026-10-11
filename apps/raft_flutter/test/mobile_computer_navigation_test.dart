import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_ui/raft_ui.dart';

import 'app_global_server_selector_test.dart' show RootFixture;
import 'mobile_back_history_test.dart' show watchAppExit;
import '../../../packages/raft_ui/test/task_typography_test.dart'
    show loadTaskFonts;

const computer = <String, dynamic>{
  'id': 'computer-a',
  'name': 'Build Computer',
  'description': 'Shared development machine',
  'isComputer': true,
  'status': 'online',
  'computerVersion': '1.0.44',
  'computerUpgradeAvailable': true,
  'hostname': 'fixture-host',
  'userId': 'alice',
  'runtimes': ['codex'],
};

RootFixture fixture() =>
    RootFixture()
      ..overrides['GET /servers/a/machines'] = (_) => {
        'machines': [computer],
        'latestComputerVersion': '1.0.45',
      };

// Android's production theme uses native generic families. The test engine
// has no OS font manager, so register bundled Latin faces as explicit stand-ins.
// These images validate layout; they do not claim the phone's chosen font.
Future<void> loadComputerPageFonts(WidgetTester t) async {
  await loadTaskFonts(t);
  await t.runAsync(() async {
    for (final (alias, asset) in [
      ('sans-serif', 'packages/raft_ui/assets/fonts/Inter.ttf'),
      ('monospace', 'packages/raft_ui/assets/fonts/GeistMono.ttf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(alias)..addFont(rootBundle.load(asset))).load();
    }
  });
}

/// The fixture's 400ms network flush does not finish Android's 450ms route.
Future<void> finishPageAnimation(WidgetTester t, Finder destination) async {
  final route = ModalRoute.of(t.element(destination));
  for (var frame = 0; frame < 12; frame++) {
    if (route?.animation?.status == AnimationStatus.completed &&
        (route?.secondaryAnimation == null ||
            route!.secondaryAnimation!.status == AnimationStatus.dismissed)) {
      break;
    }
    await t.pump(const Duration(milliseconds: 50));
  }
  expect(route?.animation?.status, AnimationStatus.completed);
  if (route?.secondaryAnimation != null) {
    expect(route!.secondaryAnimation!.status, AnimationStatus.dismissed);
  }
  await t.pump();
}

void expectDetailHeader(WidgetTester t) {
  expect(find.byKey(const Key('computer-mobile-header')), findsOneWidget);
  expect(find.byKey(const Key('computer-mobile-back')), findsOneWidget);
  expect(find.byKey(const Key('computer-section-header')), findsNothing);
  expect(find.byKey(const Key('workspace-mobile-detail-header')), findsNothing);
  expect(find.byType(RaftMobilePageHeader), findsOneWidget);
  expect(t.getRect(find.byKey(const Key('computer-mobile-header'))).top, 24);
  expect(find.byKey(const Key('workspace-mobile-navigation')), findsNothing);
}

Future<void> capturePage(WidgetTester t, String theme, String page) async {
  final directory = Platform.environment['RAFT_COMPUTER_PAGE_EVIDENCE_DIR'];
  if (directory == null) return;
  RenderObject? object = t
      .element(find.byType(RaftMobilePageHeader).first)
      .findRenderObject();
  while (object != null &&
      !(object is RenderRepaintBoundary &&
          object.hasSize &&
          object.size.height >= 800)) {
    object = object.parent;
  }
  expect(object, isA<RenderRepaintBoundary>());
  await t.runAsync(() async {
    final image = await (object! as RenderRepaintBoundary).toImage(
      pixelRatio: 2,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$theme-$page.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final theme in ['brutal', 'elegant-light', 'elegant-dark']) {
    testWidgets(
      '$theme Settings → Computers → detail uses one URL-owned stack',
      (t) async {
        final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
        WidgetController.hitTestWarningShouldBeFatal = true;
        addTearDown(
          () => WidgetController.hitTestWarningShouldBeFatal = previousFatal,
        );
        final f = fixture();
        await loadComputerPageFonts(t);
        await f.mount(t, theme, 390, uri: Uri.parse('/s/alpha/settings'));
        t.view.padding = const FakeViewPadding(top: 24, bottom: 16);
        addTearDown(t.view.resetPadding);
        await t.pump();
        final exits = watchAppExit(t);
        final w = f.workspace(t);
        await t.ensureVisible(find.text('Computers'));
        await t.tap(find.text('Computers'));
        await f.flush(t);
        await finishPageAnimation(t, find.byType(RaftMobilePageHeader).first);
        await capturePage(t, theme, 'list');
        expect(w.location.route, RaftRoute.computers);
        expect(w.location.toString(), '/s/alpha/computers');
        expect(find.byType(RaftMobileComputerList), findsOneWidget);
        expect(find.byType(ListTile), findsNothing);
        expect(find.text('Computers'), findsOneWidget);
        expect(
          find.byKey(const Key('workspace-mobile-navigation')),
          findsNothing,
        );
        final reads = f.adapter.calls
            .where((o) => o.path == '/servers/a/machines')
            .length;
        final card = find.byKey(const ValueKey('fleet-computer-a'));
        await finishPageAnimation(t, card);
        await t.tap(card);
        await f.flush(t);
        expect(w.location.toString(), '/s/alpha/computer/computer-a');
        expectDetailHeader(t);
        await finishPageAnimation(
          t,
          find.byKey(const Key('computer-mobile-back')),
        );
        await t.tap(find.byKey(const Key('computer-mobile-back')));
        await f.flush(t);
        expect(w.location.route, RaftRoute.computers);
        expect(card, findsOneWidget);
        await finishPageAnimation(t, card);
        expect(
          f.adapter.calls.where((o) => o.path == '/servers/a/machines').length,
          reads,
          reason: 'Back reuses the accepted server directory',
        );
        await t.tap(card);
        await f.flush(t);
        expect(w.location.route, RaftRoute.computer);
        await finishPageAnimation(
          t,
          find.byKey(const Key('computer-mobile-back')),
        );
        expect(await t.binding.handlePopRoute(), isTrue);
        await f.flush(t);
        expect(w.location.route, RaftRoute.computers);
        await finishPageAnimation(t, card);
        expect(await t.binding.handlePopRoute(), isTrue);
        await f.flush(t);
        expect(w.location.toString(), '/s/alpha/settings');
        expect(
          find.byKey(const Key('workspace-mobile-navigation')),
          findsOneWidget,
        );
        expect(exits, isEmpty);
        expect(t.takeException(), isNull);
        await f.close(t);
      },
    );

    testWidgets(
      '$theme cold Computer link has safe header and Settings fallback',
      (t) async {
        final f = fixture();
        await loadComputerPageFonts(t);
        await f.mount(
          t,
          theme,
          390,
          uri: Uri.parse('/s/alpha/computer/computer-a'),
        );
        t.view.padding = const FakeViewPadding(top: 24, bottom: 16);
        addTearDown(t.view.resetPadding);
        await t.pump();
        await finishPageAnimation(t, find.byType(RaftMobilePageHeader).first);
        await capturePage(t, theme, 'detail');
        expectDetailHeader(t);
        final exits = watchAppExit(t);
        await t.tap(find.byKey(const Key('computer-mobile-back')));
        await f.flush(t);
        expect(f.workspace(t).location.toString(), '/s/alpha/settings');
        expect(exits, isEmpty);
        expect(t.takeException(), isNull);
        await f.close(t);
      },
    );
  }
}
