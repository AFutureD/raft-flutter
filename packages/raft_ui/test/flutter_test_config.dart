import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart' show imageCache;
import 'package:flutter/rendering.dart' show debugDisableShadows;
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';
import 'package:raft_ui/raft_ui.dart' show RaftHotImages, RaftImageBytes;

/// The binding every test in this directory runs on.
///
/// `flutter_test` hands `package:test` an explicit 10 minute timeout for each
/// `testWidgets`, which overrides `dart_test.yaml`, so the bound has to be set
/// on the binding before any test is declared. A hanging test then fails after
/// 60 seconds (`RAFT_TEST_TIMEOUT_SECONDS` overrides) instead of stalling the
/// gate. A test that legitimately needs longer passes its own `timeout:`.
///
/// Every test file now has a test binding, which installs flutter_test's mock
/// `HttpClient` (always 400). A plain `test()` that talks to a real loopback
/// server must set `HttpOverrides.global = null;` first.
///
/// Because this binding exists before a test file's `main` runs, a test file
/// cannot construct its own binding subclass; [showShadows] covers the one
/// case that needed one.
class RaftTestBinding extends AutomatedTestWidgetsFlutterBinding {
  /// Call in `main` to paint real (blurred) shadows, like a device does.
  static void showShadows() {
    _visibleShadows = true;
    debugDisableShadows = false;
  }

  static bool _visibleShadows = false;

  @override
  bool get disableShadows => !_visibleShadows;
}

/// Leak tracking (`leak_tracker`) runs in every `testWidgets`: an object that
/// reaches the garbage collector without `dispose()` fails its test file
/// ("notDisposed"). `RAFT_LEAK_TRACKING=0` turns it off for a local run.
void _enableLeakTracking() {
  if (Platform.environment['RAFT_LEAK_TRACKING'] == '0') return;
  LeakTesting.enable();
  // The shared image cache keeps decoded images (and their handles) after a
  // test ends; they are not leaks of the test, so empty it before the report.
  tearDown(() {
    // Avatars are held by RaftHotImages beyond the widget tree (that is its
    // job); release them with the cache.
    RaftHotImages.instance.releaseAll();
    RaftImageBytes.instance = RaftImageBytes();
    RaftImageBytes.resetClient();
    imageCache
      ..clear()
      ..clearLiveImages();
  });
  // `RAFT_LEAK_STACKS=1` adds the creation stack to every report.
  if (Platform.environment['RAFT_LEAK_STACKS'] == '1') {
    LeakTesting.settings = LeakTesting.settings.withCreationStackTrace();
  }
  // Not-GC'ed tracking stays off (the default; stated so a newer leak_tracker
  // default cannot turn it on): it forces GC cycles in the end-of-file report,
  // which is slow and load-dependent. Only 'notDisposed' is reported.
  LeakTesting.settings = LeakTesting.settings.withIgnored(
    allNotGCed: true,
    classes: const [
      // Process-wide singleton (`_RaftFocusVisible.shared`): never disposed.
      '_RaftFocusVisible',
    ],
  );
}

/// A test file that still leaks calls this first thing in `main` with the
/// classes it leaks (and a comment saying why). It is the per-file debt ledger:
/// the file stays tracked for everything else, and deleting the line is how the
/// debt is paid. New leaks in a clean file fail it.
void leakDebt(List<String> classes) {
  if (!LeakTesting.enabled) return;
  LeakTesting.settings = LeakTesting.settings.withIgnored(classes: classes);
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _enableLeakTracking();
  final binding = RaftTestBinding();
  final seconds =
      int.tryParse(Platform.environment['RAFT_TEST_TIMEOUT_SECONDS'] ?? '') ??
      60;
  binding.defaultTestTimeout = Timeout(Duration(seconds: seconds));
  await testMain();
}
