import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Single source of truth for the phone status bar colour.
///
/// Web draws the header surface up under the safe-area top. Native hosts do the
/// same by painting a strip of [MediaQuery.paddingOf] height; instead of every
/// page guessing the header colour, each top header wraps itself in a
/// [RaftStatusBarSource] with its real background and the host's
/// [RaftStatusBarStrip] picks, at paint time, the visible source that is
/// directly under the strip. When no header is flush with the strip the
/// host's fallback (the page background beneath it) is used.
class RaftStatusBarRegistry {
  final Set<_RenderStatusBarSource> _sources = {};
  final Set<_RenderStatusBarStrip> _strips = {};

  void _changed() {
    for (final strip in _strips) {
      strip.markNeedsPaint();
    }
  }
}

/// Owns a [RaftStatusBarRegistry] for the headers below it.
class RaftStatusBarScope extends StatefulWidget {
  const RaftStatusBarScope({super.key, required this.child});

  final Widget child;

  static RaftStatusBarRegistry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_StatusBarScope>()?.registry;

  @override
  State<RaftStatusBarScope> createState() => _RaftStatusBarScopeState();
}

class _RaftStatusBarScopeState extends State<RaftStatusBarScope> {
  final registry = RaftStatusBarRegistry();

  @override
  Widget build(BuildContext context) =>
      _StatusBarScope(registry: registry, child: widget.child);
}

class _StatusBarScope extends InheritedWidget {
  const _StatusBarScope({required this.registry, required super.child});

  final RaftStatusBarRegistry registry;

  @override
  bool updateShouldNotify(_StatusBarScope old) => old.registry != registry;
}

/// Hosts the status bar strip above [child] on phones (Android / iOS, top
/// inset > 0) and owns the registry the headers below publish to.
///
/// Nested hosts collapse into the outermost one, so a self-hosting page
/// (for example `RaftAuthShell`) can sit inside an app host without painting a
/// second strip over the first. [expand] forces [child] to fill the host, like
/// a `Scaffold` body; otherwise the host shrink-wraps its child.
class RaftStatusBarHost extends StatelessWidget {
  const RaftStatusBarHost({
    super.key,
    required this.fallback,
    required this.child,
    this.expand = false,
    this.styleFor = RaftStatusBarStrip.defaultStyleFor,
  });

  final Color fallback;
  final Widget child;
  final bool expand;
  final SystemUiOverlayStyle Function(Color color) styleFor;

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    if (!_supported ||
        top <= 0 ||
        RaftStatusBarScope.maybeOf(context) != null) {
      return child;
    }
    return RaftStatusBarScope(
      child: Stack(
        fit: expand ? StackFit.expand : StackFit.passthrough,
        children: [
          child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: top,
            child: RaftStatusBarStrip(fallback: fallback, styleFor: styleFor),
          ),
        ],
      ),
    );
  }
}

/// Publishes [color] as the status bar colour while this widget is a visible
/// top header (flush with the host's strip). Wrap the widget that actually
/// paints the header background; it adds no layout or paint of its own.
class RaftStatusBarSource extends SingleChildRenderObjectWidget {
  const RaftStatusBarSource({
    super.key,
    required this.color,
    required Widget super.child,
  });

  final Color color;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderStatusBarSource(color, RaftStatusBarScope.maybeOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderStatusBarSource renderObject,
  ) => renderObject
    ..color = color
    ..registry = RaftStatusBarScope.maybeOf(context);
}

class _RenderStatusBarSource extends RenderProxyBox {
  _RenderStatusBarSource(this._color, this._registry);

  Color _color;
  RaftStatusBarRegistry? _registry;

  Color get color => _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    _registry?._changed();
  }

  set registry(RaftStatusBarRegistry? value) {
    if (identical(value, _registry)) return;
    if (attached) _registry?._sources.remove(this);
    _registry = value;
    if (attached) _registry?._sources.add(this);
    _registry?._changed();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _registry?._sources.add(this);
    _registry?._changed();
  }

  @override
  void detach() {
    _registry?._sources.remove(this);
    _registry?._changed();
    super.detach();
  }

  @override
  void performLayout() {
    final before = hasSize ? size : null;
    super.performLayout();
    if (before != size) _registry?._changed();
  }
}

