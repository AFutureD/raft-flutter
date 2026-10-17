import 'dart:async';
import 'dart:convert';

import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentSpeaker;

import 'agent_text_model.dart';

/// One tool the voice session ran and what came of it, kept so the summary
/// of the session reports actions as they happened, not as they were said.
class AgentToolOutcome {
  const AgentToolOutcome({
    required this.name,
    required this.args,
    required this.result,
  });

  final String name;
  final Map<String, Object?> args;
  final Map<String, Object?> result;

  /// Tools that only draw or point on the screen; they are not actions.
  static const _screenOnly = {
    'spotlight',
    'release_spotlight',
    'mark',
    'set_mood',
    'begin_surface',
    'add_component',
    'update_component',
    'end_surface',
    'show_surface',
  };

  bool get isAction => !_screenOnly.contains(name);

  /// "name(arg=value, ...) -> what came of it", short.
  String get line {
    final shown = [
      for (final e in args.entries.take(4))
        '${e.key}=${_clip('${e.value}', 30)}',
    ];
    return '$name(${shown.join(', ')}) -> $status';
  }

  /// What came of the call, from the fields tool results use.
  String get status {
    final error = result['error'];
    if (error != null) return 'failed: ${_clip('$error', 60)}';
    if (result['cancelled'] == true) return 'cancelled';
    if (result['ok'] == false) return 'failed';
    if (result['opened'] == true) return 'opened a page for the person';
    final state = result['status'];
    if (state is String && state.isNotEmpty) return _clip(state, 40);
    if (result['preview'] != null) {
      return 'preview shown, waiting for the person: '
          '${_clip('${result['preview']}', 60)}';
    }
    final message = result['message'];
    if (message is String && message.isNotEmpty) return _clip(message, 60);
    return result['ok'] == true ? 'ok' : 'returned a result';
  }
}

/// What the voice controller gives when a session ends: the lines of the
/// conversation and the tools that ran in it.
typedef AgentSessionEnd = void Function(
  List<(AgentSpeaker, String)> transcript,
  List<AgentToolOutcome> outcomes,
);

/// Makes the message sent to the agent after a voice session: a summary,
/// never the transcript itself.
class AgentSessionSummary {
  AgentSessionSummary._();

  static const header = '【语音对话摘要 · 来自 Agent 模式】';

  /// The same summary when it comes from the Agent orb.
  static const orbHeader = '【语音对话摘要 · 来自 Agent 悬浮球】';
  static const instruction =
      '这是我刚才和你的语音形态的对话，请把值得长期记住的部分（我的偏好、决定、待办）记进你的记忆，不需要回复。';

  /// How long the text model gets before the rule-based summary is used.
  static const modelTimeout = Duration(seconds: 15);

  static const maxLines = 8;
  static const _lineLimit = 140;

  static const _system =
      '你把一段语音对话整理成给用户的 Agent 看的简短摘要。只输出 JSON：{"lines":["..."]}。'
      '最多 8 条，每条一句，不超过 60 字，语言和对话一致（用户说中文就写中文）。'
      '内容：用户想要什么；做了哪些决定；实际执行了什么操作（以【工具结果】为准，写清是已执行、已发送、已批准、已推迟、失败、被取消，还是只出了预览在等用户确认）；'
      '还没完成的待办；用户说出的偏好。没有的项目就不写。'
      '不要逐字复述对话，不要引用整句话，只有名字、编号这类需要时才引用短语；不要编造对话和工具结果里没有的事。';

  /// The message for a session, or null when the person said nothing.
  /// [generate] is the text model call (JSON text out); without a model, on
  /// an error or after [timeout], a compact rule-based summary is used.
  static Future<String?> build(
    List<(AgentSpeaker, String)> transcript,
    List<AgentToolOutcome> outcomes, {
    Future<String?> Function(String system, String prompt)? generate,
    Duration timeout = modelTimeout,
    String? header,
  }) async {
    final said = [
      for (final (who, text) in transcript)
        if (who == AgentSpeaker.you && text.trim().isNotEmpty) text,
    ];
    if (said.isEmpty) return null;
    final actions = [
      for (final o in outcomes)
        if (o.isAction) o,
    ];
    List<String>? lines;
    try {
      final reply = await (generate ?? generateWithVoiceKey)(
        _system,
        _prompt(transcript, actions),
      ).timeout(timeout);
      lines = parseLines(reply);
    } catch (_) {
      lines = null; // No model, no network, a refusal or too slow.
    }
    lines ??= fallbackLines(said, actions);
    return '${header ?? AgentSessionSummary.header}\n$instruction\n\n'
        '${[for (final l in lines) '- $l'].join('\n')}';
  }

  static String _prompt(
    List<(AgentSpeaker, String)> transcript,
    List<AgentToolOutcome> actions,
  ) {
    String section(AgentSpeaker who, int clip, int last) {
      final lines = [
        for (final (s, text) in transcript)
          if (s == who && text.trim().isNotEmpty) '- ${_clip(text, clip)}',
      ];
      return lines
          .skip(lines.length > last ? lines.length - last : 0)
          .join('\n');
    }

    return '请输出 JSON。\n'
        '【用户说的话】\n${section(AgentSpeaker.you, 300, 30)}\n'
        '【语音助手说的话（仅供参考）】\n${section(AgentSpeaker.agent, 150, 20)}\n'
        '【工具结果】\n'
        '${actions.isEmpty ? '（没有）' : [for (final o in actions.skip(actions.length > 40 ? actions.length - 40 : 0)) '- ${o.line}'].join('\n')}';
  }

  /// The lines of a model reply (`{"lines":[...]}` or a bare list), each
  /// clipped, at most [maxLines]; null when there is nothing usable.
  static List<String>? parseLines(String? reply) {
    if (reply == null || reply.trim().isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(reply);
    } catch (_) {
      return null;
    }
    final raw = decoded is Map ? decoded['lines'] : decoded;
    if (raw is! List) return null;
    final lines = [
      for (final l in raw)
        if (l is String && l.trim().isNotEmpty)
          _clip(l.trim().replaceFirst(RegExp(r'^[-•*]\s*'), ''), _lineLimit),
    ].take(maxLines).toList();
    return lines.isEmpty ? null : lines;
  }

  /// No model: what the person asked (each request clipped, at most five) and
  /// what the tools did.
  static List<String> fallbackLines(
    List<String> said,
    List<AgentToolOutcome> actions,
  ) {
    const requests = 5;
    const shownActions = 6;
    return [
      for (final s in said.take(requests)) '我说过：${_clip(s, 60)}',
      if (said.length > requests) '（还有 ${said.length - requests} 句）',
      for (final o in actions.take(shownActions)) '操作：${o.line}',
      if (actions.length > shownActions)
        '（还有 ${actions.length - shownActions} 项操作）',
    ];
  }
}

String _clip(String text, int max) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= max ? t : '${t.substring(0, max)}…';
}
