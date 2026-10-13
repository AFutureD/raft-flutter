import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'attachment_lightbox.dart' show RaftLightboxStageInset;
import 'design_primitives.dart' show RaftInteractive;
import 'icons.dart';
import 'localization.dart';
import 'dialog_card.dart' show RaftShadowSet;
import 'theme.dart';

// Unified media browser visuals (phone immersive stage, strip, drag-to-dismiss,
// Hero route). Pure presentation: the host owns items, loading, sessions and
// sharing (docs/media-playback.md "Media browser").

/// Command-key helper of the media browser's keyboard map: Cmd on Apple
/// platforms, Ctrl elsewhere (Esc, Ctrl+W and Cmd+W stay bound on both, Web).
abstract final class RaftPlatformKeys {
  static bool get apple =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// `Cmd+key` on macOS / iOS, `Ctrl+key` on every other platform.
  static SingleActivator command(LogicalKeyboardKey key) =>
      SingleActivator(key, meta: apple, control: !apple);
}

/// Distance the stage follows the finger for a full scrim fade / 0.82 scale.
const raftMediaDismissDistance = 260.0;

/// Release past this offset (dp) or velocity (dp/s) closes the browser.
const raftMediaDismissOffset = 120.0;
const raftMediaDismissVelocity = 700.0;

/// Final scale of the stage at [raftMediaDismissDistance].
const raftMediaDismissScale = 0.82;

/// Height of the phone top bar below the status bar, and its touch targets.
const raftMediaTopBarRow = 56.0;
const raftMediaChromeTarget = 44.0;

/// Phone strip: 44 dp thumbnails in a [raftMediaStripBand] tall band.
const raftMediaPhoneThumb = 44.0;
const raftMediaStripBand = 56.0;

/// Desktop strip (`size-12` thumbnails, `bottom-4`, room above): the band the
/// stage keeps free above and below its centre line.
const raftMediaDesktopThumb = 48.0;
const raftMediaDesktopStripBand = 48.0 + 16 + 8;

/// Two caption lines (13 / 1.35) plus the shell's padding.
const raftMediaCaptionHeight = 62.0;

