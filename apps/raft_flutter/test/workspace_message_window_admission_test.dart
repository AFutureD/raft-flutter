import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/data/workspace_message_windows.dart';

Map<String, dynamic> row(String id) => {
  'id': id,
  'channelId': 'alpha',
  'seq': '1',
  'content': id,
};

void main() {
  late WorkspaceController workspace;
  late WorkspaceMessageWindows windows;
  setUp(() {
    workspace = WorkspaceController(
      RaftClient(
        origin: 'https://window-admission.invalid',
        sessionStore: MemorySessionStore(),
      ),
    );
    windows = workspace.messageWindows;
    windows.switchServer('s');
  });
  tearDown(() => workspace.dispose());

  void attempt(MessageWindowRequest ticket) {
    windows.acceptRows('alpha', [row('late')], replace: true, request: ticket);
    windows.rememberWindow(
      'alpha',
      'late-authority',
      false,
      'late-token',
      historyLimited: true,
      request: ticket,
    );
    windows.cacheThread('parent', (
      parentChannelId: 'alpha',
      threadChannelId: 'late-thread',
      token: 'late-token',
      authority: 'late-authority',
      generation: windows.ledger.generation,
      hasMore: true,
      historyLimited: true,
      parent: null,
    ), request: ticket);
    windows.cacheThreadParent(
      'parent',
      RaftMessage(row('late-parent')),
      request: ticket,
    );
    windows.markContext('alpha', true, request: ticket);
    windows.markDiskOnly('alpha', request: ticket);
    windows.beginContextVisit('alpha', ticket, retainRows: false);
  }

  void expectRejected() {
    expect(windows.ledger.contains('alpha', 'late'), isFalse);
    expect(windows.visibleIds['alpha'], {'original'});
    expect(windows.accepted['alpha']?.authority, 'authority');
    expect(windows.accepted['alpha']?.token, 'token');
    expect(windows.historyLimit('alpha'), isFalse);
    expect(windows.isContext('alpha'), isFalse);
    expect(windows.isDiskOnly('alpha'), isFalse);
    expect(windows.threads, isEmpty);
    expect(windows.pendingContextChannelId, isNull);
  }

  void seed() {
    windows.acceptRows('alpha', [row('original')]);
    windows.rememberWindow(
      'alpha',
      'authority',
      true,
      'token',
      historyLimited: false,
    );
  }

  test(
    'selection epoch rejects every row, boundary and cached-parent write',
    () {
      seed();
      final old = windows.request(thread: false, allowed: () => true);
      windows.channelGeneration++;
      attempt(old);
      expect(old.current, isFalse);
      expectRejected();
    },
  );

  test(
    'live permission loss rejects a request without changing its epochs',
    () {
      seed();
      var permitted = true;
      final old = windows.request(thread: true, allowed: () => permitted);
      permitted = false;
      attempt(old);
      expectRejected();
    },
  );

  test(
    'ledger reset rejects old responses even with unchanged window epoch',
    () {
      final old = windows.request(allowed: () => true);
      windows.switchServer('other');
      seed();
      attempt(old);
      expectRejected();
    },
  );

  test('another receiver cannot use an otherwise current request', () {
    seed();
    final other = WorkspaceController(
      RaftClient(
        origin: 'https://other-window.invalid',
        sessionStore: MemorySessionStore(),
      ),
    );
    addTearDown(other.dispose);
    other.messageWindows.switchServer('s');
    final foreign = other.messageWindows.request(allowed: () => true);
    expect(foreign.current, isTrue);
    attempt(foreign);
    expectRejected();
  });

  test(
    'an earlier visit cannot start over or finish the next pending context',
    () {
      final first = windows.request(thread: false, allowed: () => true);
      windows.beginContextVisit('alpha', first, retainRows: false);
      windows.channelGeneration++;
      final next = windows.request(thread: false, allowed: () => true);
      windows.beginContextVisit('beta', next, retainRows: true);
      windows.beginContextVisit('alpha', first, retainRows: false);
      windows.finishContextVisit(request: first);
      expect(windows.pendingContextChannelId, 'beta');
      expect(windows.contextRetainsRows, isTrue);
      windows.finishContextVisit(request: next);
      expect(windows.pendingContextChannelId, isNull);
    },
  );

  test(
    'a context with no newer rows remains a context when boundaries update',
    () {
      seed();
      windows.markContext('alpha', false);
      windows.rememberWindow(
        'alpha',
        'authority',
        false,
        'token',
        historyLimited: true,
      );
      expect(windows.isContext('alpha'), isTrue);
      expect(windows.contextHasNewer('alpha'), isFalse);
      expect(windows.historyLimit('alpha'), isTrue);
      expect(windows.leaveContext('alpha'), isTrue);
      expect(windows.isContext('alpha'), isFalse);
      expect(windows.historyLimit('alpha'), isTrue);
      expect(() => windows.accepted.clear(), throwsUnsupportedError);
      expect(() => windows.threads.clear(), throwsUnsupportedError);
    },
  );

  test('disposing a receiver rejects late storage writes', () {
    seed();
    final old = windows.request(allowed: () => true);
    windows.dispose();
    attempt(old);
    expect(old.current, isFalse);
    expectRejected();
  });
}
