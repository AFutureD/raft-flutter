import 'dart:convert';
import 'dart:math';

import '../../../data/user_error.dart';
import '../../../data/workspace_controller.dart';
import 'agent_action_board.dart';
import 'agent_audit_log.dart';
import 'agent_pages.dart';
import '../../../data/raft_location.dart';
import '../references/agent_reference_table.dart';
import 'agent_capability.dart';
import 'agent_consent.dart';
import 'agent_direct_tools.dart';
import 'agent_capability_args.dart';
import 'agent_capability_search.dart';
import 'agent_capability_standard.dart';

/// The model-facing tools of the capability layer, as FunctionDeclarations.
/// Three general tools stand for every function of the app (so adding a
/// capability changes neither the tools nor the prompt), plus `confirm` for
/// operations and `resolve` for "this one / the second / Cody's task".
const capabilityToolDeclarations = <Map<String, Object?>>[
  {
    'name': 'find',
    'description':
        '按用户的意思找 App 里能做的事：返回最相关的至多 5 项能力（id、一句话说明、查询还是操作、风险、参数说明）。'
        '要读数据或要做什么，而你没有现成的工具时，先 find，再按返回的参数说明 query 或 act。',
    'parameters': {
      'type': 'object',
      'properties': {
        'intent': {
          'type': 'string',
          'description': '用户想做什么，用他的话，如“Cody 的任务到哪了”',
        },
      },
      'required': ['intent'],
    },
  },
  {
    'name': 'query',
    'description':
        '执行一项“查询”能力（只读）。capability 填 find 返回的 id；args 是参数的 JSON 文本，按 find 返回的参数说明写，'
        '不认识的参数会被拒绝。返回结构化结果，里面的 id 原样使用，不要编。超过 8 秒没有结果会失败，如实告诉用户稍后再试。',
    'parameters': {
      'type': 'object',
      'properties': {
        'capability': {'type': 'string', 'description': '能力 id，如 tasks.board'},
        'args': {
          'type': 'string',
          'description': '参数的 JSON 文本，如 {"status":"in_review"}；没有参数可省略',
        },
      },
      'required': ['capability'],
    },
  },
  {
    'name': 'act',
    'description':
        '申请一项“操作”能力（发消息、改任务等常用操作有各自的专用工具，优先用它们；这里是其余操作的通用入口）。不会马上执行：先返回“将要发生什么”的预览和 confirmToken，屏幕上会自动出现带预览的确认卡；'
        '把预览用一句话告诉用户，等他自己点“确认”或亲口说确认，再用 confirm 执行。敏感操作只认点确认卡，要确认两次。永远不能语音执行的操作只会返回要打开的页面。',
    'parameters': {
      'type': 'object',
      'properties': {
        'capability': {'type': 'string', 'description': '能力 id'},
        'args': {'type': 'string', 'description': '参数的 JSON 文本'},
      },
      'required': ['capability'],
    },
  },
  {
    'name': 'confirm',
    'description':
        '用户自己确认之后（点了确认卡的“确认”，或亲口说了确认），执行 act 返回的预览。token 填 confirmToken。'
        '你自己的话不算确认：用户没有表态之前调用只会返回 needs_user_confirmation，什么都不会执行；敏感操作第一次 confirm 只会再要一次确认。',
    'parameters': {
      'type': 'object',
      'properties': {
        'token': {
          'type': 'string',
          'description': 'act 或上一次 confirm 返回的 confirmToken',
        },
      },
      'required': ['token'],
    },
  },
  {
    'name': 'undo',
    'description':
        '撤销刚刚执行完的操作（标已读、改状态、表情、指派等能撤销的）。只在用户亲口说了“撤销/改回去/刚才那个不要了”之后调用；'
        '他点结果卡上的撤销按钮不用你调用。你自己不能决定撤销：用户没有说过，会返回 needs_user_consent，什么都不做。执行后 30 秒内有效。token 省略就是最近一次能撤销的。',
    'parameters': {
      'type': 'object',
      'properties': {
        'token': {
          'type': 'string',
          'description': 'confirm 返回的 confirmToken；省略就是最近一次',
        },
      },
    },
  },
  {
    'name': 'resolve',
    'description':
        '把用户指的东西对应到屏幕上具体的一个：“第二个”“③”“Cody 那个任务”“这条”“这个”。'
        '返回它的类型和 id；对不上或对得上多个时返回 candidates，这时问用户是哪一个，不要猜、不要编 id。',
    'parameters': {
      'type': 'object',
      'properties': {
        'phrase': {'type': 'string', 'description': '用户的原话里指代的那几个字'},
      },
      'required': ['phrase'],
    },
  },
];

