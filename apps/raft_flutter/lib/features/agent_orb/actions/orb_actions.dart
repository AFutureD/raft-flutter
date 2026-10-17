import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../data/workspace_controller.dart';
import '../../agent_mode/capabilities/agent_capability.dart';
import '../../agent_mode/capabilities/agent_capability_tools.dart';
import '../../agent_mode/capabilities/agent_consent.dart';
import '../orb_driving.dart' show orbRiskyWords;
import '../orb_tool.dart';
import '../../agent_mode/agent_steering.dart' show agentAppSays;
import 'orb_action_declarations.dart';
import 'orb_card_words.dart';
import 'orb_nudge.dart';

/// One line of a confirm card: `发到  #general`. [from] is what it was before,
/// when it changes something that was there.
@immutable
class OrbCardRow {
  const OrbCardRow(this.label, this.value, {this.from = ''});
  final String label, value, from;

  /// Reads the capability layer's `字段: 原值 → 新值` line.
  static OrbCardRow? parse(String line) {
    final m = RegExp(r'^([^:：]+)[:：]\s*(.*?)\s*→\s*(.*)$').firstMatch(line);
    if (m == null) return null;
    return OrbCardRow(m[1]!.trim(), m[3]!.trim(), from: m[2]!.trim());
  }
}

/// The action that waits for the person: what the card shows.
@immutable
class OrbPendingAction {
  const OrbPendingAction({
    required this.token,
    required this.cardId,
    required this.capabilityId,
    required this.summary,
    required this.rows,
    required this.heard,
    this.step = 1,
    this.total = 1,
  });

  /// What the capability layer knows it by; the model never sees it.
  final String token;
  final String cardId, capabilityId;

  /// One sentence: what will happen ("回复 Cody 的消息：“可以合”").
  final String summary;

  /// Who, where, the exact words.
  final List<OrbCardRow> rows;

  /// The person has said yes in words; the model has yet to relay it.
  final bool heard;

  /// A sensitive operation is confirmed twice, by the buttons only.
  final int step, total;
  bool get sensitive => total > 1;
}

enum OrbOutcomeKind { done, failed, cancelled, refused }

/// What the layer says after the card: done, the error, cancelled, or the
/// refusal while driving.
@immutable
class OrbActionOutcome {
  const OrbActionOutcome(this.kind, this.text);
  final OrbOutcomeKind kind;
  final String text;
}

/// The orb's hold on the app's capability layer: what the model reads
/// (`find`, `query`) and what it asks to change (a tool for each common
/// operation, `act` for the rest).
///
/// It is the layer Agent mode runs on, so the preview is the same, the write
/// is the same and the consent is the same: nothing is written until the
/// person taps 确认 on the card, or says yes in their own words (the model
/// then relays it with `confirm`; its own say-so is no confirmation). A
/// sensitive operation takes two presses and no words. One action waits at a
/// time; a new request replaces it. While driving, only the low-risk ones are
/// allowed (see [orbDrivingCapabilities]).
class OrbActions extends ChangeNotifier {
  OrbActions({
    required this.workspace,
    bool Function()? driving,
    this.env = const AgentCapabilityEnv(),
    AgentCapabilityRegistry? registry,
    DateTime Function()? now,
    Random? random,
    List<String> Function()? card,
    this.outcomeLinger = const Duration(seconds: 8),
  }) : registry = registry ?? orbActionRegistry,
       driving = driving ?? (() => false),
       _now = now ?? DateTime.now,
       card = card ?? (() => const []) {
    ledger = AgentConsentLedger(now: _now, random: random);
    capabilities = AgentCapabilityTools(
      workspace: workspace,
      registry: this.registry,
      env: env,
      userConsent: ledger,
      // Sensitive operations take two presses on the card.
      actionRisks: const {
        AgentCapabilityRisk.change,
        AgentCapabilityRisk.sensitive,
      },
      now: _now,
      random: random,
    );
    ledger.addListener(_ledgerChanged);
  }

  final WorkspaceController workspace;
  final AgentCapabilityRegistry registry;
  final AgentCapabilityEnv env;
  final DateTime Function() _now;

  /// Whether the car is moving (the orb's driving mode).
  bool Function() driving;

  /// The ids that name the card in front of the person (driving), for
  /// "稍后提醒我" without saying which.
  List<String> Function() card;

  /// How long the result stays on the layer.
  final Duration outcomeLinger;

  /// What the person has agreed to; fed only by them.
  late final AgentConsentLedger ledger;
  late final AgentCapabilityTools capabilities;

