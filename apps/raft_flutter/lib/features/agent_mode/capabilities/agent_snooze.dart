import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../data/device_preferences.dart';
import '../../../data/workspace_controller.dart';
import '../agent_mode_data.dart';

/// "稍后 / 明天再看": an attention item the person set aside until a time.
///
/// The item leaves the attention layer (it joins the ids [AgentModeData.hidden]
/// holds, which the page already filters by) and comes back when [until]
/// passes: while the app runs, a timer puts it back and says so; when the app
/// was closed, the next visit simply finds it due and tells the person.
/// What is set aside is kept on the device (the app's SharedPreferences),
/// per account and server, so it survives leaving agent mode and closing the
/// app.
class AgentSnoozed {
  const AgentSnoozed({
    required this.id,
    required this.headline,
    required this.until,
    required this.at,
    this.channel,
    this.taskNumber,
  });

  /// The attention item's id: a task id, or `mention:<channel or thread id>`.
  final String id;

  /// What it was, in the sentence the card carried.
  final String headline;
  final DateTime until, at;
  final String? channel;
  final int? taskNumber;

  Map<String, Object?> toJson() => {
    'id': id,
    'headline': headline,
    'until': until.millisecondsSinceEpoch,
    'at': at.millisecondsSinceEpoch,
    'channel': ?channel,
    'taskNumber': ?taskNumber,
  };

  static AgentSnoozed? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], until = raw['until'], at = raw['at'];
    if (id is! String || id.isEmpty || until is! num) return null;
    return AgentSnoozed(
      id: id,
      headline: '${raw['headline'] ?? ''}',
      until: DateTime.fromMillisecondsSinceEpoch(until.toInt()),
      at: DateTime.fromMillisecondsSinceEpoch(at is num ? at.toInt() : 0),
      channel: raw['channel'] is String ? raw['channel'] as String : null,
      taskNumber: raw['taskNumber'] is int ? raw['taskNumber'] as int : null,
    );
  }
}

class AgentSnoozeStore {
  AgentSnoozeStore(this.w, {DateTime Function()? now, this.timers = true})
    : _now = now ?? DateTime.now;

  static final _stores = Expando<AgentSnoozeStore>('agent snooze');

  /// The store of this workspace: one per controller, so every capability and
  /// the page see the same entries.
  static AgentSnoozeStore of(WorkspaceController w) =>
      _stores[w] ??= AgentSnoozeStore(w);

  static const _keyPrefix = 'raft.agentModeSnoozed';

  final WorkspaceController w;
  final DateTime Function() _now;

  // Not a ChangeNotifier: one store per controller outlives any page, so it
  // has no point at which to be disposed.
  final _listeners = <VoidCallback>[];
  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
  void notifyListeners() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Whether a timer brings items back while the app runs (tests turn it off
  /// and call [tick]).
  final bool timers;

  /// The clock this store goes by.
  DateTime now() => _now();

  int _watchers = 0;

  /// A reader (the runtime of an open agent mode) wants items put back on
  /// time while it lives: only then does a timer run. Pair with [unwatch].
  void watch() => _watchers++;

  void unwatch() {
    if (_watchers > 0) _watchers--;
    if (_watchers == 0) _timer?.cancel();
  }

  String? _scope;
  var _entries = <AgentSnoozed>[];
  final _resurfaced = <AgentSnoozed>[];
  Timer? _timer;

  String get _scopeKey =>
      jsonEncode([w.client.origin, w.client.user?.id, w.client.serverId]);

  String get _storeKey => '$_keyPrefix:${_scopeKey.hashCode}';

  /// Adopts the account and server in view: reads what the device kept for
  /// them, drops what is due, hides what is not.
  void _adopt() {
    final scope = _scopeKey;
    if (_scope == scope) return;
    if (_scope != null) {
      // Another server: its items are not hidden here any more.
      final hidden = AgentModeData.hidden(w);
      for (final e in _entries) {
        hidden.remove(e.id);
      }
    }
    _scope = scope;
    _timer?.cancel();
    _entries = [];
    final raw = DevicePreferences.current?.getString(_storeKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        _entries = [
          if (list is List)
            for (final r in list) ?AgentSnoozed.fromJson(r),
        ];
      } on Object {
        _entries = [];
      }
    }
    final now = _now();
    final due = _entries.where((e) => !e.until.isAfter(now)).toList();
    _entries = [
      for (final e in _entries)
        if (e.until.isAfter(now)) e,
    ];
    _resurfaced.addAll(due);
    final hidden = AgentModeData.hidden(w);
    for (final e in _entries) {
      hidden.add(e.id);
    }
    if (due.isNotEmpty) _persist();
    _schedule();
  }

