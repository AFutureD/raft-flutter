// Evidence harness for docs/edge-to-edge-audit.md. It renders real mobile
// routes on a simulated Android phone whose system navigation bar is
// transparent (edge-to-edge) and tints the bar region, so any opaque strip
// that the app paints or leaves under the bar is visible. Not a failing
// assertion of the bug: it only checks that each capture was produced.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/forward_composer_page.dart';
import 'package:raft_flutter/features/incoming_share_picker.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_flutter/platform/system_bars.dart';
import 'package:raft_ui/raft_ui.dart';

import 'app_global_server_selector_test.dart' show RootFixture;
import 'incoming_share_review_test.dart' show PickerClient;
import 'mobile_computer_navigation_test.dart' show loadComputerPageFonts;

/// Pixel 8-class phone: 412x915 dp at 2.625.
const _dpr = 2.625;
const _size = Size(1081, 2402);

enum Nav {
  gesture('gesture', 48, 'gesture bar 48px'),
  buttons('buttons', 126, '3-button bar 126px');

  const Nav(this.id, this.px, this.label);
  final String id, label;
  final double px;
}

Directory outDir() {
  final dir = Directory(
    Platform.environment['RAFT_EDGE_AUDIT_DIR'] ??
        '${Directory.current.path}/../../.local/edge-to-edge',
  )..createSync(recursive: true);
  return dir;
}

final metrics = <Map<String, Object?>>[];

/// Lowest wide [Scrollable] viewport: how far above the screen bottom it ends
/// (dp). 0 means the scroll view runs under the system bar; the bar height
/// means a SafeArea strip clips it. Null when the page has no scroll view.
double? scrollGap(WidgetTester t) {
  final screenH = _size.height / _dpr;
  double? best;
  for (final e in find.byType(Scrollable).evaluate()) {
    final box = e.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) continue;
    if (box.size.width < 300 || box.size.height < 150) continue;
    final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    if (bottom > screenH + 1) continue;
    if (best == null || bottom > screenH - best) best = screenH - bottom;
  }
  return best;
}

String _hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Renders the whole root layer and tints the status/navigation bar bands.
/// Also records what colour the app itself leaves under the bar.
Future<void> shoot(
  WidgetTester t,
  String name, {
  required Nav nav,
  double keyboardPx = 0,
  String? probe,
}) async {
  final renderView = t.binding.renderViews.first;
  final layer = renderView.debugLayer! as OffsetLayer;
  final bounds = Offset.zero & (renderView.size * _dpr);
  final gap = scrollGap(t);
  await t.runAsync(() async {
    final image = await layer.toImage(bounds, pixelRatio: 1);
    final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int px(int x, int y) {
      final o = (y * image.width + x) * 4;
      return 0xFF000000 |
          raw.getUint8(o) << 16 |
          raw.getUint8(o + 1) << 8 |
          raw.getUint8(o + 2);
    }

    final w = image.width, h = image.height;
    final bandTop = h - nav.px.round();
    final bandY = h - (nav.px / 2).round();
    final band = {
      for (final x in [3, w ~/ 2, w - 4]) px(x, bandY),
    };
    final above = px(3, bandTop - 8);
    metrics.add({
      'name': name,
      'nav': nav.id,
      'bandColour': band.map(_hex).join('/'),
      'bandUniform': band.length == 1,
      'above8px': _hex(above),
      'bandEqualsAbove': band.length == 1 && band.first == above,
      'scrollViewportGapDp': gap?.toStringAsFixed(1),
      'probe': ?probe,
    });

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());
    final navTop = h - nav.px;
    canvas.drawRect(
      Rect.fromLTWH(0, navTop, w.toDouble(), nav.px),
      Paint()..color = const Color(0x55FF00FF),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, navTop, w.toDouble(), 3),
      Paint()..color = const Color(0xFFFF00FF),
    );
    if (keyboardPx > 0) {
      canvas.drawRect(
        Rect.fromLTWH(0, h - keyboardPx, w.toDouble(), keyboardPx),
        Paint()..color = const Color(0x4400AAFF),
      );
    }
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), 100),
      Paint()..color = const Color(0x3300AA00),
    );
    final out = await recorder.endRecording().toImage(w, h);
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    File('${outDir().path}/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    out.dispose();
  });
}

