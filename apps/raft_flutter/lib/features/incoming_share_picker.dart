import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/incoming_share_targets.dart';
import '../platform/incoming_share_staging.dart';

class IncomingSharePicker extends StatefulWidget {
  const IncomingSharePicker({
    super.key,
    required this.client,
    required this.servers,
    required this.onContinue,
    required this.valid,
    this.initialServer,
    this.staging,
    this.cachedTargets,
  });
  final RaftClient client;
  final List<RaftRecord> servers;
  final String? initialServer;
  final bool Function() valid;
  final Future<void> Function(RaftRecord, IncomingShareTarget) onContinue;

  /// Background copy of the shared files. The picker shows its per-item
  /// progress and closes if the copy fails; null when nothing is copied.
  final IncomingShareStaging? staging;

  /// Device-cached destinations painted before the network answers. A seed is
  /// only ever shown: it is replaced by the fresh directory, and hand-off
  /// waits for that revalidation before it adds anything.
  final FutureOr<List<IncomingShareTarget>?> Function(RaftRecord server)?
  cachedTargets;
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
  String? error, notice;

  /// [loading]: no row to show yet. Rows are a device seed (or stale after an
  /// authority event) while a check is pending; [revalidating] is that state.
  bool loading = false, busy = false;
  int request = 0, _checks = 0;
  bool get revalidating => _checks > 0;

