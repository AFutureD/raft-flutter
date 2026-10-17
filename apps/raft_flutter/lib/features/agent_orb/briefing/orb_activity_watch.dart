import 'package:flutter/foundation.dart';

/// Tells when the Activity window holds something new: a row that was not
/// there, or one whose newest message or unread count changed. The inbox
/// store notifies for much more (a read, a refresh with the same rows); this
/// stays quiet for those, so driving mode re-reads the briefing only when
/// there is something to read.
///
/// It listens to [source] from its creation until [dispose].
class OrbActivityWatch extends ChangeNotifier {
  OrbActivityWatch({required Listenable source, required this.rows})
    : _source = source {
    _last = _signature();
    source.addListener(_changed);
  }

  final Listenable _source;

  /// The rows of the Activity window as it is now.
  final List<Map<String, dynamic>> Function() rows;
  late String _last;
  bool _disposed = false;

  String _signature() => [
    for (final r in rows())
      '${r['channelId'] ?? r['id']}:'
          '${r['latestActivityMessageId'] ?? r['lastMessageId'] ?? r['latestMessageId']}:'
          '${r['unreadCount']}:${r['replyCount']}:${r['kind']}',
  ].join('|');

  void _changed() {
    if (_disposed) return;
    final now = _signature();
    if (now == _last) return;
    _last = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _source.removeListener(_changed);
    super.dispose();
  }
}
