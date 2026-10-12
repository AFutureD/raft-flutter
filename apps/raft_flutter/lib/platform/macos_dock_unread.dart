import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:app_badge_plus/app_badge_plus.dart';

import '../data/source_activity_unread_store.dart';
import '../data/source_server_unread.dart';
import '../data/workspace_controller.dart';

/// One app-wide Activity count. The selected server's shared inbox replaces
/// its summary count; channel/thread counters are never added a second time.
class MacOSDockUnread {
  MacOSDockUnread({
    TargetPlatform? platform,
    Future<void> Function(int)? write,
    this.refreshInterval = const Duration(seconds: 30),
  }) : supported =
           !kIsWeb &&
           (platform ?? defaultTargetPlatform) == TargetPlatform.macOS,
       _write = write ?? _writeNative;

  static Future<void> _writeNative(int count) =>
      AppBadgePlus.updateBadge(count);

  final bool supported;
  final Duration refreshInterval;
  final Future<void> Function(int) _write;
  WorkspaceController? _workspace;
  SourceActivityUnreadStore? _activity;
  SourceServerUnreadStore? _servers;
  Interceptor? _reads;
  StreamSubscription<dynamic>? _events;
  Timer? _periodic, _debounce;
  String? _scope;
  bool _closed = false;
  int? _wanted, _written;
  int _revision = 0;
  Future<void> _tail = Future.value();
  Future<void> get settled => _tail;

  void bind(WorkspaceController? next) {
    if (!supported || _closed) return;
    if (!identical(next, _workspace)) {
      _detach();
      _workspace = next;
      if (next != null) {
        _activity = next.acquireActivityUnread(this)..addListener(_publish);
        _servers = SourceServerUnreadStore(next)..addListener(_publish);
        next.addListener(_sync);
        _events = next.client.events.listen((event) {
          _sync();
          if (const {
            'rooms:joined',
            'message:new',
            'message:deleted',
            'thread:updated',
            'dm:new',
            'notification_prefs:updated',
            'server:membership-removed',
          }.contains(event.name)) {
            _scheduleRefresh();
          }
        });
        // Reconcile cross-server totals after a persisted read, including
        // read-all performed elsewhere in this process.
        _reads = InterceptorsWrapper(
          onResponse: (response, handler) {
            final request = response.requestOptions;
            if (request.method == 'POST' &&
                (RegExp(r'^/channels/[^/]+/read(?:-all)?$')
                        .hasMatch(request.path) ||
                    request.path == '/channels/inbox/read-all')) {
              _scheduleRefresh();
            }
            handler.next(response);
          },
        );
        next.client.http.interceptors.add(_reads!);
        _periodic = Timer.periodic(
          refreshInterval,
          (_) => unawaited(refresh()),
        );
      }
    }
    _sync();
  }

  void _sync() {
    if (_closed) return;
    final w = _workspace;
    final next = w?.client.signedIn == true ? _activity?.scope : null;
    final changed = next != _scope;
    _scope = next;
    _servers?.synchronize();
    _publish();
    if (changed && next != null) unawaited(refresh());
  }

  void _publish() {
    if (_closed) return;
    final w = _workspace;
    var total = 0;
    if (w != null &&
        w.client.signedIn &&
        _scope == _activity?.scope &&
        _scope != null) {
      // Membership directory bounds the receipt: revoked/unknown servers
      // cannot contribute. Push muting affects alerts, not unread state.
      final ids = {for (final server in w.servers) server.id, w.server!.id};
      for (final id in ids) {
        total += id == w.server!.id && _activity!.totalUnreadCount != null
            ? _activity!.totalUnreadCount!
            : (_servers?[id]?.activityUnreadCount ?? 0);
      }
    }
    _set(total);
  }

  void _scheduleRefresh() {
    if (_closed || _scope == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      _debounce = null;
      unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    if (_closed || _scope == null) return;
    await _servers?.refresh();
    _sync();
  }

  void _set(int count) {
    if (_wanted == count && _written == count) return;
    _wanted = count;
    final ticket = ++_revision;
    _tail = _tail.then((_) async {
      // A late queued count must not restore a badge after logout/retirement.
      if (ticket != _revision) return;
      try {
        await _write(count);
        _written = count;
      } catch (_) {
        // Optional platform service. The next synchronization retries it.
        _written = null;
      }
    });
  }

  void _detach() {
    _workspace?.removeListener(_sync);
    if (_reads != null) _workspace?.client.http.interceptors.remove(_reads);
    _reads = null;
    unawaited(_events?.cancel());
    _events = null;
    _activity?.removeListener(_publish);
    _workspace?.releaseActivityUnread(this);
    _activity = null;
    _servers?.removeListener(_publish);
    _servers?.dispose();
    _servers = null;
    _periodic?.cancel();
    _debounce?.cancel();
    _workspace = null;
    _scope = null;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _detach();
    if (supported) _set(0);
    await _tail;
  }
}
