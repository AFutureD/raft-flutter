import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import '../platform/attachment_player.dart';
import '../platform/attachment_preview_files.dart';
import '../platform/native_sharing.dart';

/// Seams for suites that mount the real message rows without a decoder (the
/// parity extension suite): files and players handed to every inline card that
/// has no explicit override. Null in the product.
abstract final class InlineMediaTestHooks {
  static AttachmentPreviewFiles? files;
  static AttachmentPlayer Function()? playerFactory;
}

/// Loads one attachment's inline media the way Web's inline cards do: the URL
/// (`disposition=inline`) is read once the card is on screen, then the media is
/// prepared (here: a private local copy opened by the native player) and the
/// card plays it. Failures read as "Download to view".
mixin InlineMediaLoader<T extends StatefulWidget> on State<T> {
  WorkspaceController get controller;
  Map<String, dynamic> get metadata;
  String? get channelId;
  bool get pending;
  bool Function() get authorized;
  AttachmentPreviewFiles? get filesOverride;
  AttachmentPlayer Function()? get playerFactoryOverride;
  bool get wantsVideo;

  /// Whether the card prepares its media as soon as it is near the viewport.
  bool get autoLoad => true;

  /// Bounds of the decoded picture on desktop (see NativeAttachmentPlayer).
  Size get maxVideoSize => const Size(1920, 1080);
  bool get transparentVideo => false;

  /// The media is open and paused at its first frame.
  void mediaReady() {}

  /// Every native playback event, after the state was updated.
  void playbackChanged(AttachmentPlayback value) {}

  final cancel = CancelToken();
  SharedFileLease? lease;
  AttachmentPlayer? player;
  StreamSubscription<AttachmentPlayback>? playbackEvents;
  AttachmentPlayback playback = const AttachmentPlayback();
  RaftInlineMediaState mediaState = RaftInlineMediaState.idle;
  bool disposed = false;

  String get filename => '${metadata['filename'] ?? 'attachment'}';
  bool get current =>
      mounted && !disposed && !cancel.isCancelled && authorized();

  @override
  void initState() {
    super.initState();
    if (!pending && autoLoad) {
      // Web: an IntersectionObserver (160px margin) starts the load once the
      // card is near the viewport; the list only builds rows that are.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(loadMedia());
      });
    }
  }

  Future<void> loadMedia() async {
    if (mediaState == RaftInlineMediaState.loading ||
        mediaState == RaftInlineMediaState.ready) {
      return;
    }
    setState(() => mediaState = RaftInlineMediaState.loading);
    try {
      final url = await controller.attachmentUrl(
        '${metadata['id']}',
        channelId: channelId ?? metadata['channelId'] as String?,
      );
      if (!current) return;
      final prepared =
          await (filesOverride ??
                  InlineMediaTestHooks.files ??
                  AttachmentPreviewFiles())
              .load(url, filename, cancel: cancel, authorized: () => current);
      if (!current) {
        await prepared?.dispose();
        return;
      }
      if (prepared == null) {
        // Too large for a private copy (or the download was refused).
        setState(() => mediaState = RaftInlineMediaState.failed);
        return;
      }
      lease = prepared;
      player =
          (playerFactoryOverride ??
          InlineMediaTestHooks.playerFactory ??
          () => NativeAttachmentPlayer(
            video: wantsVideo,
            maxVideoSize: maxVideoSize,
            transparentVideo: transparentVideo,
          ))();
      playbackEvents = player!.changes.listen((value) {
        if (!current) return;
        setState(() {
          playback = value;
          if (value.error) mediaState = RaftInlineMediaState.failed;
        });
        playbackChanged(value);
      });
      await player!.open(prepared.file);
      if (current) {
        setState(() => mediaState = RaftInlineMediaState.ready);
        mediaReady();
      }
    } catch (_) {
      if (current) setState(() => mediaState = RaftInlineMediaState.failed);
    }
  }

  Future<void> guarded(Future<void> Function(AttachmentPlayer) run) async {
    final p = player;
    if (!current || p == null) return;
    try {
      await run(p);
    } catch (_) {
      if (current) setState(() => mediaState = RaftInlineMediaState.failed);
    }
  }

  @override
  void dispose() {
    disposed = true;
    cancel.cancel();
    final held = player, heldLease = lease, events = playbackEvents;
    unawaited(() async {
      try {
        unawaited(events?.cancel());
        await held?.dispose();
      } catch (_) {
        // A failing native decoder must not retain its private file.
      } finally {
        await heldLease?.dispose();
      }
    }());
    super.dispose();
  }
}

