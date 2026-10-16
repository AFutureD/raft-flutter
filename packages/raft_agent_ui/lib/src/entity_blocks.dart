import 'package:flutter/foundation.dart' show VoidCallback;

import 'entity_model.dart';

/// The data of the organization blocks (table, timeline, confirm card): what
/// the model may put in them and what they report. They are drawn by the
/// hands-free blocks (`HfTable`, `HfTimeline`, `HfConfirm`).

/// Limits the model's content is held to; the catalog validators use them.
abstract final class AgentBlockLimits {
  static const tableColumns = 5;
  static const tableRows = 20;
  static const codeLines = 40;
  static const choiceOptions = 5;
  static const confirmChanges = 8;
}

/// A cell of a table: plain text, or a reference the app draws as a line.
class AgentTableCell {
  const AgentTableCell.text(String this.text) : entity = null, handle = null;
  const AgentTableCell.entity(AgentEntityRef this.entity, {this.handle})
    : text = null;
  final String? text;
  final AgentEntityRef? entity;
  final String? handle;
}

/// One step on a timeline.
class AgentTimelineItem {
  const AgentTimelineItem({
    required this.time,
    required this.title,
    this.entity,
    this.handle,
  });
  final String time, title;
  final AgentEntityRef? entity;
  final String? handle;
}

/// How much a confirmation weighs. `sensitive` is drawn louder and asks for
/// a clearer yes.
enum AgentConfirmRisk { change, sensitive }

/// What the person decided.
enum AgentConfirmResult { confirmed, cancelled }

/// Where a confirmed operation is, as its confirm card shows it.
enum AgentOutcomeKind { running, done, failed }

/// The outcome of the operation a confirm card asked about. The card keeps
/// its place and turns into this: "已发送 ✅" with the thing it made, or the
/// error with 重试; [onUndo] is the way back while there is one.
class AgentActionOutcome {
  const AgentActionOutcome({
    required this.kind,
    required this.text,
    this.undoLabel,
    this.onUndo,
    this.onRetry,
    this.onDismiss,
  });
  final AgentOutcomeKind kind;
  final String text;
  final String? undoLabel;
  final VoidCallback? onUndo, onRetry, onDismiss;
}

/// One line of a confirmation: "状态: 进行中 → 已完成".
class AgentChange {
  const AgentChange(this.field, this.from, this.to);
  final String field;
  final String? from, to;

  /// Splits `field: from → to` (also `->`). A line without an arrow is a
  /// `field: value` with only [to]; one without a colon is all [field].
  factory AgentChange.parse(String line) {
    final colon = line.indexOf(RegExp('[:：]'));
    if (colon < 0) return AgentChange(line.trim(), null, null);
    final field = line.substring(0, colon).trim();
    final rest = line.substring(colon + 1).trim();
    final arrow = RegExp(r'\s*(?:→|->|⟶)\s*').firstMatch(rest);
    if (arrow == null) return AgentChange(field, null, rest);
    return AgentChange(
      field,
      rest.substring(0, arrow.start).trim(),
      rest.substring(arrow.end).trim(),
    );
  }

  /// Whether [line] has the shape the model must write.
  static bool wellFormed(String line) {
    final c = AgentChange.parse(line);
    return c.field.isNotEmpty && c.from != null && c.to != null;
  }
}

