import 'dart:async';

/// How long live listening goes on with nobody speaking before it stops by
/// itself. The microphone of a live session streams to the model all the
/// time, and silence is billed as input audio.
const agentLiveIdleLimit = Duration(seconds: 30);

/// What the person is told when it stops.
const agentLiveIdleNotice = '30 秒没听到声音，先停了，点一下继续';

/// Stops a live session that nobody uses: [onIdle] runs once [limit] has
/// passed with no sign of life. A sign of life is [touch]: the person's words
/// arrived, the model is speaking, a tool ran. [busy] is asked when the time
/// is up; while the model is still talking or working it is not idle, and
/// the wait starts over.
class AgentLiveGuard {
  AgentLiveGuard({
    required this.onIdle,
    this.busy,
    this.limit = agentLiveIdleLimit,
  });

  final void Function() onIdle;
  final bool Function()? busy;
  final Duration limit;
  Timer? _timer;

  bool get running => _timer != null;

  /// Live listening began (or goes on).
  void start() => _arm();

  /// Something happened: the wait starts over. A guard that is not running
  /// stays off.
  void touch() {
    if (running) _arm();
  }

  /// Live listening ended.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(limit, () {
      _timer = null;
      if (busy?.call() ?? false) {
        _arm();
        return;
      }
      onIdle();
    });
  }
}