  void _persist() {
    final prefs = DevicePreferences.current;
    if (prefs == null) return;
    final key = _storeKey;
    final future = _entries.isEmpty
        ? prefs.remove(key)
        : prefs.setString(
            key,
            jsonEncode([for (final e in _entries) e.toJson()]),
          );
    unawaited(future.then<void>((_) {}, onError: (Object _) {}));
  }

  void _schedule() {
    _timer?.cancel();
    if (!timers || _watchers == 0 || _entries.isEmpty) return;
    final next = _entries.map((e) => e.until).reduce(
      (a, b) => a.isBefore(b) ? a : b,
    );
    var wait = next.difference(_now());
    if (wait.isNegative) wait = Duration.zero;
    // A very long wait is taken in steps, so a changed clock is noticed.
    if (wait > const Duration(hours: 6)) wait = const Duration(hours: 6);
    _timer = Timer(wait + const Duration(milliseconds: 50), tick);
  }

  /// Puts back what is due. Called by the timer and by readers.
  void tick() {
    _adopt();
    final now = _now();
    final due = [
      for (final e in _entries)
        if (!e.until.isAfter(now)) e,
    ];
    if (due.isNotEmpty) {
      _entries = [
        for (final e in _entries)
          if (e.until.isAfter(now)) e,
      ];
      final hidden = AgentModeData.hidden(w);
      for (final e in due) {
        hidden.remove(e.id);
      }
      _resurfaced.addAll(due);
      _persist();
      notifyListeners();
    }
    _schedule();
  }

  /// What is set aside now, soonest first.
  List<AgentSnoozed> get active {
    tick();
    return List.of(_entries)..sort((a, b) => a.until.compareTo(b.until));
  }

  bool isSnoozed(String id) => active.any((e) => e.id == id);

  AgentSnoozed? entry(String id) =>
      active.where((e) => e.id == id).firstOrNull;

  /// Sets [item] aside until [until] (replaces an earlier time for the same
  /// item).
  AgentSnoozed snooze(AgentAttentionItem item, DateTime until) {
    _adopt();
    final entry = AgentSnoozed(
      id: item.id,
      headline: item.headline,
      until: until,
      at: _now(),
      channel: item.channelName,
      taskNumber: item.taskNumber,
    );
    _entries = [
      for (final e in _entries)
        if (e.id != item.id) e,
      entry,
    ];
    AgentModeData.hidden(w).add(item.id);
    _persist();
    _schedule();
    notifyListeners();
    return entry;
  }

  /// Puts [id] back at once; false when it was not set aside.
  bool unsnooze(String id) {
    _adopt();
    final before = _entries.length;
    _entries = [
      for (final e in _entries)
        if (e.id != id) e,
    ];
    if (_entries.length == before) return false;
    AgentModeData.hidden(w).remove(id);
    _persist();
    _schedule();
    notifyListeners();
    return true;
  }

  /// Items that came back since the last call (the person is told once).
  List<AgentSnoozed> takeResurfaced() {
    tick();
    final out = List.of(_resurfaced);
    _resurfaced.clear();
    return out;
  }

  /// "稍后" / "明天再看" in a time. [now] is local.
  static DateTime untilFor(String when, DateTime now) {
    final local = now.toLocal();
    DateTime at(int dayOffset, int hour) =>
        DateTime(local.year, local.month, local.day + dayOffset, hour);
    switch (when) {
      case 'tonight':
        return local.hour < 17 ? at(0, 19) : at(1, 9);
      case 'tomorrow':
        return at(1, 9);
      case 'next_week':
        final days = (DateTime.monday - local.weekday + 7) % 7;
        return at(days == 0 ? 7 : days, 9);
      default:
        return local.add(const Duration(hours: 3));
    }
  }
}
