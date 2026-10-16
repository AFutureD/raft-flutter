import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_live_guard.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';

void main() {
  test('30 seconds is the limit', () {
    expect(agentLiveIdleLimit, const Duration(seconds: 30));
  });

  testWidgets('live listening nobody uses stops after the limit, once', (
    t,
  ) async {
    {
      var stopped = 0;
      final guard = AgentLiveGuard(onIdle: () => stopped++)..start();
      await t.pump(const Duration(seconds: 29));
      expect(stopped, 0);
      await t.pump(const Duration(seconds: 2));
      expect(stopped, 1);
      await t.pump(const Duration(minutes: 5));
      expect(stopped, 1);
      expect(guard.running, isFalse);
    }
  });

  testWidgets('every sign of life starts the wait over', (t) async {
    {
      var stopped = 0;
      final guard = AgentLiveGuard(onIdle: () => stopped++)..start();
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(seconds: 20));
        guard.touch(); // words arrived, the model spoke, a tool ran
      }
      expect(stopped, 0);
      await t.pump(const Duration(seconds: 31));
      expect(stopped, 1);
    }
  });

  testWidgets('a model that is still talking or working is not idle', (
    t,
  ) async {
    {
      var stopped = 0;
      var busy = true;
      AgentLiveGuard(onIdle: () => stopped++, busy: () => busy).start();
      await t.pump(const Duration(seconds: 95));
      expect(stopped, 0);
      busy = false;
      await t.pump(const Duration(seconds: 31));
      expect(stopped, 1);
    }
  });

  testWidgets(
    'stopped, or never started, it never fires; touch does not start it',
    (t) async {
      {
        var stopped = 0;
        final guard = AgentLiveGuard(onIdle: () => stopped++);
        guard.touch();
        await t.pump(const Duration(minutes: 2));
        expect(stopped, 0);
        guard.start();
        await t.pump(const Duration(seconds: 10));
        guard.stop();
        await t.pump(const Duration(minutes: 2));
        expect(stopped, 0);
        expect(guard.running, isFalse);
      }
    },
  );

  testWidgets('the limit can be set (tests, and a future setting)', (t) async {
    {
      var stopped = 0;
      AgentLiveGuard(
        onIdle: () => stopped++,
        limit: const Duration(seconds: 5),
      ).start();
      await t.pump(const Duration(seconds: 6));
      expect(stopped, 1);
    }
  });

  test('the session compresses its context early, with an explicit target', () {
    final c = GeminiLiveSession.contextCompression();
    expect(c['triggerTokens'], GeminiLiveSession.compressionTriggerTokens);
    expect(c['slidingWindow'], {
      'targetTokens': GeminiLiveSession.compressionTargetTokens,
    });
    // Well under the model's own limit (the default trigger is 80% of it), and
    // the target is below the trigger.
    expect(
      GeminiLiveSession.compressionTriggerTokens,
      lessThanOrEqualTo(40000),
    );
    expect(
      GeminiLiveSession.compressionTargetTokens,
      lessThan(GeminiLiveSession.compressionTriggerTokens),
    );
  });
}
