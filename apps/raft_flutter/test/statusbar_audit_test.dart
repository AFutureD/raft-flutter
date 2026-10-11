// Status bar audit (phone, 40dp top inset). Renders real mobile routes in the
// three themes and asserts, for every page, that the status bar strip is the
// same colour as the surface directly under it (the header, on Web the header
// is drawn up under the safe-area top) and that the status bar icons contrast
// with it. Writes the top 120dp of each page to
// `.local/statusbar/crops/<theme>/<page>.png` (see tool in the test run notes:
// `RAFT_STATUSBAR_DIR` overrides the folder); a contact sheet per theme is
// composed from those crops by `tool/statusbar-sheet.py`.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_flutter/features/auth_view.dart';
import 'package:raft_flutter/features/incoming_share_picker.dart';
import 'package:raft_flutter/features/page_layout.dart';
import 'package:raft_flutter/features/public_server_view.dart';
import 'package:raft_flutter/platform/system_bars.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

import 'app_global_server_selector_test.dart' show RootFixture;
import 'edge_to_edge_audit_test.dart'
    show
        openAttachment,
        openChannel,
        openForward,
        openTask,
        richFixture,
        settle;
import 'incoming_share_review_test.dart' show PickerClient;
import 'mobile_computer_navigation_test.dart' show loadComputerPageFonts;

const _dpr = 2.625;
const _size = Size(1081, 2402);
const _topDp = 40.0;
const _themes = ['brutal', 'elegant-light', 'elegant-dark'];

Directory outDir(String theme) => Directory(
  '${Platform.environment['RAFT_STATUSBAR_DIR'] ?? '${Directory.current.path}/../../.local/statusbar'}/crops/$theme',
)..createSync(recursive: true);

void _insets(WidgetTester t) {
  const top = _topDp * _dpr;
  t.view.viewPadding = const FakeViewPadding(top: top, bottom: 126);
  t.view.padding = const FakeViewPadding(top: top, bottom: 126);
}

Future<RootFixture> _mount(
  WidgetTester t,
  String theme,
  String path, {
  void Function(RootFixture f)? prepare,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  await loadComputerPageFonts(t);
  final f = richFixture();
  prepare?.call(f);
  await f.mount(t, theme, 412, uri: Uri.parse(path));
  t.view.devicePixelRatio = _dpr;
  t.view.physicalSize = _size;
  _insets(t);
  addTearDown(() {
    t.view.resetPadding();
    t.view.resetViewPadding();
  });
  await f.flush(t);
  await settle(t);
  return f;
}

/// Asserts strip == surface below, icons contrast, and writes the crop.
Future<void> checkTop(
  WidgetTester t,
  String theme,
  String name, {
  bool headerless = false,
  double cropDp = 120,
}) async {
  final strips = find.byType(RaftStatusBarStrip);
  if (!headerless) {
    expect(strips, findsAtLeastNWidgets(1), reason: '$name: no strip');
    expect(
      raftStatusBarResolution(t.renderObject(strips.last)).fromSource,
      isTrue,
      reason: '$name $theme: header does not publish its background',
    );
  }
  final renderView = t.binding.renderViews.first;
  final layer = renderView.debugLayer! as OffsetLayer;
  final style = layer.find<SystemUiOverlayStyle>(
    Offset(renderView.size.width / 2, _topDp / 2),
  );
  late int strip, below;
  await t.runAsync(() async {
    final image = await layer.toImage(
      Offset.zero & (renderView.size * _dpr),
      pixelRatio: 1,
    );
    final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int px(int x, int y) {
      final o = (y * image.width + x) * 4;
      return 0xFF000000 |
          raw.getUint8(o) << 16 |
          raw.getUint8(o + 1) << 8 |
          raw.getUint8(o + 2);
    }

    strip = px(3, (_topDp / 2 * _dpr).round());
    below = px(3, (_topDp * _dpr).round() + 4);
    final w = image.width;
    final h = (cropDp * _dpr).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint(),
    );
    // Mark the simulated 40dp inset so the strip edge is visible.
    canvas.drawRect(
      Rect.fromLTWH(0, _topDp * _dpr - 1, w.toDouble(), 2),
      Paint()..color = const Color(0xFFFF00FF),
    );
    final out = await recorder.endRecording().toImage(w, h);
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    File('${outDir(theme).path}/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    out.dispose();
  });
  String hex(int c) => '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  expect(
    hex(strip),
    hex(below),
    reason: '$name $theme: status bar ${hex(strip)} != surface below',
  );
  expect(style, isNotNull, reason: '$name $theme: no status bar style');
  final lightBackground = Color(strip).computeLuminance() >= .5;
  expect(
    style!.statusBarIconBrightness,
    lightBackground ? Brightness.dark : Brightness.light,
    reason: '$name $theme: status bar icons do not contrast with ${hex(strip)}',
  );
}

