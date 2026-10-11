import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_sharing.dart';

enum IncomingShareStagingState { preparing, ready, failed }

/// One incoming share whose attachments are copied into the private inbox in
/// the background. The target picker is presented as soon as the intent
/// arrives; this object carries the per-item progress it shows and the copy's
/// outcome that the hand-off awaits. Nothing is sent or drafted until then.
class IncomingShareStaging extends ChangeNotifier {
  IncomingShareStaging(this.raw)
    : state = raw.token == null
          ? IncomingShareStagingState.preparing
          : IncomingShareStagingState.ready,
      staged = raw.token == null ? null : raw;
  final IncomingShare raw;
  IncomingShareStagingState state;
  IncomingShare? staged;
  int copied = 0;
  bool cancelled = false;
  final _outcome = Completer<IncomingShare>();
  late final Future<IncomingShare?> settled = _outcome.future
      .then<IncomingShare?>((share) => share, onError: (Object _) => null);

  int get total => raw.files.length;
  bool get failed => state == IncomingShareStagingState.failed;
  bool get preparing => state == IncomingShareStagingState.preparing;

  /// Completes with the staged share, or throws when the copy failed or was
  /// cancelled. Safe to await more than once.
  Future<IncomingShare> get result => _outcome.future;

  void start(
    Future<IncomingShare> Function(void Function(int copied) progress) run,
  ) {
    if (_outcome.isCompleted) return;
    if (staged != null) {
      _outcome.complete(staged);
      return;
    }
    // A failure is surfaced through [state]; unobserved futures stay quiet.
    unawaited(_outcome.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(() async {
      try {
        final share = await run((count) {
          copied = count;
          notifyListeners();
        });
        staged = share;
        state = IncomingShareStagingState.ready;
        _outcome.complete(share);
      } catch (error) {
        state = IncomingShareStagingState.failed;
        _outcome.completeError(error);
      }
      notifyListeners();
    }());
  }

  /// Stops copying at the next item boundary and removes what was copied.
  void cancel() => cancelled = true;
}
