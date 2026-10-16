import 'package:flutter/foundation.dart';

import 'agent_capability.dart';

/// Where a confirmed operation is: running, finished, or failed.
enum AgentActionPhase { running, done, failed }

/// One operation the person confirmed, as the confirm card shows it from then
/// on: the same card, now with the outcome (and, when there is one, the thing
/// that was made or changed and the way back).
@immutable
class AgentActionRecord {
  const AgentActionRecord({
    required this.id,
    required this.capabilityId,
    required this.preview,
    required this.phase,
    required this.at,
    this.text,
    this.entity,
    this.undoLabel,
    this.undoUntil,
    this.undone = false,
    this.canRetry = false,
  });

  /// The confirmToken the operation ran under.
  final String id;
  final String capabilityId;
  final AgentActionPreview preview;
  final AgentActionPhase phase;
  final DateTime at;

  /// The outcome: "已发送", "已改为 进行中", or the error.
  final String? text;

  /// What it made or changed.
  final AgentPreviewRef? entity;

  /// The way back ("改回 待办") and until when it is offered.
  final String? undoLabel;
  final DateTime? undoUntil;
  final bool undone;
  final bool canRetry;

  bool undoOpen(DateTime now) =>
      !undone &&
      undoLabel != null &&
      undoUntil != null &&
      now.isBefore(undoUntil!);

  AgentActionRecord copyWith({
    AgentActionPhase? phase,
    String? text,
    AgentPreviewRef? entity,
    String? undoLabel,
    DateTime? undoUntil,
    bool? undone,
    bool? canRetry,
    bool clearUndo = false,
  }) => AgentActionRecord(
    id: id,
    capabilityId: capabilityId,
    preview: preview,
    phase: phase ?? this.phase,
    at: at,
    text: text ?? this.text,
    entity: entity ?? this.entity,
    undoLabel: clearUndo ? null : undoLabel ?? this.undoLabel,
    undoUntil: clearUndo ? null : undoUntil ?? this.undoUntil,
    undone: undone ?? this.undone,
    canRetry: canRetry ?? this.canRetry,
  );
}

/// The confirmed operations on screen, newest last. [AgentCapabilityTools]
/// writes it as an operation starts and ends; the consent tray draws it, so
/// a confirm card turns into its result without a new card appearing.
class AgentActionBoard extends ChangeNotifier {
  AgentActionBoard({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// A finished card stays this long (its undo is offered for less).
  static const linger = Duration(seconds: 45);

  /// A failure stays until it is dismissed or retried, up to this many.
  static const maxRecords = 4;

  final _records = <AgentActionRecord>[];

  List<AgentActionRecord> get records => List.unmodifiable(_records);

  AgentActionRecord? operator [](String id) =>
      _records.where((r) => r.id == id).firstOrNull;

  void _put(AgentActionRecord r) {
    final i = _records.indexWhere((x) => x.id == r.id);
    if (i < 0) {
      _records.add(r);
      while (_records.length > maxRecords) {
        _records.removeAt(0);
      }
    } else {
      _records[i] = r;
    }
    notifyListeners();
  }

  void running(String id, String capabilityId, AgentActionPreview preview) =>
      _put(
        AgentActionRecord(
          id: id,
          capabilityId: capabilityId,
          preview: preview,
          phase: AgentActionPhase.running,
          at: _now(),
        ),
      );

  void done(
    String id, {
    required String text,
    AgentPreviewRef? entity,
    String? undoLabel,
    DateTime? undoUntil,
  }) {
    final r = this[id];
    if (r == null) return;
    _put(
      AgentActionRecord(
        id: id,
        capabilityId: r.capabilityId,
        preview: r.preview,
        phase: AgentActionPhase.done,
        at: _now(),
        text: text,
        entity: entity,
        undoLabel: undoLabel,
        undoUntil: undoUntil,
      ),
    );
  }

  void failed(String id, String message, {bool canRetry = true}) {
    final r = this[id];
    if (r == null) return;
    _put(
      AgentActionRecord(
        id: id,
        capabilityId: r.capabilityId,
        preview: r.preview,
        phase: AgentActionPhase.failed,
        at: _now(),
        text: message,
        canRetry: canRetry,
      ),
    );
  }

  /// The operation was taken back: the card says so and offers nothing more.
  void undone(String id, String text) {
    final r = this[id];
    if (r == null) return;
    _put(r.copyWith(text: text, undone: true, clearUndo: true));
  }

  /// A retry or undo began.
  void busy(String id) {
    final r = this[id];
    if (r == null) return;
    _put(r.copyWith(phase: AgentActionPhase.running, clearUndo: true));
  }

  void dismiss(String id) {
    if (_records.any((r) => r.id == id)) {
      _records.removeWhere((r) => r.id == id);
      notifyListeners();
    }
  }

  /// When the next card or undo runs out, for a timer.
  DateTime? get nextChange {
    DateTime? next;
    for (final r in _records) {
      if (r.phase == AgentActionPhase.failed ||
          r.phase == AgentActionPhase.running) {
        continue;
      }
      for (final t in [r.at.add(linger), ?r.undoUntil]) {
        if (next == null || t.isBefore(next)) next = t;
      }
    }
    return next;
  }

  /// Takes away what ran out: finished cards past [linger], and the undo
  /// button past its window.
  void prune() {
    final now = _now();
    var changed = false;
    for (var i = _records.length - 1; i >= 0; i--) {
      final r = _records[i];
      if (r.phase == AgentActionPhase.done && !now.isBefore(r.at.add(linger))) {
        _records.removeAt(i);
        changed = true;
      } else if (r.undoLabel != null && !r.undoOpen(now)) {
        _records[i] = r.copyWith(clearUndo: true);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void clear() {
    if (_records.isEmpty) return;
    _records.clear();
    notifyListeners();
  }
}
