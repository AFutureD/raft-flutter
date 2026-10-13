import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Image viewer zoom surface: the port of the Web `ImageZoom.ts` controller
// (Web `ImageLightbox`). Same limits and gestures:
//   minScale 1 (fit), maxScale 4x and up to 16x for large images,
//   double-tap / double-click toggles fit <-> 2x around the pointer,
//   Ctrl / Cmd + wheel and trackpad pinch zoom continuously,
//   a plain wheel only pans (when zoomed), it never zooms.
// Flutter specifics: at fit scale a single finger belongs to the viewer's
// PageView (swipe), so the scale recognizer only claims the gesture with two
// pointers or when zoomed in.

/// Web `MIN_SCALE`: never smaller than fit-to-stage.
const imageMinScale = 1.0;

/// Web `MAX_SCALE`.
const imageBaseMaxScale = 4.0;

/// Web `MAX_DYNAMIC_SCALE`.
const imageDynamicMaxScale = 16.0;

/// Web `ZOOMED_SCALE_TARGET`: the double-tap / double-click target.
const imageDoubleTapScale = 2.0;

/// Web `PROGRAMMATIC_ZOOM_ANIMATION_MS` and its timing function.
const imageZoomAnimation = Duration(milliseconds: 200);
const imageZoomCurve = Cubic(0.33, 1, 0.68, 1);

/// Web `DOUBLE_TAP_WINDOW_MS` / `DOUBLE_TAP_RADIUS_PX` (a mouse double-click
/// follows the platform's slower interval).
const imageDoubleTapWindow = Duration(milliseconds: 350);
const imageDoubleClickWindow = Duration(milliseconds: 500);
const imageDoubleTapRadius = 24.0;

/// Web wheel curve constants (`WHEEL_ZOOM_*`).
const imageWheelCoefficient = 0.005;
const imageWheelAcceleratedMultiplier = 7.0;
const imageWheelMaxExponent = 0.45;

/// Web `imageDimensionsToMaxScale`: the natural-pixel to displayed-pixel
/// ratio, at least [imageBaseMaxScale] and at most [imageDynamicMaxScale].
double imageMaxScale({required Size? natural, required Size fitted}) {
  if (natural == null ||
      natural.width <= 0 ||
      natural.height <= 0 ||
      fitted.width <= 0 ||
      fitted.height <= 0) {
    return imageBaseMaxScale;
  }
  final ratio = math.max(
    natural.width / fitted.width,
    natural.height / fitted.height,
  );
  return ratio.clamp(imageBaseMaxScale, imageDynamicMaxScale).toDouble();
}

/// Web `wheelDeltaToZoomFactor` for pixel deltas (Ctrl / Cmd + wheel is the
/// accelerated path).
double imageWheelZoomFactor(double deltaY, {bool accelerated = true}) {
  final raw =
      -deltaY *
      imageWheelCoefficient *
      (accelerated ? imageWheelAcceleratedMultiplier : 1);
  return math
      .pow(2, raw.clamp(-imageWheelMaxExponent, imageWheelMaxExponent))
      .toDouble();
}

/// The box the image occupies at fit scale: its natural size, shrunk to fit
/// [stage] minus [verticalInset] above and below (never enlarged). Without a
/// known size the whole stage stands in.
Size fittedImageSize(Size stage, Size? natural, {double verticalInset = 0}) {
  if (natural == null || natural.width <= 0 || natural.height <= 0) {
    return stage;
  }
  final available = Size(
    stage.width,
    math.max(0, stage.height - 2 * verticalInset),
  );
  final scale = math.min(
    1.0,
    math.min(
      available.width / natural.width,
      available.height / natural.height,
    ),
  );
  return Size(natural.width * scale, natural.height * scale);
}

/// Scale and translation of a zoom matrix (the controller holds
/// `translate(tx, ty) * scale(s)` in stage coordinates).
typedef ImageZoomState = ({double scale, double tx, double ty});

ImageZoomState imageZoomStateOf(Matrix4 matrix) =>
    (scale: matrix.storage[0], tx: matrix.storage[12], ty: matrix.storage[13]);

Matrix4 imageZoomMatrix(ImageZoomState state) => Matrix4.identity()
  ..setEntry(0, 0, state.scale)
  ..setEntry(1, 1, state.scale)
  ..setEntry(0, 3, state.tx)
  ..setEntry(1, 3, state.ty);