/// Paints the status bar region with the colour of the header under it and
/// annotates it with an icon brightness that contrasts with that colour.
/// Sits above the page in a [Stack]; it must be a descendant of the
/// [RaftStatusBarScope] its headers register with.
class RaftStatusBarStrip extends LeafRenderObjectWidget {
  const RaftStatusBarStrip({
    super.key,
    required this.fallback,
    this.styleFor = defaultStyleFor,
  });

  /// Colour of the page directly under the strip when no header is flush.
  final Color fallback;

  /// Maps the resolved strip colour to the system overlay style.
  final SystemUiOverlayStyle Function(Color color) styleFor;

  static SystemUiOverlayStyle defaultStyleFor(Color color) {
    final dark = color.computeLuminance() < .5;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      systemStatusBarContrastEnforced: false,
    );
  }

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderStatusBarStrip(
        fallback,
        styleFor,
        RaftStatusBarScope.maybeOf(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderStatusBarStrip renderObject,
  ) => renderObject
    ..update(fallback, styleFor)
    ..registry = RaftStatusBarScope.maybeOf(context);
}

class _RenderStatusBarStrip extends RenderBox {
  _RenderStatusBarStrip(this._fallback, this._styleFor, this._registry);

  Color _fallback;
  SystemUiOverlayStyle Function(Color) _styleFor;
  RaftStatusBarRegistry? _registry;

  void update(Color fallback, SystemUiOverlayStyle Function(Color) styleFor) {
    if (fallback == _fallback && styleFor == _styleFor) return;
    _fallback = fallback;
    _styleFor = styleFor;
    markNeedsPaint();
  }

  set registry(RaftStatusBarRegistry? value) {
    if (identical(value, _registry)) return;
    if (attached) _registry?._strips.remove(this);
    _registry = value;
    if (attached) _registry?._strips.add(this);
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _registry?._strips.add(this);
  }

  @override
  void detach() {
    _registry?._strips.remove(this);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.biggest.isFinite ? constraints.biggest : constraints.smallest;

  @override
  bool hitTestSelf(Offset position) => false;

  static bool _hidden(RenderObject box) {
    for (RenderObject? p = box.parent; p != null; p = p.parent) {
      if (p is RenderOffstage && p.offstage) return true;
    }
    return false;
  }

  /// Colour of the innermost visible source whose box is flush under the strip,
  /// and whether one was found (otherwise the fallback).
  ({Color color, bool fromSource}) resolution() {
    _RenderStatusBarSource? best;
    for (final source in _registry?._sources ?? const {}) {
      if (!source.attached || !source.hasSize || _hidden(source)) continue;
      final Offset topLeft;
      try {
        topLeft = source.localToGlobal(Offset.zero, ancestor: this);
      } catch (_) {
        continue;
      }
      final bottom = topLeft.dy + source.size.height;
      final covers =
          topLeft.dx <= size.width / 2 &&
          topLeft.dx + source.size.width >= size.width / 2;
      // Flush: starts at or above the strip's bottom edge and extends below it.
      if (!covers || topLeft.dy > size.height + 1 || bottom <= size.height) {
        continue;
      }
      if (best == null || source.depth >= best.depth) best = source;
    }
    return best == null
        ? (color: _fallback, fromSource: false)
        : (color: Color.alphaBlend(best.color, _fallback), fromSource: true);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final color = resolution().color;
    context.canvas.drawRect(offset & size, Paint()..color = color);
    context.pushLayer(
      AnnotatedRegionLayer<SystemUiOverlayStyle>(
        _styleFor(color),
        size: size,
        offset: offset,
      ),
      (context, offset) {},
      offset,
    );
  }
}

/// Test hook: what a [RaftStatusBarStrip] currently resolves.
@visibleForTesting
({Color color, bool fromSource}) raftStatusBarResolution(RenderObject strip) =>
    (strip as _RenderStatusBarStrip).resolution();

/// Test hook: the colour a [RaftStatusBarStrip] currently resolves.
@visibleForTesting
Color raftStatusBarResolvedColor(RenderObject strip) =>
    raftStatusBarResolution(strip).color;
