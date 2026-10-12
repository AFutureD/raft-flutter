import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/incoming_share_targets.dart';
import '../platform/incoming_share_staging.dart';
import '../platform/native_sharing.dart' show IncomingSharedFile;
import 'forward_composer_page.dart' show forwardTargetIcon;

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

  /// Web's single-select forward flow: choosing a row opens the second page
  /// ("Add shared content"), whose action is Continue.
  bool review = false;
  String? handoffError;
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
          review = false;
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
      if (!(same && keepSelection)) {
        selected = null;
        review = false;
      }
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
            if (fresh == null) review = false;
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
            review = false;
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
        handoffError = null;
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
      handoffError = null;
    });
    try {
      await widget.onContinue(scope, destination);
      if (mounted && widget.valid()) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted && widget.valid()) {
        setState(() {
          busy = false;
          handoffError =
              'The shared content could not be added. Please try again.';
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

  /// Web `getForwardTargets`: most recent activity first, then by label.
  /// Destinations that have no conversation yet (a new DM) follow.
  List<IncomingShareTarget> get ordered {
    final query = search.text.trim().toLowerCase();
    int time(IncomingShareTarget t) {
      final json = t.channel?.json;
      return DateTime.tryParse(
            '${json?['lastMessageAt'] ?? json?['createdAt'] ?? ''}',
          )?.millisecondsSinceEpoch ??
          0;
    }

    return targets.where((t) => t.label.toLowerCase().contains(query)).toList()
      ..sort((a, b) {
        final order = time(b) - time(a);
        return order != 0
            ? order
            : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
  }

  /// The share, as the second line of the target page.
  String summary(BuildContext context) {
    final raw = widget.staging?.raw;
    final files = raw?.files.length ?? 0;
    final text = raw?.text != null && raw!.text!.isNotEmpty;
    if (files == 0) return raftText(context, 'Sharing text');
    return raftFormat(
      context,
      text
          ? files == 1
                ? 'Sharing {count} file and text'
                : 'Sharing {count} files and text'
          : files == 1
          ? 'Sharing {count} file'
          : 'Sharing {count} files',
      {'count': files},
    );
  }

  Widget progress(BuildContext context) => RaftProgressBar(
    key: const Key('incoming-share-preparing'),
    label: raftFormat(context, 'Preparing {done} of {total} files', {
      'done': widget.staging!.copied,
      'total': widget.staging!.total,
    }),
    value: 100 * widget.staging!.copied / widget.staging!.total,
  );

  bool get preparing =>
      widget.staging?.preparing == true && widget.staging!.total > 0;

  @override
  Widget build(BuildContext context) {
    final target = selected;
    final second = review && target != null;
    return PopScope(
      canPop: !busy && !second,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && second && !busy) setState(() => review = false);
      },
      child: RaftForwardPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (second)
              ..._reviewStep(context, target)
            else
              ..._targetsStep(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _targetsStep(BuildContext context) {
    final query = search.text.trim();
    final rows = ordered;
    return [
      RaftForwardPageHeader(
        leading: RaftForwardIconAction(
          glyph: RaftGlyph.arrowLeft,
          tooltip: raftText(context, 'Back'),
          onPressed: busy ? null : () => Navigator.of(context).pop(false),
        ),
        title: raftText(context, 'Select destinations'),
        subtitle: summary(context),
      ),
      Expanded(
        child: RaftForwardTargetsBody(
          leading: [
            if (preparing) progress(context),
            if (servers.length > 1)
              RaftForwardServerChips(
                semanticLabel: raftText(context, 'Server'),
                names: {for (final s in servers) s.id: s.name},
                selected: server?.id ?? '',
                onSelected: busy
                    ? null
                    : (id) => load(servers.firstWhere((s) => s.id == id)),
              ),
          ],
          search: RaftForwardSearchInput(
            controller: search,
            focusNode: searchFocus,
            placeholder: raftText(context, 'Search targets'),
            onChanged: (_) => setState(() {}),
          ),
          label: raftText(context, 'Recent'),
          itemCount: loading || error != null
              ? 1
              : (rows.isEmpty ? 1 : rows.length) + (notice == null ? 0 : 1),
          itemBuilder: (context, index) {
            if (loading) return const RaftForwardSearchStatus(loading: true);
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
            if (rows.isEmpty) {
              return RaftForwardSearchStatus(
                message: raftText(
                  context,
                  query.isEmpty
                      ? 'No destinations available.'
                      : 'No destinations match your search.',
                ),
              );
            }
            final row = rows[index];
            final channel = row.channel;
            return RaftForwardTargetRow(
              key: ValueKey('incoming-target-${row.key}'),
              icon: forwardTargetIcon(
                widget.client.origin,
                name: row.label,
                type: channel?.type ?? 'dm',
                agent:
                    row.agentId != null || channel?.json['peerType'] == 'agent',
                peerId:
                    row.agentId ??
                    row.userId ??
                    (channel?.json['peerId'] is String
                        ? channel!.json['peerId'] as String
                        : null),
                avatarUrl: channel?.json['peerAvatarUrl'] is String
                    ? channel!.json['peerAvatarUrl'] as String
                    : null,
                gravatarHash: channel?.json['peerGravatarHash'] is String
                    ? channel!.json['peerGravatarHash'] as String
                    : null,
              ),
              // Web `targetPickerLabel`: channels show the bare name.
              label: channel != null && channel.type != 'dm'
                  ? channel.name
                  : row.label,
              selected: selected?.key == row.key,
              checkbox: false,
              trailing: row.requiresJoin
                  ? RaftForwardTargetBadge(
                      glyph: RaftGlyph.logIn,
                      label: raftText(context, 'Not joined'),
                    )
                  : channel == null
                  ? RaftForwardTargetBadge(
                      glyph: RaftGlyph.userPlus,
                      label: raftText(context, 'New DM'),
                    )
                  : null,
              onTap: busy
                  ? null
                  : () => setState(() {
                      selected = row;
                      review = true;
                      handoffError = null;
                    }),
            );
          },
        ),
      ),
    ];
  }

  List<Widget> _reviewStep(BuildContext context, IncomingShareTarget target) {
    final raw = widget.staging?.raw;
    final files = raw?.files ?? const <IncomingSharedFile>[];
    return [
      RaftForwardPageHeader(
        leading: RaftForwardIconAction(
          glyph: RaftGlyph.arrowLeft,
          tooltip: raftText(context, 'Back to destinations'),
          onPressed: busy ? null : () => setState(() => review = false),
        ),
        title: raftText(context, 'Add shared content'),
        subtitle: raftFormat(context, 'Add to {target}', {
          'target': target.label,
        }),
      ),
      Expanded(
        child: RaftForwardPreviewStep(
          warnings: [if (preparing) progress(context)],
          error: handoffError == null ? null : raftText(context, handoffError!),
          previewLabel: raftText(context, 'Shared content'),
          preview: RaftForwardSharePreview(
            header: raftText(context, 'Shared'),
            count: files.isEmpty
                ? null
                : raftFormat(
                    context,
                    files.length == 1 ? '{count} file' : '{count} files',
                    {'count': files.length},
                  ),
            text: raw?.text,
            files: [
              for (final f in files)
                RaftForwardShareFile(
                  filename: f.filename,
                  mimeType: f.mimeType,
                  sizeBytes: f.sizeBytes,
                ),
            ],
          ),
          hint: files.isEmpty
              ? null
              : raftText(
                  context,
                  'Files are added to the composer. Review them before sending.',
                ),
          action: RaftForwardContinueAction(
            key: const Key('incoming-share-continue'),
            label: raftText(context, 'Continue'),
            busy: busy,
            onPressed: busy || loading ? null : proceed,
          ),
        ),
      ),
    ];
  }
}
