// Login / onboarding acceptance guard (docs/login-acceptance.md): every screen
// between cold start and the first workspace frame is pumped through the real
// RaftApp on a phone (390x844) in the three themes. None may paint text in
// Flutter's missing-Material fallback style (yellow double underline).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/global_server_selector.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_ui/test_themes.dart';

import 'app_global_server_selector_test.dart' show RootFixture;
import 'fallback_text_style.dart';

typedef _Prepare = void Function(RootFixture f);
typedef _Act = Future<void> Function(WidgetTester t, RootFixture f);

class _State {
  const _State(
    this.name, {
    this.prepare,
    this.act,
    this.uri,
    this.cached = false,
    this.expectText,
  });
  final String name;
  final _Prepare? prepare;
  final _Act? act;
  final Uri? uri;
  final bool cached;
  final String? expectText;
}

final _held = <String, Completer<dynamic>>{};

Map<String, dynamic> _me({bool verified = true, bool profile = true}) => {
  'id': 'alice',
  'name': profile ? 'alice' : 'pending_alice',
  'displayName': profile ? 'Alice' : null,
  'email': 'alice@example.invalid',
  'emailVerified': verified,
  if (!profile) 'profileSetupCompletedAt': null,
  if (!profile) 'profileSetupSuggestedHandle': 'alice',
};

void _hold(RootFixture f, String route) =>
    f.holds[route] = _held[route] = Completer<dynamic>();

final _states = <_State>[
  _State(
    'restoring',
    prepare: (f) => _hold(f, 'GET /auth/me'),
    expectText: 'Restoring session…',
  ),
  _State(
    'login',
    prepare: (f) => f.adapter.statuses['GET /auth/me'] = 401,
    expectText: 'Sign In',
  ),
  _State(
    'servers-loading',
    prepare: (f) => _hold(f, 'GET /servers'),
    expectText: 'Loading servers…',
  ),
  _State(
    'servers-many',
    expectText: 'Choose server',
  ),
  _State(
    'servers-none',
    prepare: (f) => f.servers.clear(),
    expectText: 'CREATE YOUR FIRST SERVER',
  ),
  _State(
    'servers-failed',
    prepare: (f) => f.serverDirectory = () => throw StateError('boom'),
  ),
  _State(
    'server-create',
    act: (t, f) async {
      await t.tap(find.text('+ Create New Server'));
      await t.pump();
    },
    expectText: 'Create server',
  ),
  _State(
    'onboarding-profile',
    prepare: (f) => f.overrides['GET /auth/me'] = (_) => _me(profile: false),
  ),
  _State(
    'onboarding-verify',
    prepare: (f) => f.overrides['GET /auth/me'] = (_) => _me(verified: false),
  ),
  _State(
    'invite-signed-in',
    uri: Uri.parse('/join/abc123'),
  ),
  _State(
    'access-denied',
    uri: Uri.parse('/s/unknown'),
  ),
  _State(
    'joining-community',
    uri: Uri.parse('/s/community'),
    prepare: (f) => _hold(f, 'POST /servers/community/join'),
  ),
  _State(
    'workspace',
    act: (t, f) async {
      await t.tap(find.byKey(const ValueKey('global-server-a')));
      await f.flush(t);
    },
  ),
];

void main() {
  for (final theme in raftThemeMatrix([
    'brutal',
    'elegant-light',
    'elegant-dark',
  ])) {
    for (final state in _states) {
      testWidgets('login flow state ${state.name} ($theme, 390x844)', (t) async {
        _held.clear();
        final f = RootFixture();
        state.prepare?.call(f);
        await f.mount(t, theme, 390, uri: state.uri, settle: false);
        await t.view.physicalSize;
        await f.flush(t);
        await state.act?.call(t, f);
        if (state.expectText != null) {
          expect(find.text(state.expectText!), findsWidgets);
        }
        expectNoFallbackTextStyle(state.name);
        for (final h in _held.values) {
          if (!h.isCompleted) h.complete(null);
        }
        await f.close(t);
      });
    }
  }
}
