import 'package:flutter/material.dart';

import 'agent_theme.dart';

/// One result layer on the Z axis. [key] identifies the layer across pushes
/// and pops so a layer keeps its state while it moves back and forth.
@immutable
class ZLayer {
  const ZLayer({required this.key, required this.peek, required this.child});
  final Key key;

  /// Short label shown on the strip a layer leaves visible when it is behind.
  final String peek;
  final Widget child;
}

/// Results stacked along the axis perpendicular to the screen.
///
/// The last entry of [layers] is in front. Adding an entry floats it forward
/// from slightly behind while the old front layer recedes; removing the front
/// entry sends it toward the viewer and fades it while the next one returns.
/// Only the front layer takes input; tapping a peek strip calls [onReveal]
/// with that layer's index.
class ZLayerStack extends StatefulWidget {
  const ZLayerStack({
    super.key,
    required this.layers,
    this.onReveal,
    this.padding = EdgeInsets.zero,
  });

  final List<ZLayer> layers;
  final ValueChanged<int>? onReveal;
  final EdgeInsets padding;

  @override
  State<ZLayerStack> createState() => _ZLayerStackState();
}

class _ZLayerStackState extends State<ZLayerStack> {
  /// Layers that left the stack and are still animating toward the viewer.
  final _leaving = <ZLayer>[];

  @override
  void didUpdateWidget(ZLayerStack old) {
    super.didUpdateWidget(old);
    final kept = {for (final l in widget.layers) l.key};
    for (final l in old.layers) {
      if (!kept.contains(l.key) && !_leaving.any((x) => x.key == l.key)) {
        _leaving.add(l);
      }
    }
    _leaving.removeWhere((l) => kept.contains(l.key));
  }

  @override
  Widget build(BuildContext context) {
    final theme = RaftAgentTheme.of(context);
    final front = widget.layers.length - 1;
    return Padding(
      padding: widget.padding,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < widget.layers.length; i++)
            if (front - i <= theme.visibleBehind)
              Positioned.fill(
                key: widget.layers[i].key,
                child: _ZLayerView(
                  layer: widget.layers[i],
                  depth: (front - i).toDouble(),
                  enterFrom: i == front && i > 0 ? .45 : 0,
                  theme: theme,
                  onReveal: i == front - 1 && widget.onReveal != null
                      ? () => widget.onReveal!(i)
                      : null,
                ),
              ),
          for (final l in _leaving)
            Positioned.fill(
              key: l.key,
              child: _ZLayerView(
                layer: l,
                depth: -1,
                enterFrom: 0,
                theme: theme,
                onSettled: () {
                  if (mounted) setState(() => _leaving.remove(l));
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ZLayerView extends StatelessWidget {
  const _ZLayerView({
    required this.layer,
    required this.depth,
    required this.enterFrom,
    required this.theme,
    this.onReveal,
    this.onSettled,
  });

  final ZLayer layer;
  final double depth, enterFrom;
  final RaftAgentTheme theme;
  final VoidCallback? onReveal, onSettled;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: enterFrom == 0 ? depth : enterFrom, end: depth),
      duration: theme.duration,
      curve: theme.curve,
      onEnd: onSettled,
      builder: (context, d, child) {
        final behind = d.clamp(0, double.infinity).toDouble();
        final ahead = (-d).clamp(0, 1).toDouble();
        final scale =
            1 - theme.depthScale * behind + theme.leavingScale * ahead;
        final dy = -theme.depthOffset * behind + theme.leavingOffset * ahead;
        final opacity = (1 - theme.depthFade * behind - ahead)
            .clamp(0, 1)
            .toDouble();
        return IgnorePointer(
          ignoring: d.abs() > .05 && onReveal == null,
          child: Opacity(
            opacity: opacity,
            child: Transform(
              alignment: Alignment.topCenter,
              transform: Matrix4.identity()
                ..translateByDouble(0, dy, 0, 1)
                ..scaleByDouble(scale, scale, 1, 1),
              child: child,
            ),
          ),
        );
      },
      child: _LayerSurface(
        theme: theme,
        front: depth == 0,
        peek: depth >= 1 ? layer.peek : null,
        onReveal: onReveal,
        child: layer.child,
      ),
    );
  }
}

class _LayerSurface extends StatelessWidget {
  const _LayerSurface({
    required this.theme,
    required this.front,
    required this.child,
    this.peek,
    this.onReveal,
  });

  final RaftAgentTheme theme;
  final bool front;
  final String? peek;
  final VoidCallback? onReveal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(theme.layerRadius);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: front ? theme.layer : theme.backLayer,
        borderRadius: radius,
        border: Border.all(color: theme.line, width: theme.border),
        boxShadow: front ? theme.topShadow : theme.layerShadow,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: peek == null
            ? child
            : Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  child: Text(
                    '‹  $peek',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.body(13, color: theme.muted),
                  ),
                ),
              ),
      ),
    );
    if (onReveal == null) return surface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onReveal,
      child: Semantics(button: true, label: peek, child: surface),
    );
  }
}
