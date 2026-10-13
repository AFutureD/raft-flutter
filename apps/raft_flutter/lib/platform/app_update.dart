import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:raft_client/system_proxy.dart';

import '../data/search_memory.dart';

/// The GitHub release that CI published for one platform (one entry of that
/// platform's `build-manifest-<platform>-<arch>.json`, see tool/release.py).
@immutable
class AppRelease {
  const AppRelease({
    required this.version,
    required this.buildNumber,
    required this.releaseTag,
    required this.artifact,
  });

  /// The compiled app version, e.g. `0.1.0`.
  final String version;

  /// The CI build number (`GITHUB_RUN_NUMBER`): what the newer-than test
  /// compares. Release builds pass it as `--build-number` and as the
  /// `RAFT_BUILD_NUMBER` define.
  final int buildNumber;

  /// The full release tag, e.g. `v0.1.0+5`.
  final String releaseTag;

  /// The platform asset name, e.g. `raft-flutter-0.1.0+5-android-arm64.apk`.
  final String artifact;

  static const repository = 'https://github.com/kevinzhow/raft-flutter';

  /// The human release page.
  Uri get releasePage => Uri.parse('$repository/releases/tag/$releaseTag');

  /// The direct asset download (used on Android, where the browser hands the
  /// APK to the installer).
  Uri get downloadUrl =>
      Uri.parse('$repository/releases/download/$releaseTag/$artifact');

  Map<String, Object?> toJson() => {
    'version': version,
    'buildNumber': buildNumber,
    'releaseTag': releaseTag,
    'artifact': artifact,
  };

  /// Null unless every field is present and well formed. The tag and asset
  /// name end up in a URL, so only plain path-safe characters are accepted.
  static AppRelease? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = raw['version'];
    final tag = raw['releaseTag'];
    final artifact = raw['artifact'];
    final build = switch (raw['buildNumber']) {
      final int n => n,
      final String s => int.tryParse(s.trim()),
      _ => null,
    };
    final safe = RegExp(r'^[A-Za-z0-9._+\-]+$');
    if (version is! String ||
        version.trim().isEmpty ||
        tag is! String ||
        !tag.startsWith('v') ||
        !safe.hasMatch(tag) ||
        artifact is! String ||
        !safe.hasMatch(artifact) ||
        build == null ||
        build < 1) {
      return null;
    }
    return AppRelease(
      version: version.trim(),
      buildNumber: build,
      releaseTag: tag,
      artifact: artifact,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppRelease &&
      other.version == version &&
      other.buildNumber == buildNumber &&
      other.releaseTag == releaseTag &&
      other.artifact == artifact;

  @override
  int get hashCode => Object.hash(version, buildNumber, releaseTag, artifact);
}

/// Parses a build manifest body: a JSON array of receipts (a single object is
/// tolerated). Returns the entry for [platformKey] (`<platform>-<arch>`) with
/// the highest build number, or null when the body is not a valid manifest or
/// has no usable entry.
AppRelease? parseBuildManifest(String body, String platformKey) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  final rows = decoded is List ? decoded : [decoded];
  AppRelease? best;
  for (final row in rows) {
    if (row is! Map) continue;
    if ('${row['platform']}-${row['arch']}' != platformKey) continue;
    final release = AppRelease.fromJson(row);
    if (release != null &&
        (best == null || release.buildNumber > best.buildNumber)) {
      best = release;
    }
  }
  return best;
}

/// `<platform>-<arch>` of the manifest this build updates from, or null when
/// the platform is not distributed on GitHub releases: iOS, web, and Linux
/// outside an AppImage (`APPIMAGE` is exported by the AppImage runtime).
String? appUpdatePlatformKey({
  bool web = kIsWeb,
  TargetPlatform? target,
  Map<String, String>? environment,
}) {
  if (web) return null;
  return switch (target ?? defaultTargetPlatform) {
    TargetPlatform.android => 'android-arm64',
    TargetPlatform.macOS => 'macos-arm64',
    TargetPlatform.windows => 'windows-x64',
    TargetPlatform.linux =>
      (environment ?? Platform.environment)['APPIMAGE']?.isNotEmpty == true
          ? 'appimage-x64'
          : null,
    _ => null,
  };
}

/// Fetches the manifest body at [url]; null when the release has no such
/// file (404). Any other failure throws.
typedef AppUpdateFetcher = Future<String?> Function(Uri url);

/// The production fetcher: plain GET through the app's proxy-aware HTTP stack
/// (Settings > Network), following GitHub's download redirect. It carries no
/// credentials and does not use the rate-limited GitHub REST API.
Future<String?> fetchManifestOverHttp(Uri url) async {
  final dio = createProxiedDio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      maxRedirects: 5,
      validateStatus: (status) => status == 200 || status == 404,
    ),
  );
  try {
    final response = await dio.getUri<String>(url);
    return response.statusCode == 200 ? response.data : null;
  } finally {
    dio.close(force: true);
  }
}

/// Detects a newer CI release and remembers what the user has already seen.
///
/// One manifest request at start (after the first frame) and at most one per
/// [interval] afterwards, triggered by [checkIfDue] on app resume plus one
/// one-shot timer re-armed after each check (no periodic timer). Every failure
/// is silent apart from one diagnostic line per run.
class AppUpdateService extends ChangeNotifier {
  AppUpdateService({
    required this.currentVersion,
    required this.currentBuild,
    required this.platformKey,
    required this.fetch,
    SearchMemoryStorage? storage,
    DateTime Function()? clock,
    this.interval = const Duration(hours: 6),
    this.retryAfterFailure = const Duration(minutes: 30),
    this.scheduleTimer = true,
    void Function(String message)? log,
  }) : storage = storage ?? PreferencesSearchMemoryStorage(),
       _clock = clock ?? DateTime.now,
       _log = log ?? debugPrint;