/// Keeps the fitted image box (centred in [stage]) in view: where it is
/// larger than the stage its edges cannot leave the stage edges, where it is
/// smaller it stays centred. Scale is limited to [imageMinScale]..[maxScale].
ImageZoomState clampImageZoom(
  ImageZoomState state, {
  required Size stage,
  required Size fitted,
  required double maxScale,
}) {
  final scale = state.scale
      .clamp(imageMinScale, math.max(imageMinScale, maxScale))
      .toDouble();
  double axis(double t, double stageExtent, double fittedExtent) {
    final centre = stageExtent / 2;
    final scaled = fittedExtent * scale;
    if (scaled <= stageExtent) return centre - scale * centre;
    // Scaled edges: scale * (centre -+ fitted / 2) + t.
    final low = stageExtent - scale * (centre + fittedExtent / 2);
    final high = -scale * (centre - fittedExtent / 2);
    return t.clamp(low, high);
  }

  return (
    scale: scale,
    tx: axis(state.tx, stage.width, fitted.width),
    ty: axis(state.ty, stage.height, fitted.height),
  );
}

/// Zooms [state] to [scale] keeping the content point under [focal] (stage
/// coordinates) where it is.
ImageZoomState zoomImageAround(
  ImageZoomState state,
  double scale,
  Offset focal,
) {
  final ratio = scale / state.scale;
  return (
    scale: scale,
    tx: focal.dx - (focal.dx - state.tx) * ratio,
    ty: focal.dy - (focal.dy - state.ty) * ratio,
  );
}

/// The scale recognizer of the surface. At fit scale a single pointer never
/// claims the gesture (the PageView's drag takes it, however fast the flick);
/// two pointers (pinch) or any pointer while zoomed in do. Trackpad pan-zoom
/// is handled by the surface itself.
class ImageZoomScaleRecognizer extends ScaleGestureRecognizer {
  ImageZoomScaleRecognizer({
    required this.isZoomed,
    super.debugOwner,
    super.supportedDevices,
  });
  final bool Function() isZoomed;

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) => false;

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted &&
        !isZoomed() &&
        pointerCount < 2) {
      return;
    }
    super.resolve(disposition);
  }
}

/// The stage of one viewer page: [child] (the image) sized to its fitted box
/// at the stage centre, transformed by [controller]. Pinch, pan, double-tap,
/// Ctrl / Cmd + wheel and trackpad gestures drive the controller; the pan is
/// bounded by the fitted image. [onTapOutside] fires for a plain tap outside
/// the painted image (Web "empty-stage click closes").
class ImageZoomSurface extends StatefulWidget {
  const ImageZoomSurface({
    super.key,
    required this.controller,
    required this.natural,
    required this.child,
    this.verticalInset = 0,
    this.onTapOutside,
    this.onTap,
    this.onZoomGesture,
  });
  final TransformationController controller;

  /// The image's pixel size (decoded, else declared); null when unknown.
  final Size? natural;

  /// Space the fitted box keeps free above and below the stage centre line
  /// (the thumbnail strip's band).
  final double verticalInset;
  final VoidCallback? onTapOutside;

  /// A single tap, reported once the double-tap window has passed without a
  /// second tap (phone: toggles the chrome).
  final VoidCallback? onTap;

  /// A pinch or double-tap zoom begins (phone: the chrome gets out of the way).
  final VoidCallback? onZoomGesture;
  final Widget child;

  @override
  State<ImageZoomSurface> createState() => ImageZoomSurfaceState();
}

