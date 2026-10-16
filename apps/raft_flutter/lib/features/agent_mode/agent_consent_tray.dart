import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;
import 'package:raft_agent_ui/raft_agent_ui.dart' as ui show AgentEntityRef;

import 'capabilities/agent_action_board.dart';
import 'capabilities/agent_capability.dart' show AgentPreviewRef;
import 'capabilities/agent_consent.dart';

/// The confirm cards of the operations the model asked for (`act`), above the
/// voice dock. The app draws them itself from the preview it computed, so the
/// person always sees what will really happen, whatever the model said; a
/// press on 确认 here is the one signal that approves a sensitive operation.
class AgentConsentTray extends StatefulWidget {
  const AgentConsentTray({
    super.key,
    required this.ledger,
    this.board,
    this.onUndo,
    this.onRetry,
    this.now,
  });
  final AgentConsentLedger ledger;

  /// The confirmed operations: their cards turn into the result in place.
  final AgentActionBoard? board;

  /// The person pressed 撤销 / 重试 on a result card (record id).
  final void Function(String id)? onUndo, onRetry;
  final DateTime Function()? now;

  /// The things the operation is about, as the cards of the app's data.
  static List<ui.AgentEntityRef> _things(List<AgentPreviewRef> refs) {
    final kinds = {for (final k in AgentEntityKind.values) k.name: k};
    return [
      for (final r in refs)
        if (kinds[r.entity] != null) ui.AgentEntityRef(kinds[r.entity]!, r.id),
    ];
  }

  /// The cards of the tray, in the order they are drawn: the results of the
  /// operations that ran, the previews that wait for an answer, and what the
  /// person moved on from. A card with a tap is dismissed by it.
  static List<AgentTrayEntry> entriesOf({
    required AgentConsentLedger ledger,
    AgentActionBoard? board,
    required DateTime now,
    void Function(String id)? onUndo,
    void Function(String id)? onRetry,
  }) {
    final pending = ledger.active;
    final cancelled = ledger.cancelledCards;
    final records = board?.records ?? const <AgentActionRecord>[];
    return [
      for (final r in records)
        (
          card: HfConfirm(
            // The card the confirmation was on: same key, same place.
            key: ValueKey('agent-consent-${ledger.cardIdFor(r.id) ?? r.id}'),
            message: r.preview.summary,
            changes: r.preview.changes,
            things: _things([
              if (r.entity != null && !r.undone)
                r.entity!
              else
                ...r.preview.refs,
            ]),
            outcome: AgentActionOutcome(
              kind: switch (r.phase) {
                AgentActionPhase.running => AgentOutcomeKind.running,
                AgentActionPhase.done => AgentOutcomeKind.done,
                AgentActionPhase.failed => AgentOutcomeKind.failed,
              },
              text: r.text ?? '执行中',
              undoLabel: r.undoLabel,
              onUndo: r.undoOpen(now) && onUndo != null
                  ? () => onUndo(r.id)
                  : null,
              onRetry:
                  r.phase == AgentActionPhase.failed &&
                      r.canRetry &&
                      onRetry != null
                  ? () => onRetry(r.id)
                  : null,
              onDismiss: r.phase == AgentActionPhase.running
                  ? null
                  : () => board?.dismiss(r.id),
            ),
          ),
          onTap: null,
        ),
      for (final p in pending)
        if (!records.any((r) => r.id == p.request.token))
          (
            card: HfConfirm(
              key: ValueKey('agent-consent-${p.cardId}'),
              message: p.request.total > 1
                  ? '${p.request.preview.summary}（第 ${p.request.step}/${p.request.total} 次确认）'
                  : p.request.preview.summary,
              changes: p.request.preview.changes,
              things: _things(p.request.preview.refs),
              risk: p.request.sensitive
                  ? AgentConfirmRisk.sensitive
                  : AgentConfirmRisk.change,
              result: p.approved ? AgentConfirmResult.confirmed : null,
              onConfirm: () => ledger.cardTapped(p.cardId, yes: true),
              onCancel: () => ledger.cardTapped(p.cardId, yes: false),
            ),
            onTap: null,
          ),
      // What the person moved on from: the card says so for a moment.
      for (final c in cancelled)
        (
          card: HfConfirm(
            key: ValueKey('agent-consent-${c.cardId}'),
            message: c.request.preview.summary,
            changes: c.request.preview.changes,
            risk: c.request.sensitive
                ? AgentConfirmRisk.sensitive
                : AgentConfirmRisk.change,
            result: AgentConfirmResult.cancelled,
          ),
          onTap: () => ledger.dismissCancelled(c.cardId),
        ),
    ];
  }

  @override
  State<AgentConsentTray> createState() => _AgentConsentTrayState();
}

/// One card of the tray, and what a tap on it does (nothing for most).
typedef AgentTrayEntry = ({HfConfirm card, VoidCallback? onTap});

class _AgentConsentTrayState extends State<AgentConsentTray> {
  Timer? _expiry;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    widget.ledger.addListener(_changed);
    widget.board?.addListener(_changed);
    _schedule();
  }

  @override
  void didUpdateWidget(AgentConsentTray old) {
    super.didUpdateWidget(old);
    if (old.ledger != widget.ledger) {
      old.ledger.removeListener(_changed);
      widget.ledger.addListener(_changed);
    }
    if (old.board != widget.board) {
      old.board?.removeListener(_changed);
      widget.board?.addListener(_changed);
    }
    _schedule();
  }

  @override
  void dispose() {
    widget.ledger.removeListener(_changed);
    widget.board?.removeListener(_changed);
    _expiry?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(_schedule);
  }

  /// A card goes away when its confirmation runs out.
  void _schedule() {
    _expiry?.cancel();
    final a = widget.ledger.nextExpiry, b = widget.board?.nextChange;
    final at = a == null
        ? b
        : b == null
        ? a
        : (a.isBefore(b) ? a : b);
    if (at == null) return;
    final wait = at.difference(_now());
    _expiry = Timer(wait.isNegative ? Duration.zero : wait, () {
      widget.ledger.prune();
      widget.board?.prune();
      if (mounted) setState(_schedule);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = AgentConsentTray.entriesOf(
      ledger: widget.ledger,
      board: widget.board,
      now: _now(),
      onUndo: widget.onUndo,
      onRetry: widget.onRetry,
    );
    if (entries.isEmpty) return const SizedBox.shrink();
    final hf = HandsFree.of(context);
    // The tray is the end of the layer's page, whatever its height (a card
    // with the thing it is about is tall): it scrolls with the page, and the
    // page scrolls to a card that comes.
    return AgentReveal(
      signature: entries.length,
      child: Padding(
        padding: EdgeInsets.only(bottom: hf.sp(10)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final e in entries)
              Padding(
                padding: EdgeInsets.only(top: hf.sp(6)),
                child: e.onTap == null
                    ? e.card
                    : GestureDetector(onTap: e.onTap, child: e.card),
              ),
          ],
        ),
      ),
    );
  }
}