  /// Told the model something the app saw (a tap on the card); the model is
  /// not the one who pressed it.
  void Function(String note)? onTell;

  /// The agent layer: the app says the card aloud and the result itself.
  /// Every answer to the model that ends something then carries the words
  /// ([agentAppSays]), and a tap on the card is said through [onSay] instead
  /// of being told to the model.
  bool appSpeaks = false;

  /// Says a line as the agent's own words (a tap on the card, when the app
  /// speaks).
  void Function(String line)? onSay;

  /// The person's words cancelled the card (a plain no) and nobody has used
  /// that yet: the app answers it. Spent by [takeCancelledByWords].
  bool _cancelledByWords = false;

  /// Whether the card that was waiting was just cancelled by the person's own
  /// words; true once.
  bool takeCancelledByWords() {
    final was = _cancelledByWords;
    _cancelledByWords = false;
    return was;
  }

  /// The person pressed a button on the card; this is what the layer shows.
  void Function(OrbActionOutcome outcome)? onTapped;

  String? _token;
  Future<Map<String, Object?>>? _running;
  OrbPendingAction? _flying;
  Map<String, Object?>? _last;
  OrbActionOutcome? _outcome;
  Timer? _outcomeTimer, _expiry;
  bool _disposed = false;

  /// The action that waits for the person, or null.
  OrbPendingAction? get pending {
    // While it is being carried out the card stays, with its buttons off.
    final flying = _flying;
    if (flying != null) return flying;
    final token = _token;
    if (token == null) return null;
    final p = ledger.active.where((e) => e.request.token == token).firstOrNull;
    if (p == null) return null;
    return OrbPendingAction(
      token: token,
      cardId: p.cardId,
      capabilityId: p.request.capabilityId,
      summary: p.request.preview.summary,
      rows: [
        for (final line in p.request.preview.changes) ?OrbCardRow.parse(line),
      ],
      heard: p.approved,
      step: p.request.step,
      total: p.request.total,
    );
  }

  /// An action is being carried out.
  bool get busy => _running != null;

  /// What happened to the last card, for a few seconds.
  OrbActionOutcome? get outcome => _outcome;

  /// The tools the model gets.
  late final List<OrbTool> tools = [
    for (final d in orbActionDeclarations(registry))
      OrbTool(
        declaration: d,
        handler: (args, ctx) => call('${d['name']}', args),
      ),
  ];

