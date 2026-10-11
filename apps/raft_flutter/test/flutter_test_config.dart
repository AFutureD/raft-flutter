import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `testWidgets` is bounded. `flutter_test` hands `package:test` an
/// explicit 10 minute timeout, which overrides `dart_test.yaml`, so the bound
/// has to be set on the binding. A hanging test then fails in about a minute
/// (set `RAFT_TEST_TIMEOUT_SECONDS` to change it) instead of stalling the gate.
/// A test that legitimately needs longer passes its own `timeout:`.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final seconds =
      int.tryParse(Platform.environment['RAFT_TEST_TIMEOUT_SECONDS'] ?? '') ??
      60;
  if (binding is AutomatedTestWidgetsFlutterBinding) {
    binding.defaultTestTimeout = Timeout(Duration(seconds: seconds));
  }
  await testMain();
}
