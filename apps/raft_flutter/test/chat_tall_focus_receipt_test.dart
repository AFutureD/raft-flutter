import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

import 'chat_tall_focus_scenario.dart';

void main() {
  for (final (family, dark) in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets(
      '[P01] $family/$dark centered tall context publishes and releases its cache in a keyboard viewport',
      (tester) => checkTallFocusReceipt(tester, family: family, dark: dark),
    );
  }
}