/// The signed-in user reads the app in Chinese.
void _zh(RootFixture f) {
  f.overrides['GET /auth/me'] = (_) => {
    'id': 'alice',
    'name': 'alice',
    'email': 'alice@example.invalid',
    'emailVerified': true,
    'displayLanguage': 'zh-cn',
  };
}

void _withDirectory(RootFixture f) {
  f.overrides['GET /channels/dm'] = (_) => [
    {
      'id': 'dm-peer',
      'type': 'dm',
      'name': 'bob',
      'peerName': 'bob',
      'peerDisplayName': 'Bob',
      'serverId': 'a',
      'joined': true,
      'latestSeq': '1',
    },
  ];
  f.overrides['GET /messages/channel/dm-peer'] = (_) => {
    'messages': <dynamic>[],
    'hasMore': false,
    'hasNewer': false,
  };
  f.overrides['POST /channels/dm-peer/read'] = (_) => {};
  f.overrides['GET /agents'] = (_) => [
    {
      'id': 'agent-1',
      'name': 'cindy',
      'displayName': 'Cindy',
      'description': 'Engineering operator',
      'status': 'online',
    },
  ];
}

/// Minimal public-server API for [PublicServerView].
class _PublicClient extends RaftClient {
  _PublicClient()
    : super(
        origin: 'https://example.invalid',
        sessionStore: MemorySessionStore(),
      );
  @override
  void connect() {}
  @override
  Future<dynamic> request(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    bool authorized = true,
    bool retried = false,
    UploadCancellation? cancellation,
    void Function(int, int)? onSendProgress,
    Map<String, dynamic>? headers,
    bool acceptServerExit = false,
    Duration? receiveTimeout,
  }) async {
    const base = '/public/servers/raft-design';
    if (path == base) {
      return {
        'server': {'id': 's', 'name': 'Raft Design', 'slug': 'raft-design'},
        'channels': [
          {'id': 'c1', 'name': 'general', 'description': 'Announcements'},
        ],
        'canJoinAsGuest': true,
      };
    }
    if (path == '$base/channels/c1/messages') return {'messages': <dynamic>[]};
    throw RaftApiException('Not found', status: 404);
  }
}

class Page {
  const Page(
    this.name,
    this.path, {
    this.act,
    this.headerless = false,
    this.prepare,
    this.cropDp = 120,
  });
  final double cropDp;
  final String name, path;
  final void Function(RootFixture f)? prepare;

  /// The page has no header surface under the status bar (fallback colour).
  final bool headerless;
  final Future<void> Function(WidgetTester t, RootFixture f)? act;
}

Future<void> openAddMembers(WidgetTester t, RootFixture f) async {
  await f.flush(t);
  await settle(t);
}

