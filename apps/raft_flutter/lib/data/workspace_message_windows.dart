import 'package:flutter/foundation.dart';

import 'conversation_window.dart';

/// Read ports over the existing window owners. There is no transport, ledger,
/// request ticket, persistence or read-receipt execution in this adapter.
class WorkspaceMessageWindows {
  WorkspaceMessageWindows({
    required this.authority,
    required this.read,
    required this.visible,
  });
  final Object? Function(ConversationWindowScope) authority;
  final ConversationWindowSnapshot Function(ConversationWindowScope) read;
  final bool Function(ConversationWindowScope) visible;
  final _windows = <ConversationWindowScope, _ProjectedConversationWindow>{};
  bool _disposed = false;

  ConversationWindow? channel(String? id) =>
      id == null ? null : _open((channelId: id, parentMessageId: null));
  ConversationWindow? thread(
    String? parentChannelId,
    String? parentMessageId,
  ) => parentChannelId == null || parentMessageId == null
      ? null
      : _open((channelId: parentChannelId, parentMessageId: parentMessageId));

  ConversationWindow? _open(ConversationWindowScope scope) {
    if (_disposed) return null;
    final token = authority(scope);
    if (token == null) return null;
    var window = _windows[scope];
    if (window != null && window.token != token) {
      _windows.remove(scope);
      window.retire();
      window = null;
    }
    return window ??= _windows[scope] = _ProjectedConversationWindow(
      scope,
      token,
      read(scope),
      () => !_disposed && authority(scope) == token,
      () => visible(scope),
    );
  }

  /// Called after existing state mutations; only changed windows publish.
  void synchronize() {
    if (_disposed) return;
    for (final entry in _windows.entries.toList()) {
      final window = entry.value;
      if (authority(entry.key) != window.token) {
        _windows.remove(entry.key);
        window.retire();
      } else {
        window.refresh(read(entry.key));
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final window in _windows.values) {
      window.retire(notify: false);
    }
    _windows.clear();
  }
}

class _ProjectedConversationWindow extends ConversationWindow {
  _ProjectedConversationWindow(
    this.scope,
    this.token,
    this._snapshot,
    this._current,
    this._visible,
  );
  @override
  final ConversationWindowScope scope;
  final Object token;
  ConversationWindowSnapshot _snapshot;
  final bool Function() _current, _visible;
  final _changes = _WindowChanges();
  bool _retired = false;
  static final _empty = ConversationWindowSnapshot(retired: true);

  @override
  Listenable get changes => _changes;
  @override
  ConversationWindowSnapshot get snapshot =>
      _retired || !_current() ? _empty : _snapshot;
  @override
  bool get visible => !_retired && _current() && _visible();

  void refresh(ConversationWindowSnapshot next) {
    if (_retired || _snapshot.samePresentation(next)) return;
    _snapshot = next;
    _changes.publish();
  }

  void retire({bool notify = true}) {
    if (_retired) return;
    _retired = true;
    _snapshot = _empty;
    if (notify) _changes.publish();
    _changes.dispose();
  }
}

class _WindowChanges extends ChangeNotifier {
  void publish() => notifyListeners();
}