/// The kind of thing a result key lists, as `EntityCard.entity` names it.
const _entityOfKey = <String, String>{
  'task': 'task',
  'tasks': 'task',
  'message': 'message',
  'messages': 'message',
  'channel': 'channel',
  'channels': 'channel',
  'member': 'member',
  'members': 'member',
  'humans': 'member',
  'agent': 'agent',
  'agents': 'agent',
  'computer': 'computer',
  'computers': 'computer',
  'file': 'file',
  'files': 'file',
};

/// [result] with `entity` (the kind an `EntityCard` takes) added next to the
/// `id` of every task, message, channel, member, agent, computer and file row,
/// so the model can put a card on screen from what it read without guessing
/// the kind. [found] is whether any row got one.
({Map<String, Object?> result, bool found}) annotateEntities(
  Map<String, Object?> result,
) {
  var found = false;
  Map<String, Object?> tag(Map<String, Object?> row, String kind) {
    if (row['id'] is! String || row.containsKey('entity')) return row;
    found = true;
    return {'entity': kind, ...row};
  }

  Object? walk(Object? value, String? kind) {
    if (value is Map) {
      final map = {
        for (final e in value.entries)
          '${e.key}': walk(e.value, _entityOfKey['${e.key}']),
      };
      return kind == null ? map : tag(map, kind);
    }
    if (value is List) return [for (final v in value) walk(v, kind)];
    return value;
  }

  return (result: walk(result, null) as Map<String, Object?>, found: found);
}

class _Pending {
  _Pending(this.capability, this.args, this.preview, this.expires);
  final AgentCapability capability;
  final Map<String, Object?> args;
  final AgentActionPreview preview;
  final DateTime expires;

  /// Sensitive operations: the first confirmation was given.
  bool confirmedOnce = false;
}

class _Ran {
  _Ran(this.capability, this.args, this.preview);
  final AgentCapability capability;
  final Map<String, Object?> args;
  final AgentActionPreview preview;
  AgentUndoPlan? plan;
  DateTime? until;
  bool undone = false;
}

/// One run of an operation, for the record of what was done by voice.
class AgentExecution {
  const AgentExecution(this.capability, this.args, this.at);
  final String capability;
  final Map<String, Object?> args;
  final DateTime at;
}

/// Runs `find`, `query`, `act`, `confirm` and `resolve`.
///
/// Every tool answers with a map and never throws for a bad call: a wrong
/// capability id, wrong arguments or a failed read come back as `error`
/// (with the schema or candidates to correct it). The 8 s limit on a call is
/// the [AgentToolResponder]'s, which wraps this whole handler.
class AgentCapabilityTools {
  AgentCapabilityTools({
    required this.workspace,
    AgentCapabilityRegistry? registry,
    this.env = const AgentCapabilityEnv(),
    AgentReferenceTable Function()? references,
    AgentEntityRef? Function()? pointed,
    this.actionRisks = const {AgentCapabilityRisk.change},
    this.userConsent,
    AgentAuditLog? audit,
    this.board,
    this.onPageOpened,
    DateTime Function()? now,
    Random? random,
  }) : registry = registry ?? agentStandardCapabilities,
       audit = audit ?? AgentAuditLog(),
       _references = references ?? (() => AgentReferenceTable.empty),
       _pointed = pointed ?? (() => null),
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure() {
    index = AgentCapabilityIndex(this.registry.all);
  }

  static const names = {'find', 'query', 'act', 'confirm', 'undo', 'resolve'};

  /// Every tool this handler answers: the generic ones and the one-step
  /// action tools (`send_message` ...), which are `act` on one capability.
  static Set<String> get allNames => {...names, ...agentDirectActionTools.keys};

  /// How long an operation can be taken back after it ran.
  static const undoWindow = Duration(seconds: 30);

  /// How long a preview waits for its confirmation.
  static const confirmWindow = Duration(minutes: 2);

  final WorkspaceController workspace;
  final AgentCapabilityRegistry registry;
  final AgentCapabilityEnv env;

  /// What ran, for `agent.audit_log` and the timeline.
  final AgentAuditLog audit;

  /// The confirm cards turn into their result here.
  final AgentActionBoard? board;

