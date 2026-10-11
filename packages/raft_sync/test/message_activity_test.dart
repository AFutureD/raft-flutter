import 'package:test/test.dart';
import 'package:raft_sync/raft_sync.dart';

class TimestampProbe {
  TimestampProbe(this.value);
  String value;
  int reads = 0;
  @override
  String toString() {
    reads++;
    return value;
  }
}

Map<String, dynamic> row(
  String id,
  dynamic stamp, {
  String channel = 'a',
  String seq = '1',
}) => {'id': id, 'channelId': channel, 'seq': seq, 'createdAt': stamp};

void main() {
  test('600 held dates are parsed once across 20 sidebar/resize reads', () {
    final ledger = MessageLedger()..switchServer('server');
    final dates = List.generate(
      600,
      (i) => TimestampProbe(
        DateTime.utc(2026, 10, 1).add(Duration(minutes: i)).toIso8601String(),
      ),
    );
    ledger.ingest([
      for (var i = 0; i < dates.length; i++) row('m$i', dates[i], seq: '$i'),
    ], expectedGeneration: ledger.generation);
    for (var i = 0; i < 20; i++) {
      expect(ledger.latestCreatedAt('a'), DateTime.utc(2026, 10, 1, 9, 59));
    }
    expect(dates.fold<int>(0, (sum, date) => sum + date.reads), 600);
  });

  test(
    'dates, timezone and invalid/null values do not follow sequence order',
    () {
      final ledger = MessageLedger()..switchServer('server');
      ledger.ingest([
        row('older-high-seq', '2026-10-01T10:00:00Z', seq: '9007199254740999'),
        row('newest-low-seq', '2026-10-01T20:00:00+08:00', seq: '2'),
        row('invalid', 'garbage', seq: '100'),
        row('null', null),
      ], expectedGeneration: ledger.generation);
      expect(ledger.latestCreatedAt('a'), DateTime.utc(2026, 10, 1, 12));
      expect(ledger.latestCreatedAt('unknown'), isNull);
      ledger.ingest([
        row('unknown-valid', '2026-10-02T00:00:00Z', channel: 'unknown'),
      ], expectedGeneration: ledger.generation);
      expect(ledger.latestCreatedAt('unknown'), DateTime.utc(2026, 10, 2));
    },
  );

  test(
    'updates, deletion, revoke and reingress invalidate only their channel',
    () {
      final ledger = MessageLedger()..switchServer('server');
      final untouched = TimestampProbe('2026-10-01T11:00:00Z');
      ledger.ingest([
        row('one', '2026-10-01T10:00:00Z'),
        row('two', '2026-10-01T12:00:00Z'),
        row('other', untouched, channel: 'b'),
      ], expectedGeneration: ledger.generation);
      expect(ledger.latestCreatedAt('a'), DateTime.utc(2026, 10, 1, 12));
      final cachedOther = ledger.latestCreatedAt('b');
      ledger.ingestUpdate(
        row('two', '2026-10-01T09:00:00Z'),
        expectedGeneration: ledger.generation,
      );
      expect(ledger.latestCreatedAt('a'), DateTime.utc(2026, 10, 1, 10));
      ledger.remove('a', 'one');
      expect(ledger.latestCreatedAt('a'), DateTime.utc(2026, 10, 1, 9));
      ledger.revokeChannel('a');
      expect(ledger.latestCreatedAt('a'), isNull);
      ledger.ingest([
        row('fresh', '2026-10-02T10:00:00Z'),
      ], expectedGeneration: ledger.generation);
      expect(ledger.latestCreatedAt('a'), DateTime.utc(2026, 10, 2, 10));
      expect(identical(ledger.latestCreatedAt('b'), cachedOther), true);
      expect(untouched.reads, 1);
    },
  );

  test(
    'cached null, empty channels and stale generations never leak after switch',
    () {
      final ledger = MessageLedger()..switchServer('first');
      final invalid = TimestampProbe('bad');
      ledger.ingest([
        row('bad', invalid),
      ], expectedGeneration: ledger.generation);
      expect(ledger.latestCreatedAt('a'), isNull);
      expect(ledger.latestCreatedAt('a'), isNull);
      expect(invalid.reads, 1);
      final oldGeneration = ledger.generation;
      ledger.switchServer('second');
      expect(ledger.latestCreatedAt('a'), isNull);
      expect(
        ledger.ingest([
          row('late', '2026-10-10'),
        ], expectedGeneration: oldGeneration),
        false,
      );
      expect(ledger.latestCreatedAt('a'), isNull);
      ledger.ingest([
        row('current', '2026-10-02'),
      ], expectedGeneration: ledger.generation);
      expect(ledger.latestCreatedAt('a'), DateTime(2026, 10, 2));
      ledger.switchServer(null);
      expect(ledger.latestCreatedAt('a'), isNull);
    },
  );
}
