import 'dart:async';
import 'dart:io';

import 'package:flutter/rendering.dart' show debugDisableShadows;
import 'package:flutter_test/flutter_test.dart';

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

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = RaftTestBinding();
  final seconds =
      int.tryParse(Platform.environment['RAFT_TEST_TIMEOUT_SECONDS'] ?? '') ??
      60;
  binding.defaultTestTimeout = Timeout(Duration(seconds: seconds));
  await testMain();
}
