// Web inline audio / video attachment cards (MessageItem.tsx
// InlineVideoAttachmentCard, InlineAudioAttachmentCard, InlineAudioPlayer).
// The app owns the media: URL, download, decoding, play state.
import 'package:flutter/material.dart';

import 'design_primitives.dart';
import 'dialog_card.dart' show RaftShadowSet;
import 'icons.dart';
import 'localization.dart';
import 'recipe_surface.dart';
import 'recipes/message_video_preview.g.dart';
import 'video_controls.dart';
import 'theme.dart';
import 'tooltip.dart';

enum RaftInlineMediaState { idle, loading, failed, ready }

/// The video card (Web InlineVideoAttachmentCard): a black 16:9 box whose
/// video is letterboxed (`object-contain`), so a portrait clip keeps its
/// aspect between black bars. The poster is the first decoded frame (the
/// paused video surface) or [poster] (a server thumbnail) beneath it.
///
/// Controls follow the native `<video controls>` Web renders: a centred Play
/// button while paused (on hover with a mouse, always on touch), a bottom bar
/// (play / pause, time, seek, volume) on hover, while paused after the first
/// play, or for a few seconds after a tap on touch; clicking the picture
/// toggles playback. The corner action opens the full preview. While loading
/// a spinner shows, and a failure reads as the codec warning with a download
/// action.
class RaftInlineVideo extends StatefulWidget {
  const RaftInlineVideo({
    super.key,
    required this.state,
    required this.filename,
    this.video,
    this.poster,
    this.playing = false,
    this.buffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 100,
    this.touch,
    this.onTogglePlay,
    this.onSeek,
    this.onVolume,
    this.onOpenPreview,
    this.onDownload,
  });
  final RaftInlineMediaState state;
  final String filename;

  /// The decoded video surface (state ready).
  final Widget? video;

  /// Server thumbnail shown until the video surface has a frame.
  final Widget? poster;
  final bool playing, buffering;
  final Duration position, duration;

  /// 0..100 like the native player.
  final double volume;

  /// Touch input (controls without hover). Defaults to the mobile platforms.
  final bool? touch;
  final VoidCallback? onTogglePlay, onOpenPreview, onDownload;
  final ValueChanged<Duration>? onSeek;

  /// 0..100.
  final ValueChanged<double>? onVolume;

  @override
  State<RaftInlineVideo> createState() => _RaftInlineVideoState();
}

class _RaftInlineVideoState extends State<RaftInlineVideo> {
  bool actionHovered = false;