  /// A never-by-voice operation took the person to a page of the app: the
  /// workspace now shows [location]. The runtime lets agent mode step aside.
  final void Function(RaftLocation location)? onPageOpened;
  late final AgentCapabilityEnv _env = env.withAudit(audit);
  late final AgentCapabilityIndex index;
  final AgentReferenceTable Function() _references;
  final AgentEntityRef? Function() _pointed;
  final DateTime Function() _now;
  final Random _random;

  /// Risks of operations that may be previewed and run in this version.
  /// Phase 1 allows ordinary changes only; a sensitive operation answers
  /// "not available" until the risk is added here.
  final Set<AgentCapabilityRisk> actionRisks;

  /// Whether the person agreed (the confirm card the app draws for each
  /// preview, or their own words after it). Without one nothing can be
  /// confirmed: the model's own `confirm` call is never the confirmation.
  final AgentUserConsent? userConsent;

  final _pending = <String, _Pending>{};

  /// What ran, oldest first.
  final executions = <AgentExecution>[];

  Future<Map<String, Object?>?> run(
    String name,
    Map<String, Object?> args,
  ) async {
    switch (name) {
      case 'find':
        return _find(args);
      case 'query':
        return _query(args);
      case 'act':
        return _act(args);
      case 'confirm':
        return _confirm(args);
      case 'undo':
        return _undoByModel('${args['token'] ?? ''}'.trim());
      case 'resolve':
        return _resolve(args);
    }
    final direct = agentDirectActionTools[name];
    if (direct != null) return _act({'capability': direct, 'args': args});
    return null;
  }

  // ---- find ----------------------------------------------------------

  Map<String, Object?> _find(Map<String, Object?> args) {
    final intent = '${args['intent'] ?? ''}'.trim();
    if (intent.isEmpty) return {'error': '需要 intent：用户想做什么'};
    final hits = index.find(intent);
    return {
      'matches': [for (final c in hits) c.describe()],
      if (hits.isEmpty) 'hint': '没有对得上的能力：换个说法再 find，或如实告诉用户这个现在做不到',
    };
  }

  // ---- query ---------------------------------------------------------

  Object? _argsOf(Object? raw) {
    if (raw is! String) return raw;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final fenced = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$')
        .firstMatch(text);
    return jsonDecode(fenced == null ? text : fenced[1]!);
  }

  /// The capability named in [args] with its arguments checked, or the
  /// answer to give instead.
  ({
    AgentCapability? capability,
    Map<String, Object?> args,
    Map<String, Object?>? error,
  })
  _prepare(Map<String, Object?> args) {
    ({
      AgentCapability? capability,
      Map<String, Object?> args,
      Map<String, Object?>? error,
    })
    fail(Map<String, Object?> answer) =>
        (capability: null, args: const {}, error: answer);
    final id = '${args['capability'] ?? ''}'.trim();
    final capability = registry[id];
    if (capability == null) {
      return fail({
        'error': id.isEmpty ? '需要 capability（能力 id）' : '没有叫 $id 的能力：先 find',
        if (id.isNotEmpty)
          'suggestions': [for (final c in index.find(id, limit: 3)) c.id],
      });
    }
    final Object? given;
    try {
      given = _argsOf(args['args']);
    } on FormatException {
      return fail({
        'error': 'args 不是合法的 JSON 文本',
        'params': capability.paramsSchema,
      });
    }
    final checked = checkAgentArgs(capability.paramsSchema, given);
    if (!checked.ok) {
      return fail({
        'error': '参数不对：${checked.problems.join('；')}',
        'problems': checked.problems,
        'params': capability.paramsSchema,
      });
    }
    return (capability: capability, args: checked.args, error: null);
  }

  Future<Map<String, Object?>> _query(Map<String, Object?> args) async {
    final prepared = _prepare(args);
    final capability = prepared.capability;
    if (capability == null) return prepared.error!;
    final checked = prepared.args;
    if (!capability.isQuery) {
      return {'error': '${capability.id} 是操作不是查询：用 act，用户确认后再 confirm'};
    }
    try {
      final result = await capability.run(workspace, checked, _env);
      final cards = annotateEntities(result);
      return {
        'capability': capability.id,
        'result': cards.result,
        if (cards.found) 'render': '要在屏幕上展示其中某一项：用 EntityCard 组件 {entity, id}，entity 和 id 原样取自结果，不要编',
      };
    } on AgentCapabilityError catch (e) {
      return e.toJson();
    }
  }

