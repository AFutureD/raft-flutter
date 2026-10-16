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

  @override
  State<AgentConsentTray> createState() => _AgentConsentTrayState();
}

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

  /// The things the operation is about, as cards the app draws from its data.
  Widget? _refs(List<AgentPreviewRef> refs) {
    final kinds = {for (final k in AgentEntityKind.values) k.name: k};
    final shown = [
      for (final r in refs)
        if (kinds[r.entity] != null) ui.AgentEntityRef(kinds[r.entity]!, r.id),
    ];
    if (shown.isEmpty) return null;
    final gap = HandsFree.of(context).rowGap;
    return Padding(
      padding: EdgeInsets.only(top: gap * .5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in shown)
            Padding(
              padding: EdgeInsets.only(bottom: gap),
              child: HfEntityCard(entity: e),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.ledger.active;
    final cancelled = widget.ledger.cancelledCards;
    final records = widget.board?.records ?? const <AgentActionRecord>[];
    if (pending.isEmpty && records.isEmpty && cancelled.isEmpty) {
      return const SizedBox.shrink();
    }
    final hf = HandsFree.of(context);
    final now = _now();
    // A card with the thing it is about is tall: the tray never takes more
    // than half the screen, and scrolls past that.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .5,
      ),
      child: SingleChildScrollView(
        reverse: true,
        padding: EdgeInsets.fromLTRB(0, 0, hf.sp(8), hf.sp(10)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final r in records)
              Padding(
                padding: EdgeInsets.only(top: hf.sp(6)),
                child: HfConfirm(
                  // The card the confirmation was on: same key, same place.
                  key: ValueKey(
                    'agent-consent-${widget.ledger.cardIdFor(r.id) ?? r.id}',
                  ),
                  message: r.preview.summary,
                  changes: r.preview.changes,
                  attachment: _refs([
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
                    onUndo: r.undoOpen(now) && widget.onUndo != null
                        ? () => widget.onUndo!(r.id)
                        : null,
                    onRetry:
                        r.phase == AgentActionPhase.failed &&
                            r.canRetry &&
                            widget.onRetry != null
                        ? () => widget.onRetry!(r.id)
                        : null,
                    onDismiss: r.phase == AgentActionPhase.running
                        ? null
                        : () => widget.board?.dismiss(r.id),
                  ),
                ),
              ),
            for (final p in pending)
              if (!records.any((r) => r.id == p.request.token))
                Padding(
                  padding: EdgeInsets.only(top: hf.sp(6)),
                  child: HfConfirm(
                    key: ValueKey('agent-consent-${p.cardId}'),
                    message: p.request.total > 1
                        ? '${p.request.preview.summary}（第 ${p.request.step}/${p.request.total} 次确认）'
                        : p.request.preview.summary,
                    changes: p.request.preview.changes,
                    attachment: _refs(p.request.preview.refs),
                    risk: p.request.sensitive
                        ? AgentConfirmRisk.sensitive
                        : AgentConfirmRisk.change,
                    result: p.approved ? AgentConfirmResult.confirmed : null,
                    onConfirm: () =>
                        widget.ledger.cardTapped(p.cardId, yes: true),
                    onCancel: () =>
                        widget.ledger.cardTapped(p.cardId, yes: false),
                  ),
                ),
            // What the person moved on from: the card says so for a moment.
            for (final c in cancelled)
              Padding(
                padding: EdgeInsets.only(top: hf.sp(6)),
                child: GestureDetector(
                  onTap: () => widget.ledger.dismissCancelled(c.cardId),
                  child: HfConfirm(
                    key: ValueKey('agent-consent-${c.cardId}'),
                    message: c.request.preview.summary,
                    changes: c.request.preview.changes,
                    risk: c.request.sensitive
                        ? AgentConfirmRisk.sensitive
                        : AgentConfirmRisk.change,
                    result: AgentConfirmResult.cancelled,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
