import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Display-size image decoding (owner decision 2026-10-12: every image decodes
/// at its display size by default).
///
/// A plain `NetworkImage` / `MemoryImage` decodes the whole source bitmap into
/// the shared `ImageCache`, however small the widget that shows it is: a
/// 36 dp avatar from a 1024 px upload costs 4 MB, the same avatar at 36 dp x 3x
/// needs 108 x 108 px (47 KB). [RaftSizedImage] and [raftSizedImage] decode to
/// `logical size x devicePixelRatio` (rounded up, never upscaled, aspect kept)
/// and are the only place that may construct raw network or memory providers
/// (guarded by `test/image_decode_guard_test.dart`).

/// Zoom ceiling used for pinch/scroll-zoomable viewers. Matches
/// `InteractiveViewer.maxScale`'s default so a fully zoomed viewer still shows
/// one source pixel per device pixel.
const double raftZoomableImageScale = 2.5;

/// The one sanctioned raw network provider (public URL, no auth headers).
/// Always hand it to [RaftSizedImage] / [raftSizedImage]; never to `Image`.
// ignore: raft_lints/avoid_raw_image_decode -- The sized-image helper itself: the only place raw providers are built and wrapped so the decode size is the display size.
ImageProvider<Object> raftPublicNetworkImage(String url) => NetworkImage(url);

/// Drops the unsized cache entry for [bytes]. Sized entries are dropped by
/// [RaftSizedImage.evictOnDispose].
Future<bool> raftEvictMemoryImage(Uint8List bytes) =>
    // ignore: raft_lints/avoid_raw_image_decode -- The sized-image helper itself: the only place raw providers are built and wrapped so the decode size is the display size.
    MemoryImage(bytes).evict();

/// Physical pixels needed to show [logical] dp at [devicePixelRatio], rounded
/// up. The epsilon keeps `36 * 3.0000000000000004` at 108, not 109.
int raftPhysicalExtent(double logical, double devicePixelRatio) =>
    math.max(1, (logical * devicePixelRatio - 1e-6).ceil());

/// Wraps [provider] so it decodes no larger than the display box.
///
/// [logicalWidth] / [logicalHeight] are the box in dp (either may be null for
/// an unbounded axis; both null returns [provider] unchanged). [zoom] scales
/// the box for zoomable viewers. [fit] picks the policy: [BoxFit.cover] and
/// [BoxFit.fill] decode so the *smaller* side still covers the box (a
/// non-square source in a square avatar must not blur); every other fit
/// decodes to fit inside the box. The decode never exceeds the source size.
ImageProvider<Object> raftSizedImage(
  ImageProvider<Object> provider, {
  double? logicalWidth,
  double? logicalHeight,
  required double devicePixelRatio,
  BoxFit fit = BoxFit.cover,
  double zoom = 1,
}) {
  final w = logicalWidth != null && logicalWidth.isFinite && logicalWidth > 0
      ? raftPhysicalExtent(logicalWidth * zoom, devicePixelRatio)
      : null;
  final h = logicalHeight != null && logicalHeight.isFinite && logicalHeight > 0
      ? raftPhysicalExtent(logicalHeight * zoom, devicePixelRatio)
      : null;
  if (w == null && h == null) return provider;
  return RaftSizedImageProvider(
    provider,
    width: w,
    height: h,
    cover: fit == BoxFit.cover || fit == BoxFit.fill,
  );
}

/// The target decode size for a [intrinsicWidth] x [intrinsicHeight] source in
/// a [width] x [height] physical box. Exposed for tests.
({int width, int height}) raftSizedImageTarget({
  required int intrinsicWidth,
  required int intrinsicHeight,
  int? width,
  int? height,
  required bool cover,
}) {
  double? sx = width == null ? null : width / intrinsicWidth;
  double? sy = height == null ? null : height / intrinsicHeight;
  final double scale;
  if (sx != null && sy != null) {
    scale = cover ? math.max(sx, sy) : math.min(sx, sy);
  } else {
    scale = (sx ?? sy)!;
  }
  if (scale >= 1) return (width: intrinsicWidth, height: intrinsicHeight);
  return (
    width: math.max(1, (intrinsicWidth * scale).ceil()),
    height: math.max(1, (intrinsicHeight * scale).ceil()),
  );
}

@immutable
class RaftSizedImageKey {
  const RaftSizedImageKey._(
    this._inner,
    this._width,
    this._height,
    this._cover,
  );
  final Object _inner;
  final int? _width, _height;
  final bool _cover;

  /// The decode box is part of the identity: the same URL at two sizes (or two
  /// pixel ratios) is two cache entries, never a small decode shown large.
  @override
  bool operator ==(Object other) =>
      other is RaftSizedImageKey &&
      other._inner == _inner &&
      other._width == _width &&
      other._height == _height &&
      other._cover == _cover;
  @override
  int get hashCode => Object.hash(_inner, _width, _height, _cover);
}

/// [ResizeImage] cannot express "cover the box, keep aspect" without knowing
/// the source aspect ratio, so this applies the same `getTargetSize` hook with
/// a cover-or-fit policy. Never upscales.
@immutable
class RaftSizedImageProvider extends ImageProvider<RaftSizedImageKey> {
  const RaftSizedImageProvider(
    this.imageProvider, {
    this.width,
    this.height,
    this.cover = true,
  }) : assert(width != null || height != null);
  final ImageProvider<Object> imageProvider;

  /// Physical pixel box; either axis may be null (scale by the other).
  final int? width, height;
  final bool cover;

  @override
  Future<RaftSizedImageKey> obtainKey(ImageConfiguration configuration) {
    Completer<RaftSizedImageKey>? completer;
    SynchronousFuture<RaftSizedImageKey>? result;
    imageProvider.obtainKey(configuration).then((Object key) {
      final k = RaftSizedImageKey._(key, width, height, cover);
      if (completer == null) {
        result = SynchronousFuture<RaftSizedImageKey>(k);
      } else {
        completer.complete(k);
      }
    });
    if (result != null) return result!;
    completer = Completer<RaftSizedImageKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(
    RaftSizedImageKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeSized(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(
        getTargetSize == null,
        'RaftSizedImageProvider cannot wrap a provider that sets getTargetSize.',
      );
      return decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final t = raftSizedImageTarget(
            intrinsicWidth: intrinsicWidth,
            intrinsicHeight: intrinsicHeight,
            width: width,
            height: height,
            cover: cover,
          );
          return ui.TargetImageSize(width: t.width, height: t.height);
        },
      );
    }

    final completer = imageProvider.loadImage(key._inner, decodeSized);
    if (!kReleaseMode) {
      completer.debugLabel =
          '${completer.debugLabel} - Sized(${width}x$height)';
    }
    completer.addEphemeralErrorListener((Object exception, StackTrace? stack) {
      // Same reason as ResizeImage: the cache may not have tracked the key yet.
      // ignore: raft_lints/avoid_unreviewed_idle_work -- One-shot image cache eviction after a load error.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is RaftSizedImageProvider &&
      other.imageProvider == imageProvider &&
      other.width == width &&
      other.height == height &&
      other.cover == cover;
  @override
  int get hashCode => Object.hash(imageProvider, width, height, cover);
  @override
  String toString() =>
      'RaftSizedImageProvider($imageProvider, ${width}x$height, '
      '${cover ? 'cover' : 'fit'})';
}

/// An [Image] that decodes at the size it is displayed at.
///
/// The box is [width] x [height] when given, otherwise the incoming layout
/// constraints (a finite max extent per axis; an unbounded axis is not
/// limited). The pixel ratio comes from `MediaQuery`, so moving the window to a
/// display with another ratio rebuilds the provider and re-resolves the image.
///
/// Pass [zoom] (for example [raftZoomableImageScale]) inside an
/// `InteractiveViewer`, and [evictOnDispose] for one-shot in-memory pictures
/// whose bytes must not outlive the widget.
class RaftSizedImage extends StatefulWidget {
  const RaftSizedImage({
    super.key,
    required this.image,
    this.width,
    this.height,
    this.fit,
    this.zoom = 1,
    this.evictOnDispose = false,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = false,
    this.excludeFromSemantics = false,
    this.semanticLabel,
    this.frameBuilder,
    this.errorBuilder,
  });

  /// Public network image decoded at display size (no auth headers).
  RaftSizedImage.network(
    String url, {
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    double zoom = 1,
    Alignment alignment = Alignment.center,
    FilterQuality filterQuality = FilterQuality.medium,
    bool gaplessPlayback = false,
    bool excludeFromSemantics = false,
    String? semanticLabel,
    ImageFrameBuilder? frameBuilder,
    ImageErrorWidgetBuilder? errorBuilder,
  }) : this(
         key: key,
         // ignore: raft_lints/avoid_raw_image_decode -- The sized-image helper itself: the only place raw providers are built and wrapped so the decode size is the display size.
         image: NetworkImage(url),
         width: width,
         height: height,
         fit: fit,
         zoom: zoom,
         alignment: alignment,
         filterQuality: filterQuality,
         gaplessPlayback: gaplessPlayback,
         excludeFromSemantics: excludeFromSemantics,
         semanticLabel: semanticLabel,
         frameBuilder: frameBuilder,
         errorBuilder: errorBuilder,
       );

  /// In-memory encoded picture decoded at display size.
  RaftSizedImage.memory(
    Uint8List bytes, {
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    double zoom = 1,
    bool evictOnDispose = false,
    Alignment alignment = Alignment.center,
    FilterQuality filterQuality = FilterQuality.medium,
    bool gaplessPlayback = false,
    bool excludeFromSemantics = false,
    String? semanticLabel,
    ImageFrameBuilder? frameBuilder,
    ImageErrorWidgetBuilder? errorBuilder,
  }) : this(
         key: key,
         // ignore: raft_lints/avoid_raw_image_decode -- The sized-image helper itself: the only place raw providers are built and wrapped so the decode size is the display size.
         image: MemoryImage(bytes),
         width: width,
         height: height,
         fit: fit,
         zoom: zoom,
         evictOnDispose: evictOnDispose,
         alignment: alignment,
         filterQuality: filterQuality,
         gaplessPlayback: gaplessPlayback,
         excludeFromSemantics: excludeFromSemantics,
         semanticLabel: semanticLabel,
         frameBuilder: frameBuilder,
         errorBuilder: errorBuilder,
       );

  final ImageProvider<Object> image;
  final double? width, height;
  final BoxFit? fit;
  final double zoom;
  final bool evictOnDispose;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final bool gaplessPlayback, excludeFromSemantics;
  final String? semanticLabel;
  final ImageFrameBuilder? frameBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<RaftSizedImage> createState() => _RaftSizedImageState();
}

class _RaftSizedImageState extends State<RaftSizedImage> {
  // Every provider this widget built; evicted on dispose when asked, so the
  // sized cache entries (whose keys hold the source bytes) do not linger.
  final Set<ImageProvider<Object>> _built = {};

  void _evictBuilt(ImageProvider<Object> source) {
    for (final p in _built) {
      unawaited(p.evict());
    }
    unawaited(source.evict());
    _built.clear();
  }

  @override
  void didUpdateWidget(RaftSizedImage old) {
    super.didUpdateWidget(old);
    if (old.evictOnDispose && old.image != widget.image) _evictBuilt(old.image);
  }

  @override
  void dispose() {
    if (widget.evictOnDispose) _evictBuilt(widget.image);
    _built.clear();
    super.dispose();
  }

  Widget _build(BuildContext context, double? w, double? h) {
    final dpr =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.maybeOf(context)?.devicePixelRatio ??
        1.0;
    final fit = widget.fit ?? BoxFit.scaleDown;
    final provider = raftSizedImage(
      widget.image,
      logicalWidth: w,
      logicalHeight: h,
      devicePixelRatio: dpr,
      fit: fit,
      zoom: widget.zoom,
    );
    if (widget.evictOnDispose) _built.add(provider);
    // ignore: raft_lints/avoid_raw_image_decode -- The sized-image helper itself: the only place raw providers are built and wrapped so the decode size is the display size.
    return Image(
      image: provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: widget.filterQuality,
      gaplessPlayback: widget.gaplessPlayback,
      excludeFromSemantics: widget.excludeFromSemantics,
      semanticLabel: widget.semanticLabel,
      frameBuilder: widget.frameBuilder,
      errorBuilder: widget.errorBuilder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width, h = widget.height;
    bool fixed(double? v) => v != null && v.isFinite;
    if (fixed(w) && fixed(h)) return _build(context, w, h);
    return LayoutBuilder(
      builder: (context, constraints) => _build(
        context,
        fixed(w) ? w : constraints.maxWidth,
        fixed(h) ? h : constraints.maxHeight,
      ),
    );
  }
}
