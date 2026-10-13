// Helpers for `player_interactions_test.dart`: the range server's counters and
// the mailbox to the host runner (`tool/player-interactions`), which performs
// what only the host can (adb key events and swipes, screen recordings, the
// system save dialog).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class PlayerLab {
  PlayerLab(this.base, {required this.hostDriven});
  final String base;

  /// A host runner is polling the mailbox (`--dart-define=VP_HOST=true`).
  final bool hostDriven;

  Future<Map<String, dynamic>> _get(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final response = await (await client.getUrl(Uri.parse('$base$path'))).close();
      return jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> reset() => _get('/__reset');

  Future<void> failNext(String file, {int status = 403, int count = 1}) =>
      _get('/__fail?file=$file&status=$status&count=$count');

  Future<ServerStats> stats() async => ServerStats(await _get('/__stats'));

  /// Asks the host runner to do [command] and waits for it. Returns the
  /// runner's result text, or null when no runner is attached.
  Future<String?> host(WidgetTester tester, String command, {int seconds = 30}) async {
    if (!hostDriven) return null;
    await _get('/__cmd?set=${Uri.encodeQueryComponent(command)}');
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
      final state = await _get('/__cmd?poll');
      if (state['done'] == true) return state['result'] as String? ?? '';
    }
    throw TestFailure('The host runner did not answer "$command" in $seconds s.');
  }
}

/// What the server really sent.
class ServerStats {
  ServerStats(this.json);
  final Map<String, dynamic> json;

  List<Map<String, dynamic>> get log => [
    for (final entry in json['log'] as List) Map<String, dynamic>.from(entry as Map),
  ];

  Map<String, dynamic> _file(String file) =>
      Map<String, dynamic>.from(((json['files'] as Map)[file] ?? const {'requests': 0, 'bytes': 0, 'size': 0}) as Map);

  int bytes(String file) => _file(file)['bytes'] as int;
  int requests(String file) => _file(file)['requests'] as int;

  /// Requests for [file] that asked for a byte range (a streaming player
  /// does; `Dio.download` does not).
  int ranged(String file) => log.where((e) => e['file'] == file && e['range'] != null).length;

  /// Requests for [file] made by the app's Dart HTTP client: a download
  /// (`Dio`/`HttpClient` send a `Dart/...` user agent), as opposed to the
  /// native player (ExoPlayer, AVPlayer) reading the stream itself.
  int dart(String file) =>
      log.where((e) => e['file'] == file && '${e['ua']}'.startsWith('Dart')).length;

  /// Requests for [file] made by anything but the Dart client.
  int player(String file) =>
      log.where((e) => e['file'] == file && !'${e['ua']}'.startsWith('Dart')).length;
}

/// Pumps real time until [done] holds; the failure names [what].
Future<Duration> until(
  WidgetTester tester,
  bool Function() done,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > timeout) throw TestFailure('Timed out after ${timeout.inSeconds} s waiting for: $what');
    await tester.pump(const Duration(milliseconds: 50));
  }
  return watch.elapsed;
}

/// A tap at the centre of [finder] as a finger would do it (through the
/// gesture arena, hit-testing what is really on top there).
Future<void> tapCentre(WidgetTester tester, Finder finder) async {
  final at = tester.getCenter(finder);
  await tester.tapAt(at);
  await tester.pump();
}

Offset centreOf(WidgetTester tester, Finder finder) => tester.getCenter(finder);