class ImageZoomSurfaceState extends State<ImageZoomSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: imageZoomAnimation,
  );
  ImageZoomState? _from, _to;
  ImageZoomState _gestureStart = (scale: 1, tx: 0, ty: 0);
  Offset _gestureFocal = Offset.zero;
  Offset? _lastTap;
  Timer? _lastTapExpiry;
  double _panZoomScale = 1;
  Offset _panZoomPan = Offset.zero;
  (Size, Size)? _laidOut;

  bool get zoomed => widget.controller.value.getMaxScaleOnAxis() > 1.001;

  Size get _stage => (context.findRenderObject() as RenderBox).size;
  Size get _fitted => fittedImageSize(
    _stage,
    widget.natural,
    verticalInset: widget.verticalInset,
  );
  double get _maxScale =>
      imageMaxScale(natural: widget.natural, fitted: _fitted);

  @override
  void initState() {
    super.initState();
    _animation.addListener(_tick);
  }

  @override
  void dispose() {
    _lastTapExpiry?.cancel();
    _animation.dispose();
    super.dispose();
  }

  void _tick() {
    final from = _from, to = _to;
    if (from == null || to == null) return;
    final t = imageZoomCurve.transform(_animation.value);
    double lerp(double a, double b) => a + (b - a) * t;
    widget.controller.value = imageZoomMatrix((
      scale: lerp(from.scale, to.scale),
      tx: lerp(from.tx, to.tx),
      ty: lerp(from.ty, to.ty),
    ));
  }

  void _stopAnimation() {
    if (_animation.isAnimating) _animation.stop();
  }

  ImageZoomState _clamped(ImageZoomState state) => clampImageZoom(
    state,
    stage: _stage,
    fitted: _fitted,
    maxScale: _maxScale,
  );

  void _apply(ImageZoomState state) {
    widget.controller.value = imageZoomMatrix(_clamped(state));
  }

  /// Programmatic zoom (double-tap): animates to [target].
  void _animateTo(ImageZoomState target) {
    _from = imageZoomStateOf(widget.controller.value);
    _to = _clamped(target);
    _animation.forward(from: 0);
  }

  /// Keyboard / accessibility zoom: [factor] times the current scale around
  /// the stage centre, animated like a double-tap.
  void zoomStep(double factor) {
    final current = imageZoomStateOf(widget.controller.value);
    final next = (current.scale * factor).clamp(imageMinScale, _maxScale);
    if (next > current.scale) widget.onZoomGesture?.call();
    _animateTo(zoomImageAround(current, next, _stage.center(Offset.zero)));
  }

  /// Back to fit (keyboard `0`, accessibility action).
  void resetZoom() => _animateTo((scale: 1, tx: 0, ty: 0));

  /// Web `onDoubleClick`: any zoom or pan returns to fit; otherwise zoom to
  /// 2x around the pointer.
  void toggleZoomAt(Offset focal) {
    final current = imageZoomStateOf(widget.controller.value);
    if ((current.scale - imageMinScale).abs() > 0.001 ||
        current.tx != 0 ||
        current.ty != 0) {
      _animateTo((scale: 1, tx: 0, ty: 0));
    } else {
      final scale = math.min(imageDoubleTapScale, _maxScale);
      widget.onZoomGesture?.call();
      _animateTo(zoomImageAround(current, scale, focal));
    }
  }

  // Tap recognition: a tap outside the painted image closes; two taps within
  // the Web double-tap window and radius toggle the zoom instead.
  void _tapUp(TapUpDetails details) {
    final last = _lastTap;
    if (last != null &&
        (details.localPosition - last).distance < imageDoubleTapRadius) {
      _forgetTap();
      toggleZoomAt(details.localPosition);
      return;
    }
    _lastTap = details.localPosition;
    _lastTapExpiry?.cancel();
    _lastTapExpiry = Timer(
      details.kind == PointerDeviceKind.mouse
          ? imageDoubleClickWindow
          : imageDoubleTapWindow,
      () {
        _lastTap = null;
        _lastTapExpiry = null;
        if (mounted) widget.onTap?.call();
      },
    );
    if (!imageContains(details.localPosition)) widget.onTapOutside?.call();
  }

  void _forgetTap() {
    _lastTap = null;
    _lastTapExpiry?.cancel();
    _lastTapExpiry = null;
  }

  void _scaleStart(ScaleStartDetails details) {
    _stopAnimation();
    if (details.pointerCount > 1) widget.onZoomGesture?.call();
    _gestureStart = imageZoomStateOf(widget.controller.value);
    _gestureFocal = details.localFocalPoint;
  }

  void _scaleUpdate(ScaleUpdateDetails details) {
    final scale = _gestureStart.scale * details.scale;
    final zoomedAround = zoomImageAround(
      _gestureStart,
      scale.clamp(imageMinScale, _maxScale),
      _gestureFocal,
    );
    _apply((
      scale: zoomedAround.scale,
      tx: zoomedAround.tx + details.localFocalPoint.dx - _gestureFocal.dx,
      ty: zoomedAround.ty + details.localFocalPoint.dy - _gestureFocal.dy,
    ));
  }

  bool get _zoomModifier =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _zoomBy(double factor, Offset focal) {
    _stopAnimation();
    final current = imageZoomStateOf(widget.controller.value);
    final scale = (current.scale * factor).clamp(imageMinScale, _maxScale);
    _apply(zoomImageAround(current, scale, focal));
  }

  void _panBy(Offset delta) {
    _stopAnimation();
    final current = imageZoomStateOf(widget.controller.value);
    _apply((
      scale: current.scale,
      tx: current.tx + delta.dx,
      ty: current.ty + delta.dy,
    ));
  }

  // Wheel: Ctrl / Cmd zooms; otherwise it pans while zoomed and is left to
  // others (nothing) at fit scale.
  void _signal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (_zoomModifier) {
        GestureBinding.instance.pointerSignalResolver.register(event, (e) {
          final scroll = e as PointerScrollEvent;
          _zoomBy(
            imageWheelZoomFactor(scroll.scrollDelta.dy),
            scroll.localPosition,
          );
        });
      } else if (zoomed) {
        GestureBinding.instance.pointerSignalResolver.register(event, (e) {
          final scroll = e as PointerScrollEvent;
          var delta = scroll.scrollDelta;
          // Shift + wheel pans sideways.
          if (HardwareKeyboard.instance.isShiftPressed && delta.dx == 0) {
            delta = Offset(delta.dy, 0);
          }
          _panBy(-delta);
        });
      }
    } else if (event is PointerScaleEvent) {
      GestureBinding.instance.pointerSignalResolver.register(event, (e) {
        final scale = e as PointerScaleEvent;
        _zoomBy(scale.scale, scale.localPosition);
      });
    }
  }

  // Trackpad: pinch zooms around the fingers, two-finger scroll pans while
  // zoomed (at fit scale it is left to the page view).
  void _panZoomStart(PointerPanZoomStartEvent event) {
    _stopAnimation();
    _panZoomScale = 1;
    _panZoomPan = Offset.zero;
  }

  void _panZoomUpdate(PointerPanZoomUpdateEvent event) {
    final factor = event.scale / _panZoomScale;
    final pan = event.pan - _panZoomPan;
    _panZoomScale = event.scale;
    _panZoomPan = event.pan;
    if ((factor - 1).abs() > 1e-6) _zoomBy(factor, event.localPosition);
    if (zoomed && pan != Offset.zero) _panBy(pan);
  }

  /// Whether [point] (stage coordinates) lands on the painted image: its
  /// fitted box centred in the stage, mapped through the zoom / pan
  /// transform. Without a known pixel size every point counts as the image
  /// (never closes by accident).
  @visibleForTesting
  bool imageContains(Offset point) {
    final natural = widget.natural;
    if (natural == null || natural.isEmpty) return true;
    final stage = _stage;
    final box = Rect.fromCenter(
      center: stage.center(Offset.zero),
      width: _fitted.width,
      height: _fitted.height,
    );
    final inverse = Matrix4.tryInvert(widget.controller.value);
    if (inverse == null) return true;
    return box.contains(MatrixUtils.transformPoint(inverse, point));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stage = constraints.biggest;
        final fitted = fittedImageSize(
          stage,
          widget.natural,
          verticalInset: widget.verticalInset,
        );
        final layout = (stage, fitted);
        if (_laidOut != layout) {
          final first = _laidOut == null;
          _laidOut = layout;
          // A new stage or image size: bring a zoomed image back in bounds.
          if (!first) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && zoomed) {
                _apply(imageZoomStateOf(widget.controller.value));
              }
            });
          }
        }
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _stopAnimation(),
          onPointerSignal: _signal,
          onPointerPanZoomStart: _panZoomStart,
          onPointerPanZoomUpdate: _panZoomUpdate,
          child: RawGestureDetector(
            key: const ValueKey('lightbox-stage'),
            behavior: HitTestBehavior.translucent,
            gestures: {
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                    TapGestureRecognizer.new,
                    (recognizer) => recognizer.onTapUp = _tapUp,
                  ),
              ImageZoomScaleRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    ImageZoomScaleRecognizer
                  >(
                    () => ImageZoomScaleRecognizer(isZoomed: () => zoomed),
                    (recognizer) => recognizer
                      ..onStart = _scaleStart
                      ..onUpdate = _scaleUpdate,
                  ),
            },
            child: ClipRect(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, child) =>
                    Transform(transform: widget.controller.value, child: child),
                child: SizedBox.expand(
                  child: Center(
                    child: SizedBox(
                      width: fitted.width,
                      height: fitted.height,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