  /// Settles when every check started so far has finished. Never throws.
  Future<void> validation = Future.value();
  @override
  void initState() {
    super.initState();
    widget.staging?.addListener(stagingChanged);
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
        refreshAuthority();
      }
    });
    final initial =
        widget.servers.where((s) => s.id == widget.initialServer).firstOrNull ??
        widget.servers.firstOrNull;
    if (initial != null) {
      load(initial);
    } else {
      loading = true;
    }
    // The server list shown first is the device's; membership is re-read now.
    revalidateServers();
  }

  void stagingChanged() {
    if (!mounted) return;
    if (widget.staging?.failed == true && !busy) {
      Navigator.of(context).maybePop(false);
      return;
    }
    setState(() {});
  }

  /// Runs [body] as one pending check: hand-off waits for all of them.
  Future<void> _check(Future<void> Function() body) {
    _checks++;
    final done = body().whenComplete(() {
      _checks--;
      if (mounted) setState(() {});
    });
    final settled = done.then<void>((_) {}, onError: (Object _) {});
    validation = Future.wait([validation, settled]).then<void>((_) {});
    return settled;
  }

  /// Authority changed: keep what is on screen but re-read it. A row the fresh
  /// directory no longer offers is dropped with a notice.
  void refreshAuthority() {
    revalidateServers();
    final current = server;
    if (current != null) load(current, keepSelection: true);
  }

  /// Membership: a server the account no longer belongs to leaves the picker
  /// (with its destinations and selection); a changed role reloads them.
  Future<void> revalidateServers() => _check(() async {
    try {
      final next = await widget.client.servers();
      if (!mounted || !widget.valid()) return;
      final current = server;
      final fresh = current == null
          ? null
          : next.where((s) => s.id == current.id).firstOrNull;
      setState(() => servers = next);
      if (current != null && fresh != null) {
        if (fresh.string('role') != current.string('role')) {
          load(fresh, keepSelection: true);
        } else {
          setState(() => server = fresh);
        }
        return;
      }
      final alternative = next.firstOrNull;
      if (alternative != null) {
        // The selected destination's server is gone.
        final lost = current != null && selected != null;
        load(alternative);
        if (lost) {
          setState(
            () => notice = 'The selected destination is no longer available.',
          );
        }
      } else {
        request++;
        setState(() {
          if (selected != null) {
            notice = 'The selected destination is no longer available.';
          }
          server = null;
          selected = null;
          targets = [];
          loading = false;
        });
      }
    } catch (_) {
      // Offline: the device's list stays; hand-off re-reads membership.
      if (mounted && server == null && targets.isEmpty) {
        setState(() {
          loading = false;
          error = 'Conversations could not be loaded.';
        });
      }
    }
  });

  Future<void> load(RaftRecord next, {bool keepSelection = false}) {
    final ticket = ++request;
    final same = server?.id == next.id;
    // Seed from the device synchronously when the source can: the first frame
    // already lists the cached destinations.
    final seed = same ? null : widget.cachedTargets?.call(next);
    final seeded = seed is List<IncomingShareTarget> ? seed : null;
    final keptNotice = notice;
    setState(() {
      server = next;
      if (!(same && keepSelection)) selected = null;
      if (!same) {
        targets = seeded ?? [];
        search.clear();
      }
      loading = targets.isEmpty;
      error = null;
      notice = same && keepSelection ? keptNotice : null;
    });
    bool current() => mounted && request == ticket && widget.valid();
    return _check(() async {
      if (seed is Future<List<IncomingShareTarget>?>) {
        try {
          final rows = await seed;
          if (current() && rows != null && targets.isEmpty) {
            setState(() {
              targets = rows;
              loading = false;
            });
          }
        } catch (_) {
          // A missing device copy only means a spinner until the read ends.
        }
      }
      try {
        final rows = await incomingShareTargets(widget.client, next);
        if (!current()) return;
        setState(() {
          targets = rows;
          loading = false;
          final held = selected;
          if (held != null) {
            final fresh = rows.where((t) => t.key == held.key).firstOrNull;
            if (fresh == null) {
              notice = 'The selected destination is no longer available.';
            }
            selected = fresh;
          }
        });
      } catch (e) {
        if (!current()) return;
        setState(() {
          loading = false;
          if (targets.isEmpty ||
              e is RaftApiException && (e.status == 403 || e.status == 404)) {
            // Refused or nothing to show: no destination of this server stays
            // selectable on the strength of the device copy.
            targets = [];
            selected = null;
            error = 'Conversations could not be loaded.';
          } else {
            notice = 'Conversations could not be loaded.';
          }
        });
      }
    });
  }

  Future<void> proceed() async {
    if (selected == null || server == null || busy || !widget.valid()) return;
    // A device-cached or authority-stale row authorizes nothing: wait for the
    // fresh directory (it may drop the row) before joining or adding.
    for (var wait = 0; revalidating && wait < 3; wait++) {
      setState(() {
        busy = true;
        error = null;
      });
      await validation;
      if (!mounted || !widget.valid()) return;
      setState(() => busy = false);
    }
    final destination = selected, scope = server;
    if (destination == null || scope == null || revalidating) return;
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
    widget.staging?.removeListener(stagingChanged);
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
            // Native-only page: it wears the same Web PanelHeader as every
            // phone page.
            RaftPanelHeaderBar(
              title: raftText(context, 'Select destinations'),
              onBack: busy ? null : () => Navigator.of(context).pop(false),
              backTooltip: raftText(context, 'Back'),
            ),
            if (widget.staging?.preparing == true && widget.staging!.total > 0)
              RaftPanel(
                key: const Key('incoming-share-preparing'),
                child: RaftProgressBar(
                  label: raftFormat(
                    context,
                    'Preparing {done} of {total} files',
                    {
                      'done': widget.staging!.copied,
                      'total': widget.staging!.total,
                    },
                  ),
                  value: 100 * widget.staging!.copied / widget.staging!.total,
                ),
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
                itemCount: loading || error != null
                    ? 1
                    : rows.length + (notice == null ? 0 : 1),
                itemBuilder: (context, index) {
                  if (loading) {
                    return const RaftForwardSearchStatus(loading: true);
                  }
                  if (notice != null && index == 0) {
                    return RaftForwardSearchStatus(
                      key: const Key('incoming-share-notice'),
                      message: raftText(context, notice!),
                    );
                  }
                  if (notice != null) index--;
                  if (error != null) {
                    return RaftForwardSearchStatus(
                      message: raftText(context, error!),
                      retryLabel: raftText(context, 'Retry'),
                      onRetry: () =>
                          server == null ? refreshAuthority() : load(server!),
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
            // The footer paints to the screen edge and pads by the system inset.
            RaftBottomInsetSurface(
              decoration: BoxDecoration(
                color: RaftTokens.of(context).panel,
                border: Border(
                  top: BorderSide(
                    color: RaftTokens.of(context).line,
                    width: RaftTokens.of(context).border,
                  ),
                ),
              ),
              padding: const EdgeInsets.all(RaftSpace.x4),
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
