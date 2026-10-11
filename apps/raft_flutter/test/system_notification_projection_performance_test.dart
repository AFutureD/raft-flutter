import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/system_notification_projection.dart';

// Counts access to the downgrade input without production instrumentation.
class _ServerReadProbe extends MapBase<String, dynamic> {
  _ServerReadProbe(this.data);
  final Map<String, dynamic> data;
  int downgradeReads = 0;

  @override
  dynamic operator [](Object? key) {
    if (key == 'planDowngradedAt') downgradeReads++;
    return data[key];
  }

  @override
  void operator []=(String key, dynamic value) => data[key] = value;
  @override
  Iterable<String> get keys => data.keys;
  @override
  void clear() => data.clear();
  @override
  dynamic remove(Object? key) => data.remove(key);
}

List<SystemNotice> _project(Map<String, dynamic> server, DateTime now) =>
    projectSystemNotifications(
      server: server,
      channels: const [],
      machines: const [],
      agents: const [],
      machinesReady: true,
      canViewMachines: true,
      mobile: false,
      feedbackUnread: 2,
      now: now,
    );

void main() {
  test('repeated paid or unknown plan projections skip downgrade input', () {
    for (final plan in ['pro', 'enterprise', null]) {
      final server = _ServerReadProbe({
        'id': 's',
        'role': 'owner',
        'plan': plan,
        'planDowngradedAt': '2026-10-01T00:00:00Z',
      });
      for (var i = 0; i < 20; i++) {
        expect(_project(server, DateTime.utc(2026, 10, 8)).map((n) => n.id), [
          'feedback-replies',
        ]);
      }
      expect(server.downgradeReads, 0, reason: 'plan=$plan');
    }
  });

  test('free grace deadline follows current clock and input on every read', () {
    final server = _ServerReadProbe({
      'id': 's',
      'role': 'owner',
      'plan': 'free',
      'planDowngradedAt': '2026-10-01T00:00:00Z',
    });
    final grace = _project(server, DateTime.utc(2026, 10, 7, 23, 59, 59)).first;
    expect(grace.kind, SystemNoticeKind.warning);
    expect(grace.parameters, {'expired': false, 'count': 1});
    expect(grace.fingerprint, 'plan-downgrade:grace:0:0:0');
    final expired = _project(server, DateTime.utc(2026, 10, 8)).first;
    expect(expired.kind, SystemNoticeKind.error);
    expect(expired.parameters, {'expired': true, 'count': 0});
    expect(expired.fingerprint, 'plan-downgrade:expired:0:0:0');
    server['planDowngradedAt'] = '2026-10-07T00:00:00Z';
    expect(_project(server, DateTime.utc(2026, 10, 8)).first.parameters, {
      'expired': false,
      'count': 6,
    });
    server['plan'] = 'pro';
    expect(_project(server, DateTime.utc(2026, 10, 8)).map((n) => n.id), [
      'feedback-replies',
    ]);
    expect(server.downgradeReads, 3);
  });

  test('absent empty and malformed free dates retain other notices', () {
    for (final raw in [null, '', 'not-a-date']) {
      final server = {
        'id': 's',
        'role': 'owner',
        'plan': 'free',
        'planDowngradedAt': ?raw,
      };
      expect(_project(server, DateTime.utc(2026, 10, 8)).map((n) => n.id), [
        'feedback-replies',
      ]);
    }
  });
}
