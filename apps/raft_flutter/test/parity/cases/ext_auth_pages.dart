// raft-flutter parity EXTENSION suite builders (tool/parity-ext): MISSING auth / onboarding / entry pages.
// NOT official cases; ids `components.auth-pages.<platform>.<surface>.<theme>` mirror
// tool/parity-ext/build-auth-pages.py and host/AuthPagesCases.tsx (dispatch on props.view).
//
// Data: tool/parity-ext/fixtures/auth-pages.json (fixtures['ext:auth-pages']); `routes` +
// `routeSets[props.routeSet]` answer the API for both providers (`$pending` never answers, `$status` fails
// with that status).
//
// Surfaces the Flutter app does not implement are listed in [extAuthPagesUncovered] with the reason (gap
// `noFlutterSurface`): the Web case still renders the page, the Flutter side has no widget to capture.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/account_onboarding.dart';
import 'package:raft_flutter/features/auth_view.dart';
import 'package:raft_flutter/features/global_server_selector.dart';
import 'package:raft_ui/raft_ui.dart';

import '../parity_harness.dart';
import 'ext_settings.dart' show extSettingsPage;
import 'screens/screen_fixture.dart';

const _origin = 'http://localhost:13041';

Map<String, dynamic> _fx(ParityContext ctx) =>
    ctx.fixtures['ext:auth-pages'] as Map<String, dynamic>;

/// The fixture answer of `METHOD path` for this case, throwing the error a `$status` rule stands for.
Object? _answer(ParityContext ctx, String method, String path) {
  final fx = _fx(ctx);
  final merged = {
    ...Map<String, dynamic>.from(fx['routes'] as Map),
    ...Map<String, dynamic>.from(
      ((fx['routeSets'] as Map?)?[ctx.props['routeSet']] as Map?) ?? const {},
    ),
  };
  final value = merged['$method $path'];
  if (value is Map && value[r'$pending'] == true) {
    return ScreenFixtureClient.pending;
  }
  if (value is Map && value[r'$status'] != null) {
    final body = Map<String, dynamic>.from(value[r'$body'] as Map? ?? const {});
    throw RaftApiException.response(
      '${body['error'] ?? 'fixture error'}',
      status: value[r'$status'] as int,
      body: body,
    );
  }
  return value ?? <String, dynamic>{};
}

Widget _register(ParityContext ctx) => AuthView(
  origin: _origin,
  initialMode: 'register',
  onLogin: (_, _, _) async {},
  onRegister: (_, _, _, _) async {
    final answer = _answer(ctx, 'POST', '/auth/register');
    if (identical(answer, ScreenFixtureClient.pending)) {
      await Completer<void>().future;
    }
  },
  onOAuth: (_, _, _, _) async {},
  anonymousClientFactory: (origin) => ScreenFixtureClient(
    (method, path, query) => _answer(ctx, method, path),
    origin: origin,
  ),
);

/// App.tsx AuthBootstrapStatus / ServerSelectionPage / ServerResolver splashes: one cream box with the
/// label centred (main.dart shows the same widget while the session restores).
Widget _splash(String label) => RaftServerResolutionBody(label: label);

/// RootErrorFallback over fixtures `rootError` (message, stack, React component stack).
Widget _rootError(ParityContext ctx) {
  final error = _fx(ctx)['rootError'] as Map<String, dynamic>;
  return RaftRootErrorFallback(
    message: error['message'] as String,
    stack: error['stack'] as String,
    componentStack: error['componentStack'] as String,
    onReload: () {},
  );
}

/// ServerAccessDeniedPage over the case's server list (the fallback is the first server).
Widget _serverDenied(ParityContext ctx) {
  final servers =
      (_fx(ctx)['servers'] as Map)[ctx.props['servers']] as List? ?? const [];
  return RaftServerAccessDeniedPage(
    serverName: servers.isEmpty ? null : (servers.first as Map)['name'] as String,
    onContinue: () {},
  );
}

Widget _serversLoading(ParityContext ctx) {
  final fx = _fx(ctx);
  return GlobalServerSelector(
    servers: const [],
    user: RaftRecord(Map<String, dynamic>.from(fx['user'] as Map)),
    loading: true,
    onSelect: (_) async {},
    onCreate: (_, _) async {},
    onLogout: () async {},
    onRetry: () async {},
  );
}

/// AccountIdentitySetupPage preview (the official profile-setup case's user: pending_new_designer, suggested
/// handle new_designer, no display name); showSessionFooter false mirrors the React preview mode.
Widget _identity(ParityContext ctx) {
  final wire = ScreenWire(ctx.fixtureData);
  return ScreenClientHost(
    create: () => ScreenFixtureClient(
      wire.common,
      user: {
        ...wire.me(),
        'name': 'pending_new_designer',
        'displayName': null,
        'profileSetupCompletedAt': null,
        'profileSetupSuggestedHandle': 'new_designer',
        'emailVerified': true,
      },
    ),
    builder: (context, client) => AccountOnboardingView(
      client: client,
      onComplete: () async {},
      onSignOut: () async {},
      showSessionFooter: false,
    ),
  );
}

Widget _serverSelector(ParityContext ctx) {
  final fx = _fx(ctx);
  final servers = (fx['servers'] as Map)[ctx.props['servers']] as List;
  return GlobalServerSelector(
    servers: [
      for (final server in servers)
        RaftRecord(Map<String, dynamic>.from(server as Map)),
    ],
    user: RaftRecord(Map<String, dynamic>.from(fx['user'] as Map)),
    loading: false,
    onSelect: (_) async {},
    onCreate: (_, _) async {},
    onLogout: () async {},
    onRetry: () async {},
  );
}

