import 'dart:async';

import 'package:raft_client/raft_client.dart';

import '../../../data/workspace_controller.dart';
import 'orb_eval_data.dart';

/// A write the app tried to send (POST, PUT, PATCH, DELETE). The fixture
/// records it and answers OK; nothing leaves the device.
class OrbEvalWrite {
  const OrbEvalWrite(this.method, this.path, this.body);
  final String method;
  final String path;
  final Object? body;

  Map<String, Object?> toJson() => {
    'method': method,
    'path': path,
    if (body != null) 'body': body,
  };

  @override
  String toString() => '$method $path';
}

/// The server of a fixture workspace: answers the app's reads from
/// [OrbEvalData] and records every write without sending it. Its origin is a
/// reserved `.invalid` host, so even a request that slipped past [request]
/// could not reach a real server.
class OrbEvalClient extends RaftClient {
  OrbEvalClient(this.data)
    : super(
        origin: 'https://orb-eval.invalid',
        sessionStore: MemorySessionStore(),
      );

  final OrbEvalData data;

  /// Every write, in order.
  final writes = <OrbEvalWrite>[];

  /// Reads nothing answered (an empty object went back).
  final unrouted = <String>[];

  final _ingress = StreamController<RaftEvent>.broadcast(sync: true);
  final _released = Completer<void>();

  @override
  Stream<RaftEvent> get events => _ingress.stream;

  /// A realtime event, as the server's socket would push it.
  void emit(String name, Object? payload) =>
      _ingress.add(RaftEvent(name, payload));

  /// No socket in a fixture.
  @override
  void connect() {}

  @override
  Future<dynamic> request(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    bool authorized = true,
    bool retried = false,
    UploadCancellation? cancellation,
    void Function(int, int)? onSendProgress,
    Map<String, dynamic>? headers,
    bool acceptServerExit = false,
    Duration? receiveTimeout,
  }) async {
    final verb = method.toUpperCase();
    if (verb != 'GET') {
      writes.add(OrbEvalWrite(verb, path, data));
      return <String, dynamic>{'ok': true};
    }
    return _read(path, query ?? const {});
  }

  Future<dynamic> _read(String path, Map<String, dynamic> query) async {
    final d = data;
    switch (path) {
      case '/servers':
        return [_server];
      case '/channels':
        return d.channels;
      case '/channels/dm':
        return d.dms;
      case '/channels/unread':
        return {'channels': d.unread};
      case '/agents':
        return d.agentRows;
      case '/channels/inbox':
        if (d.holdInbox) await _released.future;
        return _inbox(query);
      case '/tasks/server':
        return {'tasks': _tasks(query['status'], null)};
    }
    final members = RegExp(r'^/servers/[^/]+/members$');
    if (members.hasMatch(path)) return d.memberRows;
    final page = RegExp(r'^/messages/channel/([^/]+)$').firstMatch(path);
    if (page != null) return _page(page.group(1)!, query);
    final context = RegExp(r'^/messages/context/([^/]+)$').firstMatch(path);
    if (context != null) {
      final id = Uri.decodeComponent(context.group(1)!);
      return {
        'messages': [
          for (final list in d.messages.values)
            for (final m in list)
              if (m['id'] == id) m,
        ],
      };
    }
    final number = RegExp(r'^/tasks/channel/([^/]+)/number/(\d+)$')
        .firstMatch(path);
    if (number != null) {
      final n = int.parse(number.group(2)!);
      return {'task': d.tasks.where((t) => t['taskNumber'] == n).firstOrNull};
    }
    final tasks = RegExp(r'^/tasks/channel/([^/]+)$').firstMatch(path);
    if (tasks != null) {
      return {'tasks': _tasks(query['status'], tasks.group(1))};
    }
    unrouted.add(path);
    return <String, dynamic>{};
  }

  Map<String, dynamic> get _server => {
    'id': evalServerId,
    'name': 'Fixture HQ',
    'slug': evalServerSlug,
    'role': 'owner',
  };

  List<Map<String, dynamic>> _tasks(Object? status, String? channel) => [
    for (final t in data.tasks)
      if ((status == null || t['status'] == status) &&
          (channel == null || t['channelId'] == channel))
        t,
  ];

  Map<String, dynamic> _page(String id, Map<String, dynamic> query) {
    final all = [...?data.messages[id]]
      ..sort((a, b) => int.parse('${a['seq']}') - int.parse('${b['seq']}'));
    final limit = (query['limit'] as num?)?.toInt() ?? 50;
    final tail = all.length <= limit ? all : all.sublist(all.length - limit);
    return {
      'messages': tail,
      'hasMore': tail.length < all.length,
      'hasNewer': false,
    };
  }

  Map<String, dynamic> _inbox(Map<String, dynamic> query) {
    final rows = data.inbox;
    final offset = (query['offset'] as num?)?.toInt() ?? 0;
    final limit = (query['limit'] as num?)?.toInt() ?? 30;
    final page = rows.skip(offset).take(limit).toList();
    return {
      'items': [for (final r in page) Map<String, dynamic>.of(r)],
      'totalCount': rows.length,
      'totalUnreadCount': rows.fold<int>(
        0,
        (sum, r) => sum + ((r['unreadCount'] as num?)?.toInt() ?? 0),
      ),
      'hasMore': offset + page.length < rows.length,
    };
  }

  @override
  Future<void> dispose() async {
    if (!_released.isCompleted) _released.complete();
    await _ingress.close();
    await super.dispose();
  }
}

/// One scenario's workspace: the fixture server, the client that serves it and
/// the app's own [WorkspaceController] over it, loaded as it is after sign-in.
class OrbEvalWorld {
  OrbEvalWorld._(this.data, this.client, this.workspace);

  final OrbEvalData data;
  final OrbEvalClient client;
  final WorkspaceController workspace;

  static Future<OrbEvalWorld> create(OrbEvalData data) async {
    final client = OrbEvalClient(data)
      ..user = RaftRecord({
        'id': evalMe.id,
        'name': evalMe.name,
        'displayName': evalMe.name,
        'email': 'sam@example.invalid',
      });
    client.selectServer(evalServerId);
    final server = RaftRecord(client._server);
    final workspace = WorkspaceController(client, mobileNavigation: true)
      ..server = server
      ..servers = [server];
    await workspace.selectServer(server);
    workspace
      ..loading = false
      ..notifyListeners();
    return OrbEvalWorld._(data, client, workspace);
  }

  /// The writes the app tried; always empty for a read-only scenario.
  List<OrbEvalWrite> get writes => List.unmodifiable(client.writes);

  Future<void> dispose() async {
    workspace.dispose();
    await client.dispose();
  }
}
