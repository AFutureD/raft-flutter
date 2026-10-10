import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_flutter/features/auth_view.dart';
import 'package:raft_flutter/features/account_onboarding.dart';

void main() {
  test(
    'real legacy handle completes identity even if its timestamp is missing',
    () {
      expect(
        accountNeedsProfile(
          RaftRecord({
            'id': 'old',
            'name': 'developer',
            'profileSetupCompletedAt': null,
          }),
        ),
        false,
      );
      expect(
        accountNeedsProfile(
          RaftRecord({
            'id': 'new',
            'name': 'PENDING_fixtu',
            'profileSetupCompletedAt': '2026-07-01',
          }),
        ),
        true,
      );
      expect(
        accountNeedsOnboarding(
          RaftRecord({'name': 'developer', 'emailVerified': true}),
        ),
        false,
      );
    },
  );
  test('username validation follows Unicode first-letter contract', () {
    expect(accountUsernameError('123abc'), isNotNull);
    expect(accountUsernameError('日本語ユーザー'), isNull);
    expect(accountUsernameError('pending_fixture'), isNotNull);
  });
  testWidgets(
    'login preserves password spaces and validates origin before calling parent',
    (tester) async {
      final calls = <List<String>>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AuthView(
            origin: 'https://example.invalid',
            onLogin: (b, e, p) async {
              calls.add([b, e, p]);
            },
            onRegister: (b, e, p, a) async {},
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('login-email')),
        'alice@example.invalid',
      );
      await tester.enterText(
        find.byKey(const Key('login-password')),
        '  password  ',
      );
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(calls.single.last, '  password  ');
      // A native client's server origin is validated before the parent is
      // called (the origin is edited from the brand bar).
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AuthView(
            key: const ValueKey('bad-origin'),
            origin: 'https://user:secret@example.invalid',
            onLogin: (b, e, p) async {
              calls.add([b, e, p]);
            },
            onRegister: (b, e, p, a) async {},
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('login-email')),
        'alice@example.invalid',
      );
      await tester.enterText(find.byKey(const Key('login-password')), 'pw');
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter the server origin, such as https://raft.example.com.'),
        findsOneWidget,
      );
      expect(calls, hasLength(1));
    },
  );
  testWidgets('registration requires a separate explicit legal agreement', (
    tester,
  ) async {
    var registered = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: AuthView(
          origin: 'https://example.invalid',
          onLogin: (b, e, p) async {},
          onRegister: (b, e, p, accepted) async {
            expect(accepted, true);
            registered++;
          },
        ),
      ),
    );
    await tester.tapOnText(find.textRange.ofSubstring('Create one'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('login-email')),
      'alice@example.invalid',
    );
    await tester.enterText(
      find.byKey(const Key('login-password')),
      'valid-password',
    );
    await tester.ensureVisible(find.byKey(const Key('login-submit')));
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    // RegisterPage.tsx: the submit button stays disabled until the legal
    // checkbox is ticked.
    expect(registered, 0);
    await tester.ensureVisible(find.byKey(const Key('register-legal')));
    await tester.tap(find.byKey(const Key('register-legal')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('login-submit')));
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(registered, 1);
  });

  testWidgets('login validation shows the Web messages under the field', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: AuthView(
          origin: 'https://example.invalid',
          onLogin: (b, e, p) async => calls.add(e),
          onRegister: (b, e, p, a) async {},
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('login-email')), 'nope');
    await tester.enterText(find.byKey(const Key('login-password')), 'secret');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Invalid email format'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('login-email')), 'a@b.co');
    await tester.enterText(find.byKey(const Key('login-password')), '');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Invalid email format'), findsNothing);
    expect(find.text('Password is required'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('forgot password ends on the check-your-email page', (
    tester,
  ) async {
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AuthView(
          origin: 'http://localhost:13041',
          initialMode: 'forgot',
          onLogin: (b, e, p) async {},
          onRegister: (b, e, p, a) async {},
          anonymousClientFactory: (origin) => _AnonymousClient(requests),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('login-email')),
      'alice@example.invalid',
    );
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(requests, contains('POST /auth/forgot-password'));
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('alice@example.invalid'), findsOneWidget);
    await tester.tap(find.text('Back to Sign In'));
    await tester.pumpAndSettle();
    expect(find.text('Sign In'), findsWidgets);
    expect(find.byKey(const Key('login-password')), findsOneWidget);
  });

  testWidgets('reset with a link token asks for the new password twice', (
    tester,
  ) async {
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AuthView(
          origin: 'http://localhost:13041',
          initialMode: 'reset',
          resetToken: 'abc',
          onLogin: (b, e, p) async {},
          onRegister: (b, e, p, a) async {},
          anonymousClientFactory: (origin) => _AnonymousClient(requests),
        ),
      ),
    );
    expect(find.byKey(const Key('reset-token')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('reset-password')),
      'longenough1',
    );
    await tester.enterText(
      find.byKey(const Key('reset-confirm')),
      'different11',
    );
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.enterText(
      find.byKey(const Key('reset-confirm')),
      'longenough1',
    );
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(requests, ['POST /auth/reset-password']);
    expect(find.text('Password reset'), findsOneWidget);
  });
}

class _AnonymousClient extends RaftClient {
  _AnonymousClient(this.requests)
    : super(
        origin: 'https://example.invalid',
        sessionStore: MemorySessionStore(),
      );
  final List<String> requests;
  @override
  Future<dynamic> request(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? query,
    bool authorized = true,
    bool retried = false,
    UploadCancellation? cancellation,
    void Function(int, int)? onSendProgress,
    Map<String, dynamic>? headers,
    bool acceptServerExit = false,
    Duration? receiveTimeout,
  }) async {
    requests.add('$method $path');
    return <String, dynamic>{};
  }
}
