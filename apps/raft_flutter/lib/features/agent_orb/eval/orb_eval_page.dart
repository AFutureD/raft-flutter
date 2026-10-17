import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:raft_ui/raft_ui.dart';

import '../../../data/workspace_controller.dart';
import '../../../platform/app_services.dart';
import '../../agent_mode/voice_provider.dart';
import '../../agent_mode/agent_audio.dart';
import '../../workspace_view.dart';
import 'orb_eval_report.dart';
import 'orb_eval_result.dart';
import 'orb_eval_runner.dart';
import 'orb_eval_scenario.dart';
import 'orb_eval_scenarios.dart';

/// Where reports go: `orb-eval` in the app's documents directory (on Android
/// `app_flutter/orb-eval`).
Future<Directory> orbEvalReportRoot() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/orb-eval');
}

/// The evaluation: runs scenarios against the real model on fixture data and
/// shows the progress and then the result. While a scenario runs, the app's
/// own phone shell over the fixture workspace is on screen, so what the orb
/// does can be watched.
///
/// Debug builds only: [OrbEvalLauncher] and the Labs card are the way in.
class OrbEvalPage extends StatefulWidget {
  const OrbEvalPage({
    super.key,
    this.only = const [],
    this.runs = 2,
    this.autoStart = true,
    this.scenarios,
    this.sessionFactory,
    this.voiceKey,
    this.reportRoot = orbEvalReportRoot,
    this.settle = const Duration(milliseconds: 1200),
    this.turnTimeout = const Duration(seconds: 45),
  });

  /// Scenario ids or groups (`B2`, `C`); all when empty.
  final List<String> only;
  final int runs;
  final bool autoStart;

  /// Tests give their own scenarios, session and key.
  final List<OrbEvalScenario>? scenarios;
  final VoiceSessionFactory? sessionFactory;
  final AgentVoiceKey? voiceKey;
  final Future<Directory> Function() reportRoot;
  final Duration settle;
  final Duration turnTimeout;

  @override
  State<OrbEvalPage> createState() => _OrbEvalPageState();
}