  // ---- never by voice: take the person to the page ----------------------

  Future<Map<String, Object?>> _openPage(
    AgentCapability c,
    Map<String, Object?> args,
  ) async {
    var route = c.openRoute!;
    String? note;
    final dynamicRoute = c.openRouteFor;
    if (dynamicRoute != null) {
      // The arguments only narrow the page; a bad one still gets the list.
      final prepared = _prepare(args);
      try {
        if (prepared.capability != null) {
          route = await dynamicRoute(workspace, prepared.args);
        }
      } on AgentCapabilityError catch (e) {
        // ignore: raft_lints/avoid_caught_exception_text -- AgentCapabilityError is this layer's own error; its text is written for the person and the model.
        note = '${e.message}；先带用户去列表页，让他自己找';
      }
    }
    final result = openAgentPage(workspace, route);
    audit.add(
      AgentAuditEntry(
        at: _now(),
        capability: c.id,
        summary: '带用户去页面：${c.title}',
        args: _argsText(const {}),
        result: result.opened ? '已打开 $route' : '没有打开：${result.problem}',
        ok: result.opened,
      ),
    );
    if (result.opened) onPageOpened?.call(result.location!);
    return {
      'status': 'open_page',
      'capability': c.id,
      'openPage': route,
      'opened': result.opened,
      'note': ?note,
      'error': ?(result.opened ? null : result.problem),
      'message': result.opened
          ? '这类操作不能用语音做，App 已经把页面打开了（${c.title}）。用一句话告诉用户：已带他去对应页面，请他在页面里自己操作；Agent 模式随后会收起'
          : '这类操作不能用语音做，页面也没能打开：${result.problem}。如实告诉用户，让他自己去 App 里找',
    };
  }

  // ---- act / confirm ---------------------------------------------------

