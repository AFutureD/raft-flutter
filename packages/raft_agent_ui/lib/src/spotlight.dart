import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'marks.dart';

/// Which component the agent is talking about. [AgentFocusable] widgets with
/// that id lift out of the page and float above it until [release].
class AgentSpotlightController extends ChangeNotifier {
  String? _focused;
  String? get focused => _focused;

  void focus(String id) {
    if (_focused == id) return;
    _focused = id;
    notifyListeners();
  }

  void release() {
    if (_focused == null) return;
    _focused = null;
    notifyListeners();
  }

  /// Mirrors a focus received from elsewhere (e.g. the phone, on a TV).
  void sync(String? id) => id == null ? release() : focus(id);
}

class _Entry {
  _Entry(this.key, this.builder);
  final GlobalKey key;
  WidgetBuilder builder;
}

/// Hosts the spotlight for everything below it: focusable components
/// register here, and the lifted copy is drawn above [child].
class AgentSpotlight extends StatefulWidget {
  const AgentSpotlight({
    super.key,
    required this.controller,
    required this.child,
    this.maxWidth = 560,
  });

  final AgentSpotlightController controller;
  final Widget child;

  /// Width of the lifted component on wide screens.
  final double maxWidth;

  @override
  State<AgentSpotlight> createState() => _AgentSpotlightState();
}

class _AgentSpotlightState extends State<AgentSpotlight>
    with SingleTickerProviderStateMixin {
  final _entries = <String, _Entry>{};
  final _stackKey = GlobalKey();
  late final _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 320),
  );

  /// The component being shown (kept while it flies back).
  String? _shown;
  Rect? _origin;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _lift.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() => _shown = null);
        _changed();
      }
    });
  }

  @override
  void didUpdateWidget(AgentSpotlight old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _lift.dispose();
    super.dispose();
  }

  void _register(String id, GlobalKey key, WidgetBuilder builder) {
    final entry = _entries[id];
    if (entry != null && entry.key == key) {
      entry.builder = builder;
    } else {
      _entries[id] = _Entry(key, builder);
    }
  }

  void _unregister(String id, GlobalKey key) {
    if (_entries[id]?.key == key) _entries.remove(id);
  }

  Rect? _rectOf(String id) {
    final box = _entries[id]?.key.currentContext?.findRenderObject();
    final stack = _stackKey.currentContext?.findRenderObject();
    if (box is! RenderBox || stack is! RenderBox || !box.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: stack) & box.size;
  }

  void _changed() {
    if (!mounted) return;
    final want = widget.controller.focused;
    if (_shown != null && _shown != want) {
      // Fly the current one back first; the next follows on dismissal.
      _origin = _rectOf(_shown!) ?? _origin;
      _lift.reverse();
      return;
    }
    if (want == null || _shown == want) return;
    final rect = _rectOf(want);
    if (rect == null) return;
    setState(() {
      _shown = want;
      _origin = rect;
    });
    _lift.forward(from: 0);
  }

  bool _isLifted(String id) => _shown == id;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return _SpotlightScope(
      state: this,
      shown: _shown,
      child: Stack(
        key: _stackKey,
        children: [
          widget.child,
          if (_shown != null && _origin != null)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, box) {
                  final origin = _origin!;
                  // Always lift visibly, never wider than the screen.
                  final fit = box.maxWidth * .96 / origin.width;
                  final width = (box.maxWidth * .9).clamp(0, widget.maxWidth);
                  final scale = (width / origin.width)
                      .clamp(1.08, 1.6)
                      .clamp(1.0, fit < 1.0 ? 1.0 : fit);
                  final size = origin.size * scale;
                  final target = Rect.fromCenter(
                    center: box.biggest.center(Offset.zero),
                    width: size.width,
                    height: size.height,
                  );
                  final builder = _entries[_shown]?.builder;
                  return AnimatedBuilder(
                    animation: _lift,
                    builder: (context, _) {
                      final v = Curves.easeOutCubic.transform(_lift.value);
                      final rect = Rect.lerp(origin, target, v)!;
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              key: const ValueKey('agent-spotlight-scrim'),
                              onTap: widget.controller.release,
                              child: ColoredBox(
                                color: t.foreground.withValues(alpha: .32 * v),
                              ),
                            ),
                          ),
                          Positioned.fromRect(
                            rect: rect,
                            child: Transform.rotate(
                              angle: -.018 * v,
                              child: IgnorePointer(
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  alignment: Alignment.topLeft,
                                  child: SizedBox(
                                    width: origin.width,
                                    height: origin.height,
                                    child: builder == null
                                        ? const SizedBox.shrink()
                                        : Builder(builder: builder),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _SpotlightScope extends InheritedWidget {
  const _SpotlightScope({
    required this.state,
    required this.shown,
    required super.child,
  });
  final _AgentSpotlightState state;
  final String? shown;

  @override
  bool updateShouldNotify(_SpotlightScope old) => old.shown != shown;
}

/// A component the agent can point at: while focused it lifts out of the
/// page (its place stays reserved) and floats above everything.
class AgentFocusable extends StatefulWidget {
  const AgentFocusable({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  State<AgentFocusable> createState() => _AgentFocusableState();
}

class _AgentFocusableState extends State<AgentFocusable> {
  final _key = GlobalKey();
  _AgentSpotlightState? _host;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _host = context
        .dependOnInheritedWidgetOfExactType<_SpotlightScope>()
        ?.state;
  }

  @override
  void deactivate() {
    _host?._unregister(widget.id, _key);
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    final host = _host;
    if (host == null) {
      return AgentItemScope(id: widget.id, child: widget.child);
    }
    Widget scoped(Widget child) => AgentItemScope(id: widget.id, child: child);
    host._register(widget.id, _key, (_) => scoped(widget.child));
    return Opacity(
      key: _key,
      opacity: host._isLifted(widget.id) ? 0 : 1,
      child: scoped(widget.child),
    );
  }
}
