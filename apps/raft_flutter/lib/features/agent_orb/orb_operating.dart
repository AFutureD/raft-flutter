import 'package:flutter/foundation.dart';

/// The orb's "Agent is operating" notifier: the `ValueNotifier<bool>` of
/// `OrbToolContext.operating`, with two extras for the shell.
///
/// Contract for tools that change the screen:
/// - set `operating.value = true` when starting to move the screen;
/// - name what was opened for the toast ("Agent 打开了 X · 点屏幕即可接管")
///   with [OrbOperating.describe]; without it the shell uses the tool call's
///   `target` / `name` / `title` argument;
/// - after every await, check `operating.value`: a user pointer-down on the
///   app content sets it back to false. That is the cancellation: stop, leave
///   the screen as the user has it, return `{'cancelled': true}`;
/// - clear it (`value = false`) when done if the screen should be the user's
///   again at once; otherwise it stays on until the user touches the screen
///   or the model's turn ends.
class OrbOperating extends ValueNotifier<bool> {
  OrbOperating() : super(false);

  String? _label;

  /// What the agent opened, for the toast.
  String? get label => _label;
  set label(String? next) {
    if (next == _label) return;
    _label = next;
    if (value) notifyListeners();
  }

  /// How many times the user took over; a tool may compare it with the count
  /// it saw when it started.
  int takeovers = 0;

  /// The user touched the app: ends [value] and counts as a cancellation.
  void takeOver() {
    if (!value) return;
    takeovers++;
    value = false;
  }

  /// Names what the agent opened. A no-op for a plain notifier (tests).
  static void describe(ValueNotifier<bool> operating, String label) {
    if (operating is OrbOperating) operating.label = label;
  }
}
