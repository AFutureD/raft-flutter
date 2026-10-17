import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../data/workspace_controller.dart';
import '../orb_tool.dart';
import 'orb_screen_contract.dart';
import 'orb_screen_reader.dart';
import 'orb_screen_snapshot.dart';

/// Tells the orb's layer that a reading is under way (and how many). Not a
/// `ChangeNotifier`: it lives as long as the workspace and nobody disposes it.
class OrbScreenReveal implements ValueListenable<int> {
  final _listeners = <VoidCallback>[];
  int _value = 0;

  @override
  int get value => _value;
  set value(int v) {
    if (v == _value) return;
    _value = v;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void increment() => value = _value + 1;
  void decrement() => value = _value - 1;

  /// The layer is listening (it is open).
  bool get watched => _listeners.isNotEmpty;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

/// Asks the person before a risky action runs, through the orb's confirm
/// card (`screen.action` of the capability layer): given the arguments of
/// `screen_action` (`id`, `action`, `text`), answers what the model is told
/// (the preview, with the card on the screen). Without one (no orb session),
/// `screen_action` answers `needsConfirm` and waits for a retry with
/// `confirmed: true`.
typedef OrbScreenAsk = Future<Map<String, Object?>> Function(
  Map<String, Object?> args,
);

/// What [OrbScreen.act] did.
class OrbScreenActed {
  const OrbScreenActed({
    this.stale,
    this.cancelled = false,
    this.unavailable = false,
    required this.screen,
    this.before,
  });

  /// Why the id did not hold (the screen is then [screen], freshly read).
  final String? stale;
  final bool cancelled;

  /// The app gave no semantics to read or press on.
  final bool unavailable;

  /// The screen after the action (after nothing, when it did not happen).
  final Map<String, Object?> screen;

  /// The control that was pressed, as it was read.
  final OrbScreenNode? before;

  bool get done => stale == null && !cancelled && !unavailable;
}

/// The screen of the app as the model gets it: the semantics tree (what a
/// screen reader reads), read into a snapshot whose ids `screen_action` takes.
///
/// One per workspace ([of]); the tools of one orb all use the same one, so
/// `navigate`, `describe_page` and `screen_action` share the latest snapshot.
class OrbScreen {
  OrbScreen(this.workspace);
  final WorkspaceController workspace;

  static final _shared = Expando<OrbScreen>('OrbScreen');
  static OrbScreen of(WorkspaceController w) => _shared[w] ??= OrbScreen(w);

  /// The seam for the orb's confirm card (see [OrbScreenAsk]).
  OrbScreenAsk? ask;

  /// The Navigator's context of the last tool call: the confirm card's
  /// action runs after the call, with no context of its own.
  BuildContext? context;

  /// The snapshot `screen_action` ids belong to.
  OrbScreenSnapshot? latest;
  int _count = 0;

  /// What a risky action asked to confirm when there is no card to ask:
  /// `<id>|<action>`, until the retry.
  String? pendingConfirm;

  // ---- the layer -----------------------------------------------------------

  /// More than 0 while a reading is under way: the orb's layer then lets the
  /// page below show in the semantics (a modal barrier hides it from a
  /// screen reader, and the model is not a person who can see through).
  final revealing = OrbScreenReveal();

  // ---- reading -------------------------------------------------------------

  SemanticsOwner? _owner(BuildContext context) {
    final view = View.maybeOf(context);
    for (final rv in RendererBinding.instance.renderViews) {
      if (view != null && !identical(rv.flutterView, view)) continue;
      final owner = rv.owner?.semanticsOwner;
      if (owner != null) return owner;
    }
    return RendererBinding.instance.rootPipelineOwner.semanticsOwner;
  }

  Future<void> _frame() => SchedulerBinding.instance.endOfFrame.timeout(
    const Duration(milliseconds: 500),
    onTimeout: () {},
  );

  /// Runs [use] while the semantics are on and the page shows through the
  /// orb's layer. The app builds no semantics for a screen reader nobody
  /// uses, so they are switched on for the length of [use] (and stay on
  /// while a person's own screen reader has them on); a node is only in the
  /// tree, and only takes an action, in that time.
  Future<T?> _lease<T>(BuildContext context, Future<T?> Function() use) async {
    if (!context.mounted) return null;
    final handle = SemanticsBinding.instance.ensureSemantics();
    final peek = revealing.watched;
    if (peek) revealing.increment();
    try {
      return await use();
    } finally {
      if (peek) revealing.decrement();
      handle.dispose();
    }
  }

  /// The screen now. With [settle] it waits a frame or two for the tree to
  /// stop changing, so a page that has just opened is read, not the one
  /// before it. [waitFirst]: a tree that has just been switched on, or a
  /// layer that has just been let through, shows after the next frame.
  Future<OrbScreenSnapshot?> _settled(
    BuildContext context, {
    required bool settle,
    bool waitFirst = true,
  }) async {
    String? previous;
    OrbScreenSnapshot? found;
    var wait = waitFirst;
    for (var i = 0; i < (settle ? 6 : 3); i++) {
      if (wait || i > 0) await _frame();
      wait = false;
      if (!context.mounted) return null;
      final root = _owner(context)?.rootSemanticsNode;
      if (root == null) continue;
      found = readOrbScreen(
        root,
        number: _count + 1,
        route: workspace.location.toString(),
      );
      if (!settle) break;
      final key = [
        for (final n in found.nodes) '${n.id}${n.label}',
        ...found.text,
      ].join('|');
      // The same twice in a row, after a first frame: settled.
      if (i > 0 && key == previous) break;
      previous = key;
    }
    if (found == null) return null;
    _count++;
    return latest = found;
  }

  /// What the screen shows now, or null when the app has no semantics to
  /// read.
  Future<OrbScreenSnapshot?> read(BuildContext context, {bool settle = true}) =>
      _lease(context, () => _settled(context, settle: settle));

  /// The contract of what is on the screen now, as JSON for the model; an
  /// `{unavailable}` note when the app has no semantics.
  Future<Map<String, Object?>> contract(
    BuildContext context, {
    OrbScreenDetail detail = OrbScreenDetail.full,
  }) async {
    try {
      final s = await read(context);
      return s == null ? _unavailable : orbScreenContract(s, detail: detail);
    } on Object {
      return {'unavailable': '读屏幕出错'};
    }
  }

  static const _unavailable = <String, Object?>{
    'unavailable': '读不到屏幕上的控件（界面没有准备好）',
  };

  /// [contract] for the Navigator of [ctx], read when called (so a caller
  /// that has awaited before does not hold a context across the gap).
  Future<Map<String, Object?>> contractFor(
    OrbToolContext ctx, {
    OrbScreenDetail detail = OrbScreenDetail.full,
  }) => contract(ctx.navigatorContext, detail: detail);

  /// One line of what the person can tap here, for the model's page note.
  Future<String> shortLine(BuildContext context) async {
    try {
      final s = await read(context, settle: false);
      return s == null ? '' : orbScreenShort(s);
    } on Object {
      return '';
    }
  }

  // ---- acting --------------------------------------------------------------

  /// [id] in the latest snapshot: the control or the scroll view, or why it
  /// is not there. This is what the model saw; the press checks it again
  /// against the screen of that moment.
  ({OrbScreenNode? node, OrbScreenScroll? scroll, String? stale}) resolve(
    String id,
  ) {
    final s = latest;
    if (s == null) return (node: null, scroll: null, stale: '还没有读过屏幕');
    final node = s.byId(id);
    final scroll = node == null ? s.scrollById(id) : null;
    if (node == null && scroll == null) {
      return (node: null, scroll: null, stale: '屏幕已经变了，$id 不在最新读到的屏幕上');
    }
    return (node: node, scroll: scroll, stale: null);
  }

  /// Performs [name] on the control [id] of the latest snapshot, through the
  /// semantics owner: the call a screen reader's tap makes. The screen is
  /// read again first and the control must still be the one the model saw
  /// (same id, role and name), else nothing is pressed. A field takes text
  /// once it has the focus, so `setText` first taps it. [stillMine] false
  /// (the person touched the screen) cancels. Answers the screen afterwards.
  Future<OrbScreenActed> act(
    BuildContext context,
    String id,
    SemanticsAction action, {
    String? text,
    bool Function()? stillMine,
  }) async {
    final seen = resolve(id);
    final saw = seen.node ?? seen.scroll;
    final fingerprint = seen.node?.fingerprint;
    final out = await _lease<OrbScreenActed>(context, () async {
      final fresh = await _settled(context, settle: true);
      if (fresh == null) {
        return const OrbScreenActed(unavailable: true, screen: _unavailable);
      }
      OrbScreenActed stale(String why) =>
          OrbScreenActed(stale: why, screen: orbScreenContract(fresh));
      if (saw == null) return stale(seen.stale ?? '屏幕已经变了');
      final node = fresh.byId(id);
      final scroll = node == null ? fresh.scrollById(id) : null;
      if (node == null && scroll == null) return stale('这个控件已经不在屏幕上了');
      if (node != null &&
          fingerprint != null &&
          node.fingerprint != fingerprint) {
        return stale('这个控件变了');
      }
      if (stillMine != null && !stillMine()) {
        return OrbScreenActed(
          cancelled: true,
          screen: orbScreenContract(fresh),
        );
      }
      final target = (node?.node ?? scroll!.node);
      if (!context.mounted) {
        return const OrbScreenActed(unavailable: true, screen: _unavailable);
      }
      final owner = target.owner ?? _owner(context);
      if (owner == null) {
        return const OrbScreenActed(unavailable: true, screen: _unavailable);
      }
      if (action == SemanticsAction.setText &&
          !target.getSemanticsData().hasAction(SemanticsAction.setText)) {
        owner.performAction(target.id, SemanticsAction.tap);
        await _frame();
        await _frame();
      }
      owner.performAction(target.id, action, text);
      if (!context.mounted) {
        return const OrbScreenActed(unavailable: true, screen: _unavailable);
      }
      final after = await _settled(context, settle: true);
      return OrbScreenActed(
        before: seen.node,
        screen: after == null ? _unavailable : orbScreenContract(after),
      );
    });
    return out ?? const OrbScreenActed(unavailable: true, screen: _unavailable);
  }
}
