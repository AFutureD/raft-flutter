import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../../private_route_guard.dart' show PrivateRouteGuard;
import '../../agent_mode/agent_thinking.dart';
import 'orb_eval_page.dart';
import 'orb_eval_result.dart' show OrbEvalHarness;

/// What a start request asks for.
class OrbEvalRequest {
  const OrbEvalRequest({
    this.only = const [],
    this.runs = 2,
    this.harness = OrbEvalHarness.realtime,
    this.thinking,
    this.model,
  });

  /// Scenario ids or groups (`B2`, `C`); all when empty.
  final List<String> only;
  final int runs;

  /// What drives the orb; `harness=agent` in the link picks the text agent.
  final OrbEvalHarness harness;

  /// `thinking=minimal|low|medium|high` for the text agent, for this run only;
  /// null: the Labs setting.
  final AgentThinking? thinking;

  /// `model=gemini-3.5-flash-lite` (or `provider/model` for `harness=genkit`)
  /// for the text agent, for this run only; null: the app picks a Flash Lite.
  final String? model;

  /// The request a `raft://orb-eval/run?only=A1,B2&runs=3&harness=agent` link
  /// makes; null for any other link.
  static OrbEvalRequest? fromLink(Uri uri) {
    if (uri.scheme != 'raft' || uri.host != 'orb-eval') return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 1 || segments.single != 'run') return null;
    final only = (uri.queryParameters['only'] ?? '')
        .split(RegExp('[,\\s]+'))
        .where((s) => s.isNotEmpty)
        .take(60)
        .toList();
    final runs = int.tryParse(uri.queryParameters['runs'] ?? '') ?? 2;
    final harness = OrbEvalHarness.values.firstWhere(
      (h) => h.name == (uri.queryParameters['harness'] ?? '').toLowerCase(),
      orElse: () => OrbEvalHarness.realtime,
    );
    return OrbEvalRequest(
      only: only,
      runs: runs.clamp(1, 5),
      harness: harness,
      thinking: AgentThinking.parse(uri.queryParameters['thinking']),
      model: _modelParam(uri.queryParameters['model']),
    );
  }
}

/// A model id from a link: letters, digits and `. - _ : /` only, so nothing
/// else rides into a request path.
String? _modelParam(String? value) {
  final id = value?.trim();
  if (id == null || id.isEmpty || id.length > 80) return null;
  return RegExp(r'^[A-Za-z0-9._:/-]+$').hasMatch(id) ? id : null;
}

/// How the evaluation is started in a debug build: from the Labs card or from
/// adb, with an explicit-component intent that carries a `raft://orb-eval/run`
/// link (the app's link stream hands it to [receiveLink]).
///
/// In any other build mode it does nothing: no link is taken and no page is
/// opened.
class OrbEvalLauncher {
  OrbEvalLauncher({bool? debug, this.pageBuilder, this.navigator})
    : debug = debug ?? kDebugMode;

  /// The launcher the app uses; tests put their own here and put it back.
  static OrbEvalLauncher instance = OrbEvalLauncher();

  /// What the page is (tests give a stand-in that does not run).
  final Widget Function(OrbEvalRequest request)? pageBuilder;

  /// Where the page opens: the app's outermost Navigator unless a test gives
  /// another.
  final NavigatorState? Function()? navigator;

  /// Whether this launcher works at all (debug builds).
  final bool debug;

  /// How many frames a link waits for the app's Navigator to exist (a link
  /// that starts the app arrives before it).
  static const maxWaitFrames = 600;

  OrbEvalRequest? _pending;
  bool _open = false;

  /// The request waiting for the app's Navigator.
  OrbEvalRequest? get pending => _pending;

  /// Whether the evaluation page is on screen.
  bool get isOpen => _open;

  NavigatorState? _navigator() {
    final given = navigator;
    if (given != null) return given();
    NavigatorState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        found = element.state as NavigatorState;
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  /// A link the app received. True when it was an evaluation link and was
  /// taken (the app then ignores it).
  bool receiveLink(Uri uri) {
    if (!debug) return false;
    final request = OrbEvalRequest.fromLink(uri);
    if (request == null) return false;
    open(request);
    return true;
  }

  /// Opens the page and starts the run. False when it cannot yet (no
  /// Navigator: it tries again every frame) or is already open.
  bool open(OrbEvalRequest request) {
    if (!debug || _open) return false;
    final state = _navigator();
    if (state == null) {
      _wait(request, 0);
      return false;
    }
    _pending = null;
    return openOn(state, request);
  }

  void _wait(OrbEvalRequest request, int frames) {
    if (frames >= maxWaitFrames) {
      _pending = null;
      return;
    }
    _pending = request;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      if (_open || !identical(_pending, request)) return;
      final state = _navigator();
      if (state == null) {
        _wait(request, frames + 1);
      } else {
        _pending = null;
        openOn(state, request);
      }
    });
    // ignore: raft_lints/avoid_unreviewed_idle_work -- Debug builds only; one frame per retry, at most maxWaitFrames, and none once the Navigator exists or the page is open.
    binding.scheduleFrame();
  }

  /// Opens the page on [state] (the Labs card has its own context).
  bool openOn(NavigatorState state, OrbEvalRequest request) {
    if (!debug || _open) return false;
    _open = true;
    state
        .push(
          MaterialPageRoute<void>(
            // The page is not the signed-in workspace's: a change of the real
            // workspace's authority (its channel list refreshing) must not
            // close it under a running evaluation.
            settings: const RouteSettings(
              name: PrivateRouteGuard.rootOwnedRoute,
            ),
            builder: (_) =>
                pageBuilder?.call(request) ??
                OrbEvalPage(
                  only: request.only,
                  runs: request.runs,
                  harness: request.harness,
                  thinking: request.thinking,
                  model: request.model,
                ),
          ),
        )
        .whenComplete(() => _open = false);
    return true;
  }
}

/// Labs card "Agent 评测（开发）": runs the whole evaluation. Debug builds
/// only.
class OrbEvalLabsCard extends StatelessWidget {
  const OrbEvalLabsCard({super.key, this.debug, this.launcher});

  static const title = 'Agent 评测（开发）';

  /// Overrides `kDebugMode` (tests).
  final bool? debug;
  final OrbEvalLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    if (!(debug ?? kDebugMode)) return const SizedBox.shrink();
    final t = RaftTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: RaftSpace.x4),
      child: RaftRecipeCard(
        padding: const EdgeInsets.all(RaftSpace.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RaftCssText(
              title,
              style: RaftTypography.body(
                t,
                size: 14,
                line: 20,
                weight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            const SizedBox(height: RaftSpace.x1),
            RaftCssText(
              '用真模型和测试数据跑一遍 Agent 悬浮球的场景并自动打分，'
              '报告存在应用文档目录的 orb-eval 里。需要已经填好语音 Key。',
              style: RaftTypography.body(t, size: 13, line: 18, color: t.muted),
            ),
            const SizedBox(height: RaftSpace.x3),
            RaftButton(
              key: const ValueKey('orb-eval-open'),
              label: '运行评测',
              onPressed: () => (launcher ?? OrbEvalLauncher.instance).openOn(
                Navigator.of(context),
                const OrbEvalRequest(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
