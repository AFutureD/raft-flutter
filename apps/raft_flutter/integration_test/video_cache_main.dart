// Prototype evidence harness for the on-disk video cache (not part of the
// app): plays real files with the platform's real player, scripted, and logs
// what the player did and what the upstream really sent.
//
//   tool/video-parity-range-server <dir with the media> 8791
//   tool/flutter build linux --profile -t integration_test/video_cache_main.dart \
//     --dart-define=VC_BASE=http://127.0.0.1:8791 --dart-define=VC_FILES=short20.mp4,long180.mp4
//
// Android emulator: VC_BASE=http://10.0.2.2:8791 (cleartext to that host is
// already allowed by network_security_config.xml). Output lines start with
// `VCP ` (stdout on Linux, logcat tag `flutter` on Android).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:raft_flutter/platform/attachment_player.dart';
import 'package:raft_flutter/platform/attachment_player_factory.dart';
import 'package:raft_flutter/platform/video_cache.dart';

const _base = String.fromEnvironment(
  'VC_BASE',
  defaultValue: 'http://127.0.0.1:8791',
);
const _files = String.fromEnvironment(
  'VC_FILES',
  defaultValue: 'short20.mp4,long180.mp4',
);
const _phases = String.fromEnvironment(
  'VC_PHASES',
  defaultValue: 'cold,warm,direct',
);
const _rate = String.fromEnvironment('VC_RATE', defaultValue: '');

// Desktop runs can override the compile-time defaults from the environment.
String env(String name, String fallback) =>
    Platform.environment[name] ?? fallback;
final base = env('VC_BASE', _base);
final files = env('VC_FILES', _files);
final phases = env('VC_PHASES', _phases);
final rate = env('VC_RATE', _rate);
final started = Stopwatch()..start();
final current = ValueNotifier<AttachmentPlayer?>(null);

void log(String text) {
  final line =
      'VCP ${(started.elapsedMilliseconds / 1000).toStringAsFixed(1).padLeft(6)}s $text';
  debugPrint(line);
  // Windows GUI builds have no stdout: VC_LOG names a file to append to.
  final file = Platform.environment['VC_LOG'];
  if (file != null && file.isNotEmpty) {
    File(file).writeAsStringSync('$line\n', mode: FileMode.append);
  }
}

Future<Map<String, dynamic>> stats([bool reset = false]) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('$base/${reset ? '__reset' : '__stats'}'),
    );
    final response = await request.close();
    return jsonDecode(await utf8.decodeStream(response))
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<(int bytes, int requests)> upstream(String file) async {
  final all = (await stats())['files'] as Map<String, dynamic>;
  final f = all[file] as Map<String, dynamic>?;
  return (
    f == null ? 0 : f['bytes'] as int,
    f == null ? 0 : f['requests'] as int,
  );
}