  String _token() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    return 'cf_${List.generate(10, (_) => chars[_random.nextInt(chars.length)]).join()}';
  }

  Future<Map<String, Object?>> _act(Map<String, Object?> args) async {
    // What cannot be done by voice needs no confirmation: the app takes the
    // person to the page where they do it themselves.
    final named = registry['${args['capability'] ?? ''}'];
    if (named != null &&
        !named.isQuery &&
        named.risk == AgentCapabilityRisk.neverByVoice) {
      return _openPage(named, args);
    }
    final prepared = _prepare(args);
    final capability = prepared.capability;
    if (capability == null) return prepared.error!;
    final checked = prepared.args;
    if (capability.isQuery) {
      return {'error': '${capability.id} 是查询不是操作：用 query'};
    }
    if (!actionRisks.contains(capability.risk)) {
      return {
        'status': 'not_available',
        'error': '${capability.title} 这个版本还不能用语音做',
        'message': '如实告诉用户现在做不到，并说能查看什么',
      };
    }
    final AgentActionPreview preview;
    try {
      preview = await capability.preview!(workspace, checked, _env);
    } on AgentCapabilityError catch (e) {
      return e.toJson();
    }
    final token = _token();
    final total = capability.risk == AgentCapabilityRisk.sensitive ? 2 : 1;
    final pending = _Pending(
      capability,
      checked,
      preview,
      _now().add(confirmWindow),
    );
    _pending[token] = pending;
    _show(token, pending, 1, total);
    return _needsConfirmation(token, capability, preview, 1, total);
  }

  /// The preview goes in front of the person (the app draws its confirm
  /// card); from here on their answer can count for [token].
  void _show(String token, _Pending p, int step, int total) =>
      userConsent?.previewShown(
        AgentConsentRequest(
          token: token,
          capabilityId: p.capability.id,
          preview: p.preview,
          risk: p.capability.risk,
          expires: p.expires,
          step: step,
          total: total,
        ),
      );

  Map<String, Object?> _needsConfirmation(
    String token,
    AgentCapability capability,
    AgentActionPreview preview,
    int step,
    int total,
  ) => {
    'status': 'needs_confirmation',
    'preview': preview.toJson(),
    'confirmToken': token,
    'risk': capability.risk.name,
    'confirmation': '$step/$total',
    'next':
        '屏幕上已经出现确认卡。把 preview.summary 用一句话告诉用户，等他点“确认”或亲口说确认；'
        '他表态之后调用 confirm(token)，没有表态就什么都不要做',
  };

  Future<Map<String, Object?>> _confirm(Map<String, Object?> args) async {
    final token = '${args['token'] ?? ''}'.trim();
    final pending = _pending[token];
    if (pending == null || !_now().isBefore(pending.expires)) {
      _pending.remove(token);
      return {'error': 'confirmToken 无效或已过期：重新 act 一次'};
    }
    switch (userConsent?.take(token) ?? AgentConsentVerdict.pending) {
      case AgentConsentVerdict.pending:
        // The token stays: the person may still agree.
        return {
          'error': 'needs_user_confirmation',
          'message':
              '用户还没有确认，什么都没有做。请他点屏幕上确认卡的“确认”或亲口说确认；'
              '你自己说的话不算确认，不要重复调用',
          if (pending.capability.risk == AgentCapabilityRisk.sensitive)
            'hint': '敏感操作只认确认卡上的按钮',
        };
      case AgentConsentVerdict.declined:
        _pending.remove(token);
        return {'status': 'declined', 'message': '用户没有确认，什么都没有做'};
      case AgentConsentVerdict.granted:
        _pending.remove(token);
    }
    if (pending.capability.risk == AgentCapabilityRisk.sensitive &&
        !pending.confirmedOnce) {
      final again = _token();
      final second = _Pending(
        pending.capability,
        pending.args,
        pending.preview,
        _now().add(confirmWindow),
      )..confirmedOnce = true;
      _pending[again] = second;
      _show(again, second, 2, 2);
      return {
        ..._needsConfirmation(again, pending.capability, pending.preview, 2, 2),
        'status': 'needs_second_confirmation',
        'warning': '这是敏感操作：请再向用户确认一次，让他再说一遍确认',
      };
    }
    return _execute(token, pending.capability, pending.args, pending.preview);
  }

  // ---- running, retrying and taking back -------------------------------

  final _ran = <String, _Ran>{};

  Future<Map<String, Object?>> _execute(
    String id,
    AgentCapability c,
    Map<String, Object?> args,
    AgentActionPreview preview,
  ) async {
    _ran[id] = _Ran(c, args, preview);
    while (_ran.length > 12) {
      _ran.remove(_ran.keys.first);
    }
    board?.running(id, c.id, preview);
    AgentUndoPlan? plan;
    try {
      plan = await c.prepareUndo?.call(workspace, args, _env);
    } on Object {
      plan = null;
    }
    try {
      final result = await c.run(workspace, args, _env);
      final at = _now();
      executions.add(AgentExecution(c.id, args, at));
      final text = '${result['done'] ?? '已完成'}';
      final entity = _entityOf(result);
      audit.add(
        AgentAuditEntry(
          at: at,
          capability: c.id,
          summary: preview.summary,
          args: _argsText(args),
          result: text,
          ok: true,
          entity: entity?.entity,
          entityId: entity?.id,
        ),
      );
      final until = at.add(undoWindow);
      final ran = _ran[id]!..plan = plan;
      ran.until = plan == null ? null : until;
      board?.done(
        id,
        text: text,
        entity: entity,
        undoLabel: plan?.label,
        undoUntil: plan == null ? null : until,
      );
      return {
        'status': 'done',
        'capability': c.id,
        'result': result,
        'card': '确认卡已在屏幕上变成结果：“$text”。用一句话告诉用户做完了，不要重复念细节',
        if (plan != null)
          'undo': {
            'label': plan.label,
            'seconds': undoWindow.inSeconds,
            'how': '用户亲口说了撤销之后才调用 undo（30 秒内有效）；卡上也有撤销按钮，他点了就不用你调用',
          },
      };
    } on Object catch (e) {
      final message = e is AgentCapabilityError
          // ignore: raft_lints/avoid_caught_exception_text -- AgentCapabilityError is this layer's own error; its text is written for the person and the model.
          ? e.message
          : userErrorText(e, fallback: '没有成功（服务器没有接受，或网络出错）', where: c.id);
      audit.add(
        AgentAuditEntry(
          at: _now(),
          capability: c.id,
          summary: preview.summary,
          args: _argsText(args),
          result: '失败：$message',
          ok: false,
        ),
      );
      board?.failed(id, message);
      return {
        if (e is AgentCapabilityError) ...e.toJson() else 'error': message,
        'status': 'failed',
        'message': '没有成功，屏幕上的卡片上有“重试”。如实告诉用户原因，不要说成功了',
      };
    }
  }

  /// The person pressed 重试 on a failed card: that press is their consent.
  Future<Map<String, Object?>> retryAction(String id) async {
    final ran = _ran[id];
    if (ran == null) return {'error': '这次操作已经过期，请重新说一遍'};
    return _execute(id, ran.capability, ran.args, ran.preview);
  }

  /// The `undo` tool: the model asks to take something back. That is the
  /// person's decision, never the model's: it runs only when they just said
  /// so in their own words ("撤销", "改回去"). The card's 撤销 button does not
  /// come here (see [undoAction]).
  Future<Map<String, Object?>> _undoByModel(String id) async {
    if (_undoKey(id) == null) return {'error': '没有能撤销的操作'};
    if (!(userConsent?.takeUndo() ?? false)) {
      return {
        'error': 'needs_user_consent',
        'message':
            '撤销要用户自己决定：他点结果卡上的“撤销”，或亲口说“撤销/改回去”之后才能撤销。'
            '你不能自己撤销，什么都没有做；告诉他可以点卡上的撤销，或说一声“撤销”',
      };
    }
    return undoAction(id);
  }

  String? _undoKey(String id) {
    final now = _now();
    final key = id.isEmpty ? null : id;
    return key ??
        _ran.entries
            .where(
              (e) =>
                  e.value.plan != null &&
                  !e.value.undone &&
                  (e.value.until?.isAfter(now) ?? false),
            )
            .map((e) => e.key)
            .lastOrNull;
  }

  /// Takes back the operation [id] (the latest one that can be, when empty).
  /// This is what the person's own press on the card's 撤销 button runs, so
  /// it needs no further consent; the `undo` tool goes through
  /// [_undoByModel], which asks for it. Within [undoWindow] it only restores
  /// what the person had agreed to change.
  Future<Map<String, Object?>> undoAction(String id) async {
    final now = _now();
    final String? key = _undoKey(id);
    final ran = key == null ? null : _ran[key];
    final plan = ran?.plan;
    if (ran == null || plan == null || ran.undone) {
      return {'error': '没有能撤销的操作'};
    }
    if (ran.until == null || !now.isBefore(ran.until!)) {
      return {'error': '撤销的 30 秒已经过了，这个只能再做一次相反的操作（走 act，要用户确认）'};
    }
    board?.busy(key!);
    try {
      final text = await plan.run();
      ran.undone = true;
      audit.add(
        AgentAuditEntry(
          at: _now(),
          capability: ran.capability.id,
          summary: '撤销：${ran.preview.summary}',
          args: _argsText(ran.args),
          result: text,
          ok: true,
          undo: true,
        ),
      );
      board?.undone(key!, text);
      return {'status': 'undone', 'message': text};
    } on Object catch (e) {
      final message = e is AgentCapabilityError
          // ignore: raft_lints/avoid_caught_exception_text -- AgentCapabilityError is this layer's own error; its text is written for the person and the model.
          ? e.message
          : userErrorText(e, fallback: '没有成功（服务器没有接受，或网络出错）', where: 'undo');
      audit.add(
        AgentAuditEntry(
          at: _now(),
          capability: ran.capability.id,
          summary: '撤销：${ran.preview.summary}',
          args: _argsText(ran.args),
          result: '撤销失败：$message',
          ok: false,
          undo: true,
        ),
      );
      final r = board?[key!];
      board?.done(
        key!,
        text: '${r?.text ?? '已完成'} · 撤销没成功：$message',
        entity: r?.entity,
        undoLabel: plan.label,
        undoUntil: ran.until,
      );
      return {'error': '撤销没成功：$message'};
    }
  }

  static AgentPreviewRef? _entityOf(Map<String, Object?> result) {
    final e = result['entity'], id = result['id'];
    return e is String && id is String && id.isNotEmpty
        ? AgentPreviewRef(e, id)
        : null;
  }

  static String _argsText(Map<String, Object?> args) {
    final text = [
      for (final e in args.entries)
        if (e.value != null) '${e.key}=${e.value}',
    ].join(' ');
    return text.length <= 120 ? text : '${text.substring(0, 120)}…';
  }

  // ---- resolve ---------------------------------------------------------

  Map<String, Object?> _resolve(Map<String, Object?> args) {
    final phrase = '${args['phrase'] ?? ''}'.trim();
    if (phrase.isEmpty) return {'error': '需要 phrase：用户指的是什么'};
    return resolveAgentReference(
      phrase,
      _references(),
      pointed: _pointed(),
    ).toJson();
  }
}
