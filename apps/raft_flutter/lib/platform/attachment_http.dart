import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// The app-wide HTTP client for attachment storage hosts.
///
/// Every attachment transfer used to build its own `Dio`, hence its own
/// `HttpClient` and connection pool, so each open paid DNS + TCP + TLS again.
/// One long-lived client keeps those connections alive between opens (and
/// between the list preview and the lightbox of the same host).
///
/// It is deliberately separate from the Raft API client: no interceptors, no
/// default headers, no cookies. A signed storage URL is the only credential it
/// ever carries, so API tokens can never reach a storage host through it.
class AttachmentHttp {
  AttachmentHttp._();

  /// Idle connections stay pooled this long (the platform default is 15 s,
  /// shorter than the gap between two typical previews).
  static const idleTimeout = Duration(seconds: 60);
  static const maxConnectionsPerHost = 8;

  static Dio? _shared;
  static final Map<String, DateTime> _warmed = {};

  /// The shared client, created on first use.
  static Dio get shared => _shared ??= create();

  /// A new client with the storage configuration. Tests and the latency probe
  /// call this directly (with [configure] for a test certificate); production
  /// code uses [shared].
  static Dio create({void Function(HttpClient)? configure}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..idleTimeout = idleTimeout
          ..maxConnectionsPerHost = maxConnectionsPerHost;
        configure?.call(client);
        return client;
      },
    );
    return dio;
  }

  /// Opens (and pools) a connection to the storage host of [url] before the
  /// real transfer, so the transfer finds TCP and TLS already done. Sends a
  /// credential-free `HEAD` to the host root: the signed path and query never
  /// leave the caller. Failures are ignored; at most one per host per 45 s.
  static void warmHost(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    final origin = '${uri.scheme}://${uri.host}:${uri.port}';
    final now = DateTime.now();
    final last = _warmed[origin];
    if (last != null && now.difference(last) < const Duration(seconds: 45)) {
      return;
    }
    _warmed[origin] = now;
    shared
        .head<void>(
          '$origin/',
          options: Options(
            validateStatus: (_) => true,
            followRedirects: false,
            receiveTimeout: const Duration(seconds: 5),
            sendTimeout: const Duration(seconds: 5),
          ),
        )
        .then<void>((_) {}, onError: (Object _) {});
  }

  /// Closes the pool (app teardown, tests). The next [shared] builds a new one.
  static void close() {
    _shared?.close(force: false);
    _shared = null;
    _warmed.clear();
  }

  /// Test hook: replaces the shared client.
  static void debugReplace(Dio? dio) {
    _shared = dio;
    _warmed.clear();
  }
}