const pages = <Page>[
  Page('01-home-root', '/s/alpha'),
  Page('02-tasks-root', '/s/alpha/tasks'),
  Page('03-members-root', '/s/alpha/members'),
  Page('04-settings-root', '/s/alpha/settings'),
  Page('05-channel-chat', '/s/alpha', act: openChannel),
  Page('06-thread', '/s/alpha/channel/ca?thread=ca:ma'),
  Page('07-search', '/s/alpha/search'),
  Page('08-activity', '/s/alpha/activity'),
  Page('09-saved', '/s/alpha/saved'),
  Page('10-settings-account', '/s/alpha/settings/account'),
  Page('11-settings-workspace', '/s/alpha/settings/server'),
  Page('12-settings-bottom-bar', '/s/alpha/settings/bottom-bar'),
  Page('13-computers', '/s/alpha/computers'),
  Page('14-member-detail', '/s/alpha/human/bob'),
  Page('15-channel-settings', '/s/alpha/channel/ca?channelPage=settings:ca'),
  Page('16-channel-members', '/s/alpha/channel/ca?channelPage=members:ca'),
  Page(
    '17-channel-add-members',
    '/s/alpha/channel/ca?channelPage=members:ca&channelPageAdd=1',
  ),
  Page('46-dm-chat', '/s/alpha/dm/dm-peer', prepare: _withDirectory),
  Page('47-agent-detail', '/s/alpha/agent/agent-1', prepare: _withDirectory),
  Page('48-human-detail', '/s/alpha/human/alice', prepare: _withDirectory),
  Page(
    '49-dm-settings',
    '/s/alpha/dm/dm-peer?channelPage=settings:dm-peer',
    prepare: _withDirectory,
  ),
  Page(
    '50-add-members-zh',
    '/s/alpha/channel/ca?channelPage=members:ca&channelPageAdd=1',
    prepare: _zh,
    cropDp: 915,
  ),
  Page('21-server-selector', '/'),
  Page('22-server-not-found', '/s/unknown', headerless: true),
  Page('23-agent-detail', '/s/alpha/agent/missing'),
  Page('24-computer-detail', '/s/alpha/computer/computer-1'),
  Page('25-member-graph', '/s/alpha/member-graph'),
  Page('26-settings-appearance', '/s/alpha/settings/appearance'),
  Page('27-settings-notifications', '/s/alpha/settings/notifications'),
  Page('28-settings-language', '/s/alpha/settings/language'),
  Page('29-settings-billing', '/s/alpha/settings/billing'),
  Page('30-settings-providers', '/s/alpha/settings/providers'),
  Page('31-settings-integrations', '/s/alpha/settings/integrations'),
  Page('32-settings-mcp', '/s/alpha/settings/mcp'),
  Page('33-settings-im-bridges', '/s/alpha/settings/im-bridges'),
  Page('34-settings-joint-channels', '/s/alpha/settings/joint-channels'),
  Page('35-settings-administration', '/s/alpha/settings/administration'),
  Page(
    '36-settings-workspace-settings',
    '/s/alpha/settings/workspace-settings',
  ),
  Page('37-settings-sidebar', '/s/alpha/settings/sidebar-settings'),
  Page('38-release-notes', '/s/alpha/release-notes'),
  Page('18-task-detail', '/s/alpha/tasks', act: openTask, headerless: true),
  Page('19-attachment-preview', '/s/alpha', act: openAttachment),
  // The forward page paints its own canvas under the status bar.
  Page('20-forward-composer', '/s/alpha', act: openForward, headerless: true),
];

void main() {
  for (final theme in raftThemeMatrix(_themes, full: true)) {
    for (final p in pages) {
      testWidgets('statusbar ${p.name} $theme', (t) async {
        try {
          final f = await _mount(t, theme, p.path, prepare: p.prepare);
          await p.act?.call(t, f);
          await checkTop(
            t,
            theme,
            p.name,
            headerless: p.headerless,
            cropDp: p.cropDp,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  // Pages that are not reachable through the workspace router: built directly
  // under the app's system bars, exactly as their routes mount them.
  final standalone = <String, Widget Function()>{
    '40-auth-login': () => AuthView(
      origin: 'https://example.invalid',
      onLogin: (_, _, _) async {},
      onRegister: (_, _, _, _) async {},
    ),
    '41-share-picker': () => IncomingSharePicker(
      client: PickerClient(),
      servers: [
        RaftRecord({'id': 'a', 'name': 'Server A'}),
      ],
      valid: () => true,
      onContinue: (server, target) async {},
    ),
    '42-standalone-route': () => Builder(
      builder: (context) => Scaffold(
        appBar: raftPageAppBar(context, title: 'Feedback'),
        body: const SizedBox.expand(),
      ),
    ),
    '44-public-server': () => PublicServerView(
      client: _PublicClient(),
      slug: 'raft-design',
      onSignIn: () {},
      onRegister: () {},
      onUnavailable: () {},
    ),
    '45-server-access-denied': () =>
        RaftServerAccessDeniedPage(serverName: 'Alpha', onContinue: () {}),
    '51-root-error': () =>
        RaftRootErrorFallback(message: 'Boom', onReload: () {}),
    '43-onboarding-shell': () =>
        const RaftOnboardingShell(child: Text('Create')),
  };
  for (final theme in raftThemeMatrix(_themes, full: true)) {
    for (final entry in standalone.entries) {
      testWidgets('statusbar ${entry.key} $theme', (t) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await loadComputerPageFonts(t);
          t.view.devicePixelRatio = _dpr;
          t.view.physicalSize = _size;
          _insets(t);
          addTearDown(() {
            t.view.resetPadding();
            t.view.resetViewPadding();
            t.view.resetPhysicalSize();
            t.view.resetDevicePixelRatio();
          });
          await t.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: raftTheme(
                theme == 'brutal' ? RaftFamily.brutal : RaftFamily.elegant,
                dark: theme == 'elegant-dark',
              ),
              home: RaftSystemBars(child: entry.value()),
            ),
          );
          await settle(t, 6);
          await checkTop(
            t,
            theme,
            entry.key,
            // Full-page cards: the page colour runs under the status bar.
            headerless: const {
              '45-server-access-denied',
              '51-root-error',
            }.contains(entry.key),
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}