class _OrbEvalPageState extends State<OrbEvalPage> implements OrbEvalStage {
  final _navigator = GlobalKey<NavigatorState>();
  WorkspaceController? _workspace;
  OrbEvalRunner? _runner;
  OrbEvalProgress? _progress;
  OrbEvalReport? _report;
  Directory? _folder;
  String? _problem;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    _runner?.stop();
    super.dispose();
  }

  Future<void> _start() async {
    if (_running || !mounted) return;
    final scenarios = widget.scenarios ?? orbEvalSelect(widget.only);
    final runner = OrbEvalRunner(
      stage: this,
      runs: widget.runs,
      settle: widget.settle,
      turnTimeout: widget.turnTimeout,
      sessionFactory: widget.sessionFactory,
      voiceKey: widget.voiceKey,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    setState(() {
      _runner = runner;
      _running = true;
      _report = null;
      _folder = null;
      _problem = null;
    });
    try {
      final report = await runner.runAll(scenarios);
      final folder = await writeOrbEvalReport(
        report,
        await widget.reportRoot(),
      );
      debugPrint('orb-eval: report written to ${folder.path}');
      if (!mounted) return;
      setState(() {
        _report = report;
        _folder = folder;
      });
    } catch (e) {
      debugPrint('orb-eval: failed ${e.runtimeType}');
      if (mounted) setState(() => _problem = '评测没能完成：${e.runtimeType}');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _workspace = null;
        });
      }
    }
  }

  // ---- the stage -----------------------------------------------------------

  @override
  Future<OrbEvalSite> mount(WorkspaceController workspace) async {
    if (!mounted) throw StateError('closed');
    setState(() => _workspace = workspace);
    await WidgetsBinding.instance.endOfFrame;
    return _PageSite(this);
  }

  Future<void> _unmount() async {
    if (!mounted) return;
    setState(() => _workspace = null);
    await WidgetsBinding.instance.endOfFrame;
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final workspace = _workspace;
    return PopScope(
      canPop: !_running,
      child: Scaffold(
        body: Stack(
          children: [
            if (workspace != null)
              Positioned.fill(child: _fixtureApp(workspace))
            else
              Positioned.fill(child: _panel(context)),
            if (workspace != null) _banner(context),
          ],
        ),
      ),
    );
  }

  /// The app's phone shell over the scenario's workspace, in its own
  /// Navigator (the orb's layer opens on it).
  Widget _fixtureApp(WorkspaceController workspace) => MaterialApp(
    key: const ValueKey('orb-eval-app'),
    navigatorKey: _navigator,
    debugShowCheckedModeBanner: false,
    theme: raftTheme(RaftFamily.brutal),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: AppServicesScope(
      services: const AppServices.updatesDisabledForTestOrPreview(),
      child: WorkspaceView(
        key: ValueKey(workspace),
        controller: workspace,
        appearance: RaftAppearance(light: RaftFamily.brutal),
        onAppearance: (_) async {},
        onLogout: () async {},
      ),
    ),
  );

  Widget _banner(BuildContext context) {
    final p = _progress;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: SafeArea(
        bottom: false,
        child: Material(
          color: Colors.black87,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    p == null
                        ? '评测准备中…'
                        : '评测 ${p.scenario.id} · 第 ${p.run}/${p.runs} 次 · '
                              '${p.index}/${p.total}',
                    key: const ValueKey('orb-eval-progress'),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                TextButton(
                  key: const ValueKey('orb-eval-stop'),
                  onPressed: _runner?.stop,
                  child: const Text('停止'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final report = _report;
    final children = <Widget>[
      Text('Agent 评测（开发）', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
    ];
    if (_running) {
      final p = _progress;
      children.add(
        Text(
          p == null ? '评测准备中…' : '评测 ${p.scenario.id}（${p.index}/${p.total}）…',
          key: const ValueKey('orb-eval-progress'),
        ),
      );
      children.add(const SizedBox(height: 12));
      children.add(
        RaftButton(
          key: const ValueKey('orb-eval-stop'),
          label: '停止',
          onPressed: _runner?.stop,
        ),
      );
    } else if (report != null) {
      children.addAll(_result(context, report));
    } else {
      if (_problem != null) children.add(Text(_problem!));
      children
        ..add(const Text('用真模型和测试数据把场景跑一遍，自动打分。需要已经填好语音 Key。'))
        ..add(const SizedBox(height: 12))
        ..add(
          RaftButton(
            key: const ValueKey('orb-eval-run'),
            label: '运行评测',
            onPressed: _start,
          ),
        );
    }
    return SafeArea(
      child: ListView(padding: const EdgeInsets.all(16), children: children),
    );
  }

  List<Widget> _result(BuildContext context, OrbEvalReport report) {
    String mark(OrbEvalOutcome o) => switch (o) {
      OrbEvalOutcome.passed => '通过',
      OrbEvalOutcome.flaky => '不稳定',
      OrbEvalOutcome.failed => '失败',
      OrbEvalOutcome.skipped => '跳过',
      OrbEvalOutcome.expectedFail => '预期失败',
      OrbEvalOutcome.unexpectedPass => '意外通过',
    };
    return [
      Text(
        report.ok ? '评测通过' : '评测有失败',
        key: const ValueKey('orb-eval-verdict'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Text(
        '通过 ${report.count(OrbEvalOutcome.passed)} · '
        '不稳定 ${report.count(OrbEvalOutcome.flaky)} · '
        '失败 ${report.count(OrbEvalOutcome.failed)} · '
        '跳过 ${report.count(OrbEvalOutcome.skipped)} · '
        '预期失败 ${report.count(OrbEvalOutcome.expectedFail)}',
      ),
      if (_folder != null) SelectableText('报告：${_folder!.path}'),
      const SizedBox(height: 8),
      for (final r in report.results)
        ExpansionTile(
          key: ValueKey('orb-eval-${r.scenario.id}'),
          title: Text('${r.scenario.id} ${r.scenario.title}'),
          subtitle: Text(
            r.runs.isEmpty
                ? mark(r.outcome)
                : '${mark(r.outcome)} · ${r.passes}/${r.runs.length}',
          ),
          children: [
            for (final e in r.failedChecks.entries)
              ListTile(dense: true, title: Text(e.key)),
            if (r.runs.isNotEmpty)
              ListTile(
                dense: true,
                title: Text(
                  r.runs.first.run.text.isEmpty
                      ? '（没有说话）'
                      : r.runs.first.run.text,
                ),
              ),
          ],
        ),
      const SizedBox(height: 12),
      RaftButton(
        key: const ValueKey('orb-eval-again'),
        label: '再跑一次',
        onPressed: _start,
      ),
    ];
  }
}

class _PageSite implements OrbEvalSite {
  _PageSite(this._state);
  final _OrbEvalPageState _state;

  @override
  BuildContext? navigatorContext() =>
      _state._navigator.currentState?.overlay?.context;

  @override
  Future<void> unmount() => _state._unmount();
}