String mq(BuildContext c) {
  final m = MediaQuery.of(c);
  String d(double v) => (v * _dpr).round().toString();
  return 'padding.bottom=${d(m.padding.bottom)}px viewPadding.bottom='
      '${d(m.viewPadding.bottom)}px viewInsets.bottom=${d(m.viewInsets.bottom)}px';
}

void setInsets(WidgetTester t, Nav nav, {double keyboardPx = 0}) {
  t.view.viewPadding = FakeViewPadding(top: 100, bottom: nav.px);
  // Android: the IME replaces the nav bar inset, so padding.bottom drops to 0
  // while viewPadding keeps reporting the bar.
  t.view.padding = FakeViewPadding(
    top: 100,
    bottom: keyboardPx > 0 ? 0 : nav.px,
  );
  t.view.viewInsets = FakeViewPadding(bottom: keyboardPx);
}

Future<RootFixture> mountAt(
  WidgetTester t,
  String theme,
  String path,
  Nav nav, {
  RootFixture? fixture,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  await loadComputerPageFonts(t);
  final f = fixture ?? RootFixture();
  await f.mount(t, theme, 412, uri: Uri.parse(path));
  t.view.devicePixelRatio = _dpr;
  t.view.physicalSize = _size;
  setInsets(t, nav);
  addTearDown(() {
    t.view.resetPadding();
    t.view.resetViewPadding();
    t.view.resetViewInsets();
  });
  await f.flush(t);
  // Some pages keep a spinner alive; settle for a bounded time instead.
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return f;
}

Map<String, dynamic> _task(int i) => {
  'id': 'task-$i',
  'taskNumber': i,
  'title': i == 14 ? 'Scoped actual task' : 'Audit task number $i',
  'description': 'Accepted task description',
  'channelId': 'ca',
  'channelName': 'general-a',
  'messageId': 'task-parent',
  'threadChannelId': 'task-thread',
  'status': 'todo',
  'createdByType': 'user',
  'createdById': 'alice',
  'createdByName': 'Alice',
};

RootFixture richFixture() {
  final f = RootFixture();
  f.overrides['GET /messages/context/ma'] = (_) => {
    'messages': [_message('ma', 'Accepted a')],
  };
  f.overrides['GET /messages/channel/ca'] = (_) => {
    'messages': [
      for (var i = 1; i <= 6; i++)
        {
          ..._message(
            'm$i',
            i.isEven ? 'Reply number $i' : 'Edge to edge sample $i',
            seq: i,
          ),
          if (i == 6)
            'attachments': [
              {
                'id': 'preview-attachment',
                'filename': 'research.md',
                'mimeType': 'text/markdown',
              },
            ],
        },
    ],
    'hasMore': false,
    'hasNewer': false,
  };
  f.overrides['GET /servers/a/members'] = (_) => [
    {'userId': 'alice', 'name': 'Alice', 'role': 'owner'},
    {'userId': 'bob', 'name': 'Bob', 'role': 'member'},
  ];
  f.overrides['GET /tasks/server'] = (_) => {
    'tasks': [for (var i = 1; i <= 14; i++) _task(i)],
    'next_cursor': null,
  };
  f.overrides['GET /tasks/task-14/history'] = (_) => {'events': <dynamic>[]};
  f.overrides['GET /tasks/channel/ca/number/14'] = (_) => {'task': _task(14)};
  f.overrides['GET /messages/context/task-parent'] = (_) => {
    'messages': [_message('task-parent', 'Parent')],
  };
  f.overrides['GET /messages/channel/task-thread'] = (_) => {
    'messages': <dynamic>[],
  };
  f.overrides['POST /channels/task-thread/read'] = (_) => {};
  f.overrides['GET /messages/attachment-preview/enabled'] = (_) => {
    'enabled': true,
  };
  f.overrides['GET /attachments/preview-attachment/preview'] = (_) => {
    'status': 'ok',
    'data': {'kind': 'text', 'text': 'Fixture document'},
  };
  return f;
}

Map<String, dynamic> _message(String id, String text, {int seq = 1}) => {
  'id': id,
  'channelId': 'ca',
  'seq': '$seq',
  'senderId': 'alice',
  'senderName': 'Alice',
  'content': text,
  'createdAt': '2026-10-10T00:0$seq:00Z',
};

class Scenario {
  const Scenario(this.name, this.path, {this.act, this.nav = Nav.gesture});
  final String name, path;
  final Nav nav;
  final Future<void> Function(WidgetTester t, RootFixture f)? act;
}

Future<void> settle(WidgetTester t, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Opens the channel the way a user does: a cold URL launch does not load the
/// message window in this fixture.
Future<void> openChannel(WidgetTester t, RootFixture f) async {
  await t.tap(find.byKey(const ValueKey('sidebar-channel-ca')));
  await f.flush(t);
  await settle(t);
}

Future<void> scrollToEnd(WidgetTester t, RootFixture f) async {
  final list = find.byType(Scrollable).evaluate().where((e) {
    final b = e.renderObject;
    return b is RenderBox && b.size.width >= 300 && b.size.height >= 300;
  }).first;
  await t.fling(
    find.byElementPredicate((e) => e == list),
    const Offset(0, -3000),
    8000,
  );
  await settle(t, 20);
}

Future<void> openTask(WidgetTester t, RootFixture f) async {
  await t.tap(find.text('Scoped actual task'));
  await f.flush(t);
  await settle(t);
}

Future<void> openAttachment(WidgetTester t, RootFixture f) async {
  await openChannel(t, f);
  await t.tap(find.textContaining('research.md').first);
  await f.flush(t);
  await settle(t);
}

Future<void> openForward(WidgetTester t, RootFixture f) async {
  await openChannel(t, f);
  final w = f.workspace(t);
  final ctx = t.element(find.byType(WorkspaceView));
  final messages = w.messages.take(1).toList();
  unawaited(showForwardComposerPage(ctx, w, messages));
  await f.flush(t);
  await settle(t);
}

final scenarios = <Scenario>[
  const Scenario('01-home-root', '/s/alpha'),
  const Scenario('02-tasks-root', '/s/alpha/tasks'),
  const Scenario(
    '05-tasks-root-scrolled-end',
    '/s/alpha/tasks',
    act: scrollToEnd,
  ),
  const Scenario(
    '06-settings-root-scrolled-end',
    '/s/alpha/settings',
    act: scrollToEnd,
  ),
  const Scenario('07-home-root-scrolled-end', '/s/alpha', act: scrollToEnd),
  const Scenario('03-members-root', '/s/alpha/members'),
  const Scenario('04-settings-root', '/s/alpha/settings'),
  const Scenario('10-channel-chat', '/s/alpha', act: openChannel),
  const Scenario('11-thread', '/s/alpha/channel/ca?thread=ca:ma'),
  const Scenario('12-search', '/s/alpha/search'),
  const Scenario('13-activity', '/s/alpha/activity'),
  const Scenario('14-saved', '/s/alpha/saved'),
  const Scenario('15-settings-account', '/s/alpha/settings/account'),
  const Scenario('16-settings-workspace', '/s/alpha/settings/server'),
  const Scenario('17-computers', '/s/alpha/computers'),
  const Scenario('18-member-detail', '/s/alpha/human/bob'),
  const Scenario(
    '20-channel-settings-page',
    '/s/alpha/channel/ca?channelPage=settings:ca',
  ),
  const Scenario(
    '21-channel-members-page',
    '/s/alpha/channel/ca?channelPage=members:ca',
  ),
  const Scenario('22-task-detail', '/s/alpha/tasks', act: openTask),
  const Scenario('23-attachment-preview', '/s/alpha', act: openAttachment),
  const Scenario('24-forward-composer', '/s/alpha', act: openForward),
  // Same pages with a 3-button bar (126px).
  const Scenario(
    '10-channel-chat',
    '/s/alpha',
    act: openChannel,
    nav: Nav.buttons,
  ),
  const Scenario('01-home-root', '/s/alpha', nav: Nav.buttons),
  const Scenario('12-search', '/s/alpha/search', nav: Nav.buttons),
  const Scenario(
    '16-settings-workspace',
    '/s/alpha/settings/server',
    nav: Nav.buttons,
  ),
];

/// What a page body sees under a bare Scaffold (no SafeArea) when the nav bar
/// is up, and when the IME replaces it: the numbers the shared helper relies on.
void mqProbeTests() {
  for (final resize in [true, false]) {
    testWidgets('40-mq-probe Scaffold resizeToAvoidBottomInset=$resize', (
      t,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      t.view.devicePixelRatio = _dpr;
      t.view.physicalSize = _size;
      addTearDown(() {
        t.view.resetPadding();
        t.view.resetViewPadding();
        t.view.resetViewInsets();
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });
      late BuildContext inner;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: resize,
            body: Builder(
              builder: (c) {
                inner = c;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      for (final (label, kb) in [
        ('nav bar only', 0.0),
        ('keyboard 300dp', 300 * _dpr),
      ]) {
        setInsets(t, Nav.gesture, keyboardPx: kb);
        await t.pump();
        metrics.add({
          'name': 'mq-probe resize=$resize $label',
          'probe': mq(inner),
        });
      }
      debugDefaultTargetPlatformOverride = null;
    });
  }
}

void main() {
  mqProbeTests();
  tearDownAll(() {
    File('${outDir().path}/metrics.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(metrics));
  });
  for (final theme in const ['brutal', 'elegant-light']) {
    for (final s in scenarios) {
      testWidgets('${s.name} $theme ${s.nav.id}', (t) async {
        final f = await mountAt(
          t,
          theme,
          s.path,
          s.nav,
          fixture: richFixture(),
        );
        await s.act?.call(t, f);
        if (Platform.environment['RAFT_EDGE_DEBUG'] != null) {
          await f.flush(t);
          await settle(t, 20);
          debugPrint(
            f.adapter.calls
                .map((c) => '${c.method} ${c.path} ${c.queryParameters}')
                .join('\n'),
          );
        }
        await shoot(t, '${s.name}-$theme-${s.nav.id}', nav: s.nav);
        debugDefaultTargetPlatformOverride = null;
      });
    }
    // Keyboard up / down on the channel composer.
    testWidgets('30-chat-keyboard $theme', (t) async {
      final f = await mountAt(
        t,
        theme,
        '/s/alpha',
        Nav.gesture,
        fixture: richFixture(),
      );
      await openChannel(t, f);
      await t.tap(find.byType(EditableText).last);
      await settle(t, 3);
      const kb = 300 * _dpr;
      setInsets(t, Nav.gesture, keyboardPx: kb);
      await settle(t, 5);
      await shoot(
        t,
        '30-chat-keyboard-up-$theme',
        nav: Nav.gesture,
        keyboardPx: kb,
        probe: mq(t.element(find.byType(EditableText).last)),
      );
      setInsets(t, Nav.gesture);
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(t, 8);
      await shoot(
        t,
        '31-chat-keyboard-down-$theme',
        nav: Nav.gesture,
        probe: mq(t.element(find.byType(EditableText).last)),
      );
      debugDefaultTargetPlatformOverride = null;
      expect(f.workspace(t), isNotNull);
    });
    testWidgets('25-share-picker $theme', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await loadComputerPageFonts(t);
      t.view.devicePixelRatio = _dpr;
      t.view.physicalSize = _size;
      setInsets(t, Nav.gesture);
      addTearDown(() {
        t.view.resetPadding();
        t.view.resetViewPadding();
        t.view.resetViewInsets();
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: raftTheme(
            theme == 'brutal' ? RaftFamily.brutal : RaftFamily.elegant,
          ),
          home: RaftSystemBars(
            child: IncomingSharePicker(
              client: PickerClient(),
              servers: [
                RaftRecord({'id': 'a', 'name': 'Server A'}),
              ],
              valid: () => true,
              onContinue: (server, target) async {},
            ),
          ),
        ),
      );
      await settle(t, 6);
      await shoot(t, '25-share-picker-$theme-gesture', nav: Nav.gesture);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
