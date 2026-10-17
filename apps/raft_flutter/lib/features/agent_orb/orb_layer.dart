import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'briefing/orb_briefing_cards.dart';
import 'briefing/orb_briefing_models.dart' show OrbBriefing;
import 'orb_controller.dart';
import 'orb_driving.dart';
import 'orb_state.dart';
import 'orb_status.dart';
import 'orb_widget.dart';

/// The route of the orb's immersive layer: a full-screen, see-through layer
/// over the app (not a sheet, no panel). It fades in over [transitionDuration]
/// and out over [reverseTransitionDuration]; what it draws is the
/// [OrbLayer]'s, which reads the route's animation.
class OrbLayerRoute extends PopupRoute<void> {
  OrbLayerRoute({required this.orb});
  final OrbController orb;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => OrbLayer(controller: orb, animation: animation);
}

/// The scrim's darkness, the blur and where a swipe down lets go (frames 05
/// and 07).
const _scrimAlpha = .55, _blurSigma = 12.0, _closeAt = .25;
const _flingToClose = 700.0;

/// The immersive layer (design frames 05, 06, 07 and 10): the app behind it
/// is blurred and dimmed; the agent's latest line is the big text, the
/// briefing cards, the transcript and the tool lines are under it, the input
/// is at the bottom and the orb is docked at the bottom right with its call
/// pill.
///
/// A swipe down anywhere on it (while its text is scrolled to the top) pulls
/// it away: the content follows the finger, fades, and the scrim and the blur
/// lighten; past a quarter of the height, or with a downward fling, it closes,
/// else it springs back. A tap on the empty backdrop and Back close it too.
/// Closing it never hangs up the call.
class OrbLayer extends StatefulWidget {
  const OrbLayer({
    super.key,
    required this.controller,
    required this.animation,
  });
  final OrbController controller;

  /// 0 to 1 as the route opens.
  final Animation<double> animation;

  @override
  State<OrbLayer> createState() => _OrbLayerState();
}

