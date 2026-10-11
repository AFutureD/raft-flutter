// Web ForwardComposerDialog on a narrow viewport (< md) renders
// ForwardComposerMobile: a full-screen "Select destinations" page (Recent
// targets from the channel + DM stores, search), then an "Add a note" page
// with the forwarded-bundle preview and the note composer.
// Source: packages/web/src/components/message/ForwardComposerMobile.tsx,
// ForwardComposerTargetList.tsx, forwardComposerModel.tsx.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/source_time_formatter.dart';
import '../data/workspace_controller.dart';
import 'channel_footer_states.dart' show jointChannelReadOnly;
import 'forward_messages_dialog.dart';
import 'private_route_guard.dart';

/// One destination: a local channel/DM (`localTarget`) or a search row.
class _Destination {
  _Destination({
    required this.key,
    required this.label,
    this.channel,
    this.search,
  });
  final String key, label;
  final RaftChannel? channel;
  final Map<String, dynamic>? search;
  String? get channelId =>
      channel?.id ??
      (search?['channelId'] is String ? search!['channelId'] : null);
}

/// `targetLabel`: `@peer` for DMs, `#name` otherwise.
String forwardTargetLabel(RaftChannel c) {
  if (c.type == 'dm') {
    final peer = c.json['peerDisplayName'] ?? c.json['peerName'] ?? c.name;
    return '@$peer';
  }
  return '#${c.name}';
}

/// `targetPickerLabel`: DMs keep `@peer`, channels show the bare name.
String forwardTargetPickerLabel(RaftChannel c) =>
    c.type == 'dm' ? forwardTargetLabel(c) : c.name;

/// Approximates `localeCompare(..., {sensitivity: "base", numeric: true})`
/// under the ICU root collation used by Chromium: case-insensitive, ASCII
/// punctuation ordered before digits before letters, `@` before `#`.
int forwardLabelCompare(String a, String b) {
  const punctuation = "_-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~\$";
  int rank(int code) {
    final ch = String.fromCharCode(code);
    final p = punctuation.indexOf(ch);
    if (p >= 0) return p;
    if (code >= 48 && code <= 57) return 100 + code - 48;
    final lower = ch.toLowerCase().codeUnitAt(0);
    if (lower >= 97 && lower <= 122) return 200 + lower - 97;
    return 1000 + lower;
  }

  final x = a.codeUnits, y = b.codeUnits;
  for (var i = 0; i < x.length && i < y.length; i++) {
    final d = rank(x[i]) - rank(y[i]);
    if (d != 0) return d;
  }
  return x.length - y.length;
}

/// `getForwardTargets` with an empty query: channels then DMs, most recent
/// activity first, ties by label.
List<RaftChannel> forwardRecentTargets(
  List<RaftChannel> channels,
  List<RaftChannel> dms,
) {
  final now = sourceTimeNow();
  int time(RaftChannel c) =>
      DateTime.tryParse(
        '${c.json['lastMessageAt'] ?? c.json['createdAt'] ?? ''}',
      )?.millisecondsSinceEpoch ??
      0;
  bool forwardable(RaftChannel c) {
    if (c.archived || c.type == 'thread') return false;
    if (c.type == 'dm') return true;
    // canForwardToTarget: a read-only (locked) Joint Channel takes no forward.
    if (jointChannelReadOnly(c.json, now)) return false;
    return c.joined;
  }

  final all = [...channels, ...dms].where(forwardable).toList();
  all.sort((a, b) {
    final t = time(b) - time(a);
    if (t != 0) return t;
    final l = forwardLabelCompare(forwardTargetLabel(a), forwardTargetLabel(b));
    return l != 0 ? l : a.id.compareTo(b.id);
  });
  return all;
}

Future<bool> showForwardComposerPage(
  BuildContext context,
  WorkspaceController controller,
  List<RaftMessage> messages,
) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) =>
            ForwardComposerPage(controller: controller, messages: messages),
      ),
    ) ??
    false;

class ForwardComposerPage extends StatefulWidget {
  const ForwardComposerPage({
    super.key,
    required this.controller,
    required this.messages,
    this.desktop = false,
  });
  final WorkspaceController controller;
  final List<RaftMessage> messages;

  /// ForwardComposerDesktop (>= md): the two-pane dialog card instead of the
  /// full-screen pages.
  final bool desktop;
  @override
  State<ForwardComposerPage> createState() => _ForwardComposerPageState();
}

