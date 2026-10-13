import 'package:flutter/widgets.dart';

/// A full-bleed overlay that owns state in the workspace tree (the attachment
/// preview: its owner closes it when disposed) holds the workspace layout
/// while it is open. The overlay covers the workspace and adapts itself, so
/// the layout beneath it catches up the moment it closes.
abstract final class LayoutHold {
  // ignore: raft_lints/avoid_unreleased_resource -- Process-wide singleton counter, never torn down.
  static final ValueNotifier<int> count = ValueNotifier(0);
  static bool get held => count.value > 0;

  static void hold(TransitionRoute<dynamic> route) {
    count.value++;
    route.completed.whenComplete(() => count.value--);
  }
}
