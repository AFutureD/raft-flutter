import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import '../platform/attachment_player.dart';
import '../platform/attachment_player_factory.dart';
import '../platform/attachment_player_sessions.dart';
import '../platform/attachment_stream.dart';

/// Seams for suites that mount the real message rows without a decoder (the
/// parity extension suite): the player handed to every inline card that has no
/// explicit override. Null in the product.
abstract final class InlineMediaTestHooks {
  static AttachmentPlayer Function()? playerFactory;
}

/// Why a card gave its player back (see `InlineMediaLoader.releasePlayer`).
enum PlayerRelease { ended, offscreen, hidden, background, evicted }

/// Loads one attachment's inline media the way Web's inline cards do: the URL
/// (`disposition=inline`) is signed once the card is on screen, then the
/// player opens it and streams it (progressive range reads; nothing is saved
/// or downloaded first) and the card plays it. Failures read as "Download to
/// view".
///
/// The player belongs to a session shared with the full-screen viewer of the
/// same attachment (see [PlayerSessions]): the card holds it, never owns it.
mixin InlineMediaLoader<T extends StatefulWidget> on State<T> {
  WorkspaceController get controller;
  Map<String, dynamic> get metadata;
  String? get channelId;
  bool get pending;
  bool Function() get authorized;
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

  PlayerHold? hold;
  Duration resumeAt = Duration.zero;

  /// A downscaled still of the last picture, shown while no player exists (after
  /// playback ended, or the player was released to free its decoder).
  ui.Image? still;
  final stillKey = GlobalKey();

  AttachmentPlayer? player;
  StreamSubscription<AttachmentPlayback>? playbackEvents;
  AttachmentPlayback playback = const AttachmentPlayback();
  RaftInlineMediaState mediaState = RaftInlineMediaState.idle;
  bool disposed = false;

  String get filename => '${metadata['filename'] ?? 'attachment'}';
  bool get current => mounted && !disposed && authorized();

  /// A full-screen viewer holds this card's player: the card must not pause
  /// or stop it (the viewer shows it).
  bool get viewerHolds => hold?.session.viewerOpen ?? false;

  /// A card must stay built this long before it prepares its player: a fast
  /// scroll past a column of clips would otherwise open (and abandon) one per
  /// clip.
  static const settle = Duration(milliseconds: 250);
  Timer? settleTimer;

  String get mediaKey => attachmentMediaKey(metadata);

  @override
  void initState() {
    super.initState();
    final sessions = controller.playerSessions;
    // A card built again for an attachment prepared earlier shows its last
    // picture and where it stopped, and prepares on a tap (see
    // PlayerSessions.prepared), never by itself.
    still = sessions.stillFor(mediaKey);
    resumeAt = sessions.resumeAt[mediaKey] ?? Duration.zero;
    if (!pending && autoLoad && !sessions.prepared.contains(mediaKey)) {
      // Web: an IntersectionObserver (160px margin) starts the load once the
      // card is near the viewport; the list only builds rows that are.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        waitUntilSeen();
      });
    }
  }

  /// Starts the load once the card has been near the viewport for [settle]
  /// (Web: an IntersectionObserver with a margin). Cards built only because
  /// the list builds ahead of the viewport, or flung past, start nothing.
  void waitUntilSeen() {
    settleTimer?.cancel();
    settleTimer = Timer(settle, () {
      if (!mounted || disposed) return;
      if (nearViewport()) {
        unawaited(loadMedia());
      } else {
        waitUntilSeen();
      }
    });
  }

  /// Whether the card is within [margin] of the scrollable that holds it (a
  /// card outside any scrollable counts as seen).
  bool nearViewport({double margin = 160}) {
    final box = context.findRenderObject();
    final scrollable = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    if (scrollable is! RenderBox || !scrollable.attached) return true;
    final card = box.localToGlobal(Offset.zero) & box.size;
    final view = scrollable.localToGlobal(Offset.zero) & scrollable.size;
    return card.overlaps(view.inflate(margin));
  }

  AttachmentPlayer createPlayer() =>
      (playerFactoryOverride ??
      InlineMediaTestHooks.playerFactory ??
      () => createAttachmentPlayer(
        video: wantsVideo,
        maxVideoSize: maxVideoSize,
        transparentVideo: transparentVideo,
      ))();

  Future<void> loadMedia() async {
    if (mediaState == RaftInlineMediaState.loading ||
        mediaState == RaftInlineMediaState.ready) {
      return;
    }
    setState(() => mediaState = RaftInlineMediaState.loading);
    try {
      final owner = channelId ?? metadata['channelId'] as String?;
      // One player per attachment for the session, shared with the viewer: a
      // clip scrolled out of view and back, or opened full screen, continues
      // from its own stream.
      final acquired = controller.playerSessions.acquire(
        mediaKey,
        scope: controller.attachmentImageScope,
        channelId: owner,
        create: createPlayer,
        source: () => attachmentStreamSource(
          controller,
          '${metadata['id']}',
          channelId: owner,
          start: resumeAt,
        ),
      );
      controller.playerSessions.prepared.add(mediaKey);
      hold = acquired;
      acquired.onEvicted = () => unawaited(releasePlayer(PlayerRelease.evicted));
      player = acquired.player;
      playback = acquired.player.playback;
      playbackEvents = acquired.player.changes.listen((value) {
        if (!current) return;
        setState(() {
          playback = value;
          if (value.error) mediaState = RaftInlineMediaState.failed;
        });
        playbackChanged(value);
        if (value.hasFrame) keepFirstStill();
        if (mediaState == RaftInlineMediaState.ready && playbackEnded(value)) {
          scheduleEndedRelease();
        }
      });
      await acquired.ready;
      if (current && !acquired.orphaned) {
        setState(() {
          playback = acquired.player.playback;
          mediaState = RaftInlineMediaState.ready;
        });
        mediaReady();
      }
    } catch (_) {
      if (current) setState(() => mediaState = RaftInlineMediaState.failed);
    }
  }

  /// Playback reached the end and stopped.
  static bool playbackEnded(AttachmentPlayback value) =>
      !value.playing &&
      !value.error &&
      value.duration > Duration.zero &&
      value.position >= value.duration - const Duration(milliseconds: 250);

  bool endedReleaseQueued = false;
  void scheduleEndedRelease() {
    if (endedReleaseQueued || viewerHolds) return;
    endedReleaseQueued = true;
    // After this frame: the release changes the card's state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      endedReleaseQueued = false;
      if (!mounted || disposed || viewerHolds) return;
      final value = playback;
      if (playbackEnded(value)) unawaited(releasePlayer(PlayerRelease.ended));
    });
  }

  /// How long a card that left the screen keeps its player.
  static const releaseGrace = Duration(seconds: 3);
  Timer? graceTimer;

  /// The card is out of view (scrolled away, route covered, app in the
  /// background): release its player after [releaseGrace], unless the viewer
  /// holds it. [cancelRelease] undoes it when the card is seen again.
  void armRelease(PlayerRelease reason) {
    if (player == null || graceTimer != null || viewerHolds) return;
    graceTimer = Timer(releaseGrace, () {
      graceTimer = null;
      if (!mounted || disposed || viewerHolds) return;
      unawaited(releasePlayer(reason));
    });
  }

  void cancelRelease() {
    graceTimer?.cancel();
    graceTimer = null;
  }

  bool stillQueued = false;

  /// The first picture becomes the card's still in the session (once per
  /// attachment): a card disposed with its player alive (a list drops rows far
  /// from the viewport) still has a picture when it is built again.
  void keepFirstStill() {
    final sessions = controller.playerSessions;
    if (stillQueued || sessions.hasStill(mediaKey)) return;
    stillQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final image = mounted && !disposed ? await captureStill() : null;
      if (image == null) return;
      if (disposed) {
        image.dispose();
        return;
      }
      sessions.keepStill(mediaKey, image);
      image.dispose();
    });
  }

  /// A downscaled still of the picture on screen, or null.
  Future<ui.Image?> captureStill() async {
    final boundary = stillKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !playback.hasFrame) return null;
    try {
      return await boundary.toImage(pixelRatio: 1.5);
    } on Object {
      return null;
    }
  }

  /// Frees the native player (decoder and frame buffers) and keeps a still of
  /// the last picture; the card is idle again and a tap prepares a new player
  /// (a stream: only the ranges needed). [PlayerRelease.ended] restarts at 0,
  /// the others resume where the card was.
  Future<void> releasePlayer(PlayerRelease reason) async {
    final held = hold;
    if (held == null || disposed) return;
    cancelRelease();
    final last = playback;
    final captured = reason == PlayerRelease.evicted && held.orphaned
        ? null
        : await captureStill();
    if (disposed || !mounted || !identical(hold, held)) {
      captured?.dispose();
      return;
    }
    resumeAt = reason == PlayerRelease.ended ? Duration.zero : last.position;
    final sessions = controller.playerSessions;
    sessions.resumeAt[mediaKey] = resumeAt;
    if (captured != null) sessions.keepStill(mediaKey, captured);
    final events = playbackEvents;
    hold = null;
    player = null;
    playbackEvents = null;
    unawaited(events?.cancel());
    held.release();
    final old = still;
    setState(() {
      if (captured != null) still = captured;
      mediaState = RaftInlineMediaState.idle;
      playback = AttachmentPlayback(duration: last.duration, videoSize: last.videoSize);
    });
    if (old != null && captured != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    mediaReleased(reason);
  }

  /// The player was released (see [releasePlayer]).
  void mediaReleased(PlayerRelease reason) {}

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
    settleTimer?.cancel();
    graceTimer?.cancel();
    if (hold != null && !pending) {
      controller.playerSessions.resumeAt[mediaKey] = playbackEnded(playback)
          ? Duration.zero
          : playback.position;
    }
    final events = playbackEvents, held = hold, picture = still;
    hold = null;
    player = null;
    playbackEvents = null;
    still = null;
    picture?.dispose();
    unawaited(events?.cancel());
    // Gives the player back; the session disposes it when nobody holds it
    // (a viewer may still), or keeps it paused for a moment.
    held?.release();
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
    this.playerFactory,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> metadata;
  final String? channelId;
  final bool Function() authorized;

  /// An optimistic (still uploading) attachment: no URL yet, spinner shown.
  final bool pending;
  final VoidCallback? onOpenPreview, onDownload;
  final AttachmentPlayer Function()? playerFactory;

  @override
  State<InlineVideoAttachment> createState() => _InlineVideoAttachmentState();
}

