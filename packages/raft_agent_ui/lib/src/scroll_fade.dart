import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'agent_theme.dart';

/// From this window width agent mode lays out for a desktop: layers keep to a
/// readable column, handles move into the margin, the dock stays short.
const agentLayerWideWidth = 900.0;

/// The widest a layer's content (cards, rows, messages) gets on a desktop
/// window; the rest of the layer is margin.
const agentLayerContentWidth = 780.0;

/// The least margin on each side of that column on a desktop window: room for
/// the handle of a card ("②") so it never sits on the card.
const agentLayerGutter = 44.0;

/// Whether the window is wide enough for the desktop layout.
bool agentIsWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= agentLayerWideWidth;

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
  });

  final Widget Function(BuildContext context, ScrollController? controller)
  builder;
  final bool enabled;

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
                colors: [t.layer, t.layer.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
      ),
    );
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
          Positioned.fill(
            child: Scrollbar(
              controller: _controller,
              thumbVisibility: _before || _after,
              child: widget.builder(context, _controller),
            ),
          ),
          edge(top: true, shown: _before),
          edge(top: false, shown: _after),
        ],
      ),
    );
  }
}