String raftMediaDuration(Duration value) {
  final seconds = value.inSeconds;
  final h = seconds ~/ 3600, m = seconds % 3600 ~/ 60, s = seconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

// ---------------------------------------------------------------- route

/// Route of the media browser: transparent and fading (the shell paints its
/// own scrim, the Hero flies the picture), so the page below shows through
/// while the scrim is not yet black and while a drag-to-dismiss fades it.
/// Once the open transition ends it turns opaque (the page below stops
/// painting); a drag makes it see-through again ([setTranslucent]).
class RaftMediaBrowserRoute<T> extends PageRoute<T> {
  RaftMediaBrowserRoute({
    required this.builder,
    this.reducedMotion = false,
    super.settings,
  });
  final WidgetBuilder builder;

  /// Reduced motion: an 80 ms cross-fade, no Hero (the host leaves it out).
  final bool reducedMotion;

  /// The browser route enclosing [context], if there is one.
  static RaftMediaBrowserRoute<dynamic>? maybeOf(BuildContext context) {
    final route = ModalRoute.of(context);
    return route is RaftMediaBrowserRoute ? route : null;
  }

  @override
  Duration get transitionDuration =>
      Duration(milliseconds: reducedMotion ? 80 : 300);

  @override
  Duration get reverseTransitionDuration =>
      Duration(milliseconds: reducedMotion ? 80 : 220);

  @override
  bool get opaque => true;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  /// While true the page below is built and painted even at rest (the scrim
  /// of a drag-to-dismiss fades over it).
  void setTranslucent(bool value) {
    final entries = overlayEntries;
    if (entries.isEmpty) return;
    entries.first.opaque = !value && (animation?.isCompleted ?? false);
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    // Text outside a Material falls back to the debug underline style.
    child: Material(type: MaterialType.transparency, child: builder(context)),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(
    opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
    child: child,
  );
}

// ----------------------------------------------------------------- hero

/// The picture that flies between a message card and the browser stage. The
/// shuttle shows [image] cropped like the card (cover) in the interpolated
/// rect and rounds from [radius] to square, so the card's bitmap never
/// flashes or stretches.
class RaftMediaHero extends StatelessWidget {
  const RaftMediaHero({
    super.key,
    required this.tag,
    required this.child,
    this.image,
    this.radius = BorderRadius.zero,
  });
  final Object tag;
  final Widget child;

  /// The bitmap of the shuttle; without it the hero child is used as is.
  final ImageProvider? image;

  /// The corner radius of this end of the flight (the card's; the stage is
  /// square).
  final BorderRadius radius;

  static BorderRadius _radiusOf(BuildContext heroContext) =>
      heroContext.findAncestorWidgetOfExactType<RaftMediaHero>()?.radius ??
      BorderRadius.zero;

  @override
  Widget build(BuildContext context) => Hero(
    tag: tag,
    flightShuttleBuilder: image == null
        ? null
        : (flight, animation, direction, from, to) {
            // The card end rounds, the stage end is square.
            final card = _radiusOf(from) == BorderRadius.zero
                ? _radiusOf(to)
                : _radiusOf(from);
            return AnimatedBuilder(
              animation: animation,
              builder: (context, _) => ClipRRect(
                key: const ValueKey('media-hero-shuttle'),
                borderRadius: BorderRadius.lerp(
                  card,
                  BorderRadius.zero,
                  animation.value,
                )!,
                // ignore: raft_lints/avoid_raw_image_decode -- The shuttle paints the host's already decoded card / stage bitmap.
                child: Image(
                  image: image!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            );
          },
    child: child,
  );
}

// ---------------------------------------------------------------- strip

/// One thumbnail of [RaftMediaStrip]. Videos carry a play badge with their
/// duration so they are recognisable at 44 dp.
@immutable
class RaftMediaStripItem {
  const RaftMediaStripItem({
    required this.label,
    this.thumbnail,
    this.video = false,
    this.duration,
  });

  /// Semantics label, already localized ("Image 3 of 9").
  final String label;
  final ImageProvider? thumbnail;
  final bool video;
  final Duration? duration;
}

/// The scrollable thumbnail strip: drag or wheel scrolls it, the active item
/// is centred and ringed, a few items stay centred as a group. Thumbnails are
/// built lazily.
class RaftMediaStrip extends StatefulWidget {
  const RaftMediaStrip({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
    this.compact = false,
  });
  final List<RaftMediaStripItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  /// Phone strip: 44 dp thumbnails filling a [raftMediaStripBand] band.
  /// Otherwise the Web strip: `size-12` thumbnails, 16 dp above the bottom.
  final bool compact;

  @override
  State<RaftMediaStrip> createState() => _RaftMediaStripState();
}

class _RaftMediaStripState extends State<RaftMediaStrip> {
  static const _gap = 6.0;
  ScrollController? _scroll;
  double _viewport = 0;

  double get _thumb =>
      widget.compact ? raftMediaPhoneThumb : raftMediaDesktopThumb;

  /// Room around the thumbnails for the active one's shadow.
  double get _pad => widget.compact ? 6 : 8;
  double get _pitch => _thumb + _gap;
  double get _total => widget.items.length * _pitch - _gap;

  /// Offset that centres item [i] in a [viewport] wide strip.
  double _offsetFor(int i, double viewport) {
    final target = _pad + i * _pitch + _thumb / 2 - viewport / 2;
    final max = math.max(0.0, _total + 2 * _pad - viewport);
    return target.clamp(0.0, max);
  }

  @override
  void didUpdateWidget(RaftMediaStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _reveal();
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  void _reveal() {
    final reduce = MediaQuery.disableAnimationsOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scroll = _scroll;
      if (!mounted || scroll == null || !scroll.hasClients) return;
      final offset = _offsetFor(widget.index, _viewport);
      if (reduce) {
        scroll.jumpTo(offset);
      } else {
        unawaited(
          scroll.animateTo(
            offset,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  /// Mouse wheel over the strip scrolls it sideways (a plain vertical wheel
  /// included) instead of reaching the stage underneath.
  void _wheel(PointerSignalEvent event) {
    final scroll = _scroll;
    if (event is! PointerScrollEvent || scroll == null || !scroll.hasClients) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final delta = (e as PointerScrollEvent).scrollDelta;
      final position = scroll.position;
      scroll.jumpTo(
        (position.pixels + (delta.dx != 0 ? delta.dx : delta.dy)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.compact ? 0 : 16 - _pad),
        child: Listener(
          onPointerSignal: _wheel,
          child: SizedBox(
            key: const ValueKey('lightbox-thumbnails'),
            height: _thumb + 2 * _pad,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _viewport = constraints.maxWidth;
                final scrolls = _total + 2 * _pad > _viewport;
                final side = scrolls ? _pad : (_viewport - _total) / 2;
                _scroll ??= ScrollController(
                  initialScrollOffset: _offsetFor(widget.index, _viewport),
                );
                final list = ListView.separated(
                  key: const ValueKey('lightbox-thumbnail-scroll'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                    horizontal: side,
                    vertical: _pad,
                  ),
                  itemCount: widget.items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: _gap),
                  itemBuilder: (context, i) => _thumbAt(context, t, i),
                );
                if (!scrolls) return list;
                // The edge fade says "there is more".
                return ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (r) => const LinearGradient(
                    colors: [
                      Color(0x00000000),
                      Color(0xFF000000),
                      Color(0xFF000000),
                      Color(0x00000000),
                    ],
                    stops: [0, .05, .95, 1],
                  ).createShader(r),
                  child: list,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbAt(BuildContext context, RaftTokens t, int i) {
    final item = widget.items[i];
    final active = i == widget.index;
    final border = active
        ? (t.brutal ? t.product.softSignal : t.colors['accent-strong']!)
        : Colors.white.withValues(alpha: .3);
    final image = item.thumbnail;
    final thumb = _thumb;
    Widget box = Container(
      width: thumb,
      height: thumb,
      decoration: BoxDecoration(
        border: Border.all(color: border, width: 2),
        boxShadow: !active
            ? null
            : t.brutal
            ? RaftShadowSet.brutalSm
            : t.themeShadows.sm.outer,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            // ignore: raft_lints/avoid_raw_image_decode -- Thumbnail strip reuses the already-decoded bitmaps of the message attachments (OneFrame bitmap providers, nothing left to resize).
            Image(image: image, fit: BoxFit.cover)
          else
            ColoredBox(
              color: Colors.white.withValues(alpha: .2),
              child: Center(
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontFamily: t.headingFont,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: .5),
                  ),
                ),
              ),
            ),
          if (item.video)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 15,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: .62),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const RaftIcon(
                        RaftGlyph.play,
                        size: 8,
                        color: Colors.white,
                        filled: true,
                      ),
                      if (item.duration != null) ...[
                        const SizedBox(width: 3),
                        Text(
                          raftMediaDuration(item.duration!),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (!active) box = Opacity(opacity: widget.compact ? .72 : .6, child: box);
    return RaftInteractive(
      key: ValueKey('lightbox-thumbnail-$i'),
      onPressed: () => widget.onSelect(i),
      semanticLabel: item.label,
      selected: active,
      builder: (_, _) => ExcludeSemantics(child: box),
    );
  }
}

// ------------------------------------------------------------ chrome bits

/// A phone chrome action (Share, More, Download): glyph, semantics label and
/// a press handler that receives the button's global rect (menus anchor to it).
@immutable
class RaftMediaAction {
  const RaftMediaAction({
    required this.glyph,
    required this.label,
    required this.onPressed,
    this.id,
  });
  final RaftGlyph glyph;
  final String label;
  final ValueChanged<Rect> onPressed;
  final Key? id;
}

/// Round (elegant) or boxed (brutal) icon button of the immersive chrome;
/// the touch target is 44 dp.
class RaftMediaChromeButton extends StatelessWidget {
  const RaftMediaChromeButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onPressed,
  });
  final RaftGlyph glyph;
  final String label;
  final ValueChanged<Rect> onPressed;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return RaftInteractive(
      semanticLabel: label,
      onPressed: () {
        final box = context.findRenderObject();
        onPressed(
          box is RenderBox && box.hasSize
              ? box.localToGlobal(Offset.zero) & box.size
              : Rect.zero,
        );
      },
      builder: (_, state) => SizedBox.square(
        dimension: raftMediaChromeTarget,
        child: Center(
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: t.brutal
                ? BoxDecoration(
                    color: Colors.white,
                    border: Border.all(width: 2),
                    boxShadow: RaftShadowSet.brutalSm,
                  )
                : BoxDecoration(
                    color: Colors.black.withValues(
                      alpha: state.pressed ? .62 : .42,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .16),
                    ),
                  ),
            child: RaftIcon(
              glyph,
              size: 18,
              color: t.brutal ? Colors.black : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- dismiss

/// Drag-down-to-dismiss of the stage (touch only): the stage follows the
/// finger and shrinks to 0.82 at 260 dp, [progress] (0..1) drives the scrim
/// and chrome fade. Released past 120 dp or 700 dp/s it calls [onDismiss],
/// otherwise it springs back in 200 ms. Disabled (zoomed, a video seek rail,
/// desktop) the stage is left alone.
class RaftMediaDismissible extends StatefulWidget {
  const RaftMediaDismissible({
    super.key,
    required this.enabled,
    required this.onDismiss,
    required this.progress,
    required this.child,
  });
  final bool enabled;
  final VoidCallback onDismiss;
  final ValueNotifier<double> progress;
  final Widget child;

  @override
  State<RaftMediaDismissible> createState() => _RaftMediaDismissibleState();
}

class _RaftMediaDismissibleState extends State<RaftMediaDismissible>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  double _dy = 0;

  /// Fingers down: a second one is a pinch, which never moves the stage.
  int _pointers = 0;

  /// Offset the spring-back started from.
  double _from = 0;

  @override
  void initState() {
    super.initState();
    _spring.addListener(
      () => _set(_from * (1 - Curves.easeOut.transform(_spring.value))),
    );
  }

  void _set(double value) {
    _dy = value;
    widget.progress.value = (value / raftMediaDismissDistance).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _start(DragStartDetails _) {
    _spring.stop();
    RaftMediaBrowserRoute.maybeOf(context)?.setTranslucent(true);
  }

  void _update(DragUpdateDetails details) {
    if (_pointers > 1) return;
    _set(math.max(0, _dy + details.delta.dy));
  }

  void _end(DragEndDetails details) {
    if (_pointers <= 1 &&
        (_dy > raftMediaDismissOffset ||
            details.velocity.pixelsPerSecond.dy > raftMediaDismissVelocity)) {
      widget.onDismiss();
      return;
    }
    _release();
  }

  void _release() {
    _from = _dy;
    unawaited(
      _spring.forward(from: 0).whenComplete(() {
        if (!mounted) return;
        _set(0);
        RaftMediaBrowserRoute.maybeOf(context)?.setTranslucent(false);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _pointers++,
      onPointerUp: (_) => _pointers = math.max(0, _pointers - 1),
      onPointerCancel: (_) => _pointers = math.max(0, _pointers - 1),
      child: RawGestureDetector(
        key: const ValueKey('media-dismiss'),
        behavior: HitTestBehavior.translucent,
        gestures: {
          if (widget.enabled)
            VerticalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  VerticalDragGestureRecognizer
                >(
                  () => VerticalDragGestureRecognizer(
                    supportedDevices: const {PointerDeviceKind.touch},
                  ),
                  (recognizer) => recognizer
                    ..onStart = _start
                    ..onUpdate = _update
                    ..onEnd = _end
                    ..onCancel = _release,
                ),
        },
        child: ValueListenableBuilder<double>(
          valueListenable: widget.progress,
          builder: (context, progress, child) => Transform.translate(
            offset: Offset(0, _dy),
            child: Transform.scale(
              scale: reduced ? 1 : 1 - (1 - raftMediaDismissScale) * progress,
              child: child,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- shell

/// Phone media browser (page route): a black stage edge to edge under the
/// system bars, with two chrome layers that fade together on a tap (the host
/// owns [chrome]): the top bar (back, title and sub-line, counter, actions)
/// and the bottom band (optional caption, then the strip). Landscape drops the
/// bottom band. The stage keeps symmetrical room for both bands
/// ([RaftLightboxStageInset]) so toggling the chrome never moves the picture.
class RaftMediaImmersiveShell extends StatefulWidget {
  const RaftMediaImmersiveShell({
    super.key,
    required this.title,
    required this.chrome,
    required this.onClose,
    required this.child,
    this.subtitle,
    this.counter,
    this.actions = const [],
    this.strip,
    this.caption,
    this.shortcuts = const {},
    this.dismissEnabled = true,
    this.backLabel = 'Back',
  });
  final String title;
  final String? subtitle;

  /// Chrome visibility; a screen reader keeps it on regardless.
  final ValueListenable<bool> chrome;
  final VoidCallback onClose;
  final Widget? counter;
  final List<RaftMediaAction> actions;
  final Widget? strip;
  final String? caption;
  final Map<ShortcutActivator, VoidCallback> shortcuts;

  /// Whether the drag-down gesture may start (off while zoomed).
  final bool dismissEnabled;
  final String backLabel;
  final Widget child;

  @override
  State<RaftMediaImmersiveShell> createState() =>
      _RaftMediaImmersiveShellState();
}

class _RaftMediaImmersiveShellState extends State<RaftMediaImmersiveShell> {
  /// Drag-to-dismiss progress (0..1): fades the scrim and the chrome.
  final progress = ValueNotifier<double>(0);

  @override
  void dispose() {
    progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final safe = media.padding;
    final topBar = raftMediaTopBarRow + safe.top;
    final hasStrip = widget.strip != null && !landscape;
    final hasCaption = widget.caption != null && !landscape;
    final bottomBand =
        safe.bottom +
        (hasCaption ? raftMediaCaptionHeight : 0) +
        (hasStrip ? raftMediaStripBand + 8 : 0);
    final inset = math.max(topBar, bottomBand);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarBrightness: Brightness.dark,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      ),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
          ...widget.shortcuts,
        },
        child: Focus(
          autofocus: true,
          child: _stack(
            context,
            safe: safe,
            topBar: topBar,
            inset: inset,
            hasStrip: hasStrip,
            hasCaption: hasCaption,
          ),
        ),
      ),
    );
  }

  Widget _stack(
    BuildContext context, {
    required EdgeInsets safe,
    required double topBar,
    required double inset,
    required bool hasStrip,
    required bool hasCaption,
  }) {
    final t = RaftTokens.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final alwaysShown = MediaQuery.accessibleNavigationOf(context);
    final fade = reduced ? Duration.zero : const Duration(milliseconds: 160);
    Widget layer(Widget Function(BuildContext) build) => _ChromeBuilder(
      first: widget.chrome,
      second: progress,
      builder: (context, shown, drag) {
        final visible = shown || alwaysShown;
        // The chrome is gone within the first 40 dp of a drag.
        final dragFade = 1 - (drag * raftMediaDismissDistance / 40).clamp(0, 1);
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            duration: fade,
            opacity: visible ? dragFade.toDouble() : 0,
            child: ExcludeSemantics(excluding: !visible, child: build(context)),
          ),
        );
      },
    );

    final top = layer((context) {
      final rule = t.brutal
          ? const Border(bottom: BorderSide(color: Colors.white, width: 2))
          : null;
      return Container(
        height: topBar + (t.brutal ? 2 : 0),
        padding: EdgeInsets.fromLTRB(
          4 + safe.left,
          safe.top,
          4 + safe.right,
          0,
        ),
        decoration: t.brutal
            ? BoxDecoration(color: Colors.black, border: rule)
            : BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: .8),
                    Colors.black.withValues(alpha: 0),
                  ],
                ),
              ),
        child: Row(
          children: [
            RaftMediaChromeButton(
              glyph: RaftGlyph.chevronLeft,
              label: raftText(context, widget.backLabel),
              onPressed: (_) => widget.onClose(),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: t.headingFont,
                      fontSize: 15,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  if (widget.subtitle != null)
                    Text(
                      widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: t.bodyFont,
                        fontSize: 12,
                        height: 1.35,
                        color: Colors.white.withValues(alpha: .78),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.counter != null) ...[
              const SizedBox(width: 6),
              widget.counter!,
            ],
            for (final action in widget.actions)
              RaftMediaChromeButton(
                key: action.id,
                glyph: action.glyph,
                label: raftText(context, action.label),
                onPressed: action.onPressed,
              ),
          ],
        ),
      );
    });

    final bottom = layer((context) {
      final content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasCaption) _MediaCaption(text: widget.caption!),
          if (hasStrip)
            SizedBox(height: raftMediaStripBand, child: widget.strip!),
        ],
      );
      return Container(
        padding: EdgeInsets.fromLTRB(
          safe.left,
          t.brutal ? 6 : 12,
          safe.right,
          safe.bottom + 8,
        ),
        decoration: t.brutal
            ? const BoxDecoration(
                color: Colors.black,
                border: Border(top: BorderSide(color: Colors.white, width: 2)),
              )
            : BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(alpha: .78),
                  ],
                ),
              ),
        child: content,
      );
    });

    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, drag, _) =>
              ColoredBox(color: Colors.black.withValues(alpha: 1 - drag)),
        ),
        Positioned.fill(
          child: RaftMediaDismissible(
            enabled: widget.dismissEnabled,
            progress: progress,
            onDismiss: widget.onClose,
            child: RaftLightboxStageInset(vertical: inset, child: widget.child),
          ),
        ),
        Positioned(left: 0, right: 0, top: 0, child: top),
        Positioned(left: 0, right: 0, bottom: 0, child: bottom),
      ],
    );
  }
}

/// Rebuilds from two listenables.
class _ChromeBuilder extends StatelessWidget {
  const _ChromeBuilder({
    required this.first,
    required this.second,
    required this.builder,
  });
  final ValueListenable<bool> first;
  final ValueListenable<double> second;
  final Widget Function(BuildContext, bool, double) builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([first, second]),
    builder: (context, _) => builder(context, first.value, second.value),
  );
}

class _MediaCaption extends StatefulWidget {
  const _MediaCaption({required this.text});
  final String text;
  @override
  State<_MediaCaption> createState() => _MediaCaptionState();
}

class _MediaCaptionState extends State<_MediaCaption> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Semantics(
      container: true,
      label: widget.text,
      child: GestureDetector(
        key: const ValueKey('media-caption'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => expanded = !expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: SizedBox(
            height: expanded ? null : raftMediaCaptionHeight - 12,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: expanded ? 200 : raftMediaCaptionHeight - 12,
              ),
              child: SingleChildScrollView(
                physics: expanded
                    ? const ClampingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                child: Text(
                  widget.text,
                  maxLines: expanded ? null : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: t.bodyFont,
                    fontSize: 13,
                    height: 1.35,
                    color: Colors.white.withValues(alpha: .92),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
