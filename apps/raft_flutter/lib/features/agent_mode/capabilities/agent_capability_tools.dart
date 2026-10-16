import 'dart:convert';
import 'dart:math';

import '../../../data/workspace_controller.dart';
import '../references/agent_reference_table.dart';
import 'agent_capability.dart';
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
        '申请一项“操作”能力。不会马上执行：先返回“将要发生什么”的预览和 confirmToken，把预览用一句话告诉用户，'
        '等用户明确说确认后，再用 confirm 执行。敏感操作要确认两次。永远不能语音执行的操作只会返回要打开的页面。',
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
    'description': '用户明确确认之后，执行 act 返回的预览。token 填 confirmToken。用户没有明确说“确认/好/做吧”之前不要调用；敏感操作第一次 confirm 只会再要一次确认。',
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

class _Pending {
  _Pending(this.capability, this.args, this.preview, this.expires);
  final AgentCapability capability;
  final Map<String, Object?> args;
  final AgentActionPreview preview;
  final DateTime expires;

  /// Sensitive operations: the first confirmation was given.
  bool confirmedOnce = false;
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
    DateTime Function()? now,
    Random? random,
  }) : registry = registry ?? agentStandardCapabilities,
       _references = references ?? (() => AgentReferenceTable.empty),
       _pointed = pointed ?? (() => null),
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure() {
    index = AgentCapabilityIndex(this.registry.all);
  }

  static const names = {'find', 'query', 'act', 'confirm', 'resolve'};

  /// How long a preview waits for its confirmation.
  static const confirmWindow = Duration(minutes: 2);

  final WorkspaceController workspace;
  final AgentCapabilityRegistry registry;
  final AgentCapabilityEnv env;
  late final AgentCapabilityIndex index;
  final AgentReferenceTable Function() _references;
  final AgentEntityRef? Function() _pointed;
  final DateTime Function() _now;
  final Random _random;

  /// Risks of operations that may be previewed and run in this version.
  /// Phase 1 allows ordinary changes only; a sensitive operation answers
  /// "not available" until the risk is added here.
  final Set<AgentCapabilityRisk> actionRisks;

  /// Asks the person themselves (the confirm card, or their spoken "确认")
  /// before an operation runs. Without it the model's own `confirm` call is
  /// the confirmation, which phase 2 replaces with the card button.
  final Future<bool> Function(AgentActionPreview preview)? userConsent;

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
      case 'resolve':
        return _resolve(args);
    }
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
      final result = await capability.run(workspace, checked, env);
      return {'capability': capability.id, 'result': result};
    } on AgentCapabilityError catch (e) {
      return e.toJson();
    }
  }

  // ---- act / confirm ---------------------------------------------------

  String _token() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    return 'cf_${List.generate(10, (_) => chars[_random.nextInt(chars.length)]).join()}';
  }

  Future<Map<String, Object?>> _act(Map<String, Object?> args) async {
    // What cannot be done by voice needs no arguments to say so.
    final named = registry['${args['capability'] ?? ''}'];
    if (named != null &&
        !named.isQuery &&
        named.risk == AgentCapabilityRisk.neverByVoice) {
      return {
        'status': 'open_page',
        'openPage': named.openRoute,
        'message': '这类操作不能用语音做：请告诉用户，帮他打开对应的页面自己操作',
      };
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
      preview = await capability.preview!(workspace, checked, env);
    } on AgentCapabilityError catch (e) {
      return e.toJson();
    }
    final token = _token();
    _pending[token] = _Pending(
      capability,
      checked,
      preview,
      _now().add(confirmWindow),
    );
    return _needsConfirmation(
      token,
      capability,
      preview,
      1,
      capability.risk == AgentCapabilityRisk.sensitive ? 2 : 1,
    );
  }

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
        '把 preview.summary 用一句话告诉用户并等他明确确认；确认后调用 confirm(token)，没有确认就什么都不要做',
  };

  Future<Map<String, Object?>> _confirm(Map<String, Object?> args) async {
    final token = '${args['token'] ?? ''}'.trim();
    final pending = _pending.remove(token);
    if (pending == null || !_now().isBefore(pending.expires)) {
      return {'error': 'confirmToken 无效或已过期：重新 act 一次'};
    }
    final consent = userConsent;
    if (consent != null && !await consent(pending.preview)) {
      return {'status': 'declined', 'message': '用户没有确认，什么都没有做'};
    }
    if (pending.capability.risk == AgentCapabilityRisk.sensitive &&
        !pending.confirmedOnce) {
      final again = _token();
      _pending[again] = _Pending(
        pending.capability,
        pending.args,
        pending.preview,
        _now().add(confirmWindow),
      )..confirmedOnce = true;
      return {
        ..._needsConfirmation(again, pending.capability, pending.preview, 2, 2),
        'status': 'needs_second_confirmation',
        'warning': '这是敏感操作：请再向用户确认一次，让他再说一遍确认',
      };
    }
    try {
      final result = await pending.capability.run(workspace, pending.args, env);
      executions.add(
        AgentExecution(pending.capability.id, pending.args, _now()),
      );
      return {
        'status': 'done',
        'capability': pending.capability.id,
        'result': result,
      };
    } on AgentCapabilityError catch (e) {
      return e.toJson();
    }
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
