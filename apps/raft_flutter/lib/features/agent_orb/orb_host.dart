import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:raft_ui/raft_ui.dart';

import '../../data/workspace_controller.dart';
import 'orb_avoidance.dart';
import 'orb_controller.dart';
import 'orb_preference.dart';
import 'orb_state.dart';
import 'orb_widget.dart';

/// Builds the orb's session for a workspace. [navigatorContext] is a context
/// under the app's Navigator (null before the first frame has one).
typedef OrbControllerFactory = OrbController Function(
  WorkspaceController workspace,
  BuildContext? Function() navigatorContext,
);

/// The Agent orb above every phone page. Put it in `MaterialApp.builder`
/// around the app's Navigator, so it floats over pushed pages and sheets too:
///
/// ```dart
/// builder: (context, child) => AgentOrbHost(
///   workspace: workspace,
///   navigatorKey: appRouter.navigatorKey,
///   child: child!,
/// )
/// ```
///
/// It adds nothing while the Labs switch is off, the window is not a phone
/// layout (compact), there is no workspace yet, or in release builds; the
/// child keeps the same place in the tree either way, so switching the orb on
/// or off never rebuilds the app under it.
class AgentOrbHost extends StatefulWidget {
  const AgentOrbHost({
    super.key,
    required this.child,
    required this.navigatorKey,
    this.workspace,
    this.avoidance,
    this.createController,
  });

  /// The app (the Navigator).
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  /// The signed-in workspace, or null (no orb then).
  final WorkspaceController? workspace;

  /// What the orb keeps clear of; the phone tab bar and the composer by
  /// default.
  final OrbAvoidance? avoidance;

  /// Tests build the session with fakes.
  final OrbControllerFactory? createController;

  @override
  State<AgentOrbHost> createState() => _AgentOrbHostState();
}

class _AgentOrbHostState extends State<AgentOrbHost> {
  final _pref = AgentOrbPreference.instance;
  OrbController? _controller;
  WorkspaceController? _controllerFor;
  late OrbAvoidance _avoidance = widget.avoidance ?? OrbAvoidance.app();
  List<Rect> _obstacles = const [];
  bool _measureQueued = false;
  Timer? _measureTimer;

  // Where the person left the orb: the side, and how far down (null: resting
  // at the bottom). [_drag] is its top-left while a finger holds it.
  bool _onRight = true;
  double? _y;
  Offset? _drag;

  @override
  void initState() {
    super.initState();
    _pref.addListener(_prefChanged);
  }