Future<bool> until(bool Function() ok, {int seconds = 20}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    if (ok()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return ok();
}

class Run {
  Run(this.label, this.file);
  final String label, file;
  final result = <String, Object?>{};
  late AttachmentPlayer player;
  AttachmentPlayback get now => player.playback;
  int bufferingEvents = 0;
}

Future<void> playthrough(
  String label,
  String file, {
  required bool cache,
}) async {
  VideoCache.debugEnabled = cache;
  await stats(true);
  final run = Run(label, file);
  final player = createAttachmentPlayer(video: true);
  run.player = player;
  current.value = player;
  final total = Stopwatch()..start();
  final firstFrame = Completer<int>();
  var wasBuffering = false;
  final sub = player.changes.listen((p) {
    if (p.hasFrame && p.videoSize != null && !firstFrame.isCompleted) {
      firstFrame.complete(total.elapsedMilliseconds);
    }
    if (p.buffering && !wasBuffering) run.bufferingEvents++;
    wasBuffering = p.buffering;
    if (p.error) log('$label $file ERROR ${p.failure}');
  });
  final query = rate.isEmpty ? '' : '?rate=$rate';
  final source = AttachmentSource.network(
    Uri.parse('$base/$file$query'),
    cacheKey: 'harness-$file',
  );
  log('$label $file open (cache=$cache)');
  await player.open(source);
  final openMs = total.elapsedMilliseconds;
  final ttff = await firstFrame.future.timeout(
    const Duration(seconds: 30),
    onTimeout: () => -1,
  );
  run.result
    ..['openMs'] = openMs
    ..['firstFrameMs'] = ttff;
  log(
    '$label $file opened in ${openMs}ms, first frame at ${ttff}ms, duration ${now(run).duration}',
  );
  final length = now(run).duration;
  final looping =
      cache && length > Duration.zero && length <= kLoopingVideoMaxDuration;

  await player.toggle();
  final playedAt = total.elapsedMilliseconds;
  final playing = await until(
    () =>
        now(run).playing &&
        now(run).position > const Duration(milliseconds: 1500),
  );
  run.result['playMs'] = total.elapsedMilliseconds - playedAt;
  log('$label $file playing=$playing position=${now(run).position}');

  // Seeks: middle, near the end, back to the start.
  final seeks = <String, Object?>{};
  for (final (name, fraction) in [('50%', 0.5), ('90%', 0.9), ('10%', 0.1)]) {
    final target = Duration(
      milliseconds: (length.inMilliseconds * fraction).round(),
    );
    final watch = Stopwatch()..start();
    await player.seek(target);
    final ok = await until(
      () =>
          now(run).playing &&
          now(run).position >= target + const Duration(milliseconds: 300) &&
          now(run).position < target + const Duration(seconds: 6),
    );
    seeks[name] = ok ? watch.elapsedMilliseconds : -1;
    log(
      '$label $file seek $name -> ${ok ? 'resumed' : 'STUCK'} after ${watch.elapsedMilliseconds}ms at ${now(run).position}',
    );
  }
  run.result['seekToPlayingMs'] = seeks;
  final afterSeeks = await upstream(file);
  run.result['upstreamAfterSeeks'] = afterSeeks.$1;

  if (looping) {
    // Watch it run past its end: position must wrap while it keeps playing.
    var wraps = 0, previous = now(run).position;
    var stayedPlaying = true;
    final watch = Stopwatch()..start();
    final watchFor = Duration(
      milliseconds: (length.inMilliseconds * 1.8).round(),
    );
    while (watch.elapsed < watchFor) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final p = now(run);
      if (p.position + length * 0.5 < previous) {
        wraps++;
      }
      if (!p.playing &&
          p.position < length - const Duration(milliseconds: 300)) {
        stayedPlaying = false;
      }
      previous = p.position;
    }
    run.result
      ..['looped'] = wraps
      ..['stayedPlaying'] = stayedPlaying
      ..['playingAtEnd'] = now(run).playing;
    log(
      '$label $file loop: wraps=$wraps stayedPlaying=$stayedPlaying playing=${now(run).playing} position=${now(run).position}',
    );
  } else {
    // Play to the end, then replay (what a user does with a long video).
    await player.seek(length - const Duration(seconds: 4));
    await until(() => now(run).playing, seconds: 5);
    final ended = await until(
      () =>
          !now(run).playing &&
          now(run).position >= length - const Duration(milliseconds: 800),
      seconds: 30,
    );
    run.result['ended'] = ended;
    log('$label $file ended=$ended position=${now(run).position}');
    final beforeReplay = await upstream(file);
    final replay = Stopwatch()..start();
    run.bufferingEvents = 0;
    // What the viewer does on play at the end (togglePlay): seek to 0, then
    // toggle.
    await player.seek(Duration.zero);
    final afterSeek = now(run).playing;
    await player.toggle();
    // mpv can resume by itself when it is seeked away from its end, so the
    // toggle may have paused it: note it and press play once more.
    var extraToggle = false;
    if (!await until(() => now(run).playing, seconds: 3)) {
      extraToggle = true;
      await player.toggle();
    }
    log(
      '$label $file replay: playing right after seek=$afterSeek, second toggle needed=$extraToggle',
    );
    run.result['replayExtraToggle'] = extraToggle;
    final replayed = await until(
      () =>
          now(run).playing &&
          now(run).position > const Duration(milliseconds: 1500),
      seconds: 20,
    );
    run.result
      ..['replayMs'] = replayed ? replay.elapsedMilliseconds : -1
      ..['replayBufferingEvents'] = run.bufferingEvents;
    await Future<void>.delayed(const Duration(seconds: 3));
    final afterReplay = await upstream(file);
    run.result['replayUpstreamBytes'] = afterReplay.$1 - beforeReplay.$1;
    run.result['replayUpstreamRequests'] = afterReplay.$2 - beforeReplay.$2;
    log(
      '$label $file replay ok=$replayed in ${replay.elapsedMilliseconds}ms, upstream bytes during replay '
      '${afterReplay.$1 - beforeReplay.$1} in ${afterReplay.$2 - beforeReplay.$2} requests',
    );
  }

  await player.pause();
  final end = await upstream(file);
  run.result
    ..['upstreamBytes'] = end.$1
    ..['upstreamRequests'] = end.$2
    ..['fileOnDiskBytes'] = cache ? await VideoCache.sizeBytes() : null;
  await sub.cancel();
  await player.dispose();
  current.value = null;
  log('$label $file RESULT ${jsonEncode(run.result)}');
}

