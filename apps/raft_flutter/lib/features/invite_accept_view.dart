import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An invite the app was asked to open: its token and, for a full link, the
/// Raft server it names.
@immutable
class InviteLink {
  const InviteLink(this.token, {this.origin});
  final String token;
  final String? origin;

  /// `/join/<token>`, `/?invite=<token>` (a Web invite link, or the same path
  /// delivered by a deep link such as `raft://v1/join/<token>`). Null for any
  /// other location.
  static InviteLink? fromLocation(Uri location) {
    String? token;
    final segments = location.pathSegments;
    if (segments.length >= 2 && segments.first == 'join') {
      token = segments[1];
    }
    token ??= location.queryParameters['invite'];
    if (token == null || token.trim().isEmpty) return null;
    final origin =
        location.hasAuthority &&
            ['http', 'https'].contains(location.scheme) &&
            location.host.isNotEmpty
        ? Uri(
            scheme: location.scheme,
            host: location.host,
            port: location.hasPort ? location.port : null,
          ).toString()
        : null;
    return InviteLink(token.trim(), origin: origin);
  }

  /// What the Join workspace dialog accepts: an invite link or the bare code.
  static InviteLink? fromInput(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri != null && uri.hasScheme) {
      final fromPath = fromLocation(uri);
      if (fromPath != null) return fromPath;
      final token = uri.queryParameters['token'];
      return token == null || token.isEmpty ? null : InviteLink(token);
    }
    return InviteLink(text);
  }
}

/// Opens the invite page from anywhere in the app (the Join workspace dialog):
/// the app root listens and shows it.
class InviteRequests extends ChangeNotifier {
  InviteRequests._();
  static final InviteRequests instance = InviteRequests._();
  InviteLink? _pending;

  void open(InviteLink link) {
    _pending = link;
    notifyListeners();
  }

  InviteLink? take() {
    final link = _pending;
    _pending = null;
    return link;
  }
}

/// `storePendingInvite` / `takePendingInviteRedirectPath`: the token of an
/// invite the member left to sign in or register, resumed once the account is
/// ready.
class PendingInvite {
  PendingInvite._();
  static const _key = 'raft.pending-invite';

  static Future<void> store(String token) async =>
      (await SharedPreferences.getInstance()).setString(_key, token);

  static Future<String?> take() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_key);
    if (token == null || token.isEmpty) return null;
    await prefs.remove(_key);
    return token;
  }
}

/// What `POST /auth/accept-invite` joined.
class InviteJoined {
  const InviteJoined(this.serverId, this.serverName);
  final String serverId, serverName;
}

/// InviteAcceptPage.tsx: loads the invite (anonymously, the link is the
/// credential), shows who invited the member and what is inside, and either
/// joins (signed in) or sends the member to sign in / register (signed out).
class InviteAcceptView extends StatefulWidget {
  const InviteAcceptView({
    super.key,
    required this.token,
    required this.signedIn,
    required this.loadInfo,
    required this.accept,
    required this.onEnter,
    required this.onSignIn,
    required this.onCreateAccount,
    required this.onGoToRaft,
    this.server,
    this.onServer,
  });
  final String token;
  final bool signedIn;

  /// `GET /auth/invite-info?token=`.
  final Future<Map<String, dynamic>> Function() loadInfo;

  /// `POST /auth/accept-invite` with the accepted agreement, if any.
  final Future<InviteJoined> Function(String? agreementId) accept;

  /// Opens the joined server; false while the refreshed server list does not
  /// have it yet (the page then offers Continue).
  final Future<bool> Function(String serverId) onEnter;
  final VoidCallback onSignIn, onCreateAccount, onGoToRaft;
  final String? server;
  final VoidCallback? onServer;

  @override
  State<InviteAcceptView> createState() => _InviteAcceptViewState();
}

class _InviteAcceptViewState extends State<InviteAcceptView> {
  Map<String, dynamic>? info;
  bool loading = true, accepting = false, accepted = false;
  String acceptedName = '', acceptedId = '', error = '';

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant InviteAcceptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token) {
      info = null;
      loading = true;
      error = '';
      unawaited(load());
    }
  }

  Future<void> load() async {
    final token = widget.token;
    try {
      final data = await widget.loadInfo();
      if (!mounted || token != widget.token) return;
      info = data;
    } on RaftApiException catch (e) {
      if (!mounted || token != widget.token) return;
      error = switch (e.status) {
        404 => raftText(context, 'This invite link is invalid or has expired.'),
        429 => raftText(
          context,
          'Too many attempts. Please wait a minute and try again.',
        ),
        _ => raftText(context, 'Failed to load invite link. Please try again.'),
      };
    } catch (_) {
      if (!mounted || token != widget.token) return;
      error = raftText(
        context,
        'Failed to load invite link. Please try again.',
      );
    }
    if (mounted) setState(() => loading = false);
  }

  Map<String, dynamic>? get agreement {
    final value = info?['agreement'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  RaftInviteInfo? get view {
    final data = info;
    if (data == null) return null;
    final a = agreement;
    return RaftInviteInfo(
      joinLink: data['kind'] == 'join_link',
      serverName: '${data['serverName'] ?? ''}',
      inviterName: data['inviterName'] as String?,
      memberCount: (data['memberCount'] as num?)?.toInt() ?? 0,
      agentCount: (data['agentCount'] as num?)?.toInt() ?? 0,
      insideCountsHidden: data['insideCountsHidden'] == true,
      humanSeatLimitReached: data['humanSeatLimitReached'] == true,
      agreementTitle: a == null ? null : '${a['title'] ?? ''}',
      agreementVersion: (a?['version'] as num?)?.toInt(),
      agreementBody: a == null ? null : '${a['bodyMarkdown'] ?? ''}',
    );
  }

  Future<void> join() async {
    if (accepting) return;
    setState(() {
      accepting = true;
      error = '';
    });
    try {
      final result = await widget.accept(agreement?['id'] as String?);
      if (!mounted) return;
      setState(() {
        accepted = true;
        acceptedName = result.serverName;
        acceptedId = result.serverId;
      });
      await widget.onEnter(result.serverId);
    } on RaftApiException catch (e) {
      if (!mounted) return;
      final fresh = e.details['agreement'];
      if ((e.message == 'agreement_required' ||
              e.message == 'agreement_changed') &&
          fresh is Map) {
        // The agreement to accept changed: show the current one.
        setState(() => info = {...?info, 'agreement': fresh});
      } else {
        setState(
          () => error = e.message.isEmpty
              ? raftText(context, 'Failed to accept invite')
              : e.message,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = raftText(context, 'Failed to accept invite'));
      }
    } finally {
      if (mounted) setState(() => accepting = false);
    }
  }

  Future<void> continueToRaft() async {
    if (!await widget.onEnter(acceptedId)) widget.onGoToRaft();
  }

  @override
  Widget build(BuildContext context) => RaftInviteAcceptPage(
    stage: loading
        ? RaftInviteStage.loading
        : accepted
        ? RaftInviteStage.accepted
        : RaftInviteStage.ready,
    info: view,
    errorText: error,
    signedIn: widget.signedIn,
    accepting: accepting,
    acceptedServerName: acceptedName,
    onJoin: join,
    onContinue: continueToRaft,
    onSignIn: widget.onSignIn,
    onCreateAccount: widget.onCreateAccount,
    onGoToRaft: widget.onGoToRaft,
    server: widget.server,
    onServer: widget.onServer,
  );
}