class _OrbLayerState extends State<OrbLayer>
    with SingleTickerProviderStateMixin {
  /// How far the person has pulled the layer away, 0 (at rest) to 1 (gone), as
  /// a share of the screen's height.
  late final AnimationController pulled = AnimationController(vsync: this);
  final scroll = ScrollController();
  final focus = FocusNode();

  // The finger on the layer.
  int? _pointer;
  Offset _from = Offset.zero;
  bool _atTop = true, _decided = false, _pulling = false, _closing = false;
  VelocityTracker? _velocity;

  OrbController get c => widget.controller;

  @override
  void dispose() {
    pulled.dispose();
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  // ---- closing ----------------------------------------------------------------

  /// Slides the layer away, then closes it (the call is not touched).
  void _dismiss() {
    if (_closing) return;
    _closing = true;
    focus.unfocus();
    pulled
        .animateTo(
          1,
          // ds-allow: layer and spinner motion timing from the approved design frames
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeIn,
        )
        .whenComplete(() {
          if (mounted) c.closeLayer();
        });
  }

  void _springBack() {
    pulled.animateTo(
      0,
      // ds-allow: layer and spinner motion timing from the approved design frames
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
    );
  }

  void _down(PointerDownEvent e) {
    c.markOrbTouch();
    if (_pointer != null || _closing) return;
    _pointer = e.pointer;
    _from = e.position;
    _atTop = !scroll.hasClients || scroll.offset <= .5;
    _decided = _pulling = false;
    _velocity = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.position);
    pulled.stop();
  }

  void _move(PointerMoveEvent e, double height) {
    if (e.pointer != _pointer) return;
    _velocity?.addPosition(e.timeStamp, e.position);
    final d = e.position - _from;
    if (!_decided) {
      if (d.distance < kTouchSlop) return;
      _decided = true;
      // Down, and more down than sideways, from the top of the text.
      _pulling = _atTop && d.dy > 0 && d.dy > d.dx.abs() * 1.2;
    }
    if (_pulling) pulled.value = (d.dy / height).clamp(0.0, 1.0);
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final pulling = _pulling;
    _pulling = false;
    if (!pulling) return;
    final fling = e is PointerUpEvent
        ? (_velocity?.getVelocity().pixelsPerSecond.dy ?? 0)
        : 0.0;
    if (e is PointerUpEvent &&
        (pulled.value > _closeAt || fling > _flingToClose)) {
      _dismiss();
    } else {
      _springBack();
    }
  }

  // ---- build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = media.size.height;
    // Back with the keyboard up is for the keyboard; the next Back closes.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (focus.hasFocus) {
          focus.unfocus();
        } else {
          _dismiss();
        }
      },
      // ds-allow: a transparent Material gives the layer its text style; no panel is drawn
      child: Material(
        key: const ValueKey('orb-layer'),
        type: MaterialType.transparency,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _down,
          onPointerMove: (e) => _move(e, height),
          onPointerUp: _up,
          onPointerCancel: _up,
          child: AnimatedBuilder(
            animation: Listenable.merge([widget.animation, pulled]),
            child: _body(context, media),
            builder: (context, body) => _frame(context, media, body!),
          ),
        ),
      ),
    );
  }

  /// The blur, the scrim and the content, from how far the layer has opened
  /// and how far the person has pulled it away.
  Widget _frame(BuildContext context, MediaQueryData media, Widget body) {
    final open = Curves.easeOut.transform(widget.animation.value);
    final p = pulled.value;
    final scrim = _scrimAlpha * open * math.max(0.0, 1 - p * 1.557);
    final sigma = _blurSigma * open * math.max(0.0, 1 - p * 1.9);
    final fade = open * (1 - p * 1.43).clamp(0.0, 1.0);
    final down = p * media.size.height + (1 - open) * 28;
    final bottom = _bottom(media);
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: ColoredBox(
              key: const ValueKey('orb-layer-scrim'),
              // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
              color: Colors.black.withValues(alpha: scrim),
            ),
          ),
        ),
        // Whatever the content leaves empty is the backdrop: a tap closes.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _dismiss,
          child: const SizedBox.expand(),
        ),
        Transform.translate(
          offset: Offset(0, down),
          child: Opacity(
            key: const ValueKey('orb-layer-content'),
            opacity: fade,
            child: body,
          ),
        ),
        // The orb and its pill stay where they are while the layer goes.
        Positioned(
          right: _side,
          bottom: bottom,
          child: Opacity(
            opacity: open,
            child: KeyedSubtree(
              key: const ValueKey('orb-layer-dock'),
              child: _dock(context),
            ),
          ),
        ),
      ],
    );
  }

  static const _side = RaftSpace.x5;

  /// The bottom edge of the input and the orb: above the keyboard, else the
  /// system inset and a little air.
  double _bottom(MediaQueryData media) => media.viewInsets.bottom > 0
      ? media.viewInsets.bottom + RaftSpace.x2
      : media.padding.bottom + RaftSpace.x2;

  /// No pill while the orb is idle, unless it is driving.
  bool get _pillHidden =>
      c.state == OrbState.idle && c.endedCallLength == null && !c.driving;

  Widget _dock(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      ListenableBuilder(
        listenable: c,
        builder: (context, _) => _pillHidden
            ? const SizedBox.shrink()
            : Padding(
                // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                padding: EdgeInsets.only(
                  bottom: c.state == OrbState.idle ? RaftSpace.x3 : 28,
                ),
                child: OrbCallPill(controller: c, compact: true),
              ),
      ),
      OrbBall(controller: c),
    ],
  );

  /// The hint, the big line and the transcript, the input.
  Widget _body(BuildContext context, MediaQueryData media) {
    final t = RaftTokens.of(context);
    // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
    final quiet = Colors.white.withValues(alpha: .65);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _side,
        media.padding.top + RaftSpace.x2,
        _side,
        _bottom(media),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IgnorePointer(
            child: Column(
              children: [
                Container(
                  // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                  width: 36,
                  // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                  height: 4,
                  decoration: BoxDecoration(
                    // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
                    color: Colors.white.withValues(alpha: .5),
                    // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: RaftSpace.x1_5),
                ListenableBuilder(
                  listenable: c,
                  builder: (context, _) {
                    final hint = Text(
                      c.driving ? '向下划退出' : '向下划收起',
                      style: RaftTypography.body(
                        t,
                        size: 12,
                        line: 16,
                        weight: FontWeight.w600,
                        color: quiet,
                      ),
                    );
                    if (!c.driving) return hint;
                    return Row(
                      children: [
                        const OrbDrivingTag(),
                        const SizedBox(width: RaftSpace.x2),
                        Expanded(child: hint),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: const Alignment(0, -.25),
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) => SingleChildScrollView(
                  controller: scroll,
                  physics: const ClampingScrollPhysics(),
                  padding: EdgeInsets.only(
                    right: RaftSpace.x2,
                    // Room for the call pill that sits over the orb.
                    bottom: _pillHidden
                        ? RaftSpace.x2
                        : orbPillHeight + RaftSpace.x6 + RaftSpace.x3,
                  ),
                  child: _lines(context, t, quiet),
                ),
              ),
            ),
          ),
          _InputBar(controller: c, focus: focus),
        ],
      ),
    );
  }

  /// The big line (the briefing's sentence, or the agent's latest line), the
  /// cards, then what was said and done, the newest first.
  Widget _lines(BuildContext context, RaftTokens t, Color quiet) {
    final entries = c.entries;
    final briefing = c.shownBriefing;
    final driving = c.driving;
    // The agent's latest line, unless the person has spoken since.
    OrbEntry? headline;
    if (briefing == null || driving) {
      for (final e in entries.reversed) {
        if (e.kind == OrbEntryKind.user) break;
        if (e.kind == OrbEntryKind.agent) {
          headline = e;
          break;
        }
      }
    }
    // Driving: the agent's line, else the overview; one card, no transcript.
    final big = driving
        ? (headline?.text ?? briefing?.overview)
        : (briefing?.overview ?? headline?.text);
    final rest = [
      if (!driving)
        for (final e in entries.reversed)
          if (!identical(e, headline)) e,
    ];
    if (big == null && rest.isEmpty && briefing == null) {
      return Text(
        driving ? '驾驶模式：直接说就行，我一次只说一件' : '说点什么，或者长按球直接对话',
        style: RaftTypography.body(t, size: 15, line: 22, color: quiet),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (big != null)
          Padding(
            padding: const EdgeInsets.only(bottom: RaftSpace.x4),
            child: Text(
              big,
              // The card and its buttons must stay on the screen.
              maxLines: driving ? 2 : null,
              overflow: driving ? TextOverflow.ellipsis : null,
              key: briefing != null && !driving
                  ? const Key('orb-briefing-overview')
                  : const ValueKey('orb-layer-headline'),
              style: RaftTypography.heading(
                t,
                size: _bigSize(big, briefing != null && !driving),
                line: _bigSize(big, briefing != null && !driving) * 1.25,
                // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
                color: Colors.white,
              ),
            ),
          ),
        if (briefing != null && driving)
          Padding(
            padding: const EdgeInsets.only(bottom: RaftSpace.x3),
            child: _drivingCard(briefing),
          ),
        if (briefing != null && !driving)
          Padding(
            padding: const EdgeInsets.only(bottom: RaftSpace.x3),
            child: OrbBriefingCards(
              briefing: briefing,
              showOverview: false,
              onDark: true,
              onOpen: c.openBriefItemTapped,
            ),
          ),
        for (final entry in rest)
          Padding(
            padding: const EdgeInsets.only(bottom: RaftSpace.x3),
            child: _EntryView(entry: entry, quiet: quiet),
          ),
      ],
    );
  }

  /// Driving: the one item, its big button and the hints; "就这些" at the end.
  Widget _drivingCard(OrbBriefing briefing) {
    if (c.drivingDone) {
      return OrbDrivingDone(
        routineCount: briefing.routineCount,
        waitingTasks: briefing.waitingTasks,
      );
    }
    final item = c.drivingItems[c.drivingIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OrbDrivingCard(
          item: item,
          index: c.drivingIndex,
          total: c.drivingItems.length,
          onAct: () => c.openBriefItemTapped(item),
        ),
        const SizedBox(height: RaftSpace.x3),
        OrbDrivingHints(
          onNext: c.drivingNextTapped,
          onLater: c.drivingNextTapped,
        ),
      ],
    );
  }

  static double _bigSize(String text, bool briefing) {
    if (briefing) return 34;
    final n = text.runes.length;
    return n <= 24 ? 32 : (n <= 70 ? 24 : 19);
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry, required this.quiet});
  final OrbEntry entry;
  final Color quiet;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final body = RaftTypography.body(t, size: 14, line: 20);
    final room = MediaQuery.sizeOf(context).width * .8;
    switch (entry.kind) {
      case OrbEntryKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: room),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RaftSpace.x3,
                vertical: RaftSpace.x2,
              ),
              decoration: orbSurface(
                t,
                fill: t.brutal ? t.product.brutalYellow : null,
                radius: 12,
              ),
              child: Text(entry.text, style: body),
            ),
          ),
        );
      case OrbEntryKind.agent:
        // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
        return Text(entry.text, style: body.copyWith(color: Colors.white));
      case OrbEntryKind.activity:
      case OrbEntryKind.notice:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: RaftSpace.half),
              child: RaftIcon(
                entry.kind == OrbEntryKind.activity
                    ? RaftGlyph.check
                    : RaftGlyph.circleAlert,
                size: 14,
                color: quiet,
              ),
            ),
            const SizedBox(width: RaftSpace.x2),
            Expanded(
              child: Text(
                entry.text,
                style: RaftTypography.body(t, size: 13, line: 18, color: quiet),
              ),
            ),
          ],
        );
    }
  }
}

/// The text input and send, with a lane on the right where the orb docks.
class _InputBar extends StatelessWidget {
  const _InputBar({required this.controller, required this.focus});
  final OrbController controller;
  final FocusNode focus;

  void _send([String? _]) {
    final text = controller.draft;
    final said = text.text.trim();
    if (said.isEmpty) return;
    text.clear();
    controller.sendText(said);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: RaftSpace.x3),
      // The orb docks in the lane on the right.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: orbSize),
        child: Padding(
          padding: const EdgeInsets.only(right: orbSize + RaftSpace.x3),
          child: Row(
            children: [
              Expanded(
                child: RaftTextInput(
                  key: const ValueKey('orb-input'),
                  controller: controller.draft,
                  focusNode: focus,
                  hintText: '问点什么，或者直接说',
                  semanticLabel: 'Agent',
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                ),
              ),
              const SizedBox(width: RaftSpace.x2),
              RaftIconButton(
                key: const ValueKey('orb-send'),
                glyph: RaftGlyph.send,
                tooltip: 'Send',
                visualSize: 40,
                variant: RaftControlVariant.accent,
                onPressed: _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
