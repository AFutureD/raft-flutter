import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;

import 'capabilities/agent_consent.dart';

/// The confirm cards of the operations the model asked for (`act`), above the
/// voice dock. The app draws them itself from the preview it computed, so the
/// person always sees what will really happen, whatever the model said; a
/// press on 确认 here is the one signal that approves a sensitive operation.
class AgentConsentTray extends StatefulWidget {
  const AgentConsentTray({super.key, required this.ledger, this.now});
  final AgentConsentLedger ledger;
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
    _schedule();
  }

  @override
  void didUpdateWidget(AgentConsentTray old) {
    super.didUpdateWidget(old);
    if (old.ledger != widget.ledger) {
      old.ledger.removeListener(_changed);
      widget.ledger.addListener(_changed);
      _schedule();
    }
  }

  @override
  void dispose() {
    widget.ledger.removeListener(_changed);
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
    final at = widget.ledger.nextExpiry;
    if (at == null) return;
    final wait = at.difference(_now());
    _expiry = Timer(wait.isNegative ? Duration.zero : wait, () {
      widget.ledger.prune();
      if (mounted) setState(_schedule);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.ledger.active;
    if (pending.isEmpty) return const SizedBox.shrink();
    final compact = MediaQuery.sizeOf(context).width < 700;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final p in pending)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: AgentConfirmCardView(
                key: ValueKey('agent-consent-${p.cardId}'),
                title: p.request.total > 1
                    ? '${p.request.preview.summary}（第 ${p.request.step}/${p.request.total} 次确认）'
                    : p.request.preview.summary,
                changes: p.request.preview.changes,
                risk: p.request.sensitive
                    ? AgentConfirmRisk.sensitive
                    : AgentConfirmRisk.change,
                compact: compact,
                result: p.approved ? AgentConfirmResult.confirmed : null,
                onConfirm: () =>
                    widget.ledger.cardTapped(p.cardId, yes: true),
                onCancel: () =>
                    widget.ledger.cardTapped(p.cardId, yes: false),
              ),
            ),
        ],
      ),
    );
  }
}
