import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:raft_client/raft_client.dart';

/// The principal, server, role and page owning an accepted projection.
typedef ResourceAuthorityIdentity = ({
  String origin,
  int generation,
  String? principal,
  String? clientServer,
  String? server,
  String? role,
  String section,
  String? channel,
});

/// Memoizes an accepted page's directory facts.
///
/// Workspace notifications check record identity once; building each visible
/// row only reads the cached token.
class ResourceAuthorityCache {
  static const _accessKeys = [
    'isPrivate',
    'visibility',
    'accessLevel',
    'membership',
    'capabilities',
    'channelCapabilities',
    'guestAccessEnabled',
    'readOnlyReason',
    'parentChannelId',
    'serverId',
    'role',
  ];

  List<RaftChannel>? _channelSource, _dmSource;
  List<RaftChannel> _channels = [], _dms = [];
  Map<String, Map<String, dynamic>> _access = const {};
  List<Map<String, dynamic>> _orderedFacts = const [];

  /// The accepted access facts, isolated from mutable wire maps.
  Map<String, Map<String, dynamic>> get access => _access;
  String? _directory, _value;
  ResourceAuthorityIdentity? _identity;
  int? _revision;

  static Map<String, dynamic> _facts(RaftChannel channel) => {
    'id': channel.id,
    'type': channel.type,
    'joined': channel.joined,
    'archived': channel.archived,
    for (final key in _accessKeys)
      if (channel.json.containsKey(key)) key: channel.json[key],
  };

  /// Checks workspace directory changes, including in-place list changes.
  ///
  /// An authoritative permission event forces fresh facts even when an adapter
  /// retained a channel record while changing a nested capability map.
  void synchronize(
    List<RaftChannel> channels,
    List<RaftChannel> dms, {
    bool force = false,
  }) {
    _channelSource = channels;
    _dmSource = dms;
    if (_directory != null &&
        !force &&
        listEquals(_channels, channels) &&
        listEquals(_dms, dms)) {
      return;
    }
    _channels = List.of(channels);
    _dms = List.of(dms);
    final original = [
      for (final channel in [...channels, ...dms]) _facts(channel),
    ];
    final owned = [
      for (final row in jsonDecode(jsonEncode(original)) as List)
        Map<String, dynamic>.unmodifiable(row as Map),
    ];
    final ordered = [...owned]
      ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final directory = jsonEncode(ordered);
    if (_directory == directory) return;
    _directory = directory;
    _orderedFacts = ordered;
    // Preserve the directory's channel-then-DM collision rule independently
    // from the sorted token, and retain the previous facts across revocation.
    _access = Map.unmodifiable({
      for (final row in owned) row['id'] as String: row,
    });
    _value = null;
  }

  /// Returns the complete token for [identity] and the accepted access facts.
  String read({
    required ResourceAuthorityIdentity identity,
    required int revision,
    required List<RaftChannel> channels,
    required List<RaftChannel> dms,
  }) {
    if (_directory == null ||
        !identical(_channelSource, channels) ||
        !identical(_dmSource, dms)) {
      synchronize(channels, dms);
    }
    if (_value == null || _identity != identity || _revision != revision) {
      _identity = identity;
      _revision = revision;
      // Keep the previous token's wire shape: cached projections and pending
      // requests still compare the complete principal, page and access facts.
      _value = jsonEncode([
        identity.origin,
        identity.generation,
        identity.principal,
        identity.clientServer,
        identity.server,
        identity.role,
        identity.section,
        identity.channel,
        revision,
        ..._orderedFacts,
      ]);
    }
    return _value!;
  }
}
