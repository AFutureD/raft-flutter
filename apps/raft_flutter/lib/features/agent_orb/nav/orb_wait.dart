import 'dart:async';

import 'package:flutter/foundation.dart';

/// The most a tool waits for a page's first data.
const orbNavigateWait = Duration(seconds: 5);

/// What `describe_page` waits for when a page is still loading.
const orbDescribeWait = Duration(seconds: 2);

/// A time budget for waiting on a page's loading signals.
///
/// It never sleeps: [until] returns the moment the page says it is ready (the
/// listenable notifies and the check passes), and gives up only when the cap
/// passes or the person takes over (the operating flag falls). One budget is
/// shared by every wait of one tool call, so the cap bounds the whole call.
class OrbWaitBudget {
  OrbWaitBudget(this.cap, {this.operating});

  /// A budget that waits for nothing: a snapshot of what is there now.
  OrbWaitBudget.none() : cap = Duration.zero, operating = null;

  final Duration cap;

  /// Falls to false when the person touches the screen: the wait ends.
  final ValueListenable<bool>? operating;

  Timer? _timer;
  final Completer<void> _expired = Completer<void>();
  bool _started = false, _disposed = false;
  bool timedOut = false;
  bool interrupted = false;

  /// True when the person took over, or the time is gone.
  bool get over => timedOut || interrupted;

  void _start() {
    if (_started || _disposed) return;
    _started = true;
    if (cap <= Duration.zero) {
      timedOut = true;
      return;
    }
    _timer = Timer(cap, () {
      timedOut = true;
      if (!_expired.isCompleted) _expired.complete();
    });
  }

  /// Completes true when [ready] holds, false when the budget is over first.
  /// [source] is what notifies when the page's loading state may have changed.
  Future<bool> until(Listenable? source, bool Function() ready) async {
    if (ready()) return true;
    _start();
    if (over || _disposed) return ready();
    final done = Completer<bool>();
    void check() {
      if (!done.isCompleted && ready()) done.complete(true);
    }

    void takenOver() {
      if (operating != null && !operating!.value) {
        interrupted = true;
        if (!done.isCompleted) done.complete(ready());
      }
    }

    source?.addListener(check);
    operating?.addListener(takenOver);
    unawaited(
      _expired.future.then((_) {
        if (!done.isCompleted) done.complete(ready());
      }),
    );
    try {
      return await done.future;
    } finally {
      source?.removeListener(check);
      operating?.removeListener(takenOver);
    }
  }

  /// [future]'s value, or null when the budget is over first (the future goes
  /// on; nothing waits for it). A failure of [future] is rethrown.
  Future<T?> within<T>(Future<T> future) async {
    final settled = ValueNotifier<bool>(false);
    T? value;
    Object? failure;
    StackTrace? trace;
    var waiting = true, finished = false;
    void release() {
      if (!waiting && finished) settled.dispose();
    }

    unawaited(
      future.then(
        (v) {
          value = v;
          finished = true;
          if (waiting) settled.value = true;
          release();
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          trace = stack;
          finished = true;
          if (waiting) settled.value = true;
          release();
        },
      ),
    );
    await until(settled, () => finished);
    waiting = false;
    // A future that settles after the budget is over finds the notifier
    // released here.
    release();
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return finished ? value : null;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (!_expired.isCompleted) _expired.complete();
  }
}