class _ForwardComposerPageState extends State<ForwardComposerPage> {
  WorkspaceController get w => widget.controller;
  final search = TextEditingController(), note = TextEditingController();
  final searchFocus = FocusNode();
  final selected = <String, _Destination>{};
  List<Map<String, dynamic>> results = [];
  late final String authority;
  Timer? debounce;
  int request = 0;
  late bool multi = widget.desktop;
  bool preview = false, loading = false, failed = false;
  bool busy = false;
  String? error;
  ForwardAttempt? attempt;
  bool get current => mounted && authority == workspaceAuthority(w);

  @override
  void initState() {
    super.initState();
    authority = workspaceAuthority(w);
    w.addListener(authorityChanged);
  }

  void authorityChanged() {
    if (authority == workspaceAuthority(w)) return;
    ++request;
    debounce?.cancel();
    if (mounted && ModalRoute.of(context)?.isActive == true) {
      Navigator.of(context).removeRoute(ModalRoute.of(context)!);
    }
  }

  @override
  void dispose() {
    ++request;
    debounce?.cancel();
    w.removeListener(authorityChanged);
    search.dispose();
    note.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  String get sourceLabel {
    final source = w.channels
        .followedBy(w.dms)
        .where((c) => c.id == widget.messages.first.channelId)
        .firstOrNull;
    return source == null
        ? ''
        : source.type == 'dm' || source.type == 'thread'
        ? forwardTargetLabel(source)
        : '#${source.name}';
  }

  void changedSearch(String value) {
    ++request;
    debounce?.cancel();
    final query = value.trim();
    setState(() {
      results = [];
      failed = false;
      loading = query.isNotEmpty;
    });
    if (query.isNotEmpty) {
      debounce = Timer(const Duration(milliseconds: 250), () => load(query));
    }
  }

  Future<void> load(String query) async {
    final ticket = ++request;
    try {
      final value = await w.query(
        '/messages/forward/targets/search',
        query: {'q': query, 'limit': 20},
      );
      if (!current || ticket != request) return;
      setState(() {
        results = (value['targets'] as List)
            .whereType<Map>()
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        loading = false;
      });
    } catch (_) {
      if (!current || ticket != request) return;
      setState(() {
        loading = false;
        failed = true;
      });
    }
  }

  void choose(_Destination d) {
    if (busy) return;
    setState(() {
      if (multi) {
        if (selected.remove(d.key) == null && selected.length < 10) {
          selected[d.key] = d;
        }
      } else {
        selected
          ..clear()
          ..[d.key] = d;
        preview = true;
      }
    });
  }

  /// Joins / opens a DM for search rows that need it, then forwards.
  Future<void> send() async {
    if (!current || busy || selected.isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      for (final d in selected.values) {
        final target = d.search;
        if (target == null ||
            d.channelId != null && target['requiredAction'] == null) {
          continue;
        }
        if (target['requiredAction'] == 'join_channel' &&
            target['channelId'] is String) {
          await w.command('POST', '/channels/${target['channelId']}/join');
        } else if (target['requiredAction'] == 'create_dm') {
          final created = await w.command(
            'POST',
            '/channels/dm',
            data: {
              target['type'] == 'agent' ? 'agentId' : 'userId': target['id'],
            },
          );
          if (created is Map && created['id'] is String) {
            target['channelId'] = created['id'];
          }
        }
      }
      final destinations = [
        for (final d in selected.values)
          if (d.channelId != null) d.channelId!,
      ];
      attempt ??= ForwardAttempt(
        requestId: w.client.newRandomId(),
        sources: widget.messages.map((m) => m.id).toList(),
        destinations: destinations,
        note: note.text,
      );
      final response = await w.command(
        'POST',
        '/messages/forward',
        data: attempt!.payload,
      );
      if (!current || !mounted) return;
      attempt!.apply(response);
      if (attempt!.completed) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(
        () => error = raftText(
          context,
          "We couldn't confirm whether the forward finished. It's safe to try again.",
        ),
      );
    } catch (e) {
      if (current) setState(() => error = '$e');
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && preview && !busy) setState(() => preview = false);
    },
    child: widget.desktop
        ? desktopDialog()
        : RaftForwardPage(child: preview ? previewStep() : targetsStep()),
  );