AttachmentPlayback now(Run run) => run.player.playback;

/// The host answers 403 (an expired signature; five times on Android: four player attempts and the diagnosis probe, because
/// ExoPlayer retries a failed load three times before it reports the error): the proxy must hand the
/// 403 to the player so its own re-sign path (`refresh`) runs, and playback
/// then continues from the same cache key.
Future<void> expiredCase(String file) async {
  VideoCache.debugEnabled = true;
  await VideoCache.clear();
  await stats(true);
  final client = HttpClient();
  final fail = await client.getUrl(
    Uri.parse(
      '$base/__fail?file=$file&status=403&count=${Platform.isAndroid ? 5 : 2}',
    ),
  );
  await (await fail.close()).drain<void>();
  client.close();
  final player = createAttachmentPlayer(video: true);
  current.value = player;
  var refreshed = 0;
  final source = AttachmentSource.network(
    Uri.parse('$base/$file?sig=old'),
    cacheKey: 'harness-expired-$file',
    refresh: () async {
      refreshed++;
      return Uri.parse('$base/$file?sig=new');
    },
  );
  Object? error;
  try {
    await player.open(source);
    await player.toggle();
  } catch (e) {
    error = e;
  }
  final played = await until(
    () =>
        player.playback.playing &&
        player.playback.position > const Duration(seconds: 2),
    seconds: 25,
  );
  final (bytes, requests) = await upstream(file);
  log(
    'expired $file: open error=$error refreshCalls=$refreshed playing=$played '
    'error=${player.playback.error} position=${player.playback.position} upstream requests=$requests',
  );
  await player.dispose();
  current.value = null;
}

/// Dart-side GET latency to the upstream, without any player: new
/// connection each time, then one kept-alive client, with and without an idle
/// gap in between (separates the emulator's network path from the proxy).
Future<void> netProbe(String file) async {
  final url = Uri.parse('$base/$file');
  Future<int> get(HttpClient client) async {
    final watch = Stopwatch()..start();
    final request = await client.getUrl(url);
    request.headers.set('range', 'bytes=0-0');
    final response = await request.close();
    final headers = watch.elapsedMilliseconds;
    await response.drain<void>();
    return headers;
  }

  // Event loop wake-up with no network involved: a 20 ms timer, after idle.
  final late = <int>[];
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final watch = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    late.add(watch.elapsedMilliseconds - 20);
  }
  log('netprobe 20ms timer after 1.5 s idle: lateness ms=$late');
  for (final gap in [0, 1500]) {
    final fresh = <int>[], reused = <int>[];
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration(milliseconds: gap));
      final client = HttpClient();
      fresh.add(await get(client));
      client.close(force: true);
    }
    final client = HttpClient();
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration(milliseconds: gap));
      reused.add(await get(client));
    }
    client.close(force: true);
    log('netprobe gap=${gap}ms new-connection ms=$fresh kept-alive ms=$reused');
  }
}

Future<void> scenario() async {
  VideoCache.debugTrace = (line) => log('proxy $line');
  await Future<void>.delayed(const Duration(seconds: 1));
  log(
    'start base=$base files=$files phases=$phases platform=${Platform.operatingSystem}',
  );
  for (final file in files.split(',')) {
    for (final phase in phases.split(',')) {
      try {
        switch (phase) {
          case 'cold':
            await VideoCache.clear();
            await playthrough('cold', file, cache: true);
          case 'warm':
            await playthrough('warm', file, cache: true);
          case 'direct':
            await playthrough('direct', file, cache: false);
          case 'expired':
            await expiredCase(file);
          case 'netprobe':
            await netProbe(file);
          case 'direct2':
            await playthrough('direct2', file, cache: false);
        }
      } catch (error, stack) {
        log('$phase $file FAILED $error\n$stack');
      }
    }
  }
  log('DONE');
  await Future<void>.delayed(const Duration(seconds: 1));
  if (!Platform.isAndroid && !Platform.isIOS) {
    exit(0);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: 640,
            height: 360,
            child: ValueListenableBuilder<AttachmentPlayer?>(
              valueListenable: current,
              builder: (context, player, _) =>
                  player?.video() ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(scenario()));
}
