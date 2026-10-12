// Web utils/classifyRuntimeError.ts: runtime errors are recognised only by
// enumerable, stable patterns and mapped to catalog copy; anything else stays
// unclassified so the caller falls back to the generic message (arbitrary
// server English is never "translated" by substring).

enum RuntimeErrorKind { notLoggedIn, notInstalled, authFailed, toolArgsInvalid }

final _patterns = <(RuntimeErrorKind, RegExp)>[
  (
    RuntimeErrorKind.notLoggedIn,
    RegExp('is not logged in', caseSensitive: false),
  ),
  (
    RuntimeErrorKind.notInstalled,
    RegExp('not installed', caseSensitive: false),
  ),
  (
    RuntimeErrorKind.authFailed,
    RegExp(
      r'(?:auth(?:entication|orization)? (?:failed|error|invalid)|invalid api key|unauthorized)',
      caseSensitive: false,
    ),
  ),
];

/// `classifyRuntimeError(message)`. `toolArgsInvalid` is reachable only from the
/// typed carrier ([classifyTypedRuntimeError]), never from message text.
RuntimeErrorKind? classifyRuntimeError(String message) {
  for (final (kind, re) in _patterns) {
    if (re.hasMatch(message)) return kind;
  }
  return null;
}

/// The authoritative typed diagnostic (`lastRuntimeError.errorClass` /
/// `errorReason`) the daemon and server persisted.
RuntimeErrorKind? classifyTypedRuntimeError(Object? lastRuntimeError) {
  if (lastRuntimeError is! Map) return null;
  final errorClass = lastRuntimeError['errorClass'];
  final reason = lastRuntimeError['errorReason'];
  if (errorClass is! String ||
      errorClass.isEmpty ||
      reason is! String ||
      reason.isEmpty) {
    return null;
  }
  if (reason == 'auth_failed' || errorClass == 'AuthError') {
    return RuntimeErrorKind.authFailed;
  }
  if (reason == 'model_tool_args_invalid' ||
      errorClass == 'ToolArgumentParseError') {
    return RuntimeErrorKind.toolArgsInvalid;
  }
  return null;
}

/// `RUNTIME_ERROR_LABEL_ID`: the English catalog string per kind
/// (`agent.runtimeError.*`).
String runtimeErrorText(RuntimeErrorKind kind) => switch (kind) {
  RuntimeErrorKind.notLoggedIn =>
    'This runtime is not logged in on this computer.',
  RuntimeErrorKind.notInstalled =>
    'This runtime is not installed on this computer.',
  RuntimeErrorKind.authFailed => 'Runtime authentication failed.',
  RuntimeErrorKind.toolArgsInvalid =>
    'The model produced tool-call arguments in an invalid format, so Codex rejected the tool call — try a different model.',
};
