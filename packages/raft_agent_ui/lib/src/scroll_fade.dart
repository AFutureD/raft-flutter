import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'agent_theme.dart';

/// A scrolling body that shows there is more: a scrollbar that stays visible
/// and a soft fade on the edge where content is cut off, so a card or a
/// heading is never cropped mid-glyph without a hint.
///
/// [builder] gets the controller to hand to its scrollable (null when [enabled]
/// is off, and then nothing is added: the phone draws its list as it did).
class AgentScrollFade extends StatefulWidget {
  const AgentScrollFade({
    super.key,
    required this.builder,
    this.enabled = true,
    this.shrinkWrap = false,
    this.scrollbar = true,
    this.fadeColor,
  });

  final Widget Function(BuildContext context, ScrollController? controller)
  builder;
  final bool enabled;

  /// Take the height of the content when it is shorter than the room, rather
  /// than the whole room (a card that scrolls only when it must).
  final bool shrinkWrap;

  /// Whether to draw the scrollbar (a screen that is only looked at has no
  /// pointer to use one; it still gets the fade).
  final bool scrollbar;

  /// The colour the fade melts into: the background behind the content. The
  /// layer's own, by default.
  final Color? fadeColor;

  @override
  State<AgentScrollFade> createState() => _AgentScrollFadeState();
}

class _AgentScrollFadeState extends State<AgentScrollFade> {
  final _controller = ScrollController();
  bool _before = false, _after = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _changed(ScrollMetrics m) {
    final before = m.extentBefore > 1, after = m.extentAfter > 1;
    if (before == _before && after == _after) return false;
    void apply() {
      if (!mounted) return;
      setState(() {
        _before = before;
        _after = after;
      });
    }

    // A metrics notification may arrive while a frame is being laid out.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.builder(context, null);
    final t = RaftAgentTheme.of(context);
    final bg = widget.fadeColor ?? t.layer;
    Widget edge({required bool top, required bool shown}) => Positioned(
      top: top ? 0 : null,
      bottom: top ? null : 0,
      left: 0,
      right: 0,
      height: 40,
      child: IgnorePointer(
        child: AnimatedOpacity(
          key: ValueKey(top ? 'agent-fade-top' : 'agent-fade-bottom'),
          duration: const Duration(milliseconds: 150),
          opacity: shown ? 1 : 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                end: top ? Alignment.bottomCenter : Alignment.topCenter,
                colors: [bg, bg.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
      ),
    );
    final body = widget.builder(context, _controller);
    final scrolled = widget.scrollbar
        ? Scrollbar(
            controller: _controller,
            thumbVisibility: _before || _after,
            child: body,
          )
        : body;
    return NotificationListener<Notification>(
      onNotification: (n) {
        // Any scroll or size change below: read our own scrollable.
        if ((n is ScrollNotification || n is ScrollMetricsNotification) &&
            _controller.hasClients &&
            _controller.position.hasContentDimensions) {
          _changed(_controller.position);
        }
        return false;
      },
      child: Stack(
        children: [
          if (widget.shrinkWrap) scrolled else Positioned.fill(child: scrolled),
          edge(top: true, shown: _before),
          edge(top: false, shown: _after),
        ],
      ),
    );
  }
}