  /// ForwardedBundleCard's `formatShortDateTime` in the account's zone / hour cycle.
  String Function(DateTime) forwardStamp() {
    final user = w.client.user;
    return SourceTimeFormatter(
      locale: Localizations.localeOf(context).toLanguageTag(),
      preferredTimezone:
          user?.string('preferredTimezone') ?? user?.string('timezone'),
      preferredTimeFormat: sourceTimeFormatPreference(
        user?.string('preferredTimeFormat') ?? user?.string('timeFormat'),
      ),
      systemTimeFormat: MediaQuery.alwaysUse24HourFormatOf(context)
          ? SourceTimeFormat.twentyFourHour
          : null,
    ).shortDateTime;
  }

  /// The forwarded-bundle preview metadata of the selected messages.
  Map<String, dynamic> get previewMetadata {
    final source = w.channels
        .followedBy(w.dms)
        .where((c) => c.id == widget.messages.first.channelId)
        .firstOrNull;
    final thread = source?.type == 'thread';
    return <String, dynamic>{
      'kind': 'forwarded-bundle',
      'version': 1,
      'forwardedItems': [
        for (final (index, m) in widget.messages.indexed)
          {
            'index': index,
            'sourceMessageSeq': m.json['seq'],
            'sourceMessageId': m.id,
            'sourceTargetId': thread ? null : source?.id,
            'sourceAuthorSnapshot': {
              'type': m.string('senderType') == 'agent' ? 'agent' : 'user',
              'id': m.string('senderId'),
              'name': m.author,
              'uniqueName': m.author,
            },
            'sourceCreatedAt': m.json['createdAt'],
            'sourceTargetSnapshot': {
              'id': source?.id,
              'type': source?.type,
              'label': sourceLabel,
              'labelVisibility':
                  source?.type == 'channel' || thread ? 'public' : 'restricted',
            },
            'contentSnapshot': m.content,
            'attachmentPolicy': 'projected',
            'provenanceState': 'available',
          },
      ],
    };
  }

