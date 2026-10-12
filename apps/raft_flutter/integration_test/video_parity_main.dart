// Debug/profile-only entrypoint: the production RaftApp on perf-lab fixtures
// with a channel of video attachments served by an external S3-like range
// server (tool/video-parity-range-server).
// No login. Never built into the release app.
//
//   tool/video-parity-range-server <dir: portrait.mp4 landscape.mp4 landscape2.mp4 corrupt.mp4> 8791
//   tool/flutter build linux --profile -t integration_test/video_parity_main.dart \
//     --dart-define=VP_BASE=http://127.0.0.1:8791 --dart-define=VP_MOBILE=false
//
// Android: `adb reverse tcp:8791 tcp:8791` and VP_MOBILE=true; the isolated
// package is `app.raft.raft_flutter.linkperf` (see attachment_progress_main).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/data/mobile_tabbar_preferences.dart';
import 'package:raft_flutter/data/source_time_formatter.dart';
import 'package:raft_flutter/main.dart' as app;
import 'package:raft_flutter/platform/android_performance_hint.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_flutter/platform/system_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'perf_lab/fixtures.dart';
import 'perf_lab/navigation_host.dart';

Future<void> main() async {
  RaftWidgetsFlutterBinding.ensureInitialized();
  await NativeSystemFonts.instance.initialize();
  await initializeSourceTimeFormatting();
  await DevicePreferences.load();
  const base = String.fromEnvironment(
    'VP_BASE',
    defaultValue: 'http://127.0.0.1:8791',
  );
  const mobile = bool.fromEnvironment('VP_MOBILE');
  final images = await LabImages.start();

  Map<String, dynamic> row(
    int n,
    String text,
    List<Map<String, dynamic>> attachments,
  ) => labRow('vp', 'plain', n)
    ..['content'] = text
    ..['attachments'] = attachments;
  Map<String, dynamic> video(
    String id,
    String file,
    int size, {
    int? w,
    int? h,
  }) => {
    'id': id,
    'channelId': 'vp',
    'filename': file,
    'mimeType': 'video/mp4',
    'sizeBytes': size,
    'width': ?w,
    'height': ?h,
  };
  final channel = LabChannel('vp', const []);
  channel.rows.addAll([
    row(0, 'Portrait phone clip (720x1280, H.264 + AAC)', [
      video('vp-portrait', 'kevin.mp4', 1016187),
    ]),
    row(1, 'Landscape clip', [video('vp-landscape', 'landscape.mp4', 2377327)]),
    row(2, 'A clip that cannot be decoded', [
      video('vp-corrupt', 'broken.mp4', 200000),
    ]),
    row(3, 'Second landscape clip (one at a time)', [
      video('vp-landscape2', 'landscape2.mp4', 2377327),
    ]),
  ]);
  final (seed, api, client) = await labWorkspace(
    [channel],
    images,
    mobile: mobile,
    ownsClient: false,
  );
  seed.dispose();
  api.routes['GET /auth/me'] = (_) => {
    'id': 'alice',
    'name': 'Alice Zhang',
    'email': 'alice@example.invalid',
    'emailVerified': true,
    'displayLanguage': 'en',
  };
  api.routes['GET /servers'] = (_) => [
    {'id': 's1', 'name': 'Lab', 'slug': 'lab', 'role': 'owner'},
  ];
  api.routes['GET /channels/public'] = (_) => <dynamic>[];
  api.routes['GET /channels/vp'] = (_) => channel.record.json;
  api.routes['GET /channels/inbox'] = (_) => {'items': <dynamic>[]};
  api.routes['GET /channels/saved'] = (_) => {
    'globalTotal': 0,
    'saved': <dynamic>[],
  };
  api.routes['GET /channels/threads/followed'] = (_) => {
    'threads': <dynamic>[],
  };
  api.routes['GET /announcements/active'] = (_) => {
    'announcements': <dynamic>[],
  };
  api.routes['GET /product-feedback/tickets'] = (_) => {
    'unread_total': 0,
    'tickets': <dynamic>[],
  };
  api.routes['GET /tasks/server'] = (_) => {'tasks': <dynamic>[]};
  api.routes['GET /messages/attachment-preview/enabled'] = (_) => {
    'enabled': true,
  };
  const files = {
    'vp-portrait': 'portrait.mp4',
    'vp-landscape': 'landscape.mp4',
    'vp-corrupt': 'corrupt.mp4',
    'vp-landscape2': 'landscape.mp4',
  };
  api.patterns.insert(0, (
    (o) =>
        o.method == 'GET' &&
        o.path.startsWith('/attachments/vp-') &&
        o.path.endsWith('/url'),
    (o) => {
      'url':
          '$base/${files[o.path.split('/')[2]]}?X-Amz-Expires=3600&X-Amz-Signature=fixture',
    },
  ));
  const tabs = MobileTabbarSettings(
    order: MobileTabs.configurable,
    enabled: {
      MobileTabs.home,
      MobileTabs.tasks,
      MobileTabs.members,
      MobileTabs.computers,
    },
  );
  SharedPreferences.setMockInitialValues({
    'raft.origin': client.origin,
    'raft.mode': const String.fromEnvironment('VP_MODE', defaultValue: 'light'),
    'raft.light': const String.fromEnvironment(
      'VP_THEME',
      defaultValue: 'brutal',
    ),
    MobileTabbarStore.preferenceKey: tabs.encode(),
  });
  final dir = await Directory.systemTemp.createTemp('raft-video-parity-');
  runApp(
    app.RaftApp(
      sessionStore: client.sessionStore,
      createClient: (_, _, _) => client,
      initialLocation: Uri(path: '/s/lab/channel/vp'),
      nativeContent: LabNavigationContent(),
      nativeSharing: NativeSharing(supported: false),
      openWorkspaceCache: () async =>
          LabNavigationCache(File('${dir.path}/workspace.sqlite')),
    ),
  );
}
