import 'dart:async';
import 'dart:ui' show Image, VoidCallback;

import 'attachment_player.dart';

/// Players that live outside the card or page that shows them.
///
/// An inline card and the full-screen viewer of the same attachment share one
/// player (one stream, one buffer, one position): the viewer takes the card's
/// player over instead of opening the URL again, and gives it back on close.
/// Ownership is by reference count, not by widget: each holder [acquire]s and
/// [PlayerHold.release]s, and the player is disposed when the last holder is
/// gone (a viewer outlives a card that scrolled away; a card outlives the
/// viewer it opened). Nothing here touches the disk: a stream is the player's
/// own bounded read-ahead.
///
/// [maxLive] is a soft cap (a native decoder holds tens of megabytes of frame
/// buffers, 4K ones several times that): a new player evicts the least
/// recently used one that no viewer holds and that is not playing; its holder
/// is told ([PlayerHold.onEvicted]) and falls back to a still picture. Players
/// that are playing or held by a viewer are never evicted, so when every live
/// player is one of those the count can exceed [maxLive]. A card also releases its player when playback ends or when
/// it leaves the screen (see `InlineMediaLoader`): holding a decoder is for
/// what the user is looking at.
///
/// A session is dropped (player disposed, holders orphaned) when the identity
/// scope changes ([synchronize]: account, server, role, sign-out) or a channel
/// is revoked ([invalidateChannel]); holders keep their own authority checks.
class PlayerSessions {
  PlayerSessions({this.maxLive = 2, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final int maxLive;
  final DateTime Function() _now;
  final Map<String, PlayerSession> _sessions = {};
  Object? _scope;

  /// HDR verdicts per attachment (bounded; the colour boxes are read once),
  /// dropped with the sessions on an identity change.
  final Map<String, bool> hdrVerdicts = {};

  /// Attachments a card has prepared this session. A card that is built again
  /// (a list disposes the rows far from the viewport) does not prepare it
  /// again by itself: that would be a new stream every time a clip scrolls back
  /// into view. It shows its still picture and prepares on a tap.
  final Set<String> prepared = {};

  /// Where a released card stopped, per attachment (zero after the end).
  final Map<String, Duration> resumeAt = {};
  static const maxStills = 24;
  final Map<String, Image> _stills = {};

  bool hasStill(String key) => _stills.containsKey(key);

  /// A copy of the still picture kept for [key] (the caller disposes it), or
  /// null. Small (a card's size), bounded by [maxStills], most recent last.
  Image? stillFor(String key) => _stills[key]?.clone();

  /// Keeps [image] (a copy is made; the caller still owns its own) as the
  /// picture of [key].
  void keepStill(String key, Image image) {
    _stills.remove(key)?.dispose();
    _stills[key] = image.clone();
    while (_stills.length > maxStills) {
      final oldest = _stills.keys.first;
      _stills.remove(oldest)?.dispose();
    }
  }

  /// Players created since the start (tests).
  int created = 0;
  int get length => _sessions.length;

  /// The hold of [key]: the live session when there is one, otherwise a new
  /// one. [create] makes the player and [source] the thing it opens; both are
  /// used only by the call that starts the session. Tests and the product call
  /// this synchronously: the player exists at once, [PlayerHold.ready] completes
  /// when it has opened its source.
  PlayerHold acquire(
    String key, {
    Object? scope,
    String? channelId,
    bool viewer = false,
    required AttachmentPlayer Function() create,
    required Future<AttachmentSource> Function() source,
  }) {
    synchronize(scope);
    var session = _sessions[key];
    if (session != null && session.failed) {
      // A failed open is not shared with the next card that asks.
      _sessions.remove(key);
      session._orphan();
      session = null;
    }
    if (session == null) {
      created++;
      session = PlayerSession._(this, key, channelId, create());
      _sessions[key] = session;
      session._start(source);
      _enforceCap(session);
    }
    session.lastUsed = _now();
    return PlayerHold._(session, viewer: viewer);
  }

  /// Over [maxLive]: evict the least recently used session that is not [keep],
  /// has no viewer and is not playing.
  void _enforceCap(PlayerSession keep) {
    while (_sessions.length > maxLive) {
      final candidates = [
        for (final s in _sessions.values)
          if (!identical(s, keep) && s.viewers == 0 && !s.player.playback.playing) s,
      ]..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
      if (candidates.isEmpty) return;
      candidates.first._evict();
    }
  }

  void _gone(PlayerSession session) {
    if (identical(_sessions[session.key], session)) _sessions.remove(session.key);
  }

  /// Revocation: nothing held for [channelId] survives.
  void invalidateChannel(String channelId) {
    for (final session in _sessions.values.toList()) {
      if (session.channelId == channelId) session._drop();
    }
  }

  /// Drops everything held for another identity.
  void synchronize(Object? scope) {
    if (scope == _scope) return;
    _scope = scope;
    clear();
  }

  void clear() {
    hdrVerdicts.clear();
    prepared.clear();
    resumeAt.clear();
    for (final image in _stills.values) {
      image.dispose();
    }
    _stills.clear();
    for (final session in _sessions.values.toList()) {
      session._drop();
    }
  }

  void dispose() => clear();
}

class PlayerSession {
  PlayerSession._(this._owner, this.key, this.channelId, this.player);
  final PlayerSessions _owner;
  final String key;
  final String? channelId;
  final AttachmentPlayer player;
  int holders = 0, viewers = 0;
  bool failed = false, closed = false, opened = false;
  DateTime lastUsed = DateTime.fromMillisecondsSinceEpoch(0);
  final List<PlayerHold> _holds = [];
  Future<void>? _opening;

  /// Whether a full-screen viewer holds the player (a card leaves a playing
  /// video alone then: the picture is on the viewer).
  bool get viewerOpen => viewers > 0;

  void _start(Future<AttachmentSource> Function() source) {
    final opening = () async {
      final resolved = await source();
      if (closed) return;
      await player.open(resolved);
      opened = true;
    }();
    _opening = opening.catchError((Object error) {
      failed = true;
      throw error;
    });
    // Holders await it; nobody may be left with an unhandled error.
    unawaited(_opening!.catchError((_) {}));
  }

  void _orphan() {
    if (closed) return;
    closed = true;
    // Straight to dispose (no pause first): a native video view stays on
    // screen until its player is released, and every frame it lingers after
    // the route started to leave is visible.
    unawaited(() async {
      try {
        await player.dispose();
      } on Object {
        // A failing native player must not keep anything.
      }
    }());
  }

  void _drop() {
    _owner._gone(this);
    _orphan();
  }

  void _evict() {
    final holds = _holds.toList();
    _drop();
    for (final hold in holds) {
      hold.onEvicted?.call();
    }
  }

  void _release(PlayerHold hold, bool viewer) {
    _holds.remove(hold);
    if (holders > 0) holders--;
    if (viewer && viewers > 0) viewers--;
    // The last holder frees the native player (decoder, frame buffers).
    if (holders == 0) _drop();
  }
}

/// One holder's claim on a session. [release] gives it back (idempotent).
class PlayerHold {
  PlayerHold._(this.session, {required this.viewer}) {
    session.holders++;
    session._holds.add(this);
    if (viewer) session.viewers++;
  }
  final PlayerSession session;
  final bool viewer;
  bool _released = false;

  AttachmentPlayer get player => session.player;

  /// Completes when the player has opened its source; throws what the open
  /// threw (shared by every holder of the session).
  Future<void> get ready => session._opening!;

  /// Whether the session was dropped under this holder (identity change,
  /// revocation, or the last other holder is gone and this one is released).
  bool get orphaned => session.closed;

  /// The session was dropped to make room for another player (see
  /// [PlayerSessions.maxLive]): show a still picture, hold nothing.
  VoidCallback? onEvicted;

  /// Marks the player as just used (the LRU order of the cap).
  void touch() => session.lastUsed = DateTime.now();

  /// Gives the player back. The last holder to leave frees it at once.
  void release() {
    if (_released) return;
    _released = true;
    session._release(this, viewer);
  }
}