/// Web InlineVideoAttachmentCard.
class InlineVideoAttachment extends StatefulWidget {
  const InlineVideoAttachment({
    super.key,
    required this.controller,
    required this.metadata,
    this.channelId,
    required this.authorized,
    required this.pending,
    this.onOpenPreview,
    this.onDownload,
    this.files,
    this.playerFactory,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> metadata;
  final String? channelId;
  final bool Function() authorized;

  /// An optimistic (still uploading) attachment: no URL yet, spinner shown.
  final bool pending;
  final VoidCallback? onOpenPreview, onDownload;
  final AttachmentPreviewFiles? files;
  final AttachmentPlayer Function()? playerFactory;

  @override
  State<InlineVideoAttachment> createState() => _InlineVideoAttachmentState();
}

class _InlineVideoAttachmentState extends State<InlineVideoAttachment>
    with InlineMediaLoader {
  /// One video plays at a time: the one that last started.
  static _InlineVideoAttachmentState? active;

  /// Videos up to this size prepare their poster (the first frame) as soon as
  /// the card is near the viewport; a larger one waits for the first play.
  static const autoLoadBytes = 24 * 1024 * 1024;

  /// Web's IntersectionObserver margin: a playing video pauses once it is
  /// this far outside the scrolling viewport.
  static const offscreenMargin = 160.0;

  ScrollPosition? watched;
  bool playRequested = false;

  @override
  WorkspaceController get controller => widget.controller;
  @override
  Map<String, dynamic> get metadata => widget.metadata;
  @override
  String? get channelId => widget.channelId;
  @override
  bool get pending => widget.pending;
  @override
  bool Function() get authorized => widget.authorized;
  @override
  AttachmentPreviewFiles? get filesOverride => widget.files;
  @override
  AttachmentPlayer Function()? get playerFactoryOverride =>
      widget.playerFactory;
  @override
  bool get wantsVideo => true;
  @override
  bool get autoLoad {
    final size = metadata['sizeBytes'];
    return size is! num || size <= autoLoadBytes;
  }

  @override
  Size get maxVideoSize => const Size(960, 540);
  @override
  bool get transparentVideo => true;

  /// Server-rendered poster (`thumbnailUrl`), when the server provides one;
  /// otherwise the first decoded frame is the poster.
  String? get posterUrl {
    final value = metadata['thumbnailUrl'];
    return value is String && value.isNotEmpty ? value : null;
  }

  @override
  void mediaReady() {
    if (!playRequested) return;
    playRequested = false;
    unawaited(play());
  }

  @override
  void playbackChanged(AttachmentPlayback value) {
    if (value.playing) {
      if (active != this) {
        final other = active;
        active = this;
        other?.pauseForOther();
      }
      watchViewport();
    } else {
      unwatchViewport();
      if (active == this) active = null;
    }
  }

  void pauseForOther() => unawaited(guarded((p) => p.pause()));

  Future<void> play() async {
    final other = active;
    if (other != null && other != this) {
      active = this;
      other.pauseForOther();
    }
    await guarded((p) => p.toggle());
  }

  Future<void> togglePlay() async {
    if (widget.pending) return;
    if (mediaState == RaftInlineMediaState.idle) {
      // A large video: the first play fetches it, then plays.
      playRequested = true;
      await loadMedia();
      return;
    }
    if (mediaState != RaftInlineMediaState.ready) return;
    final value = playback;
    if (!value.playing &&
        value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 250)) {
      await guarded((p) => p.seek(Duration.zero));
    }
    await play();
  }

  void watchViewport() {
    final position = Scrollable.maybeOf(context)?.position;
    if (position == watched) return;
    unwatchViewport();
    watched = position;
    position?.addListener(checkViewport);
  }

  void unwatchViewport() {
    watched?.removeListener(checkViewport);
    watched = null;
  }

  bool viewportCheckQueued = false;

  /// The scroll offset changed; the cards' paint offsets only follow with the
  /// frame, so measure after it (once per frame).
  void checkViewport() {
    if (viewportCheckQueued || !mounted || !playback.playing) return;
    viewportCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      viewportCheckQueued = false;
      measureViewport();
    });
  }

  void measureViewport() {
    if (!mounted || !playback.playing) return;
    final box = context.findRenderObject();
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        viewport is! RenderBox ||
        !viewport.attached) {
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final bottom = top + box.size.height;
    if (bottom < -offscreenMargin ||
        top > viewport.size.height + offscreenMargin) {
      pauseForOther();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A route or tab hidden behind another one stops its video.
    if (!TickerMode.valuesOf(context).enabled && playback.playing) {
      pauseForOther();
    }
  }

  @override
  void dispose() {
    unwatchViewport();
    if (active == this) active = null;
    super.dispose();
  }

  void openPreview() {
    pauseForOther();
    widget.onOpenPreview?.call();
  }

  @override
  Widget build(BuildContext context) {
    final poster = posterUrl;
    return RaftTooltip(
      message: filename,
      child: RaftInlineVideo(
        state: widget.pending ? RaftInlineMediaState.loading : mediaState,
        filename: filename,
        video: player?.video(),
        poster: poster == null || playback.hasFrame
            ? null
            : RaftSizedImage.network(
                poster,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
        playing: playback.playing,
        position: playback.position,
        duration: playback.duration,
        volume: playback.volume,
        onTogglePlay: () => unawaited(togglePlay()),
        onSeek: (v) => guarded((p) => p.seek(v)),
        onVolume: (v) => guarded((p) => p.volume(v)),
        onOpenPreview: widget.pending || widget.onOpenPreview == null
            ? null
            : openPreview,
        onDownload: widget.onDownload,
      ),
    );
  }
}

/// Web InlineAudioAttachmentCard + InlineAudioPlayer.
class InlineAudioAttachment extends StatefulWidget {
  const InlineAudioAttachment({
    super.key,
    required this.controller,
    required this.metadata,
    this.channelId,
    required this.authorized,
    required this.pending,
    this.onDownload,
    this.files,
    this.playerFactory,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> metadata;
  final String? channelId;
  final bool Function() authorized;
  final bool pending;
  final VoidCallback? onDownload;
  final AttachmentPreviewFiles? files;
  final AttachmentPlayer Function()? playerFactory;

  @override
  State<InlineAudioAttachment> createState() => _InlineAudioAttachmentState();
}

class _InlineAudioAttachmentState extends State<InlineAudioAttachment>
    with InlineMediaLoader {
  @override
  WorkspaceController get controller => widget.controller;
  @override
  Map<String, dynamic> get metadata => widget.metadata;
  @override
  String? get channelId => widget.channelId;
  @override
  bool get pending => widget.pending;
  @override
  bool Function() get authorized => widget.authorized;
  @override
  AttachmentPreviewFiles? get filesOverride => widget.files;
  @override
  AttachmentPlayer Function()? get playerFactoryOverride =>
      widget.playerFactory;
  @override
  bool get wantsVideo => false;

  @override
  Widget build(BuildContext context) => RaftInlineAudio(
    filename: filename,
    state: widget.pending ? RaftInlineMediaState.loading : mediaState,
    playing: playback.playing,
    position: playback.position,
    duration: playback.duration,
    volume: (playback.volume / 100).clamp(0.0, 1.0),
    onDownload: widget.pending ? null : widget.onDownload,
    onTogglePlay: () => guarded((p) => p.toggle()),
    onSeek: (v) => guarded((p) => p.seek(v)),
    onVolume: (v) => guarded((p) => p.volume(v * 100)),
  );
}