ParityCase _case(Widget Function(ParityContext) build, {String? note}) =>
    ParityCase(
      widgets: const ['raft_flutter:AuthView', 'raft_ui:RaftAuthPage'],
      notes: 'Extension suite (not official).${note == null ? '' : ' $note'}',
      settle: const Duration(milliseconds: 300),
      build: build,
    );

/// surface name -> builder; the platform lists are in [_platforms].
final Map<String, ParityCase> _surfaces = {
  for (final s in const [
    'register.default',
    'register.filled',
    'register.unchecked',
    'register.invalid-email',
    'register.short-password',
    'register.error',
    'register.social',
  ])
    s: _case(_register),
  for (final s in const ['identity.default', 'identity.filled'])
    s: _case(_identity),
  for (final s in const ['server.create-first', 'server.create-first-filled'])
    s: _case(_serverSelector),
  // Settings pages: the ext-settings Flutter page (WorkspaceSettings) over fixtures/settings.json plus the
  // auth-pages route sets / server patches.
  for (final s in const [
    'settings.account-password',
    'settings.account-password-error',
    'settings.account-logout-confirm',
    'settings.server-danger-delete',
    'settings.server-danger-delete-typed',
    'settings.server-danger-member',
    'settings.server-danger-leave',
    'settings.archived-channels',
    'settings.downgrade-active',
    'settings.downgrade-expired',
    'settings.app-editor',
    'settings.release-notes',
    'settings.release-notes-loading',
    'settings.release-notes-error',
    'settings.release-notes-empty',
  ])
    s: ParityCase(
      widgets: const [
        'raft_flutter:WorkspaceSettings',
        'raft_flutter:RaftSettingsPage',
      ],
      notes: 'Extension suite (not official).',
      settle: const Duration(milliseconds: 800),
      build: extSettingsPage,
    ),
  'bootstrap.restoring': _case((_) => _splash('Restoring session…')),
  'bootstrap.loading': _case((_) => _splash('Loading…')),
  'servers.loading': _case(_serversLoading),
  'root-error.default': _case(_rootError),
  'server-denied.with-server': _case(_serverDenied),
  'server-denied.no-server': _case(_serverDenied),
};

/// Surfaces a platform does not run (see build-auth-pages.py `platforms`).
const _platforms = {
  'desktop': <String>{
    'settings.release-notes',
    'settings.release-notes-loading',
    'settings.release-notes-error',
    'settings.release-notes-empty',
  },
  'mobile': <String>{
    'server.create-first',
    'server.create-first-filled',
    'settings.server-danger-delete',
    'settings.server-danger-delete-typed',
    'settings.server-danger-member',
    'settings.server-danger-leave',
  },
};

const _themes = ['brutal', 'elegant', 'elegant-dark'];

/// Every extension auth-pages case with a Flutter page, keyed by id (3 themes each).
final Map<String, ParityCase> extAuthPagesCases = {
  for (final platform in _platforms.keys)
    for (final MapEntry(key: name, value: parityCase) in _surfaces.entries)
      if (!_platforms[platform]!.contains(name))
        for (final theme in _themes)
          'components.auth-pages.$platform.$name.$theme': parityCase,
};

/// Web pages the Flutter app has no widget for: surface name -> why.
const _missing = <String, String>{
  'servers.joining-community':
      'Flutter page missing: the app has no community-by-slug join route, so no "Joining community…" splash.',
  'invite.signed-out':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.signed-in':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.join-link':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.agreement':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.hidden-counts':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.seat-limit':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.expired':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.throttled':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.loading':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'invite.accept-error':
      'Flutter page missing: invites are accepted from the Join workspace dialog (server_views.dart), not a page.',
  'community-agreement.default':
      'Flutter page missing: the app has no community-agreement dialog (the invite flow shows the agreement as text in a form dialog).',
  'community-agreement.error':
      'Flutter page missing: the app has no community-agreement dialog (the invite flow shows the agreement as text in a form dialog).',
  'community-agreement.joining':
      'Flutter page missing: the app has no community-agreement dialog (the invite flow shows the agreement as text in a form dialog).',
  'setup-gate.resume-bar':
      'Flutter page missing: no "not set up yet / Resume setup" bar for a deferred setup (ServerSetupGate has no deferred state).',
  'setup-gate.loading':
      'Flutter page missing: the dedicated native setup surface is a Web page for native WebView hosts; the app renders setup natively with no loading page.',
  'setup-gate.unavailable':
      'Flutter page missing: the dedicated native setup surface is a Web page for native WebView hosts; the app renders setup natively with no unavailable page.',
  'setup-gate.load-failed':
      'Flutter page missing: the dedicated native setup surface is a Web page for native WebView hosts; the app renders setup natively with no load-failed page.',
  'setup-gate.complete':
      'Flutter page missing: the dedicated native setup surface is a Web page for native WebView hosts; the app renders setup natively with no completion page.',
};

/// Cases without a Flutter widget (gap noFlutterSurface), merged into parityUncovered by case_map.dart.
final Map<String, ParityUncovered> extAuthPagesUncovered = {
  for (final platform in _platforms.keys)
    for (final MapEntry(key: name, value: reason) in _missing.entries)
      for (final theme in _themes)
        'components.auth-pages.$platform.$name.$theme': ParityUncovered(
          ParityGap.noFlutterSurface,
          reason,
        ),
};