class _InlineVideoAttachmentState extends State<InlineVideoAttachment>
    with InlineMediaLoader, WidgetsBindingObserver {
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
    hold?.touch();
    if (value.playing) {
      if (active != this) {
        final other = active;
        active = this;
        other?.pauseForOther();
      }
    } else if (active == this) {
      active = null;
    }
  }

  /// Another card started, this one scrolled away or got covered: pause,
  /// unless the viewer holds the player (it is playing there).
  void pauseForOther() {
    if (viewerHolds) return;
    unawaited(guarded((p) => p.pause()));
  }

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
      // A large video: the first play prepares the player, then plays.
      playRequested = true;
      await loadMedia();
      return;
    }
    if (mediaState == RaftInlineMediaState.loading) {
      // The player is still being prepared: the tap is kept and honoured the
      // moment it is ready (mediaReady), never dropped.
      playRequested = true;
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
    if (viewportCheckQueued || !mounted) return;
    viewportCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      viewportCheckQueued = false;
      measureViewport();
    });
  }

  void measureViewport() {
    if (!mounted) return;
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
    final outside =
        bottom < -offscreenMargin ||
        top > viewport.size.height + offscreenMargin;
    if (outside) {
      // A playing video pauses at once (Web); its player is released after a
      // grace period so a quick scroll back finds it.
      if (playback.playing) pauseForOther();
      armRelease(PlayerRelease.offscreen);
    } else {
      cancelRelease();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    watchViewport();
    // A route or tab hidden behind another one stops its video and, after a
    // grace period, frees its player.
    if (!TickerMode.valuesOf(context).enabled) {
      if (playback.playing) pauseForOther();
      armRelease(PlayerRelease.hidden);
    } else {
      cancelRelease();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      armRelease(PlayerRelease.background);
    } else if (state == AppLifecycleState.resumed) {
      cancelRelease();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unwatchViewport();
    if (active == this) active = null;
    super.dispose();
  }

  /// The viewer takes this card's player over (same stream, same position);
  /// the card neither pauses nor releases it.
  void openPreview() => widget.onOpenPreview?.call();

  @override
  Widget build(BuildContext context) {
    final poster = posterUrl;
    return RaftTooltip(
      message: filename,
      child: RaftInlineVideo(
        state: widget.pending ? RaftInlineMediaState.loading : mediaState,
        filename: filename,
        video: player == null
            ? null
            : RepaintBoundary(key: stillKey, child: player!.video()),
        poster: playback.hasFrame
            ? null
            : still != null
            // ignore: raft_lints/avoid_raw_image_decode -- Paints the released player's still: a ui.Image captured from the video RepaintBoundary at display size (toImage), not a decode.
            ? RawImage(image: still, fit: BoxFit.contain)
            : poster == null
            ? null
            : RaftSizedImage.network(
                poster,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
        playing: playback.playing,
        buffering: playback.buffering,
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
    this.playerFactory,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> metadata;
  final String? channelId;
  final bool Function() authorized;
  final bool pending;
  final VoidCallback? onDownload;
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
  AttachmentPlayer Function()? get playerFactoryOverride =>
      widget.playerFactory;
  @override
  bool get wantsVideo => false;

  bool playRequested = false;

  @override
  void mediaReady() {
    if (!playRequested) return;
    playRequested = false;
    unawaited(guarded((p) => p.toggle()));
  }

  /// A tap on an audio card whose player is released or still being prepared
  /// prepares it and plays as soon as it is ready; it is never dropped.
  Future<void> togglePlay() async {
    if (widget.pending) return;
    if (mediaState == RaftInlineMediaState.idle) {
      playRequested = true;
      await loadMedia();
    } else if (mediaState == RaftInlineMediaState.loading) {
      playRequested = true;
    } else if (mediaState == RaftInlineMediaState.ready) {
      await guarded((p) => p.toggle());
    }
  }

  @override
  Widget build(BuildContext context) => RaftInlineAudio(
    filename: filename,
    state: widget.pending ? RaftInlineMediaState.loading : mediaState,
    playing: playback.playing,
    position: playback.position,
    duration: playback.duration,
    volume: (playback.volume / 100).clamp(0.0, 1.0),
    onDownload: widget.pending ? null : widget.onDownload,
    onTogglePlay: () => unawaited(togglePlay()),
    onSeek: (v) => guarded((p) => p.seek(v)),
    onVolume: (v) => guarded((p) => p.volume(v * 100)),
  );
}