  /// One call of the model, by tool name.
  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> args,
  ) async {
    try {
      return switch (name) {
        'confirm' => await confirm(),
        'cancel_action' => await cancel(),
        'find' => await _find(args),
        'query' => await _query(args),
        'undo' => await _undo(args),
        _ => await request(name, args),
      };
    } on Object {
      return {'error': '没有做成：$name 出错了，稍后再试'};
    }
  }

  Future<Map<String, Object?>> _find(Map<String, Object?> args) async {
    final r = await capabilities.run('find', args) ?? const {};
    return {...r, 'activity': '已查找可用的功能'};
  }

  Future<Map<String, Object?>> _query(Map<String, Object?> args) async {
    final r = await capabilities.run('query', args) ?? const {};
    if (r['error'] != null) return r;
    // Agent mode's hint about drawing a card does not apply here.
    return {
      for (final e in r.entries)
        if (e.key != 'render') e.key: e.value,
      'activity': '已查询：${r['capability']}',
    };
  }

  Future<Map<String, Object?>> _undo(Map<String, Object?> args) async {
    final r = await capabilities.run('undo', args) ?? const {};
    if (r['status'] == 'undone') {
      final text = '${r['message'] ?? '已撤销'}';
      _setOutcome(OrbActionOutcome(OrbOutcomeKind.done, text));
      _changed();
      return {...r, 'activity': text};
    }
    return r;
  }

  // ---- asking -----------------------------------------------------------------

  /// The model asks for [tool]. Answers with the preview (the card is on the
  /// screen), or why not. Nothing is written.
  Future<Map<String, Object?>> request(
    String tool,
    Map<String, Object?> args,
  ) async {
    // `act` names its capability; the tools with a name of their own are one.
    final String? id;
    final Map<String, Object?> inner;
    if (tool == 'act') {
      id = _text(args['capability']);
      inner = _argsOf(args['args']);
    } else {
      id = orbActionCapabilities[tool];
      inner = args;
      if (id == null) return {'error': '没有这个操作：$tool'};
    }
    final refusal = _refusal(id, inner);
    if (refusal != null) return _refuse(refusal);

    await _drop();
    _last = null;
    _setOutcome(null);
    final answer = await _preview(tool, id, inner, args);
    if (answer?['status'] != 'needs_confirmation') {
      _changed();
      if (answer?['status'] == 'open_page') {
        return {...answer!, 'activity': '已带你去对应的页面'};
      }
      return answer ?? {'error': '没有做成'};
    }
    final token = '${answer!['confirmToken']}';
    _token = token;
    final p = pending;
    if (p != null) _watchExpiry(token);
    _changed();
    final summary = '${(answer['preview'] as Map)['summary']}';
    final twice = answer['risk'] == AgentCapabilityRisk.sensitive.name;
    return {
      if (appSpeaks && p != null) agentAppSays: orbRestate(p),
      'status': 'needs_confirmation',
      'preview': {
        'summary': summary,
        'changes': (answer['preview'] as Map)['changes'],
      },
      'activity': '待确认：$summary',
      'next': twice
          ? '这是敏感操作：屏幕上出了确认卡，要用户自己点两次“确认”，说话不算。用一句话复述（$summary），请他点屏幕上的确认；他没点就什么都不要做'
          : driving()
          ? '驾驶中，确认卡占着屏幕。只用一句话复述（$summary），问“要发吗？”，等用户点大按钮或说“确认”，再调用 confirm；他没表态就什么都不要做'
          : '屏幕上已经出现确认卡。用一句话复述将要做的事（$summary），问“要发吗？”，等用户点“确认”或亲口说“确认/发吧/好”，再调用 confirm；他没表态就什么都不要做',
    };
  }

  /// The arguments of an `act`: a JSON text, or already a map.
  static Map<String, Object?> _argsOf(Object? raw) {
    try {
      final v = raw is String
          ? (raw.trim().isEmpty ? null : jsonDecode(raw))
          : raw;
      return v is Map ? Map<String, Object?>.from(v) : const {};
    } on Object {
      return const {};
    }
  }

  Future<Map<String, Object?>?> _preview(
    String tool,
    String? id,
    Map<String, Object?> inner,
    Map<String, Object?> original,
  ) async {
    Future<Map<String, Object?>?> act(Map<String, Object?> a) => capabilities
        .run('act', {'capability': id ?? original['capability'], 'args': a});
    if (id != 'attention.snooze') {
      // An `act` whose arguments are not a map goes on as the model wrote
      // them, so the layer's own error says what is wrong.
      return tool == 'act' && inner.isEmpty && original['args'] != null
          ? capabilities.run('act', original)
          : act(inner);
    }
    // "Remind me later" is about the card in front of the person unless the
    // model names the thing: the card's own ids are tried in turn.
    final given = _text(inner['item']);
    final items = [?given, ...card()];
    if (items.isEmpty) {
      return {'error': '要稍后提醒哪一件？问用户是哪一件，再带 item 调用'};
    }
    Map<String, Object?>? refusedFirst;
    for (final item in items) {
      final r = await act({...inner, 'item': item});
      if (r?['status'] == 'needs_confirmation') return r;
      refusedFirst ??= r;
    }
    return refusedFirst;
  }

  /// Why the capability [id] has to wait until the car is parked; null when
  /// it may go.
  String? _refusal(String? id, Map<String, Object?> args) {
    if (!driving()) return null;
    if (id == null || !orbDrivingCapabilities.contains(id)) {
      final title = id == null ? null : registry[id]?.title;
      return title == null ? '这件事' : '“${title.split('：').first}”';
    }
    final said = _text(args['text']);
    if (said != null && orbRiskyWords.hasMatch(said)) {
      return '批准、合并、删除、发布这类事';
    }
    return null;
  }

  Map<String, Object?> _refuse(String what) {
    final text = '停车后再做：$what';
    _setOutcome(OrbActionOutcome(OrbOutcomeKind.refused, text));
    _changed();
    return {
      'refused': true,
      'error': '停车后再做',
      'activity': text,
      'message':
          '驾驶中只做回复、表情、稍后提醒、交给别人和催一下。$what 要等停车：对用户说“这个等你停车后再做”，'
          '可以问要不要稍后提醒他；不要再试。',
    };
  }

  // ---- the person answers -------------------------------------------------------

  /// The model relays that the person agreed. It only counts if they did:
  /// a tap on the card, or their own words after the card was up.
  Future<Map<String, Object?>> confirm() async {
    final running = _running;
    if (running != null) return running;
    final token = _token;
    if (token == null) {
      final last = _last;
      if (last != null) {
        return {
          for (final e in last.entries)
            if (e.key != agentAppSays) e.key: e.value,
          'already': true,
        };
      }
      return {'error': '没有等着确认的操作：先用动作工具提出来，用户同意后再 confirm_action'};
    }
    if (pending == null) {
      // The card ran out under the model.
      _token = null;
      return {'error': '那张确认卡已经过期了，什么都没做。要做就重新提出来'};
    }
    return _run(token, tapped: false);
  }

  /// The person pressed 确认 on the card.
  Future<void> confirmTapped() async {
    final p = pending;
    if (p == null || _running != null) return;
    if (!ledger.cardTapped(p.cardId, yes: true)) return;
    await _run(p.token, tapped: true);
  }

  /// The person pressed 取消 on the card.
  Future<void> cancelTapped() async {
    final p = pending;
    if (p == null) return;
    _token = null;
    if (!ledger.cardTapped(p.cardId, yes: false)) return;
    await _forget(p.token);
    const cancelled = OrbActionOutcome(OrbOutcomeKind.cancelled, '已取消');
    _setOutcome(cancelled);
    _changed();
    onTapped?.call(cancelled);
    _announce('用户点了取消，什么都没做。用一句话回应，不要再问。', '好，已取消。');
  }

  /// The model drops the card because the person changed their mind.
  Future<Map<String, Object?>> cancel() async {
    final token = _token;
    if (token == null) {
      return {
        if (appSpeaks) agentAppSays: '现在没有等着确认的操作。',
        'status': 'cancelled',
        'message': '没有等着的操作',
      };
    }
    _token = null;
    ledger.cancel(token, force: true);
    await _forget(token);
    _setOutcome(const OrbActionOutcome(OrbOutcomeKind.cancelled, '已取消'));
    _changed();
    return {
      if (appSpeaks) agentAppSays: '好，已取消。',
      'status': 'cancelled',
      'message': '已取消，什么都没做',
      'activity': '已取消',
    };
  }

  /// The person's words, typed or spoken: they can agree or refuse.
  void userSaid(String text, {bool fresh = true}) {
    // A new utterance: what the last one cancelled is no longer news.
    if (fresh) _cancelledByWords = false;
    ledger.userSaid(text, fresh: fresh);
  }

  Future<Map<String, Object?>> _run(String token, {required bool tapped}) {
    // Set before the capability layer takes the person's answer: the ledger
    // tells this class the card is gone the moment it is taken.
    final done = Completer<Map<String, Object?>>();
    final p = pending;
    _flying = p == null
        ? null
        : OrbPendingAction(
            token: p.token,
            cardId: p.cardId,
            capabilityId: p.capabilityId,
            summary: p.summary,
            rows: p.rows,
            heard: true,
            step: p.step,
            total: p.total,
          );
    _running = done.future;
    _changed();
    _execute(token, tapped: tapped).then(
      done.complete,
      onError: (Object e, StackTrace s) => done.completeError(e, s),
    );
    return done.future;
  }

  Future<Map<String, Object?>> _execute(
    String token, {
    required bool tapped,
  }) async {
    try {
      return await _carryOut(token, tapped: tapped);
    } finally {
      _running = null;
      _flying = null;
      _changed();
    }
  }

  Future<Map<String, Object?>> _carryOut(
    String token, {
    required bool tapped,
  }) async {
    final summary = pending?.summary ?? '';
    final r = await capabilities.run('confirm', {'token': token}) ?? const {};
    if (r['error'] == 'needs_user_confirmation') {
      // Nothing was agreed yet: the card stays.
      final waiting = pending;
      return {
        if (appSpeaks && waiting != null)
          agentAppSays: waiting.sensitive
              ? orbRestate(waiting)
              : '还没有确认。${orbRestate(waiting)}',
        'error': 'needs_user_confirmation',
        'message': pending?.sensitive ?? false
            ? '这是敏感操作，只认屏幕上确认卡的按钮，说话不算，什么都没做。请他点确认卡；你自己的话不算确认，不要重复调用。'
            : '用户还没有点确认，也没有亲口说确认，什么都没做。问他一句“要发吗？”，等他点屏幕上的确认或说“确认”；你自己的话不算确认，不要重复调用。',
      };
    }
    if (r['status'] == 'needs_second_confirmation') {
      // A sensitive operation: the second card is up, the first press was
      // not the last.
      final again = '${r['confirmToken']}';
      _token = again;
      _watchExpiry(again);
      if (tapped) {
        _announce(
          '用户点了第一次确认。这是敏感操作，屏幕上出了第二张确认卡，请他再点一次确认；说话不算，不要替他确认。',
          '这是敏感操作，请你再点一次屏幕上的确认。',
        );
      }
      return {
        if (appSpeaks) agentAppSays: '这是敏感操作，请你再点一次屏幕上的确认。',
        'status': 'needs_second_confirmation',
        'message': '这是敏感操作：第二张确认卡已经在屏幕上，请用户自己再点一次确认；你不要替他确认',
      };
    }
    _token = null;
    _expiry?.cancel();
    final Map<String, Object?> answer;
    switch (r['status']) {
      case 'done':
        final done = '${(r['result'] as Map?)?['done'] ?? '已完成'}';
        _setOutcome(OrbActionOutcome(OrbOutcomeKind.done, done));
        answer = {
          if (appSpeaks) agentAppSays: orbDoneLine(done),
          'status': 'done',
          'done': done,
          'activity': done,
          'message': '已经做完了。用一句话告诉用户“$done”，不要重复细节。',
          if (r['undo'] != null) 'undo': r['undo'],
        };
        _last = answer;
        if (tapped) {
          onTapped?.call(_outcome!);
          _announce(
            '用户点了确认，已经执行：$summary（$done）。用一句话告诉他做完了。',
            orbDoneLine(done),
          );
        }
      case 'declined':
        _setOutcome(const OrbActionOutcome(OrbOutcomeKind.cancelled, '已取消'));
        answer = {
          if (appSpeaks) agentAppSays: '好，已取消。',
          'status': 'cancelled',
          'message': '用户没有确认，什么都没做',
          'activity': '已取消',
        };
      default:
        final why = '${r['error'] ?? r['message'] ?? '没有成功'}';
        _setOutcome(OrbActionOutcome(OrbOutcomeKind.failed, why));
        answer = {
          if (appSpeaks) agentAppSays: '没成功：$why',
          'status': 'failed',
          'error': why,
          'activity': '没成功：$why',
          'message': '没有成功。如实告诉用户原因，不要说成功了。',
        };
        if (tapped) {
          onTapped?.call(_outcome!);
          _announce('用户点了确认，但没有成功：$why。如实告诉他原因，不要说成功了。', '没成功：$why');
        }
    }
    return answer;
  }

  /// Takes a card away without writing: the capability layer's token is
  /// answered "declined" and spent.
  Future<void> _forget(String token) async {
    _token = null;
    _expiry?.cancel();
    await capabilities.run('confirm', {'token': token});
  }

  /// A new request is coming: the card that waits goes.
  Future<void> _drop() async {
    final token = _token;
    if (token == null) return;
    _token = null;
    ledger.cancel(token, force: true);
    await _forget(token);
  }

  // ---- state ---------------------------------------------------------------------

  void _ledgerChanged() {
    final token = _token;
    if (token != null && pending == null && _running == null) {
      // The card went by itself: the person said no, or it ran out.
      final said = ledger.cancelledCards.any((c) => c.request.token == token);
      if (said) _cancelledByWords = true;
      _token = null;
      _expiry?.cancel();
      _setOutcome(
        OrbActionOutcome(OrbOutcomeKind.cancelled, said ? '已取消' : '太久没确认，已取消'),
      );
    }
    _changed();
  }

  void _watchExpiry(String token) {
    _expiry?.cancel();
    final p = ledger.active.where((e) => e.request.token == token).firstOrNull;
    if (p == null) return;
    var wait = p.request.expires.difference(_now());
    if (wait.isNegative) wait = Duration.zero;
    _expiry = Timer(wait + const Duration(milliseconds: 50), _ledgerChanged);
  }

  void _setOutcome(OrbActionOutcome? next) {
    _outcomeTimer?.cancel();
    _outcome = next;
    if (next == null) return;
    _outcomeTimer = Timer(outcomeLinger, () {
      if (_disposed) return;
      _outcome = null;
      notifyListeners();
    });
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _tell(String note) => onTell?.call('（App 提示，不是用户的话：$note）');

  /// Something the person did on the card: the model is told [note], or, when
  /// the app speaks, [line] is said as it stands.
  void _announce(String note, String line) {
    final say = onSay;
    if (appSpeaks && say != null) {
      say(line);
    } else {
      _tell(note);
    }
  }

  static String? _text(Object? v) {
    final s = v is String ? v.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  @override
  void dispose() {
    _disposed = true;
    _outcomeTimer?.cancel();
    _expiry?.cancel();
    ledger.removeListener(_ledgerChanged);
    ledger.dispose();
    super.dispose();
  }
}
