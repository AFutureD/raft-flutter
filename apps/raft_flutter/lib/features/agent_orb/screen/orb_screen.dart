import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../data/workspace_controller.dart';
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

/// Holds the semantics of the app switched on until [release] (the app builds
/// no semantics tree for a screen reader nobody uses).
class OrbScreenHold {
  OrbScreenHold._(this._screen);
  OrbScreen? _screen;

  void release() {
    final s = _screen;
    if (s == null) return;
    _screen = null;
    s._released();
  }
}

/// Who answers for a risky action before it is done: given what is about to
/// happen, true to go on. The seam for the orb's confirm card; without one,
/// `screen_action` answers `needsConfirm` and waits for a retry with
/// `confirmed: true`.
typedef OrbScreenConfirm = Future<bool> Function(
  BuildContext context,
  String describe,
);

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

  /// The seam for the orb's confirm card (see [OrbScreenConfirm]).
  OrbScreenConfirm? confirm;

  /// The snapshot `screen_action` ids belong to.
  OrbScreenSnapshot? latest;
  int _count = 0;

  /// What a risky action asked to confirm: `<id>|<action>`, until the retry.
  String? pendingConfirm;

  // ---- keeping semantics on -----------------------------------------------

  int _holds = 0;
  SemanticsHandle? _handle;

  /// Switches the semantics on until the hold is released: for as long as the
  /// orb has a call or its layer open.
  OrbScreenHold hold() {
    _holds++;
    _handle ??= SemanticsBinding.instance.ensureSemantics();
    return OrbScreenHold._(this);
  }

  void _released() {
    if (--_holds > 0) return;
    _holds = 0;
    _handle?.dispose();
    _handle = null;
  }

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

  /// What the screen shows now, or null when the app has no semantics to
  /// read. Waits a frame or two for the tree to settle, so a page that has
  /// just opened is read, not the one before it.
  Future<OrbScreenSnapshot?> read(BuildContext context) async {
    if (!context.mounted) return null;
    final temporary = _handle == null;
    final handle = _handle ?? SemanticsBinding.instance.ensureSemantics();
    final peek = revealing.watched;
    if (peek) revealing.increment();
    try {
      String? previous;
      OrbScreenSnapshot? found;
      for (var i = 0; i < 6; i++) {
        await _frame();
        if (!context.mounted) return null;
        final root = _owner(context)?.rootSemanticsNode;
        if (root == null) continue;
        found = readOrbScreen(
          root,
          number: _count + 1,
          route: workspace.location.toString(),
        );
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
    } finally {
      if (peek) revealing.decrement();
      if (temporary) handle.dispose();
    }
  }

  /// The contract of what is on the screen now, as JSON for the model; an
  /// `{unavailable}` note when the app has no semantics.
  Future<Map<String, Object?>> contract(
    BuildContext context, {
    OrbScreenDetail detail = OrbScreenDetail.full,
  }) async {
    try {
      final s = await read(context);
      if (s == null) {
        return {'unavailable': '读不到屏幕上的控件（界面没有准备好）'};
      }
      return orbScreenContract(s, detail: detail);
    } on Object {
      return {'unavailable': '读屏幕出错'};
    }
  }

  /// One line of what the person can tap here, for the model's page note.
  Future<String> shortLine(BuildContext context) async {
    try {
      final s = await read(context);
      return s == null ? '' : orbScreenShort(s);
    } on Object {
      return '';
    }
  }

  // ---- acting --------------------------------------------------------------

  /// Why [id] is not a control of the latest snapshot any more, or null when
  /// it still is.
  String? staleReason(OrbScreenSnapshot s, OrbScreenNode node) {
    if (!node.node.attached) return '这个控件已经不在屏幕上了';
    if (orbNodeFingerprint(node.node) != node.fingerprint) {
      return '这个控件变了';
    }
    return null;
  }

  /// Performs [action] on [node] through the semantics owner: the call a
  /// screen reader's tap makes.
  void perform(
    BuildContext context,
    OrbScreenNode node,
    SemanticsAction action, [
    Object? args,
  ]) {
    final owner = node.node.owner ?? _owner(context);
    owner?.performAction(node.node.id, action, args);
  }
}
