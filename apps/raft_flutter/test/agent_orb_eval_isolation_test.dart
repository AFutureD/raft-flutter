import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_launcher.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_page.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_world.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:raft_flutter/features/app_root_router.dart';
import 'package:raft_flutter/features/private_route_guard.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_services_fixture.dart';
import 'support/orb_eval_scripted.dart';

/// The evaluation page inside a realistic outer app: the app's own router,
/// route information provider and private-route guard, with a real workspace
/// on its home page. Moving the fixture workspace must not change the outer
/// app's route, tell the platform anything, or dispose the evaluation page.

void main() {
  late Directory reports;
  final platformRoutes = <Map<dynamic, dynamic>>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentOrbPreference.instance.resetForTest();
    reports = Directory.systemTemp.createTempSync('orb-eval-isolation');
    platformRoutes.clear();
  });
  tearDown(() => reports.deleteSync(recursive: true));

  testWidgets('a navigate in the fixture leaves the outer app and the eval '
      'page alone', (t) async {
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (call) async {
        if (call.method == 'routeInformationUpdated') {
          platformRoutes.add(Map<dynamic, dynamic>.from(call.arguments));
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        null,
      ),
    );

    // The outer app: a real workspace on its home page.
    final real = (await t.runAsync(
      () => OrbEvalWorld.create(
        OrbEvalData.cast()..say('raft-flutter', evalAlice, 'real'),
      ),
    ))!;
    final guard = PrivateRouteGuard();
    final located = <Uri>[];
    late final RaftAppRouter router;
    router = RaftAppRouter(
      home: (_) => withAppServices(
        WorkspaceView(
          controller: real.workspace,
          appearance: RaftAppearance(light: RaftFamily.brutal),
          onAppearance: (_) async {},
          onLogout: () async {},
        ),
      ),
      onLocation: (uri) async => located.add(uri),
      onRootBack: () async => false,
      observers: [guard],
    );
    final provider = RaftAppRouteInformationProvider(
      initialRouteInformation: RouteInformation(
        uri: Uri.parse('/s/fixture/home'),
      ),
      consumeReplacement: router.consumeReplacement,
    );
    addTearDown(provider.dispose);
    addTearDown(router.dispose);
    await t.pumpWidget(
      MaterialApp.router(
        theme: raftTheme(RaftFamily.brutal),
        routerDelegate: router,
        routeInformationParser: const RaftAppRouteParser(),
        routeInformationProvider: provider,
      ),
    );
    await t.pump(const Duration(seconds: 1));
    router.publish(Uri.parse('/s/fixture/home'));
    await t.pump();
    final before = (
      router.currentConfiguration,
      real.workspace.location.toString(),
      platformRoutes.length,
      located.length,
    );

    // The evaluation, opened the way adb opens it, over the outer app.
    final sessions = Sessions();
    final scenario = OrbEvalScenario(
      id: 'B1',
      title: 'isolation',
      start: OrbEvalStart.home,
      data: () =>
          OrbEvalData.cast()
            ..say('raft-flutter', evalCody, '@Sam 好吗？', mentions: [evalMe]),
      say: const ['打开动态'],
      checks: [
        OrbEvalCheck.custom('navigate worked', (run) {
          final calls = run.tools.where((c) => c.name == 'navigate');
          if (calls.isEmpty) return 'no navigate';
          final error = calls.first.result['error'];
          return error == null ? null : 'navigate said: $error';
        }),
        OrbEvalCheck.screen(
          'the fixture moved',
          (s, _) => s.location == '/s/fixture/activity',
        ),
      ],
    );
    final launcher = OrbEvalLauncher(
      debug: true,
      navigator: () => router.navigatorKey.currentState,
      pageBuilder: (_) => OrbEvalPage(
        scenarios: [scenario],
        runs: 1,
        sessionFactory: sessions.factory((s, text) async {
          await s.turn(const [
            ('navigate', {'page': 'activity'}),
          ], '动态里有一条。');
        }),
        voiceKey: AgentVoiceKey.forTesting('test-key'),
        reportRoot: () async => reports,
        settle: const Duration(milliseconds: 50),
      ),
    );
    expect(launcher.receiveLink(Uri.parse('raft://orb-eval/run')), isTrue);
    await finishEvalRun(t);

    final report = readEvalReport(reports);
    expect(report['cancelled'], isNull, reason: 'the page stayed up');
    final result = (report['scenarios'] as List).single as Map;
    expect(result['failedChecks'], isEmpty, reason: '${result['results']}');
    expect(find.byKey(const ValueKey('orb-eval-verdict')), findsOneWidget);
    expect(router.currentConfiguration, before.$1);
    expect(real.workspace.location.toString(), before.$2);
    expect(platformRoutes.length, before.$3, reason: 'no route reported');
    expect(located.length, before.$4, reason: 'the outer router was not asked');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(real.dispose);
  });

  for (final own in [false, true]) {
    testWidgets('a WorkspaceView in a Navigator of its own '
        '${own ? 'leaves' : 'clears'} the host app\'s overlays '
        '(ownNavigator: $own)', (t) async {
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final other = (await t.runAsync(
        () => OrbEvalWorld.create(OrbEvalData.cast()),
      ))!;
      final guard = PrivateRouteGuard();
      final removals = Removals();
      final router = RaftAppRouter(
        home: (_) => const SizedBox(),
        onLocation: (_) async {},
        onRootBack: () async => false,
        observers: [guard, removals],
      );
      addTearDown(router.dispose);
      final provider = PlatformRouteInformationProvider(
        initialRouteInformation: RouteInformation(uri: Uri.parse('/')),
      );
      addTearDown(provider.dispose);
      await t.pumpWidget(
        MaterialApp.router(
          theme: raftTheme(RaftFamily.brutal),
          routerDelegate: router,
          routeInformationParser: const RaftAppRouteParser(),
          routeInformationProvider: provider,
        ),
      );
      await t.pump();
      // The host's own workspace has put its authority on the guard, and has
      // an overlay open (a dialog, a sheet).
      guard.scopeChanged('host-authority');
      router.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'host-overlay'),
          builder: (_) => const Text('host overlay'),
        ),
      );
      await t.pump(const Duration(seconds: 1));
      // Another workspace's view, in a Navigator of its own, shows a channel.
      router.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => withAppServices(
                WorkspaceView(
                  controller: other.workspace,
                  ownNavigator: own,
                  appearance: RaftAppearance(light: RaftFamily.brutal),
                  onAppearance: (_) async {},
                  onLogout: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump(const Duration(seconds: 1));
      unawaited(other.workspace.selectChannel(other.workspace.channels.first));
      await t.pump(const Duration(seconds: 2));
      expect(
        removals.names.contains('host-overlay'),
        !own,
        reason: 'the other view reported its authority to the host guard',
      );
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      await t.runAsync(other.dispose);
    });
  }
}

class Removals extends NavigatorObserver {
  final names = <String?>[];
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}