  bool get ready =>
      widget.state == RaftInlineMediaState.ready && widget.video != null;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), rt = t.recipeTokens;
    final s = RaftMessageVideoPreviewRecipe.resolve(
      theme: t.recipeTheme,
      states: t.recipeStates(),
      tokens: rt,
    );
    final action = RaftMessageVideoPreviewRecipe.resolve(
      theme: t.recipeTheme,
      states: t.recipeStates(hovered: actionHovered),
      tokens: rt,
    ).action;
    final width = MediaQuery.sizeOf(context).width;
    final openLabel = raftFormat(context, 'Open {filename} in preview', {
      'filename': widget.filename,
    });
    final Widget fallback = switch (widget.state) {
      RaftInlineMediaState.ready when widget.video != null => widget.video!,
      RaftInlineMediaState.loading => const Center(
        child: RaftSpinner(size: 24, inverse: true),
      ),
      RaftInlineMediaState.failed => Center(
        // `max-w-[256px] px-4`: the padding is inside the 256 px box.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 256),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: t.brutal ? 8 : 12,
              children: [
                const RaftIcon(
                  RaftGlyph.alertTriangle,
                  size: 24,
                  color: Colors.white,
                ),
                Text(
                  raftText(
                    context,
                    'This video may use a codec this browser cannot preview.',
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: t.headingFont,
                    fontSize: 12,
                    height: 16 / 12,
                    fontWeight: t.brutal ? FontWeight.w700 : FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
                GestureDetector(
                  key: const Key('inline-video-download'),
                  onTap: widget.onDownload,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      RaftIcon(
                        RaftGlyph.download,
                        size: 13,
                        color: Colors.white.withValues(alpha: .75),
                      ),
                      Text(
                        raftText(context, 'Download to view'),
                        style: TextStyle(
                          fontFamily: t.headingFont,
                          fontSize: 12,
                          height: 16 / 12,
                          fontWeight: t.brutal
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: Colors.white.withValues(alpha: .75),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      _ => Center(
        child: RaftIcon(
          RaftGlyph.play,
          size: 32,
          color: Colors.white.withValues(alpha: .8),
        ),
      ),
    };
    // A tap while the player is still being prepared is kept (the card queues
    // the play), so the picture reacts in every state but failed.
    final interactive = widget.state != RaftInlineMediaState.failed;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (width - 112).clamp(0, 448).toDouble(),
        ),
        child: _CardBox(
          child: RaftRecipeBox(
            key: const Key('inline-video'),
            style: s.root,
            tokens: rt,
            clip: true,
            child: RaftVideoOverlay(
              filename: widget.filename,
              interactive: interactive,
              ready: ready,
              buffering: widget.buffering,
              playing: widget.playing,
              position: widget.position,
              duration: widget.duration,
              volume: widget.volume,
              touch: widget.touch,
              onTogglePlay: widget.onTogglePlay,
              onSeek: widget.onSeek,
              onVolume: widget.onVolume,
              onOpen: widget.onOpenPreview,
              onDownload: widget.onDownload,
              extra: [
                if (widget.onOpenPreview != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: RaftTooltip(
                      message: openLabel,
                      excludeFromSemantics: true,
                      child: Semantics(
                        button: true,
                        label: openLabel,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          onEnter: (_) => setState(() => actionHovered = true),
                          onExit: (_) => setState(() => actionHovered = false),
                          child: GestureDetector(
                            key: const Key('inline-video-expand'),
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onOpenPreview,
                            child: RaftRecipeBox(
                              style: action,
                              tokens: rt,
                              width: 24,
                              height: 24,
                              child: const Center(
                                child: RaftIcon(RaftGlyph.eye, size: 12),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (widget.poster != null &&
                        widget.state != RaftInlineMediaState.failed)
                      widget.poster!,
                    fallback,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `aspect-video` as the browser lays it out: 16:9 with the height snapped to
/// a whole pixel (a 440 px card is 248 px tall, not 247.5).
class _CardBox extends StatelessWidget {
  const _CardBox({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : 448.0;
      return SizedBox(
        width: width,
        height: (width * 9 / 16).roundToDouble(),
        child: child,
      );
    },
  );
}

String raftAudioTimestamp(Duration value) {
  final seconds = value.inMilliseconds / 1000;
  if (!seconds.isFinite || seconds <= 0) return '0:00';
  final total = seconds.floor();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// The audio card: icon + filename + download over the player (or its loading
/// / failed placeholder).
class RaftInlineAudio extends StatelessWidget {
  const RaftInlineAudio({
    super.key,
    required this.filename,
    required this.state,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1,
    this.onDownload,
    this.onTogglePlay,
    this.onSeek,
    this.onVolume,
  });
  final String filename;
  final RaftInlineMediaState state;
  final bool playing;
  final Duration position, duration;

  /// 0..1.
  final double volume;
  final VoidCallback? onDownload, onTogglePlay;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<double>? onVolume;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final brutal = t.brutal;
    final line = brutal ? Colors.black : t.colors['line-muted']!;
    final strong = brutal ? Colors.black : t.strong;
    final downloadLabel = raftFormat(context, 'Download {filename}', {
      'filename': filename,
    });
    // Download button: `border border-line-muted bg-layer-panel` (no Brutal
    // override).
    Widget square(double size, Widget child) => Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border.all(color: t.colors['line-muted']!),
      ),
      child: child,
    );
    final headerIcon = Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: brutal ? t.product.softSignal : t.colors['primary-soft'],
        border: Border.all(color: line, width: brutal ? 2 : 1),
      ),
      child: RaftIcon(RaftGlyph.music, size: 16, color: strong),
    );
    final download = state == RaftInlineMediaState.failed || onDownload == null
        ? null
        : RaftTooltip(
            message: downloadLabel,
            excludeFromSemantics: true,
            child: Semantics(
              button: true,
              label: downloadLabel,
              child: GestureDetector(
                key: const Key('audio-download'),
                behavior: HitTestBehavior.opaque,
                onTap: onDownload,
                child: square(
                  28,
                  RaftIcon(
                    RaftGlyph.download,
                    size: 14,
                    color: brutal ? Colors.black : t.muted,
                  ),
                ),
              ),
            ),
          );
    final header = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              spacing: 8,
              children: [
                headerIcon,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RaftTooltip(
                        message: filename,
                        child: Text(
                          filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: t.headingFont,
                            fontSize: 14,
                            height: 20 / 14,
                            fontWeight: FontWeight.w700,
                            color: strong,
                          ),
                        ),
                      ),
                      Text(
                        raftText(context, 'Audio file'),
                        style: TextStyle(
                          fontFamily: t.headingFont,
                          fontSize: 12,
                          height: 16 / 12,
                          fontWeight: FontWeight.w700,
                          color: t.colors['foreground-hint'],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (download != null) ...[const SizedBox(width: 8), download],
        ],
      ),
    );
    final loadingLabel = raftFormat(context, 'Loading {filename}', {
      'filename': filename,
    });
    final inset = brutal ? t.colors['brutal-cream'] : t.colors['layer-inset'];
    final Widget body = state == RaftInlineMediaState.ready
        ? _AudioPlayer(
            filename: filename,
            playing: playing,
            position: position,
            duration: duration,
            volume: volume,
            onTogglePlay: onTogglePlay,
            onSeek: onSeek,
            onVolume: onVolume,
          )
        : GestureDetector(
            key: const Key('audio-placeholder'),
            behavior: HitTestBehavior.opaque,
            // Idle: the player was released (or not prepared yet); a tap prepares
            // it and plays.
            onTap: state == RaftInlineMediaState.failed
                ? onDownload
                : state == RaftInlineMediaState.idle
                ? onTogglePlay
                : null,
            child: Container(
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: inset,
                border: Border.all(color: line),
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  fontFamily: t.headingFont,
                  fontSize: 12,
                  height: 16 / 12,
                  fontWeight: FontWeight.w700,
                  color: brutal ? Colors.black.withValues(alpha: .7) : t.muted,
                ),
                child: state == RaftInlineMediaState.loading
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          const RaftSpinner(size: 12),
                          Text(loadingLabel),
                        ],
                      )
                    : state == RaftInlineMediaState.failed
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 6,
                        children: [
                          const RaftIcon(RaftGlyph.download, size: 13),
                          Text(raftText(context, 'Download to view')),
                        ],
                      )
                    : Text(loadingLabel),
              ),
            ),
          );
    final width = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (width - 112).clamp(0, 448).toDouble(),
        ),
        child: Container(
          key: const Key('inline-audio'),
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: brutal ? Colors.white : t.panel,
            border: Border.all(color: line, width: brutal ? 2 : 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [header, body],
          ),
        ),
      ),
    );
  }
}

/// Web `AudioPreviewBody` (modal variant): the `max-w-xl` bordered panel card
/// with the 40 px music badge, name and "Audio file" over the audio rails, in
/// the viewer's canvas.
class RaftAudioPreview extends StatelessWidget {
  const RaftAudioPreview({
    super.key,
    required this.filename,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1,
    this.onTogglePlay,
    this.onSeek,
    this.onVolume,
  });
  final String filename;
  final bool playing;
  final Duration position, duration;

  /// 0..1.
  final double volume;
  final VoidCallback? onTogglePlay;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<double>? onVolume;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final brutal = t.brutal;
    final line = brutal ? Colors.black : t.colors['line-muted']!;
    final strong = brutal ? Colors.black : t.strong;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 576),
          child: Container(
            key: const Key('audio-preview'),
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: brutal ? Colors.white : t.panel,
              border: Border.all(color: line, width: brutal ? 2 : 1),
              boxShadow: brutal
                  ? RaftShadowSet.brutalSm
                  : t.themeShadows.sm.outer,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    spacing: 12,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: brutal
                              ? t.product.softSignal
                              : t.colors['primary-soft'],
                          border: Border.all(
                            color: line,
                            width: brutal ? 2 : 1,
                          ),
                        ),
                        child: RaftIcon(
                          RaftGlyph.music,
                          size: 20,
                          color: strong,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              filename,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: t.headingFont,
                                fontSize: 14,
                                height: 20 / 14,
                                fontWeight: FontWeight.w700,
                                color: strong,
                              ),
                            ),
                            Text(
                              raftText(context, 'Audio file'),
                              style: TextStyle(
                                fontFamily: t.headingFont,
                                fontSize: 12,
                                height: 16 / 12,
                                fontWeight: FontWeight.w700,
                                color: brutal
                                    ? Colors.black.withValues(alpha: .5)
                                    : t.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _AudioPlayer(
                  filename: filename,
                  playing: playing,
                  position: position,
                  duration: duration,
                  volume: volume,
                  onTogglePlay: onTogglePlay,
                  onSeek: onSeek,
                  onVolume: onVolume,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioPlayer extends StatelessWidget {
  const _AudioPlayer({
    required this.filename,
    required this.playing,
    required this.position,
    required this.duration,
    required this.volume,
    this.onTogglePlay,
    this.onSeek,
    this.onVolume,
  });
  final String filename;
  final bool playing;
  final Duration position, duration;
  final double volume;
  final VoidCallback? onTogglePlay;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<double>? onVolume;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final brutal = t.brutal;
    final line = brutal ? Colors.black : t.colors['line-muted']!;
    final known = duration > Duration.zero;
    final bounded = known && position > duration ? duration : position;
    final progress = known
        ? (bounded.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final timeLabel =
        '${raftAudioTimestamp(bounded)} / ${raftAudioTimestamp(duration)}';
    final playLabel = raftFormat(
      context,
      playing ? 'Pause audio {filename}' : 'Play audio {filename}',
      {'filename': filename},
    );
    return Container(
      key: const Key('inline-audio-player'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: brutal ? t.colors['brutal-cream'] : t.colors['layer-inset'],
        border: Border.all(color: line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            spacing: 8,
            children: [
              Semantics(
                button: true,
                label: playLabel,
                child: GestureDetector(
                  key: const Key('audio-play-toggle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onTogglePlay,
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.panel,
                      border: Border.all(color: t.colors['line-muted']!),
                    ),
                    child: RaftIcon(
                      playing ? RaftGlyph.pause : RaftGlyph.play,
                      size: 14,
                      color: brutal ? Colors.black : t.strong,
                      filled: true,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _RailSlider(
                  key: const Key('audio-seek'),
                  semanticLabel: raftFormat(context, 'Seek audio {filename}', {
                    'filename': filename,
                  }),
                  semanticValue: timeLabel,
                  value: progress,
                  enabled: known,
                  height: 28,
                  rail: 8,
                  thumb: 12,
                  fill: brutal
                      ? t.product.brutalCyan
                      : t.colors['primary-strong']!,
                  onChanged: (v) => onSeek?.call(
                    Duration(
                      milliseconds: (v * duration.inMilliseconds).round(),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 76,
                child: Text(
                  timeLabel,
                  key: const Key('audio-time'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: t.monoFont,
                    fontSize: 11,
                    height: 16 / 11,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: t.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Row(
              spacing: 8,
              children: [
                RaftIcon(RaftGlyph.volume2, size: 13, color: t.muted),
                Expanded(
                  child: _RailSlider(
                    key: const Key('audio-volume'),
                    semanticLabel: raftFormat(
                      context,
                      'Audio volume {filename}',
                      {'filename': filename},
                    ),
                    semanticValue: '${(volume * 100).round()}%',
                    value: volume.clamp(0.0, 1.0),
                    enabled: true,
                    height: 24,
                    rail: 6,
                    thumb: 10,
                    fill: brutal
                        ? t.product.softSignal
                        : t.colors['primary-strong']!,
                    onChanged: (v) => onVolume?.call(v),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The audio rails: a bordered track with a flat fill and a square thumb.
class _RailSlider extends StatelessWidget {
  const _RailSlider({
    super.key,
    required this.value,
    required this.enabled,
    required this.height,
    required this.rail,
    required this.thumb,
    required this.fill,
    required this.onChanged,
    required this.semanticLabel,
    required this.semanticValue,
  });
  final double value, height, rail, thumb;
  final bool enabled;
  final Color fill;
  final ValueChanged<double> onChanged;
  final String semanticLabel, semanticValue;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final line = t.colors['line-muted']!;
    return Semantics(
      slider: true,
      label: semanticLabel,
      value: semanticValue,
      enabled: enabled,
      increasedValue: semanticValue,
      decreasedValue: semanticValue,
      onIncrease: enabled
          ? () => onChanged((value + .05).clamp(0.0, 1.0))
          : null,
      onDecrease: enabled
          ? () => onChanged((value - .05).clamp(0.0, 1.0))
          : null,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          void update(double dx) {
            if (!enabled || w <= 0) return;
            onChanged((dx / w).clamp(0.0, 1.0));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => update(d.localPosition.dx),
            onHorizontalDragStart: (d) => update(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
            child: SizedBox(
              height: height,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: rail,
                    decoration: BoxDecoration(
                      color: t.panel,
                      border: Border.all(color: line),
                    ),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: value,
                      heightFactor: 1,
                      child: ColoredBox(color: fill),
                    ),
                  ),
                  Positioned(
                    left: w * value - thumb / 2,
                    child: Container(
                      width: thumb,
                      height: thumb,
                      decoration: BoxDecoration(
                        color: t.panel,
                        border: Border.all(color: line),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Web MessageItem attachment area: the image gallery, then the inline videos
/// and the inline audio cards (each `space-y-2`), then every other attachment
/// as a wrapping group of cards; 8px between groups.
class RaftAttachmentStack extends StatelessWidget {
  const RaftAttachmentStack({
    super.key,
    this.gallery,
    this.videos = const [],
    this.audios = const [],
    this.others = const [],
  });
  final Widget? gallery;
  final List<Widget> videos, audios, others;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 8,
    children: [
      ?gallery,
      if (videos.isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: videos,
        ),
      if (audios.isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: audios,
        ),
      if (others.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: others),
    ],
  );
}
