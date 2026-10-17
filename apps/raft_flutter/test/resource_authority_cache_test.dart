import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/resource_authority_cache.dart';

const _identity = (
  origin: 'https://example.invalid',
  generation: 3,
  principal: 'alice',
  clientServer: 's1',
  server: 's1',
  role: 'member',
  section: 'activity',
  channel: null,
);

void main() {
  RaftChannel channel(String id, {bool allowed = true}) => RaftChannel({
    'id': id,
    'joined': true,
    'capabilities': {'viewChannel': allowed},
  });

  test('empty directory has a stable complete identity token', () {
    final memo = ResourceAuthorityCache();
    final channels = <RaftChannel>[];
    final dms = <RaftChannel>[];
    String read() => memo.read(
      identity: _identity,
      revision: 0,
      channels: channels,
      dms: dms,
    );
    final token = read();
    expect(jsonDecode(token), [
      'https://example.invalid',
      3,
      'alice',
      's1',
      's1',
      'member',
      'activity',
      null,
      0,
    ]);
    for (var i = 0; i < 100; i++) {
      expect(identical(read(), token), true);
    }
  });

  test(
    'in-place replacement/removal is reflected by the workspace notification',
    () {
      final memo = ResourceAuthorityCache();
      final channels = [channel('c1'), channel('c2')], dms = <RaftChannel>[];
      String read() => memo.read(
        identity: _identity,
        revision: 0,
        channels: channels,
        dms: dms,
      );
      final initial = read();
      final accepted = memo.access;
      channels[0] = channel('c1', allowed: false);
      memo.synchronize(channels, dms);
      final revoked = read();
      expect(revoked, isNot(initial));
      expect(accepted['c1']!['capabilities'], {'viewChannel': true});
      expect(memo.access['c1']!['capabilities'], {'viewChannel': false});
      channels.removeLast();
      memo.synchronize(channels, dms);
      expect(read(), isNot(revoked));
      expect(memo.access.containsKey('c2'), false);
    },
  );

  test(
    'authoritative event rechecks retained records and preserves old facts',
    () {
      final capabilities = <String, dynamic>{'viewChannel': true};
      final channels = [
        RaftChannel({'id': 'c1', 'joined': true, 'capabilities': capabilities}),
      ];
      final dms = <RaftChannel>[];
      final memo = ResourceAuthorityCache();
      String read() => memo.read(
        identity: _identity,
        revision: 0,
        channels: channels,
        dms: dms,
      );
      final token = read();
      final before = memo.access;
      capabilities['viewChannel'] = false;
      memo.synchronize(channels, dms, force: true);
      expect(read(), isNot(token));
      expect(before['c1']!['capabilities'], {'viewChannel': true});
      expect(memo.access['c1']!['capabilities'], {'viewChannel': false});
    },
  );

  test('principal, generation, server, role, page and authority revision invalidate', () {
    final memo = ResourceAuthorityCache();
    final channels = [channel('c1')], dms = <RaftChannel>[];
    String read(ResourceAuthorityIdentity identity, [int revision = 0]) =>
        memo.read(
          identity: identity,
          revision: revision,
          channels: channels,
          dms: dms,
        );
    final baseline = read(_identity);
    final decoded = jsonDecode(baseline) as List;
    final variants = [
      (
        origin: 'https://other.invalid',
        generation: 3,
        principal: 'alice',
        clientServer: 's1',
        server: 's1',
        role: 'member',
        section: 'activity',
        channel: null,
      ),
      (
        origin: _identity.origin,
        generation: 4,
        principal: 'alice',
        clientServer: 's1',
        server: 's1',
        role: 'member',
        section: 'activity',
        channel: null,
      ),
      (
        origin: _identity.origin,
        generation: 3,
        principal: 'bob',
        clientServer: 's1',
        server: 's1',
        role: 'member',
        section: 'activity',
        channel: null,
      ),
      (
        origin: _identity.origin,
        generation: 3,
        principal: 'alice',
        clientServer: 's2',
        server: 's1',
        role: 'member',
        section: 'activity',
        channel: null,
      ),
      (
        origin: _identity.origin,
        generation: 3,
        principal: 'alice',
        clientServer: 's1',
        server: 's2',
        role: 'member',
        section: 'activity',
        channel: null,
      ),
      (
        origin: _identity.origin,
        generation: 3,
        principal: 'alice',
        clientServer: 's1',
        server: 's1',
        role: 'guest',
        section: 'activity',
        channel: null,
      ),
      (
        origin: _identity.origin,
        generation: 3,
        principal: 'alice',
        clientServer: 's1',
        server: 's1',
        role: 'member',
        section: 'saved',
        channel: null,
      ),
      (
        origin: _identity.origin,
        generation: 3,
        principal: 'alice',
        clientServer: 's1',
        server: 's1',
        role: 'member',
        section: 'activity',
        channel: 'c1',
      ),
    ];
    for (final identity in variants) {
      expect(read(identity), isNot(baseline));
      expect(
        (jsonDecode(read(identity)) as List).last,
        decoded.last,
        reason: 'permission facts remain part of every token',
      );
    }
    expect(read(_identity, 1), isNot(baseline));
  });
}
