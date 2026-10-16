import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_search.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';

/// The use cases the capabilities were added for: what people say finds the
/// capability (or the page to go to) within the first three answers.
void main() {
  final index = AgentCapabilityIndex(agentStandardCapabilities.all);

  // What is said -> the capability `find` should offer first.
  final said = <String, String>{
    // 了解现状
    '昨天到今天整体进展汇总一下': 'digest.since',
    '有没有系统通知，套餐超限了吗': 'notifications.center',
    // 做决定、审批
    '打回去，让他重做，说明原因': 'tasks.reject_with_reason',
    '这个稍后再说': 'attention.snooze',
    '明天提醒我再看这个': 'attention.snooze',
    '我稍后的有哪些': 'attention.snoozed',
    '批准这个登录请求': 'actions.approve',
    '同意安装这个应用': 'actions.approve',
    'Grok 要的权限给他': 'apps.approve_request',
    '拒绝这个授权请求': 'apps.deny_request',
    '有什么要我批准的': 'approvals.pending',
    // 沟通
    '把这条转给 Cindy': 'messages.forward',
    '发条消息，附上刚才那张截图': 'messages.send_with_attachment',
    '把这条翻译成中文': 'messages.translate',
    '收藏这条': 'messages.set_saved',
    '关注这个话题': 'threads.set_following',
    '把这条消息变成任务': 'tasks.create_from_message',
    // 任务
    '一次建这三个任务': 'tasks.create_batch',
    // 管理 Agent
    '重启一下 Grok': 'agents.restart',
    '重置会话': 'agents.reset_session',
    '停掉所有 Agent': 'channels.sos_stop',
    '停掉 Cody': 'agents.stop',
    '新建一个 Agent，叫 Nova': 'agents.create',
    '把 Cody 迁到另一台电脑': 'agents.migrate',
    'Cody 的记忆里写了什么': 'agents.workspace_files',
    '改 Cody 的模型和推理强度': 'agents.settings',
    'Cody 最近调用了哪些工具': 'agents.mcp_usage',
    '删掉这个 Agent': 'agents.delete',
    // 找东西
    '找一下 Kevin 发的那个设计图': 'channels.files',
    // 频道和成员
    '静音这个频道': 'channels.set_muted',
    '把 design 置顶': 'channels.set_pinned',
    '建个频道 launch，把 Cody 和 Grok 拉进来': 'channels.create',
    '把 Ada 加到 general 频道': 'channels.add_members',
    '离开这个频道': 'channels.leave',
    '把这个频道归档': 'channels.archive',
    '删除这个频道': 'channels.delete',
    '邀请 Ada 加入服务器': 'server.invite',
    '把她设成管理员': 'members.change_role',
    // 电脑和运行时
    '给 K8 升级': 'computers.upgrade',
    '清理一下 K8 上没用的工作区': 'computers.cleanup',
    '轮换一下电脑的 API Key': 'computers.rotate_key',
    '删除这台电脑': 'computers.delete',
    'AI 提供商的 Key 还有效吗': 'providers.manage',
    // 集成、计费、设置
    '装一下这个应用': 'apps.marketplace',
    '连接 Slack': 'slack.bridge',
    '添加一个 MCP 服务器': 'mcp.manage',
    '我们这个月花了多少，还剩几个座位': 'billing.manage',
    '切到深色模式': 'settings.appearance',
    '字大一点': 'settings.appearance',
    '明天早上 9 点前别推送': 'settings.notifications',
    '切到 Myoland 服务器': 'servers.switch',
    '离开这个服务器': 'server.leave',
  };

  for (final e in said.entries) {
    test('"${e.key}" finds ${e.value}', () {
      final ids = [for (final c in index.find(e.key)) c.id];
      expect(ids.take(3), contains(e.value), reason: '$ids');
    });
  }

  test('every id named here exists, and the page ones never run by voice', () {
    for (final id in said.values) {
      final c = agentStandardCapabilities[id];
      expect(c, isNotNull, reason: id);
    }
    final pages = said.values
        .map((id) => agentStandardCapabilities[id]!)
        .where((c) => c.risk == AgentCapabilityRisk.neverByVoice);
    expect(pages.length, greaterThan(15));
  });
}
