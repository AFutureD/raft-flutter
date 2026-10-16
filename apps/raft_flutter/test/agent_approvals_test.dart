import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_entity_directory.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';

import 'support/agent_action_harness.dart';

/// Approvals: action cards and connected-app authorization. Approving is
/// sensitive (two confirmations); saying no is an ordinary change.
void main() {
  late ActionHarness h;

  Map<String, dynamic> card(
    String id, {
    String type = 'integration:approve_agent_login',
    String state = 'prepared',
    String channel = 'ch-general',
    Map<String, dynamic> extra = const {},
    Map<String, dynamic> action = const {},
  }) => {
    'id': id,
    'channelId': channel,
    'content': '',
    'senderName': 'Cody',
    'senderType': 'agent',
    'seq': '${5 + id.length}${id.hashCode.abs() % 100}',
    'actionMetadata': {
      'kind': 'action-card',
      'state': state,
      'confirmationVersion': 3,
      'action': {
        'type': type,
        'clientName': 'Grok Notes',
        'agentName': 'cody',
        'scopes': ['agent:notification:write', 'profile:read'],
        ...action,
      },
      ...extra,
    },
  };

  void put(List<Map<String, dynamic>> rows) => h.w.ledger.ingest(
    rows,
    expectedGeneration: h.w.ledger.generation,
  );

  setUp(() {
    h = ActionHarness();
    h.w.routes['/integrations/overview'] = (_) => [
      {
        'id': 'req1',
        'type': 'pending',
        'clientName': 'Grok Notes',
        'agentName': 'Cody',
        'agentId': 'a-cody',
        'scopes': ['agent:notification:write'],
      },
      {'id': 'g1', 'type': 'active', 'clientName': 'Old App'},
    ];
  });
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> pending([Map<String, Object?>? args]) async {
    final r = await h.tools.run('query', {
      'capability': 'approvals.pending',
      'args': args ?? const {},
    });
    return r!['result'] as Map<String, Object?>;
  }

  group('approvals.pending', () {
    test('lists the cards the app holds and the apps asking', () async {
      put([
        card('m-login'),
        card('m-redo', type: 'integration:install_marketplace_app', state: 'reconfirm_required'),
        card('m-done', state: 'executed'),
        card('m-form', type: 'channel:create', action: {'name': 'launch'}),
      ]);
      final r = await pending();
      final cards = (r['cards'] as List).cast<Map>();
      expect(cards.map((c) => c['messageId']).toSet(), {
        'm-login',
        'm-redo',
        'm-form',
      });
      final login = cards.firstWhere((c) => c['messageId'] == 'm-login');
      expect(login['what'], '批准应用“Grok Notes”登录 @cody');
      expect(login['state'], '待批准');
      expect(login['canApproveByVoice'], isTrue);
      expect(login['scopes'], 'agent:notification:write、profile:read');
      final redo = cards.firstWhere((c) => c['messageId'] == 'm-redo');
      expect(redo['state'], '需要重新确认');
      final form = cards.firstWhere((c) => c['messageId'] == 'm-form');
      expect(form['canApproveByVoice'], isNull);
      expect(form['blocked'], contains('卡片里填写'));
      final apps = (r['apps'] as List).cast<Map>();
      expect(apps.single['requestId'], 'req1');
      expect(apps.single['what'], contains('Grok Notes'));
      expect(r['total'], 4);
    });

    test('nothing to approve says so; a failed apps read is not hidden', () async {
      h.w.routes['/integrations/overview'] = (_) => [];
      expect((await pending())['message'], '没有等你批准的事');
      h.w.routes['/integrations/overview'] = (_) =>
          throw const RaftApiException('offline');
      final r = await pending();
      expect(r['problem'], contains('读不到'));
      expect(r.containsKey('message'), isFalse);
    });

    test('a named channel is read for cards the app has not loaded', () async {
      h.client.responses['GET /messages/channel/ch-design'] = {
        'messages': [card('m-far', channel: 'ch-design')],
      };
      // ActivityClient answers requests from `responses` by "METHOD path".
      final r = await pending({'channel': 'design'});
      expect(
        (r['cards'] as List).cast<Map>().map((c) => c['messageId']),
        contains('m-far'),
      );
    });
  });

  group('actions.approve', () {
    setUp(() => put([card('m-login')]));

    test('is sensitive: previewed, then confirmed twice, then runs', () async {
      expect(h.tools.registry['actions.approve']!.risk, AgentCapabilityRisk.sensitive);
      final r = await h.act('actions.approve', {'message': 'm-login'});
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect(r['confirmation'], '1/2');
      expect(h.summary(r), '批准：批准应用“Grok Notes”登录 @cody');
      expect(h.changes(r), [
        '卡片状态: 待批准 → 已批准并执行',
        '开放的权限:  → agent:notification:write、profile:read',
      ]);
      for (final line in h.changes(r)) {
        expect(ActionHarness.lineOk(line), isTrue, reason: line);
      }
      final second = await h.approve(r);
      expect(second['status'], 'needs_second_confirmation');
      expect(h.client.posts, isEmpty, reason: 'nothing before the second yes');
      h.client.responses['POST /actions/m-login/execute'] = {
        'messageId': 'm-login',
        'metadata': {'state': 'executed'},
      };
      final done = await h.approve(second);
      expect(done['status'], 'done', reason: '$done');
      expect(h.client.posts, ['POST /actions/m-login/execute']);
      expect(h.client.bodies.single, {
        'expectedState': 'prepared',
        'expectedConfirmationVersion': 3,
      });
      expect((done['result'] as Map)['entity'], 'message');
      expect(h.tools.audit.entries.single.capability, 'actions.approve');
      expect(done.containsKey('undo'), isFalse, reason: 'cannot be taken back');
    });

    test('the model alone, or one press, never runs it', () async {
      final r = await h.act('actions.approve', {'message': 'm-login'});
      final early = await h.tools.run('confirm', {'token': r['confirmToken']});
      expect(early!['error'], 'needs_user_confirmation');
      await h.approve(r);
      expect(h.client.posts, isEmpty);
    });

    test('a card that needs re-confirming is re-confirmed, not run', () async {
      put([card('m-redo', state: 'reconfirm_required')]);
      final r = await h.act('actions.approve', {'message': 'm-redo'});
      expect(h.summary(r), contains('重新确认'));
      expect(h.changes(r).single, '卡片状态: 需要重新确认 → 待批准');
      final done = await h.approveTwice(r);
      expect(done['status'], 'done');
      expect(h.client.posts, ['POST /actions/m-redo/reconfirm']);
    });

    test('install needs an owner or admin', () async {
      put([card('m-inst', type: 'integration:install_marketplace_app')]);
      h.w.server = RaftRecord({'id': 's1', 'role': 'member'});
      final r = await h.act('actions.approve', {'message': 'm-inst'});
      expect('${r['error']}', contains('所有者或管理员'));
      h.w.server = RaftRecord({'id': 's1', 'role': 'admin'});
      final ok = await h.act('actions.approve', {'message': 'm-inst'});
      expect(ok['status'], 'needs_confirmation');
      expect(h.summary(ok), contains('安装应用“Grok Notes”'));
    });

    test('refused at the preview', () async {
      put([
        card('m-form', type: 'channel:create'),
        card('m-ran', state: 'executed'),
        card('m-copy', extra: {'sourceServerId': 'other', 'targetServerName': 'Elsewhere'}),
        {'id': 'm-plain', 'channelId': 'ch-general', 'content': 'hi', 'seq': '99'},
      ]);
      for (final (id, message) in [
        ('m-form', '语音不能代批'),
        ('m-ran', '不是待批准'),
        ('m-copy', '切到那个服务器'),
        ('m-plain', '不是操作卡片'),
        ('m-nope', '没有找到消息'),
      ]) {
        final r = await h.act('actions.approve', {'message': id});
        expect('${r['error']}', contains(message), reason: id);
        expect(r.containsKey('confirmToken'), isFalse);
      }
      h.w.server = RaftRecord({'id': 's1', 'role': 'guest'});
      expect('${(await h.act('actions.approve', {'message': 'm-login'}))['error']}', contains('访客'));
      h.w.server = RaftRecord({'id': 's1', 'role': 'owner'});
      h.w.channels = [
        for (final c in h.w.channels)
          c.id == 'ch-general' ? RaftChannel({...c.json, 'archivedAt': '2026-10-01T00:00:00Z'}) : c,
      ];
      expect('${(await h.act('actions.approve', {'message': 'm-login'}))['error']}', contains('已归档'));
      expect(h.client.posts, isEmpty);
    });

    test('a server that does not execute it is a failed card', () async {
      h.client.responses['POST /actions/m-login/execute'] = {
        'metadata': {'state': 'frozen'},
      };
      final r = await h.act('actions.approve', {'message': 'm-login'});
      final done = await h.approveTwice(r);
      expect(done['status'], 'failed');
      expect('${done['error']}', contains('frozen'));
    });
  });

  test('actions.dismiss only records the decision, and says the card stays', () async {
    put([card('m-login')]);
    final r = await h.act('actions.dismiss', {'message': 'm-login'});
    expect(h.summary(r), contains('仍留在频道里'));
    final done = await h.approve(r);
    expect(done['status'], 'done');
    expect(h.client.posts, ['POST /actions/m-login/event']);
    expect((h.client.bodies.single as Map)['eventType'], 'action_card.dismiss');
    expect(h.tools.registry['actions.dismiss']!.risk, AgentCapabilityRisk.change);
  });

  group('connected-app authorization', () {
    test('approve: sensitive, remembered like the app does', () async {
      final r = await h.act('apps.approve_request', {'request': 'req1'});
      expect(r['confirmation'], '1/2');
      expect(h.summary(r), '批准：应用“Grok Notes”请求授权给 @Cody');
      expect(h.changes(r).first, '授权: 待批准 → 已批准（记住这次选择）');
      final done = await h.approveTwice(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.client.posts, ['POST /integrations/requests/req1/approve']);
      expect(h.client.bodies.single, {'remember': true});
    });

    test('deny: one confirmation', () async {
      final r = await h.act('apps.deny_request', {'request': 'req1'});
      expect(r['confirmation'], '1/1');
      final done = await h.approve(r);
      expect(done['status'], 'done');
      expect(h.client.posts, ['POST /integrations/requests/req1/deny']);
    });

    test('an unknown or settled request, and no permission', () async {
      var r = await h.act('apps.approve_request', {'request': 'gone'});
      expect('${r['error']}', contains('没有这个待批准'));
      h.w.server = RaftRecord({'id': 's1', 'role': 'member'});
      r = await h.act('apps.approve_request', {'request': 'req1'});
      expect('${r['error']}', contains('没有处理应用授权的权限'));
      r = await h.act('apps.deny_request', {'request': 'req1'});
      expect('${r['error']}', contains('没有处理应用授权的权限'));
      expect(h.client.posts, isEmpty);
    });

    test('the agent\'s own creator may answer even without the right', () async {
      h.w.server = RaftRecord({'id': 's1', 'role': 'member'});
      h.w.routes['/agents'] = (_) => [
        {
          'id': 'a-cody',
          'name': 'cody',
          'creatorType': 'user',
          'creatorId': 'kevin',
        },
      ];
      await h.w.entityDirectory.refresh(WorkspaceEntityKind.agents);
      final r = await h.act('apps.deny_request', {'request': 'req1'});
      expect(r['status'], 'needs_confirmation', reason: '$r');
    });
  });

  test('find answers what people say', () async {
    for (final (said, id) in [
      ('批准这个登录请求', 'actions.approve'),
      ('有什么要我批准的', 'approvals.pending'),
      ('Grok 要的权限给他', 'apps.approve_request'),
      ('拒绝这个授权请求', 'apps.deny_request'),
    ]) {
      final r = await h.tools.run('find', {'intent': said});
      final ids = [for (final m in r!['matches'] as List) (m as Map)['id']];
      expect(ids.take(3), contains(id), reason: said);
    }
  });
}
