import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import '../platform/attachment_player.dart';
import '../platform/attachment_preview_files.dart';
import '../platform/native_sharing.dart';

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
    if (!pending) {
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
      final prepared = await (filesOverride ?? AttachmentPreviewFiles()).load(
        url,
        filename,
        cancel: cancel,
        authorized: () => current,
      );
      if (!current || prepared == null) {
        await prepared?.dispose();
        return;
      }
      lease = prepared;
      player =
          (playerFactoryOverride ??
          () => NativeAttachmentPlayer(video: wantsVideo))();
      playbackEvents = player!.changes.listen((value) {
        if (!current) return;
        setState(() {
          playback = value;
          if (value.error) mediaState = RaftInlineMediaState.failed;
        });
      });
      await player!.open(prepared.file);
      if (current) setState(() => mediaState = RaftInlineMediaState.ready);
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
  Widget build(BuildContext context) => RaftTooltip(
    message: filename,
    child: RaftInlineVideo(
      state: widget.pending ? RaftInlineMediaState.loading : mediaState,
      filename: filename,
      video: player?.video(),
      onOpenPreview: widget.pending ? null : widget.onOpenPreview,
      onDownload: widget.onDownload,
    ),
  );
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