  @override
  void didUpdateWidget(AgentOrbHost old) {
    super.didUpdateWidget(old);
    if (widget.avoidance != old.avoidance) {
      _avoidance = widget.avoidance ?? OrbAvoidance.app();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The window, the keyboard or the insets changed: measure again.
    if (_controller != null) _measureAfterFrame();
  }

  @override
  void dispose() {
    _pref.removeListener(_prefChanged);
    _measureTimer?.cancel();
    widget.workspace?.removeListener(_workspaceChanged);
    _retire(_controller);
    _controller = null;
    super.dispose();
  }

  void _prefChanged() {
    if (mounted) setState(() {});
  }

  void _workspaceChanged() => _measureLater(const Duration(milliseconds: 150));

  void _retire(OrbController? c) {
    if (c == null) return;
    // Its listeners (the layers) go away in this frame; close its sheet and
    // dispose after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      c.closeSheet();
      c.dispose();
    });
  }

  /// Makes the session when the orb is on and drops it when it is off.
  OrbController? _sync(BuildContext context) {
    final w = widget.workspace;
    final active =
        !kReleaseMode &&
        _pref.enabled &&
        w != null &&
        RaftAdaptiveWorkspace.compactOf(context);
    if (!active) {
      if (_controller != null) {
        _controllerFor?.removeListener(_workspaceChanged);
        _retire(_controller);
        _controller = null;
        _controllerFor = null;
      }
      return null;
    }
    if (_controller == null || !identical(_controllerFor, w)) {
      _controllerFor?.removeListener(_workspaceChanged);
      _retire(_controller);
      final nav = widget.navigatorKey;
      BuildContext? navigatorContext() => nav.currentState?.overlay?.context;
      _controller =
          (widget.createController ??
          (w, nav) => OrbController(workspace: w, navigatorContext: nav))(
            w,
            navigatorContext,
          );
      _controllerFor = w..addListener(_workspaceChanged);
      _measureAfterFrame();
    }
    return _controller;
  }

  // ---- measuring what to keep clear of -------------------------------------

  void _measureAfterFrame() {
    if (_measureQueued) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      _measure();
    });
    // ignore: raft_lints/avoid_unreviewed_idle_work -- One frame request per queued measure; the callback only rebuilds when the obstacles changed and requests nothing else.
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _measureLater(Duration delay) {
    _measureTimer?.cancel();
    _measureTimer = Timer(delay, _measure);
  }

  void _measure() {
    if (!mounted || _controller == null) return;
    final found = _avoidance.obstacles(context);
    if (!listEquals(found, _obstacles)) setState(() => _obstacles = found);
  }

  // ---- placement ------------------------------------------------------------

  static const _margin = RaftSpace.x3;
  static const _glide = Duration(milliseconds: 180);

  /// The highest and lowest top the orb may have.
  (double, double) _yRange(MediaQueryData media) {
    final top = media.padding.top + _margin;
    var floor =
        media.size.height -
        math.max(media.viewInsets.bottom, media.padding.bottom) -
        _margin;
    for (final r in _obstacles) {
      floor = math.min(floor, r.top - _margin);
    }
    return (top, math.max(top, floor - orbSize));
  }

  void _panStart(DragStartDetails d, Offset at) => setState(() => _drag = at);

  void _panUpdate(DragUpdateDetails d, MediaQueryData media) {
    final (top, bottom) = _yRange(media);
    final from = _drag;
    if (from == null) return;
    final next = from + d.delta;
    setState(
      () => _drag = Offset(
        next.dx.clamp(0, media.size.width - orbSize),
        next.dy.clamp(top, bottom),
      ),
    );
  }

  void _panEnd(MediaQueryData media) {
    final at = _drag;
    if (at == null) return;
    setState(() {
      _onRight = at.dx + orbSize / 2 > media.size.width / 2;
      _y = at.dy;
      _drag = null;
    });
    _measureAfterFrame();
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = _sync(context);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _controller?.appTouched(),
          // A tap may have changed the page: measure once it has settled.
          onPointerUp: (_) {
            if (_controller != null) {
              _measureLater(const Duration(milliseconds: 450));
            }
          },
          child: widget.child,
        ),
        if (c != null)
          Positioned.fill(
            child: DefaultTextStyle(
              style: RaftTypography.body(RaftTokens.of(context)),
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) => _layers(context, c),
              ),
            ),
          ),
      ],
    );
  }

  Widget _layers(BuildContext context, OrbController c) {
    final t = RaftTokens.of(context);
    final media = MediaQuery.of(context);
    final width = media.size.width, height = media.size.height;
    final (top, bottom) = _yRange(media);
    final y = _drag?.dy ?? (_y == null ? bottom : _y!.clamp(top, bottom));
    final x = _drag?.dx ?? (_onRight ? width - _margin - orbSize : _margin);
    final state = c.state;
    final operating = c.operating.value;
    final chip = orbStatusChip(context, state, connecting: c.connecting);
    final pill = c.listeningText ?? (state == OrbState.idle ? c.notice : null);
    final accent = t.brutal ? t.product.brutalCyan : t.accent;
    final side = _onRight ? Alignment.centerRight : Alignment.centerLeft;
    final maxWide = math.min(300.0, width - _margin * 2);
    final besideRoom = width - orbSize - _margin * 3;

    final above = <Widget>[
      if (pill != null)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWide),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RaftSpace.x3,
              vertical: RaftSpace.x2,
            ),
            decoration: orbSurface(t, radius: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.listeningText != null) ...[
                  OrbWaveBars(
                    color: t.brutal ? t.product.brutalPink : t.accent,
                    height: 16,
                  ),
                  const SizedBox(width: RaftSpace.x2),
                ],
                Flexible(
                  child: Text(
                    c.listeningText == null ? pill : '“$pill”',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: RaftTypography.body(
                      t,
                      size: 14,
                      line: 20,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      if (state == OrbState.operating && chip != null) chip,
    ];

    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (operating)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('orb-operating-frame'),
                decoration: BoxDecoration(
                  border: Border.all(color: accent, width: RaftSpace.x1),
                ),
              ),
            ),
          ),
        if (operating)
          Positioned(
            top: media.padding.top + 56,
            left: _margin,
            right: _margin,
            child: IgnorePointer(
              child: Semantics(
                liveRegion: true,
                child: Center(
                  child: RaftToast(
                    key: const ValueKey('orb-operating-toast'),
                    title: c.operating.label == null
                        ? 'Agent 正在操作 · 点屏幕即可接管'
                        : 'Agent 打开了 ${c.operating.label} · 点屏幕即可接管',
                    tone: RaftToastRecipeTone.info,
                    icon: true,
                  ),
                ),
              ),
            ),
          ),
        if (!c.sheetOpen) ...[
          if (above.isNotEmpty)
            Positioned(
              bottom: height - y + RaftSpace.x2,
              left: _onRight ? null : _margin,
              right: _onRight ? _margin : null,
              child: Align(
                alignment: side,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: _onRight
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    for (final (i, w) in above.indexed) ...[
                      if (i > 0) const SizedBox(height: RaftSpace.x2),
                      w,
                    ],
                  ],
                ),
              ),
            ),
          if (chip != null && state != OrbState.operating)
            Positioned(
              top: y + (orbSize - 28) / 2,
              left: _onRight ? null : x + orbSize + _margin,
              right: _onRight ? width - x + _margin : null,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: besideRoom),
                child: chip,
              ),
            ),
          AnimatedPositioned(
            duration: _drag == null ? _glide : Duration.zero,
            curve: Curves.easeOut,
            left: x,
            top: y,
            child: OrbBall(
              state: state,
              onTap: c.tapOrb,
              onLongPress: c.longPressOrb,
              onPanStart: (d) => _panStart(d, Offset(x, y)),
              onPanUpdate: (d) => _panUpdate(d, media),
              onPanEnd: (_) => _panEnd(media),
            ),
          ),
        ],
      ],
    );
  }
}
