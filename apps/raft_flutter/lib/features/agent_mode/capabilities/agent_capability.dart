import '../../../data/workspace_controller.dart';
import '../agent_mode_data.dart';
import '../agent_surface_tools.dart' show AgentFacts;
import 'agent_audit_log.dart';
import 'agent_snooze.dart';

/// Whether a capability reads or changes something.
enum AgentCapabilityKind { query, action }

/// How careful the app must be before running a capability.
///
/// - [read]: only reads; runs at once.
/// - [change]: an ordinary change; previewed, then run on one confirmation.
/// - [sensitive]: previewed and confirmed twice.
/// - [neverByVoice]: never run by the model or by voice; the person is only
///   taken to the page where they do it themselves (delete a server, billing,
///   rotating keys ...).
enum AgentCapabilityRisk { read, change, sensitive, neverByVoice }

/// What a capability may use besides the workspace: the data reader the
/// agent-mode page was built with (so tests can stand in for it) and the
/// facts a generated screen is checked against, which every read teaches.
class AgentCapabilityEnv {
  const AgentCapabilityEnv({
    this.data,
    this.facts,
    this.onAgents,
    this.audit,
    this.snooze,
    this.onServerSwitched,
  });

  final AgentModeData? data;

  /// Where "稍后" is kept; null is the app's own (see [snoozeFor]).
  final AgentSnoozeStore? snooze;

  /// The app's server changed under the agent (`servers.switch`): whatever
  /// was read for the old one is stale.
  final void Function()? onServerSwitched;
  final AgentFacts? facts;

  /// What the agent did in this session, for `agent.audit_log`. The tools
  /// that run operations fill it (see [AgentCapabilityTools]).
  final AgentAuditLog? audit;

  AgentCapabilityEnv withAudit(AgentAuditLog log) => AgentCapabilityEnv(
    data: data,
    facts: facts,
    onAgents: onAgents,
    audit: log,
    snooze: snooze,
    onServerSwitched: onServerSwitched,
  );

  AgentSnoozeStore snoozeFor(WorkspaceController w) =>
      snooze ?? AgentSnoozeStore.of(w);

  /// Told the typed agent reading a query answered from, and whether it was
  /// the app's cached one (a caller that patches screens from a later fresh
  /// read needs the typed rows, not the JSON).
  final void Function(List<AgentRuntimeInfo> agents, {required bool cached})?
  onAgents;

  AgentModeData dataFor(WorkspaceController w) => data ?? AgentModeData(w);
}

/// A thing an action is about, as an entity card names it (`task`, an id
/// the app read). The confirm card draws it from the app's own data.
class AgentPreviewRef {
  const AgentPreviewRef(this.entity, this.id);
  final String entity, id;

  Map<String, Object?> toJson() => {'entity': entity, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is AgentPreviewRef && other.entity == entity && other.id == id;

  @override
  int get hashCode => Object.hash(entity, id);
}

/// What an action will change, shown to the person before anything runs.
class AgentActionPreview {
  const AgentActionPreview({
    required this.summary,
    this.changes = const [],
    this.reversible = false,
    this.refs = const [],
  });

  /// One sentence: what will happen.
  final String summary;

  /// The concrete changes, one line each, `字段: 原值 → 新值`.
  final List<String> changes;
  final bool reversible;

  /// The things it is about (the task, the message, the channel), drawn as
  /// cards under the changes.
  final List<AgentPreviewRef> refs;

  Map<String, Object?> toJson() => {
    'summary': summary,
    if (changes.isNotEmpty) 'changes': changes,
    'reversible': reversible,
    if (refs.isNotEmpty) 'refs': [for (final r in refs) r.toJson()],
  };
}

/// How to take back an operation that just ran: captured before it runs
/// (the previous status, the previous assignee) and good for
/// [AgentCapabilityTools.undoWindow] afterwards.
class AgentUndoPlan {
  const AgentUndoPlan({required this.label, required this.run});

  /// What undoing does, for the button: "改回 待办".
  final String label;

  /// Does it and answers with what the person reads ("已改回 待办").
  final Future<String> Function() run;
}

typedef AgentCapabilityUndo = Future<AgentUndoPlan?> Function(
  WorkspaceController w,
  Map<String, Object?> args,
  AgentCapabilityEnv env,
);

typedef AgentCapabilityRun = Future<Map<String, Object?>> Function(
  WorkspaceController w,
  Map<String, Object?> args,
  AgentCapabilityEnv env,
);

typedef AgentCapabilityPreview = Future<AgentActionPreview> Function(
  WorkspaceController w,
  Map<String, Object?> args,
  AgentCapabilityEnv env,
);

/// [AgentCapabilityRisk.neverByVoice]: the page that does it for the thing
/// the person named (`/channel/<id>?channelPage=settings:<id>`), when the
/// arguments say which. Throws [AgentCapabilityError] when the thing cannot
/// be found; the caller then falls back to [AgentCapability.openRoute].
typedef AgentCapabilityRoute = Future<String> Function(
  WorkspaceController w,
  Map<String, Object?> args,
);

/// One thing the app can do, described so a model can find and call it.
///
/// A capability runs on the app's own data layer (the workspace controller,
/// the entity directory, the same task and message endpoints the pages use),
/// so what the agent does and what the other screens show cannot drift apart.
class AgentCapability {
  const AgentCapability({
    required this.id,
    required this.title,
    required this.kind,
    required this.risk,
    required this.paramsSchema,
    required this.resultSummary,
    required this.keywords,
    required this.run,
    this.parity,
    this.preview,
    this.openRoute,
    this.openRouteFor,
    this.prepareUndo,
  });

