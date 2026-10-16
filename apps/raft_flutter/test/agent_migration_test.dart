import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_migration_view.dart';
import 'package:raft_ui/raft_ui.dart';

class _MigrationTransport implements HttpClientAdapter {
  _MigrationTransport({this.disabled = false});
  final bool disabled;
  int revision = 2;
  final requests = <Map<String, dynamic>>[];

  /// The migration state served by the status endpoint; `completed` also
  /// moves the agent to the target computer, as the server does.
  String state = 'in_transit';

  /// `GET /billing/subscription` plan; null answers 404 (billing unavailable).
  String? plan = 'pro';

  /// Answer `POST /agents/a1/migrate` with MIGRATION_PRO_PLAN_REQUIRED.
  bool startDenied = false;
  final calls = <String>[];
  int count(String route) => calls.where((c) => c == route).length;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async {
    dynamic data;
    var status = 200;
    calls.add('${o.method} ${o.path}');
    switch ('${o.method} ${o.path}') {
      case 'POST /auth/login':
        data = {
          'accessToken': 'fixture',
          'refreshToken': 'fixture',
          'user': {'id': 'alice'},
        };
      case 'GET /agents/a1':
        data = {
          'id': 'a1',
          'name': 'Fixture agent',
          'creatorType': 'user',
          'creatorId': 'alice',
          'runtime': 'codex',
          'machineId': state == 'completed' ? 'c2' : 'c1',
        };
      case 'GET /agents':
        data = [
          {
            'id': 'a1',
            'name': 'Fixture agent',
            'machineId': state == 'completed' ? 'c2' : 'c1',
          },
        ];
      case 'GET /billing/subscription':
        status = plan == null ? 404 : 200;
        data = plan == null ? {'error': 'Not found'} : {'plan': plan};
      case 'POST /agents/a1/migrate':
        status = startDenied ? 403 : 200;
        data = startDenied
            ? {
                'error': 'Agent migration requires a Pro plan',
                'code': 'MIGRATION_PRO_PLAN_REQUIRED',
              }
            : {'migration': {}};
      case 'GET /servers/s1/machines':
        data = {
          'machines': [
            {'id': 'c1', 'name': 'Source', 'status': 'online'},
            {'id': 'c2', 'name': 'Target', 'status': 'online'},
          ],
        };
      case 'GET /agents/a1/migration':
        status = disabled ? 403 : 200;
        data = disabled
            ? {'error': 'Agent migration UI is not enabled on this server'}
            : {
                'migration': {
                  'migrationRef': 'fixture-ref',
                  'revision': revision,
                  'state': state,
                  'sourceMachineId': 'c1',
                  'targetMachineId': 'c2',
                },
              };
      case 'POST /agents/a1/migration/cancel':
        requests.add(Map<String, dynamic>.from(o.data));
        revision = 3;
        status = 409;
        data = {
          'error': 'Migration changed; refresh before retrying',
          'code': 'MIGRATION_REVISION_STALE',
        };
      default:
        data = {'error': 'Unexpected endpoint'};
        status = 404;
    }
    return ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _EventClient extends RaftClient {
  _EventClient({required super.transport})
    : super(
        origin: 'https://example.invalid',
        sessionStore: MemorySessionStore(),
      );
  final stream = StreamController<RaftEvent>.broadcast(sync: true);
  @override
  Stream<RaftEvent> get events => stream.stream;
}

Future<WorkspaceController> _fixture(_MigrationTransport transport) async {
  final client = _EventClient(transport: Dio()..httpClientAdapter = transport);
  await client.login('fixture', 'fixture');
  client.selectServer('s1');
  final w = WorkspaceController(client)
    ..server = RaftRecord({'id': 's1', 'role': 'owner'});
  return w;
}

void main() {
  testWidgets(
    'disabled migration API exposes no actionable transfer controls',
    (tester) async {
      final t = _MigrationTransport(disabled: true);
      final w = (await tester.runAsync(() => _fixture(t)))!;
      addTearDown(w.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: AgentMigrationView(controller: w, agentId: 'a1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('not enabled'), findsOneWidget);
      expect(find.text('Move agent'), findsNothing);
      expect(find.text('Assign computer'), findsNothing);
    },
  );
  testWidgets(
    'cancel carries the displayed revision and a stale write stays open for review',
    (tester) async {
      final t = _MigrationTransport();
      final w = (await tester.runAsync(() => _fixture(t)))!;
      addTearDown(w.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: AgentMigrationView(controller: w, agentId: 'a1'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(RaftButton, 'Cancel migration'));
      await tester.pumpAndSettle();
      expect(t.requests, [
        {'migrationRef': 'fixture-ref', 'expectedRevision': 2},
      ]);
      expect(find.byType(RaftFormDialog), findsOneWidget);
      // Web AgentMigrationCancelDialog: the stale code picks catalog copy, the
      // server's sentence is not shown.
      expect(
        find.textContaining(
          'The migration moved on before your request went through',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('refresh before retrying'), findsNothing);
      expect(find.text('Move agent'), findsNothing);
    },
  );

  Future<(_MigrationTransport, WorkspaceController)> mount(
    WidgetTester tester, {
    String state = 'in_transit',
    String? plan = 'pro',
    DateTime Function()? now,
    Locale? locale,
  }) async {
    final t = _MigrationTransport()
      ..state = state
      ..plan = plan;
    final w = (await tester.runAsync(() => _fixture(t)))!;
    addTearDown(() async {
      w.dispose();
      await (w.client as _EventClient).stream.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: raftTheme(RaftFamily.elegant),
        home: AgentMigrationView(controller: w, agentId: 'a1', now: now),
      ),
    );
    await tester.pumpAndSettle();
    return (t, w);
  }

  group('missed-event fallback (Web realtime.ts)', () {
    testWidgets('an active migration is polled every 2s until it ends', (
      tester,
    ) async {
      final (t, _) = await mount(tester);
      final first = t.count('GET /agents/a1/migration');
      expect(find.textContaining('In progress'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(t.count('GET /agents/a1/migration'), first);
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));
      expect(t.count('GET /agents/a1/migration'), first + 1);
      // The server finishes without any push reaching this client.
      t.state = 'completed';
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.textContaining('Complete'), findsOneWidget);
      final settled = t.count('GET /agents/a1/migration');
      await tester.pump(const Duration(seconds: 10));
      expect(t.count('GET /agents/a1/migration'), settled);
    });

    testWidgets('a settled migration is not polled', (tester) async {
      final (t, _) = await mount(tester, state: 'completed');
      final first = t.count('GET /agents/a1/migration');
      await tester.pump(const Duration(seconds: 10));
      expect(t.count('GET /agents/a1/migration'), first);
    });

    testWidgets('leaving the page stops the polling', (tester) async {
      final (t, _) = await mount(tester);
      await tester.pumpWidget(const SizedBox());
      final left = t.count('GET /agents/a1/migration');
      await tester.pump(const Duration(seconds: 10));
      expect(t.count('GET /agents/a1/migration'), left);
    });

    testWidgets('rooms:joined and connected refetch the migration', (
      tester,
    ) async {
      final (t, w) = await mount(tester, state: 'completed');
      final stream = (w.client as _EventClient).stream;
      final first = t.count('GET /agents/a1/migration');
      stream.add(const RaftEvent('rooms:joined', null));
      await tester.pumpAndSettle();
      expect(t.count('GET /agents/a1/migration'), first + 1);
      stream.add(const RaftEvent('connected', null));
      await tester.pumpAndSettle();
      expect(t.count('GET /agents/a1/migration'), first + 2);
      stream.add(
        const RaftEvent('agent:migration-updated', {'agentId': 'other'}),
      );
      await tester.pumpAndSettle();
      expect(t.count('GET /agents/a1/migration'), first + 2);
    });
  });

  group('stale agent rows after a migration (Web loadAgents)', () {
    testWidgets(
      'watching a migration complete re-reads the entity directory agents',
      (tester) async {
        final t = _MigrationTransport();
        final w = (await tester.runAsync(() => _fixture(t)))!;
        addTearDown(() async {
          w.dispose();
          await (w.client as _EventClient).stream.close();
        });
        await tester.runAsync(w.entityDirectory.preload);
        expect(w.entityDirectory.agent('a1')?['machineId'], 'c1');
        await tester.pumpWidget(
          MaterialApp(
            theme: raftTheme(RaftFamily.elegant),
            home: AgentMigrationView(controller: w, agentId: 'a1'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('In progress'), findsOneWidget);
        final reads = t.count('GET /agents');
        t.state = 'completed';
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.textContaining('Complete'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(t.count('GET /agents'), greaterThan(reads));
        expect(w.entityDirectory.agent('a1')?['machineId'], 'c2');
      },
    );

    testWidgets('a migration that was never seen active does not re-read', (
      tester,
    ) async {
      final t = _MigrationTransport(), reads = <int>[];
      t.state = 'completed';
      final w = (await tester.runAsync(() => _fixture(t)))!;
      addTearDown(() async {
        w.dispose();
        await (w.client as _EventClient).stream.close();
      });
      await tester.runAsync(w.entityDirectory.preload);
      reads.add(t.count('GET /agents'));
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: AgentMigrationView(controller: w, agentId: 'a1'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(t.count('GET /agents'), reads.single);
    });
  });

  group('Pro plan gating (Web billing.ts)', () {
    final after = DateTime.utc(2026, 10, 16);

    testWidgets('a free plan opening Move sees the upgrade dialog', (
      tester,
    ) async {
      final (t, w) = await mount(
        tester,
        state: 'completed',
        plan: 'free',
        now: () => after,
      );
      expect(t.count('GET /billing/subscription'), 1);
      await tester.tap(find.widgetWithText(RaftButton, 'Move agent'));
      await tester.pumpAndSettle();
      expect(find.text('UPGRADE TO PRO TO MIGRATE AGENTS'), findsOneWidget);
      expect(
        find.textContaining(
          'After upgrading, you can migrate an agent and its workspace',
        ),
        findsOneWidget,
      );
      expect(find.byType(RaftFormDialog), findsNothing);
      // "Upgrade" opens Plan & Billing settings.
      await tester.tap(
        find.widgetWithText(RaftSettingsRecipeButton, 'Upgrade'),
      );
      await tester.pumpAndSettle();
      expect(w.section, 'billing');
    });

    testWidgets('the upgrade dialog uses the Web zh-cn copy', (tester) async {
      await mount(
        tester,
        state: 'completed',
        plan: 'free',
        now: () => after,
        locale: const Locale('zh'),
      );
      await tester.tap(find.widgetWithText(RaftButton, '迁移 Agent'));
      await tester.pumpAndSettle();
      expect(find.text('升级至 PRO 以迁移 AGENT'), findsOneWidget);
      expect(find.textContaining('升级后，可以把 Agent 连同工作区'), findsOneWidget);
      expect(
        find.widgetWithText(RaftSettingsRecipeButton, '升级'),
        findsOneWidget,
      );
    });

    testWidgets('closing the upgrade dialog stays on the page', (tester) async {
      final (_, w) = await mount(
        tester,
        state: 'completed',
        plan: 'free',
        now: () => after,
      );
      await tester.tap(find.widgetWithText(RaftButton, 'Move agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(RaftSettingsRecipeButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('UPGRADE TO PRO TO MIGRATE AGENTS'), findsNothing);
      expect(find.byType(AgentMigrationView), findsOneWidget);
      expect(w.section, isNot('billing'));
    });

    testWidgets('pro, partner, founder and an active trial open the form', (
      tester,
    ) async {
      for (final (plan, clock) in [
        ('pro', after),
        ('founder', after),
        ('partner', after),
        ('free', DateTime.utc(2026, 5, 1)),
      ]) {
        await tester.pumpWidget(const SizedBox());
        final (_, _) = await mount(
          tester,
          state: 'completed',
          plan: plan,
          now: () => clock,
        );
        await tester.tap(find.widgetWithText(RaftButton, 'Move agent'));
        await tester.pumpAndSettle();
        expect(find.byType(RaftFormDialog), findsOneWidget, reason: plan);
        expect(find.text('UPGRADE TO PRO TO MIGRATE AGENTS'), findsNothing);
      }
    });

    testWidgets('an unavailable billing read never invents a denial', (
      tester,
    ) async {
      await mount(tester, state: 'completed', plan: null, now: () => after);
      await tester.tap(find.widgetWithText(RaftButton, 'Move agent'));
      await tester.pumpAndSettle();
      expect(find.byType(RaftFormDialog), findsOneWidget);
    });

    testWidgets(
      'MIGRATION_PRO_PLAN_REQUIRED on submit swaps the form for the upgrade dialog and reloads billing',
      (tester) async {
        // The billing projection still says Pro; the server is the authority.
        final (t, _) = await mount(tester, state: 'completed', plan: 'pro');
        t.startDenied = true;
        final billingReads = t.count('GET /billing/subscription');
        await tester.tap(find.widgetWithText(RaftButton, 'Move agent'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(RaftButton, 'Move'));
        await tester.pumpAndSettle();
        expect(t.count('POST /agents/a1/migrate'), 1);
        expect(find.byType(RaftFormDialog), findsNothing);
        expect(find.text('UPGRADE TO PRO TO MIGRATE AGENTS'), findsOneWidget);
        expect(find.textContaining('requires the Pro plan'), findsNothing);
        expect(t.count('GET /billing/subscription'), billingReads + 1);
      },
    );
  });
}
