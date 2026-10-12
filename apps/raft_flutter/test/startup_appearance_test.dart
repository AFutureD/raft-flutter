import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/main.dart';
import 'package:raft_flutter/platform/native_sharing.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_global_server_selector_test.dart';

/// The family a built theme belongs to.
RaftFamily _family(ThemeData theme) => theme.extension<RaftTokens>()!.family;

Future<MaterialApp> _firstBuilt(
  WidgetTester t,
  Map<String, Object> stored, {
  required bool preload,
}) async {
  SharedPreferences.setMockInitialValues(stored);
  DevicePreferences.reset();
  if (preload) await t.runAsync(DevicePreferences.load);
  addTearDown(DevicePreferences.reset);
  final f = RootFixture();
  // One pump: no awaited startup work (restore) has run yet, so this is
  // exactly the tree the first frame would paint.
  await t.pumpWidget(
    RaftApp(
      sessionStore: f.sessions,
      nativeContent: f.content,
      nativeSharing: NativeSharing(supported: false),
      openWorkspaceCache: () async => f.cache,
      createClient: (origin, store, kind) =>
          f.client = RootClient(origin, store, kind, f.adapter),
    ),
  );
  return t.widget<MaterialApp>(find.byType(MaterialApp));
}

void main() {
  testWidgets('the first built MaterialApp uses the stored family and mode', (
    t,
  ) async {
    final app = await _firstBuilt(t, {
      'raft.mode': 'dark',
      'raft.light': 'elegant',
    }, preload: true);
    expect(app.themeMode, ThemeMode.dark);
    expect(
      _family(app.theme!),
      RaftFamily.elegant,
      reason: 'light theme must be the stored family from the first build',
    );
  });

  testWidgets('first build without stored values keeps brutal and system', (
    t,
  ) async {
    final app = await _firstBuilt(t, {}, preload: true);
    expect(app.themeMode, ThemeMode.system);
    expect(_family(app.theme!), RaftFamily.brutal);
  });

  testWidgets('an unknown stored value falls back per key, not wholesale', (
    t,
  ) async {
    final app = await _firstBuilt(t, {
      'raft.mode': 'dark',
      'raft.light': 'retired-family',
    }, preload: true);
    expect(app.themeMode, ThemeMode.dark);
    expect(_family(app.theme!), RaftFamily.brutal);
  });

  test('storedAppearance reads each key synchronously', () async {
    SharedPreferences.setMockInitialValues({
      'raft.mode': 'light',
      'raft.light': 'elegant',
    });
    final p = await SharedPreferences.getInstance();
    final a = storedAppearance(p);
    expect(a.mode, ThemeMode.light);
    expect(a.light, RaftFamily.elegant);
    DevicePreferences.reset();
    expect(storedAppearance().light, RaftFamily.brutal);
  });
}
