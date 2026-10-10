import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/incoming_share_targets.dart';

class IncomingSharePicker extends StatefulWidget {
  const IncomingSharePicker({
    super.key,
    required this.client,
    required this.servers,
    required this.onContinue,
    required this.valid,
    this.initialServer,
  });
  final RaftClient client;
  final List<RaftRecord> servers;
  final String? initialServer;
  final bool Function() valid;
  final Future<void> Function(RaftRecord, IncomingShareTarget) onContinue;
  @override
  State<IncomingSharePicker> createState() => _IncomingSharePickerState();
}

class _IncomingSharePickerState extends State<IncomingSharePicker> {
  RaftRecord? server;
  late List<RaftRecord> servers = widget.servers;
  StreamSubscription<RaftEvent>? events;
  IncomingShareTarget? selected;
  List<IncomingShareTarget> targets = [];
  final search = TextEditingController();
  final searchFocus = FocusNode();
  String? error;
  bool loading = false, busy = false;
  int request = 0;
  @override
  void initState() {
    super.initState();
    events = widget.client.events.listen((event) {
      if (!busy &&
          (event.name.startsWith('server:member') ||
              const {
                'channel:updated',
                'channel:members-updated',
                'channel:authority-updated',
                'channel:removed',
                'dm:new',
              }.contains(event.name))) {
        unawaited(refreshAuthority());
      }
    });
    final initial =
        widget.servers.where((s) => s.id == widget.initialServer).firstOrNull ??
        widget.servers.firstOrNull;
    if (initial != null) load(initial);
  }

  Future<void> refreshAuthority() async {
    final ticket = ++request;
    setState(() {
      selected = null;
      targets = [];
      loading = true;
      error = null;
    });
    try {
      final next = await widget.client.servers();
      if (!mounted || ticket != request || !widget.valid()) {
        return;
      }
      setState(() => servers = next);
      final selectedServer =
          next.where((s) => s.id == server?.id).firstOrNull ?? next.firstOrNull;
      if (selectedServer != null) {
        await load(selectedServer);
      } else {
        setState(() {
          server = null;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted && ticket == request && widget.valid()) {
        setState(() {
          loading = false;
          error = 'Conversations could not be loaded.';
        });
      }
    }
  }

  Future<void> load(RaftRecord next) async {
    final ticket = ++request;
    setState(() {
      server = next;
      selected = null;
      targets = [];
      loading = true;
      error = null;
      search.clear();
    });
    try {
      final rows = await incomingShareTargets(widget.client, next);
      if (mounted && request == ticket && widget.valid()) {
        setState(() {
          targets = rows;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted && request == ticket && widget.valid()) {
        setState(() {
          loading = false;
          error = 'Conversations could not be loaded.';
        });
      }
    }
  }

  Future<void> proceed() async {
    final destination = selected, scope = server;
    if (destination == null || scope == null || busy || !widget.valid()) return;
    if (destination.requiresJoin) {
      final accepted = await RaftConfirmDialog.show(
        context,
        RaftConfirmDialog(
          title: 'Join channel',
          confirmLabel: 'Join channel',
          confirmVariant: RaftButtonRecipeVariant.primary,
          message: raftFormat(context, 'Join {name} to add shared content?', {
            'name': destination.label,
          }),
        ),
      );
      if (!mounted ||
          accepted != true ||
          !widget.valid() ||
          server?.id != scope.id ||
          selected?.key != destination.key) {
        return;
      }
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onContinue(scope, destination);
      if (mounted && widget.valid()) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted && widget.valid()) {
        setState(() {
          busy = false;
          error = 'The shared content could not be added. Please try again.';
        });
      }
    }
  }

  @override
  void dispose() {
    request++;
    events?.cancel();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final rows = targets
        .where((t) => t.label.toLowerCase().contains(query))
        .toList();
    return PopScope(
      canPop: !busy,
      child: RaftForwardPage(
        child: Column(
          children: [
            RaftMobilePageHeader(
              title: Text(raftText(context, 'Select destinations')),
              onBack: busy ? null : () => Navigator.of(context).pop(false),
            ),
            if (servers.isNotEmpty)
              RaftPanel(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: RaftSegmentedControl<String>(
                    value: server?.id ?? '',
                    label: raftText(context, 'Server'),
                    items: [
                      for (final s in servers)
                        RaftSegmentedOption(value: s.id, label: s.name),
                    ],
                    onChanged: busy
                        ? null
                        : (id) => load(servers.firstWhere((s) => s.id == id)),
                  ),
                ),
              ),
            Expanded(
              child: RaftForwardTargetsBody(
                search: RaftForwardSearchInput(
                  controller: search,
                  focusNode: searchFocus,
                  placeholder: raftText(context, 'Search targets'),
                  onChanged: (_) => setState(() {}),
                ),
                label:
                    selected?.label ?? raftText(context, 'Select destinations'),
                itemCount: loading || error != null ? 1 : rows.length,
                itemBuilder: (context, index) {
                  if (loading) {
                    return const RaftForwardSearchStatus(loading: true);
                  }
                  if (error != null) {
                    return RaftForwardSearchStatus(
                      message: raftText(context, error!),
                      retryLabel: raftText(context, 'Retry'),
                      onRetry: server == null ? null : () => load(server!),
                    );
                  }
                  final target = rows[index];
                  return RaftForwardTargetRow(
                    key: ValueKey('incoming-target-${target.key}'),
                    icon: raftForwardTargetIcon(
                      name: target.label,
                      type: target.channel?.type ?? 'dm',
                      agent: target.agentId != null,
                    ),
                    label: target.label,
                    selected: selected?.key == target.key,
                    checkbox: true,
                    onTap: busy
                        ? null
                        : () => setState(() {
                            selected = selected?.key == target.key
                                ? null
                                : target;
                          }),
                  );
                },
              ),
            ),
            RaftPanel(
              child: Row(
                children: [
                  Expanded(
                    child: selected == null
                        ? const SizedBox()
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: RaftButton(
                              label: selected!.label,
                              glyph: RaftGlyph.x,
                              secondary: true,
                              onPressed: busy
                                  ? null
                                  : () => setState(() => selected = null),
                            ),
                          ),
                  ),
                  RaftButton(
                    key: const Key('incoming-share-continue'),
                    label: raftText(context, 'Continue'),
                    busy: busy,
                    onPressed: busy || selected == null || loading
                        ? null
                        : proceed,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