  /// `domain.verb`, lower case: `tasks.board`.
  final String id;

  /// One line in Chinese for the model: what it does.
  final String title;
  final AgentCapabilityKind kind;
  final AgentCapabilityRisk risk;

  /// JSON Schema (type object) of the arguments.
  final Map<String, Object?> paramsSchema;

  /// What the result holds, in one line, so the model knows what it gets.
  final String resultSummary;

  /// Words people say for this, for `find` (synonyms, other wordings).
  final List<String> keywords;

  /// The entry of `docs/capability-parity.json` this capability is built on
  /// (`GET /tasks/server`), for traceability. Null when it only combines
  /// several of them.
  final String? parity;

  final AgentCapabilityRun run;

  /// Actions: what the change will be, computed without changing anything.
  final AgentCapabilityPreview? preview;

  /// [AgentCapabilityRisk.neverByVoice]: the page that does it, as a
  /// workspace route without the server (`/settings/billing`, `/computers`):
  /// the app puts `/s/<slug>` in front. See `agent_pages.dart`.
  final String? openRoute;

  /// [AgentCapabilityRisk.neverByVoice]: a closer page for the arguments
  /// given (this channel's settings, that computer), else [openRoute].
  final AgentCapabilityRoute? openRouteFor;

  /// Actions that can be taken back: called right before [run] to capture
  /// what is needed (null when this call cannot be reversed).
  final AgentCapabilityUndo? prepareUndo;

  bool get isQuery => kind == AgentCapabilityKind.query;

  /// What `find` shows the model.
  Map<String, Object?> describe() => {
    'id': id,
    'title': title,
    'kind': kind.name,
    'risk': risk.name,
    'params': paramsSchema,
    'result': resultSummary,
  };
}

/// The capabilities, by id. The structure is checked on construction, so a
/// malformed entry fails in the first test run rather than in a model turn.
class AgentCapabilityRegistry {
  AgentCapabilityRegistry(Iterable<AgentCapability> capabilities)
    : all = List.unmodifiable(capabilities) {
    for (final c in all) {
      final problems = integrityProblems(c);
      if (problems.isNotEmpty) {
        throw ArgumentError('capability ${c.id}: ${problems.join('; ')}');
      }
      if (_byId.containsKey(c.id)) {
        throw ArgumentError('duplicate capability id ${c.id}');
      }
      _byId[c.id] = c;
    }
  }

  final List<AgentCapability> all;
  final _byId = <String, AgentCapability>{};

  static final idPattern = RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$');

  AgentCapability? operator [](String id) => _byId[id.trim()];

  Iterable<AgentCapability> get queries => all.where((c) => c.isQuery);

  /// Why [c] is not well formed; empty when it is.
  static List<String> integrityProblems(AgentCapability c) {
    final problems = <String>[];
    if (!idPattern.hasMatch(c.id)) problems.add('id 必须是 domain.verb');
    if (c.title.trim().isEmpty || c.title.contains('\n')) {
      problems.add('title 必须是一行非空文字');
    }
    if (c.resultSummary.trim().isEmpty) problems.add('缺 resultSummary');
    if (c.keywords.isEmpty) problems.add('缺 keywords');
    if (c.paramsSchema['type'] != 'object' ||
        c.paramsSchema['properties'] is! Map) {
      problems.add('paramsSchema 必须是 type object 并带 properties');
    }
    final required = c.paramsSchema['required'];
    if (required is List) {
      final props = (c.paramsSchema['properties'] as Map?) ?? const {};
      for (final r in required) {
        if (!props.containsKey(r)) problems.add('required 里的 $r 不在 properties');
      }
    }
    switch (c.kind) {
      case AgentCapabilityKind.query:
        if (c.risk != AgentCapabilityRisk.read) {
          problems.add('查询的 risk 只能是 read');
        }
        if (c.preview != null) problems.add('查询不需要 preview');
        if (c.prepareUndo != null) problems.add('查询不需要撤销');
      case AgentCapabilityKind.action:
        if (c.risk == AgentCapabilityRisk.read) {
          problems.add('操作的 risk 不能是 read');
        }
        if (c.risk == AgentCapabilityRisk.neverByVoice &&
            c.prepareUndo != null) {
          problems.add('不能语音执行的操作没有撤销');
        }
        if (c.risk == AgentCapabilityRisk.neverByVoice) {
          if (c.openRoute == null || !c.openRoute!.startsWith('/')) {
            problems.add('neverByVoice 需要 openRoute（以 / 开头）');
          }
        } else if (c.preview == null) {
          problems.add('操作必须有 preview');
        }
    }
    return problems;
  }
}

/// A call that cannot be answered as asked (nothing found, ambiguous): the
/// model gets [message] and [candidates] to ask the person, not a stack
/// trace.
class AgentCapabilityError implements Exception {
  const AgentCapabilityError(this.message, {this.candidates, this.extra});
  final String message;
  final List<Map<String, Object?>>? candidates;

  /// More fields of the answer (kept for tools that always answered so).
  final Map<String, Object?>? extra;

  Map<String, Object?> toJson() => {
    'error': message,
    if (candidates != null) 'candidates': candidates,
    ...?extra,
  };

  @override
  String toString() => message;
}
