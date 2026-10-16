/// What the agent did for the person in this session, newest last: the
/// operations it ran (and the failures and the undos), kept in memory only.
///
/// Fed by [AgentCapabilityTools] when an operation ends; read by the
/// `agent.audit_log` capability, which is how "刚才做了什么" is answered.
class AgentAuditEntry {
  const AgentAuditEntry({
    required this.at,
    required this.capability,
    required this.summary,
    required this.args,
    required this.result,
    required this.ok,
    this.entity,
    this.entityId,
    this.undo = false,
  });

  final DateTime at;

  /// `tasks.set_status`.
  final String capability;

  /// What was done, in one sentence (the preview's summary).
  final String summary;

  /// The arguments, short.
  final String args;

  /// "已改为 进行中", or why it failed.
  final String result;
  final bool ok;

  /// The thing it made or changed, when there is one.
  final String? entity, entityId;

  /// This entry is the taking back of an earlier operation.
  final bool undo;
}

class AgentAuditLog {
  AgentAuditLog({this.limit = 100});

  /// The oldest entries give way past this many.
  final int limit;

  final _entries = <AgentAuditEntry>[];

  /// Oldest first.
  List<AgentAuditEntry> get entries => List.unmodifiable(_entries);

  void add(AgentAuditEntry entry) {
    _entries.add(entry);
    if (_entries.length > limit) _entries.removeAt(0);
  }

  void clear() => _entries.clear();
}
