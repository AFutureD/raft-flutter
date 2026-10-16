import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentSpeaker;

import '../../data/workspace_controller.dart';

/// A Raft agent whose memory the voice agent shares.
typedef AgentBrainChoice = ({String id, String name});

/// Shares memory with one of the person's Raft agents using only existing
/// client APIs: its MEMORY.md (the agent workspace view) and the direct
/// conversation with it are read into the voice session, and a summary of
/// each voice session is sent to it as a direct message for it to keep.
class AgentBrain {
  AgentBrain(this.w);
  final WorkspaceController w;

  static const _memoryLimit = 6000;

  /// What the last [context] call managed to read, for the captions.
  String? note;
  Object? _memoryError;

  /// Agents on this server the person can choose from.
  Future<List<AgentBrainChoice>> agents() async {
    final body = await w.query('/agents');
    final rows = body is List
        ? body
        : body is Map
        ? (body['agents'] ?? body['items'])
        : null;
    return [
      for (final r in rows is List ? rows : const [])
        // Archived agents keep their name but their workspace is closed.
        if (r is Map && r['id'] is String && r['deletedAt'] == null)
          (
            id: r['id'] as String,
            name: '${r['displayName'] ?? r['name'] ?? r['id']}',
          ),
    ];
  }

  /// The agent's MEMORY.md, trimmed; null when it cannot be read (no
  /// permission, no machine, no file).
  Future<String?> memory(String agentId) async {
    try {
      final result = await w.query(
        '/agents/$agentId/workspace-files/read',
        query: {'path': 'MEMORY.md'},
      );
      final content = result is Map ? result['content'] : result;
      if (content is! String || content.trim().isEmpty) return null;
      return content.length <= _memoryLimit
          ? content
          : '${content.substring(0, _memoryLimit)}\n…';
    } catch (e) {
      _memoryError = e;
      return null;
    }
  }

  Future<String?> _directChannel(String agentId) async {
    final result = await w.client.post(
      '/channels/dm',
      data: {'agentId': agentId},
    );
    final id = result is Map
        ? (result['id'] ?? result['channel']?['id'])
        : null;
    return id is String ? id : null;
  }

  /// The latest messages between the person and the agent, oldest first.
  Future<List<String>> recent(String agentId, {int limit = 12}) async {
    try {
      final channel = await _directChannel(agentId);
      if (channel == null) return const [];
      final page = await w.client.messagePage(channel, limit: limit);
      final rows =
          [
            for (final m in (page['messages'] as List?) ?? const [])
              if (m is Map) m,
          ]..sort((a, b) {
            final sa = BigInt.tryParse('${a['seq']}') ?? BigInt.zero;
            final sb = BigInt.tryParse('${b['seq']}') ?? BigInt.zero;
            return sa.compareTo(sb);
          });
      return [
        for (final m in rows)
          '${m['senderName'] ?? ''}：${_clip('${m['content'] ?? ''}', 200)}',
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Background for the voice session: who it is and what it remembers.
  Future<String?> context(AgentBrainChoice brain) async {
    _memoryError = null;
    final results = await Future.wait<Object?>([
      memory(brain.id),
      recent(brain.id),
    ]);
    final remembered = results[0] as String?;
    final talk = results[1]! as List<String>;
    final error = _memoryError;
    note = [
      remembered != null
          ? '已读取 ${brain.name} 的 MEMORY.md（${remembered.length} 字）'
          : error != null
          ? '读不到 ${brain.name} 的 MEMORY.md：${_clip('$error', 80)}'
          : '${brain.name} 没有 MEMORY.md',
      '最近私信 ${talk.length} 条',
    ].join('，');
    return compose(brain.name, remembered, talk);
  }

  /// The prompt section for [name]'s memory and recent conversation.
  static String compose(String name, String? remembered, List<String> talk) {
    return [
      '你就是用户在 Raft 里的 Agent「$name」的语音形态，和它是同一个人，记忆共享。',
      if (remembered != null) '【你的长期记忆（$name 的 MEMORY.md）】\n$remembered',
      if (talk.isNotEmpty) '【你和用户最近的私信】\n${talk.join('\n')}',
    ].join('\n\n');
  }

  /// Sends what was said in a voice session to the agent so it can keep the
  /// parts worth remembering. Returns false when nothing was sent.
  Future<bool> sendSummary(
    AgentBrainChoice brain,
    List<(AgentSpeaker, String)> transcript,
  ) async {
    final text = summaryText(transcript);
    if (text == null) return false;
    final channel = await _directChannel(brain.id);
    if (channel == null) return false;
    await w.client.send(channel, text);
    return true;
  }

  /// The direct message for a session; null when the person said nothing.
  static String? summaryText(List<(AgentSpeaker, String)> transcript) {
    if (!transcript.any((l) => l.$1 == AgentSpeaker.you)) return null;
    final lines = [
      for (final (who, text) in transcript)
        '${who == AgentSpeaker.you ? '我' : '你（语音）'}：${_clip(text, 300)}',
    ];
    var body = lines.join('\n');
    if (body.length > 3000) body = '…${body.substring(body.length - 3000)}';
    return '【语音对话记录 · 来自 Agent 模式】\n'
        '这是我刚才和你的语音形态的对话，请把值得长期记住的部分（我的偏好、决定、待办）记进你的记忆，不需要回复。\n\n'
        '$body';
  }

  static String _clip(String text, int max) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }
}