  /// The service for this running build. Dev/local builds (version with
  /// `-dev`, or no CI build number) and platforms without a GitHub release
  /// asset get a disabled service.
  factory AppUpdateService.forThisBuild({
    String version = const String.fromEnvironment('RAFT_APP_VERSION'),
    String buildNumber = const String.fromEnvironment('RAFT_BUILD_NUMBER'),
    String? platformKey,
    AppUpdateFetcher fetch = fetchManifestOverHttp,
    SearchMemoryStorage? storage,
  }) => AppUpdateService(
    currentVersion: version,
    currentBuild: int.tryParse(buildNumber),
    platformKey: platformKey ?? appUpdatePlatformKey(),
    fetch: fetch,
    storage: storage,
  );

  static const storageKey = 'raft:app-update:v1';
  static const manifestBase =
      '${AppRelease.repository}/releases/latest/download';

  final String currentVersion;
  final int? currentBuild;
  final String? platformKey;
  final AppUpdateFetcher fetch;
  final SearchMemoryStorage storage;
  final DateTime Function() _clock;
  final Duration interval, retryAfterFailure;
  final bool scheduleTimer;
  final void Function(String message) _log;

  AppRelease? _remote;
  int _seen = 0;
  DateTime? _checkedAt, _attemptedAt;
  bool _failedLast = false, _loaded = false, _checking = false;
  bool _loggedFailure = false, _disposed = false;
  Timer? _timer;
  Future<void>? _loading;

  /// Whether this build takes part in update checks at all.
  bool get enabled =>
      platformKey != null &&
      (currentBuild ?? 0) > 0 &&
      currentVersion.isNotEmpty &&
      !currentVersion.contains('-dev');

  /// The newest published release, when it is newer than the running build.
  AppRelease? get available {
    final remote = _remote, build = currentBuild;
    if (!enabled || remote == null || build == null) return null;
    return remote.buildNumber > build ? remote : null;
  }

  /// The red dot: a newer release the user has not looked at yet.
  bool get hasUnseen {
    final release = available;
    return release != null && release.buildNumber > _seen;
  }

  Uri get manifestUrl =>
      Uri.parse('$manifestBase/build-manifest-$platformKey.json');

  /// Reads the remembered state, then checks if one is due. Safe to call
  /// repeatedly.
  Future<void> start() async {
    if (!enabled || _disposed) return;
    await _load();
    await checkIfDue();
  }

  /// Checks unless the last check is recent. Called on resume and by the
  /// one-shot timer.
  Future<void> checkIfDue() async {
    if (!enabled || _disposed || _checking) return;
    await _load();
    final now = _clock();
    final wait = _failedLast ? retryAfterFailure : interval;
    final last = _failedLast ? _attemptedAt : _checkedAt;
    // A clock set back counts as due rather than waiting out the difference.
    if (last != null && !now.isBefore(last) && now.difference(last) < wait) {
      _arm(wait - now.difference(last));
      return;
    }
    await _check();
  }

  Future<void> _check() async {
    _checking = true;
    final key = platformKey!;
    try {
      _attemptedAt = _clock();
      final body = await fetch(manifestUrl);
      if (_disposed) return;
      final release = body == null ? null : parseBuildManifest(body, key);
      _failedLast = false;
      _checkedAt = _attemptedAt;
      // A release without this platform's manifest (or an unusable one) is
      // not an update; keep what was known before.
      if (release != null) _remote = release;
      await _save();
      notifyListeners();
    } catch (error) {
      _failedLast = true;
      if (!_loggedFailure) {
        _loggedFailure = true;
        _log('Update check failed (${error.runtimeType})');
      }
    } finally {
      _checking = false;
      if (!_disposed) _arm(_failedLast ? retryAfterFailure : interval);
    }
  }

  /// Marks the newest known release as seen: the dot goes away until a newer
  /// build is published. The About row stays available.
  void markSeen() {
    final release = available;
    if (_disposed || release == null || release.buildNumber <= _seen) return;
    _seen = release.buildNumber;
    unawaited(_save());
    notifyListeners();
  }

  void _arm(Duration after) {
    if (!scheduleTimer || _disposed) return;
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(checkIfDue()));
  }

  Future<void> _load() => _loading ??= () async {
    try {
      final raw = await storage.read(storageKey);
      final data = raw == null ? null : jsonDecode(raw);
      if (data is Map) {
        _remote = AppRelease.fromJson(data['remote']);
        final seen = data['seen'];
        if (seen is int && seen > 0) _seen = seen;
        final at = data['checkedAt'];
        if (at is int) {
          _checkedAt = DateTime.fromMillisecondsSinceEpoch(at);
        }
      }
    } catch (_) {
      // Unreadable memory behaves like a first run.
    }
    _loaded = true;
    if (!_disposed && (_remote != null || _seen > 0)) notifyListeners();
  }();

  Future<void> _save() async {
    if (!_loaded) return;
    try {
      await storage.write(
        storageKey,
        jsonEncode({
          'checkedAt': _checkedAt?.millisecondsSinceEpoch,
          'remote': _remote?.toJson(),
          'seen': _seen,
        }),
      );
    } catch (_) {
      // The current run still remembers it.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