  /// ForwardComposerDesktop.tsx: `Card h-[min(clamp(30rem,72dvh,46rem),100dvh-2rem)]
  /// w-[min(clamp(48rem,60vw,60rem),100vw-2rem)]` with the header, the
  /// `clamp(19rem,24vw,22rem)` destination column and the preview / note column.
  Widget desktopDialog() {
    final t = RaftTokens.of(context);
    final size = MediaQuery.sizeOf(context);
    final width = math.min(size.width - 32, (size.width * .6).clamp(768.0, 960.0));
    final height = math.min(
      size.height - 32,
      (size.height * .72).clamp(480.0, 736.0),
    );
    final side = (size.width * .24).clamp(304.0, 352.0);
    final rule = t.brutal ? Colors.black : t.colors['line-muted']!;
    final panel = t.brutal ? Colors.white : t.colors['layer-panel']!;
    final query = search.text.trim();
    final label = TextStyle(
      fontFamily: t.headingFont,
      fontSize: 12,
      height: 16 / 12,
      fontWeight: FontWeight.w700,
      color: t.strong,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: const ValueKey('forward-dialog'),
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: panel,
            border: Border.all(color: rule, width: t.brutal ? 2 : 1),
            borderRadius: BorderRadius.circular(t.brutal ? 0 : 8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: rule, width: 2)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            raftText(context, 'Forward'),
                            style: RaftTypography.heading(t, size: 16, line: 24),
                          ),
                          Text(
                            raftFormat(context, '{count} selected from {source}', {
                              'count': widget.messages.length,
                              'source': sourceLabel,
                            }),
                            style: RaftTypography.mono(
                              t,
                              size: 12,
                              line: 16,
                              color: t.brutal
                                  ? Colors.black.withValues(alpha: .55)
                                  : t.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    RaftCloseButton(
                      tooltip: 'Close forward composer',
                      onPressed: busy ? null : () => Navigator.of(context).pop(false),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: side,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border(right: BorderSide(color: rule, width: 2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          desktopSearch(t, rule, panel),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 24,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  raftFormat(context, '{count} selected', {
                                    'count': selected.length,
                                  }),
                                  key: const ValueKey('forward-selected-count'),
                                  style: label,
                                ),
                                if (selected.isNotEmpty)
                                  GestureDetector(
                                    onTap: busy
                                        ? null
                                        : () => setState(selected.clear),
                                    child: Text(
                                      raftText(context, 'Clear'),
                                      style: label.copyWith(
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ListView(
                              padding: EdgeInsets.zero,
                              children: [
                                for (final (i, row) in (query.isEmpty
                                        ? [
                                            for (final c in forwardRecentTargets(
                                              w.channels,
                                              w.dms,
                                            ))
                                              localRow(c),
                                          ]
                                        : searchRows())
                                    .indexed) ...[
                                  if (i > 0) const SizedBox(height: 6),
                                  row,
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Text(error!, style: label),
                                    ),
                                  RaftForwardedBundle(
                                    metadata: previewMetadata,
                                    formatTimestamp: forwardStamp(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          desktopNote(t, rule, panel, label),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `label.flex items-center gap-2 border-2 bg-layer-panel px-2 py-2 shadow-brutal-sm`
  /// around the 14px Search icon and the bold 14px input.
  Widget desktopSearch(RaftTokens t, Color rule, Color panel) {
    final text = TextStyle(
      fontFamily: t.headingFont,
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w700,
      color: t.strong,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: panel,
        border: Border.all(color: rule, width: 2),
        borderRadius: BorderRadius.circular(t.brutal ? 0 : 6),
        boxShadow: t.brutal ? RaftShadowSet.brutalSm : null,
      ),
      child: Row(
        children: [
          RaftIcon(
            RaftGlyph.search,
            size: 14,
            color: t.brutal ? Colors.black.withValues(alpha: .5) : t.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              autofillHints: null,
              controller: search,
              focusNode: searchFocus,
              autofocus: true,
              onChanged: changedSearch,
              style: text,
              cursorColor: t.strong,
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: raftText(context, 'Search targets'),
                hintStyle: text.copyWith(
                  color: Colors.black.withValues(alpha: .35),
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `border-t-2 bg-layer-panel p-3`: "Optional note" + the compact composer
  /// (`border-2 p-2`, 40px editor, 28px accent send button).
  Widget desktopNote(RaftTokens t, Color rule, Color panel, TextStyle label) =>
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel,
          border: Border(top: BorderSide(color: rule, width: 2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            Text(
              raftText(context, 'Optional note'),
              style: label.copyWith(
                color: t.brutal ? Colors.black.withValues(alpha: .6) : t.muted,
              ),
            ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: panel,
                border: Border.all(color: rule, width: 2),
                borderRadius: BorderRadius.circular(t.brutal ? 0 : 6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  SizedBox(
                    height: 40,
                    child: TextField(
                      key: const Key('forward-desktop-note'),
                      autofillHints: null,
                      controller: note,
                      enabled: !busy && attempt == null,
                      maxLength: 4000,
                      maxLines: null,
                      expands: true,
                      style: RaftTypography.body(t, size: 14, line: 20, color: Colors.black),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        filled: false,
                        counterText: '',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        hintText: raftText(context, 'Add a note'),
                        hintStyle: RaftTypography.body(
                          t,
                          size: 14,
                          line: 20,
                          color: Colors.black.withValues(alpha: .35),
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: RaftRecipeButton(
                      key: const Key('forward-send'),
                      variant: RaftButtonRecipeVariant.accent,
                      size: RaftButtonRecipeSize.iconSm,
                      glyph: RaftGlyph.send,
                      tooltip: raftText(context, 'Send forward'),
                      disabled: selected.isEmpty,
                      onPressed: busy || selected.isEmpty ? null : send,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget targetsStep() {
    final selectedFrom = raftFormat(context, '{count} selected from {source}', {
      'count': widget.messages.length,
      'source': sourceLabel,
    });
    final query = search.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RaftForwardPageHeader(
          leading: multi
              ? RaftForwardIconAction(
                  glyph: RaftGlyph.undo2,
                  tooltip: raftText(context, 'Cancel'),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          selected.clear();
                          multi = false;
                        }),
                )
              : RaftForwardIconAction(
                  glyph: RaftGlyph.arrowLeft,
                  tooltip: raftText(context, 'Close forward target selection'),
                  onPressed: busy
                      ? null
                      : () => Navigator.of(context).pop(false),
                ),
          title: raftText(context, 'Select destinations'),
          subtitle: selectedFrom,
          trailing: multi
              ? RaftForwardIconAction(
                  glyph: RaftGlyph.check,
                  accent: true,
                  tooltip: raftText(context, 'Done'),
                  onPressed: selected.isEmpty || busy
                      ? null
                      : () => setState(() => preview = true),
                )
              : RaftForwardTextAction(
                  label: raftText(context, 'Select multiple'),
                  onPressed: () => setState(() {
                    selected.clear();
                    multi = true;
                  }),
                ),
        ),
        Expanded(
          child: RaftForwardTargetsBody(
            search: RaftForwardSearchInput(
              controller: search,
              focusNode: searchFocus,
              placeholder: raftText(context, 'Search targets'),
              onChanged: changedSearch,
            ),
            label: multi
                ? raftFormat(context, '{count} selected', {
                    'count': selected.length,
                  })
                : raftText(context, 'Recent'),
            labelAction: multi && selected.isNotEmpty
                ? RaftForwardLinkAction(
                    label: raftText(context, 'Clear'),
                    onTap: () => setState(selected.clear),
                  )
                : null,
            rows: query.isEmpty
                ? [
                    for (final c in forwardRecentTargets(w.channels, w.dms))
                      localRow(c),
                  ]
                : searchRows(),
          ),
        ),
      ],
    );
  }

  List<Widget> searchRows() {
    if (loading) return const [RaftForwardSearchStatus(loading: true)];
    if (failed) {
      return [
        RaftForwardSearchStatus(
          message: raftText(context, "Couldn't search destinations."),
          retryLabel: raftText(context, 'Try again'),
          onRetry: () => changedSearch(search.text),
        ),
      ];
    }
    if (results.isEmpty) {
      return [
        RaftForwardSearchStatus(
          message: raftText(context, 'No destinations match your search.'),
        ),
      ];
    }
    return [
      for (final r in results)
        () {
          final key = r['channelId'] is String
              ? 'channel:${r['channelId']}'
              : '${r['type']}:${r['id']}';
          final unavailable =
              r['canForwardNow'] != true && r['requiredAction'] == null;
          final type = r['type'];
          final action = r['requiredAction'];
          return RaftForwardTargetRow(
            key: ValueKey('forward-search-target-$type-${r['id']}'),
            icon: raftForwardTargetIcon(
              name: '${r['title']}',
              type: type == 'channel'
                  ? '${r['channelType'] ?? 'channel'}'
                  : '$type',
              agent: r['subtitle'] == 'agent',
            ),
            label: '${r['title']}',
            selected: selected.containsKey(key),
            checkbox: multi,
            unavailable: unavailable,
            trailing: action == 'join_channel' || action == 'create_dm'
                ? RaftForwardTargetBadge(
                    glyph: action == 'join_channel'
                        ? RaftGlyph.logIn
                        : RaftGlyph.userPlus,
                    label: raftText(
                      context,
                      action == 'join_channel' ? 'Not joined' : 'New DM',
                    ),
                  )
                : null,
            onTap: unavailable
                ? null
                : () => choose(
                    _Destination(key: key, label: '${r['title']}', search: r),
                  ),
          );
        }(),
    ];
  }

  Widget localRow(RaftChannel c) {
    final key = 'channel:${c.id}';
    return RaftForwardTargetRow(
      key: ValueKey('forward-target-${c.id}'),
      icon: raftForwardTargetIcon(
        name: forwardTargetPickerLabel(c),
        type: c.type,
        agent: c.json['peerType'] == 'agent',
      ),
      label: forwardTargetPickerLabel(c),
      selected: selected.containsKey(key),
      checkbox: multi,
      onTap: () => choose(
        _Destination(key: key, label: forwardTargetLabel(c), channel: c),
      ),
    );
  }

  Widget previewStep() {
    final labels = selected.values.map((d) => d.label).join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RaftForwardPageHeader(
          leading: RaftForwardIconAction(
            glyph: RaftGlyph.arrowLeft,
            tooltip: raftText(context, 'Back to destinations'),
            onPressed: busy ? null : () => setState(() => preview = false),
          ),
          title: raftText(context, 'Add a note'),
          subtitle: raftFormat(context, 'Send to {targets}', {
            'targets': labels,
          }),
        ),
        Expanded(
          child: RaftForwardPreviewStep(
            error: error,
            previewLabel: raftText(context, 'Message preview'),
            preview: RaftForwardedBundle(
              metadata: previewMetadata,
              formatTimestamp: forwardStamp(),
            ),
            noteLabel: raftText(context, 'Optional note'),
            note: RaftForwardNoteField(
              key: const Key('forward-mobile-note'),
              controller: note,
              autofocus: true,
              enabled: !busy && attempt == null,
              hint: raftText(context, 'Add a note'),
            ),
            send: RaftForwardIconAction(
              glyph: RaftGlyph.send,
              accent: true,
              tooltip: raftText(context, 'Send forward'),
              onPressed: busy || selected.isEmpty ? null : send,
            ),
          ),
        ),
      ],
    );
  }
}
