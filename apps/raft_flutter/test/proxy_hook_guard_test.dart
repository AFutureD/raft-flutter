import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every network path must follow the shared proxy decision (system / manual /
/// direct): see docs/system-proxy.md. This scans `lib/` of the app and of every
/// package for the constructors that open a connection of their own and fails
/// on one that is not routed through `SystemProxy`.
///
/// A new `HttpClient()`, `Dio()` or `WebSocket.connect()` must either use
/// `createProxiedDio` / `SystemProxy.instance.createHttpClient()` /
/// `proxiedWebSocketConnector`, or get an entry below that says why it is
/// exempt. Entry counts are exact.
const _patterns = <String, String>{
  'HttpClient()': r'(?<![A-Za-z_])HttpClient\(',
  'Dio()': r'(?<![A-Za-z_.])Dio\(',
  'IOHttpClientAdapter()': r'IOHttpClientAdapter\(',
  'WebSocket.connect()': r'WebSocket\.connect\(',
  'socket.io io()': r'(?<![A-Za-z_])io\.io\(',
  'findProxyFromEnvironment': r'findProxyFromEnvironment',
  'http.Client()': r'(?<![A-Za-z_])(?:http\.)?(?:IOClient|Client)\(',
};

const _allow = <String, Map<String, int>>{
  // The hook itself.
  'packages/raft_client/lib/src/proxy/transport_io.dart': {
    'Dio()': 1,
    'IOHttpClientAdapter()': 1,
    'WebSocket.connect()': 1,
  },
  'packages/raft_client/lib/src/proxy/transport_stub.dart': {'Dio()': 1},
  'packages/raft_client/lib/src/proxy/system_proxy.dart': {
    'HttpClient()': 1, // createHttpClient
    'findProxyFromEnvironment': 2, // env override + the overrides hook
  },
  // The socket.io client; applyProxyTransport() below proves it is wired.
  'packages/raft_client/lib/src/client.dart': {'socket.io io()': 1},
};

void main() {
  final root = Directory.current.path.endsWith('apps/raft_flutter')
      ? Directory('../..')
      : Directory('.');
  final libs = <Directory>[
    Directory('${root.path}/apps/raft_flutter/lib'),
    for (final entry in Directory('${root.path}/packages').listSync())
      if (entry is Directory) Directory('${entry.path}/lib'),
  ].where((d) => d.existsSync());

  Iterable<(String, String)> sources() sync* {
    for (final dir in libs) {
      for (final file in dir.listSync(recursive: true)) {
        if (file is File && file.path.endsWith('.dart')) {
          final relative = file.path.substring(root.path.length + 1);
          yield (relative.replaceAll(r'\', '/'), file.readAsStringSync());
        }
      }
    }
  }

  String code(String text) => text
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('no network client is created outside the shared proxy hook', () {
    final found = <String, Map<String, int>>{};
    for (final (path, text) in sources()) {
      final body = code(text);
      for (final MapEntry(key: name, value: pattern) in _patterns.entries) {
        final count = RegExp(pattern).allMatches(body).length;
        if (count > 0) found.putIfAbsent(path, () => {})[name] = count;
      }
    }
    final problems = <String>[];
    for (final MapEntry(key: path, value: kinds) in found.entries) {
      for (final MapEntry(key: kind, value: count) in kinds.entries) {
        final allowed = _allow[path]?[kind] ?? 0;
        if (count != allowed) {
          problems.add(
            '$path: $count x $kind (allowed $allowed). Build it with '
            'createProxiedDio / SystemProxy.createHttpClient / '
            'proxiedWebSocketConnector, or document an exemption here.',
          );
        }
      }
    }
    for (final MapEntry(key: path, value: kinds) in _allow.entries) {
      for (final kind in kinds.keys) {
        if (found[path]?[kind] == null) {
          problems.add('$path: allowlist entry for $kind no longer matches.');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  String read(String path) => File('${root.path}/$path').readAsStringSync();

  test('the API client builds its Dio and socket through the hook', () {
    final client = read('packages/raft_client/lib/src/client.dart');
    expect(client, contains('createProxiedDio('));
    expect(client, contains('applyProxyTransport('));
  });

  test('app start-up installs the resolver and the process-wide overrides', () {
    final main = read('apps/raft_flutter/lib/main.dart');
    expect(main, contains('startSystemProxy('));
    final boot = read(
      'apps/raft_flutter/lib/platform/system_proxy_bootstrap.dart',
    );
    expect(boot, contains('installGlobally()'));
    // Avatars and other third-party image loaders create plain HttpClient()s;
    // only the override covers them.
    final chatUi = read('packages/flutter_chat_ui/lib/src/avatar.dart');
    expect(chatUi, contains('CachedNetworkImage'));
  });

  test('the media player stays file-only (it opens no network connection)', () {
    // media_kit/mpv does its own networking. While the whitelist is `file`, the
    // downloaded attachment (fetched through the proxy-aware Dio) is all it
    // opens. Widening it needs mpv's `http-proxy` property wired to SystemProxy.
    final player = read(
      'apps/raft_flutter/lib/platform/attachment_player.dart',
    );
    expect(player, contains("protocolWhitelist: ['file']"));
  });
}
