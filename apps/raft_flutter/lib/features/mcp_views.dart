import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/web_error.dart';
import '../data/workspace_controller.dart';
import 'management_support.dart';

class AgentMcpView extends StatefulWidget {
  const AgentMcpView({super.key, required this.controller, this.agentId});
  final WorkspaceController controller;
  final String? agentId;
  @override
  State<AgentMcpView> createState() => _AgentMcpState();
}

class _AgentMcpState extends ManagementState<AgentMcpView> {
  @override
  WorkspaceController get w => widget.controller;
  List<Map<String, dynamic>> servers = [], recommendations = [];
  Map<String, dynamic> agent = {};
  bool get canAssign =>
      widget.agentId != null &&
      (w.can('editAgents') ||
          (agent['creatorType'] == 'user' &&
              agent['creatorId'] == w.client.user?.id));
  @override
  void initState() {
    super.initState();
    startManagement();
  }

  @override
  void clearData() {
    servers = [];
    recommendations = [];
    agent = {};
  }

  @override
  String get snapshotKey => 'mcp:${widget.agentId ?? ''}';
  @override
  Map<String, Object?> captureSnapshot() => {
    'servers': servers,
    'recommendations': recommendations,
    'agent': agent,
  };
  @override
  bool restoreSnapshot(Map<String, Object?> fields) {
    servers = fields['servers'] as List<Map<String, dynamic>>;
    recommendations = fields['recommendations'] as List<Map<String, dynamic>>;
    agent = fields['agent'] as Map<String, dynamic>;
    return true;
  }

  /// AgentMcpTab `messageFor(error, agent.mcp.errorRequestFailed)`: the
  /// server's `error` text, else the managed-MCP failure message.
  static const _failed = 'Managed MCP request failed';

  @override
  Future<void> run(
    Future<void> Function() action, {
    bool refresh = true,
    String? fallback,
  }) => super.run(
    () => withWebError(fallback ?? _failed, action, where: 'managed mcp'),
    refresh: refresh,
    fallback: fallback ?? _failed,
  );

  @override
  Future<bool> form(
    String title,
    List<RaftFormField> fields,
    Future<void> Function(Map<String, String>) save, {
    String submit = 'Save',
    String? description,
    bool destructive = false,
  }) => super.form(
    title,
    fields,
    (values) => withWebError(_failed, () => save(values), where: 'managed mcp'),
    submit: submit,
    description: description,
    destructive: destructive,
  );

  @override
  Future<void> loadData(int request, int generation) => withWebError(
    _failed,
    () => _loadData(request, generation),
    where: 'managed mcp',
  );

  Future<void> _loadData(int request, int generation) async {
    final results = await Future.wait([
      w.client.get(
        widget.agentId == null
            ? '/mcp/servers'
            : '/mcp/agents/${widget.agentId}',
      ),
      if (widget.agentId != null) w.client.get('/agents/${widget.agentId}'),
    ]);
    if (!accepts(generation, request)) return;
    final catalog = managementMap(results[0]);
    servers = managementRows(catalog['servers']);
    recommendations = managementRows(catalog['recommendations']);
    if (results.length > 1) agent = managementMap(results[1]);
  }

  Future<void> edit([Map<String, dynamic>? server]) async {
    final creating = server == null || server['id'] == null;
    await form(
      creating ? 'Add MCP connection' : 'Edit MCP connection',
      [
        RaftFormField(
          'name',
          'Connection name',
          initial: server?['name'] ?? '',
          required: true,
        ),
        RaftFormField(
          'description',
          'Description',
          initial: server?['description'] ?? '',
          multiline: true,
        ),
        RaftFormField(
          'endpointUrl',
          'Endpoint URL',
          initial: server?['endpointUrl'] ?? '',
          required: true,
          validator: (v) {
            final invalid = managementHttpUrl(v);
            if (invalid != null) return invalid;
            return Uri.parse(v).hasQuery
                ? 'Put credentials in encrypted headers, not the URL.'
                : null;
          },
        ),
        RaftFormField(
          'provider',
          'Provider',
          initial: server?['provider'] ?? 'custom',
          choices: const {
            'custom': 'Custom',
            'notion': 'Notion',
            'linear': 'Linear',
          },
        ),
        RaftFormField(
          'authMode',
          'Authentication',
          initial: server?['authMode'] ?? 'none',
          choices: const {
            'none': 'None',
            'headers': 'Encrypted headers',
            'oauth': 'OAuth',
          },
        ),
        const RaftFormField(
          'headerName',
          'Credential header name',
          help: 'For encrypted headers, for example Authorization.',
        ),
        const RaftFormField(
          'headerValue',
          'Credential header value',
          obscure: true,
          trim: false,
          help: 'Leave empty when editing to keep existing credentials.',
        ),
        // The Web editor lists stored headers with a remove control.
        if (!creating &&
            managementStrings(server['credentialHeaderNames']).isNotEmpty)
          RaftFormField(
            'removeHeader',
            'Remove a stored header',
            initial: '',
            choices: {
              '': 'Keep all stored headers',
              for (final name in managementStrings(
                server['credentialHeaderNames'],
              ))
                name: name,
            },
          ),
      ],
      (v) async {
        if ((v['headerName']!.isEmpty) != (v['headerValue']!.isEmpty)) {
          throw const RaftUserError(
            'Credential header names must be unique, and new or renamed headers need a value.',
          );
        }
        if (v['authMode'] != 'headers' && v['headerValue']!.isNotEmpty) {
          throw const RaftUserError(
            'Select encrypted headers to save a header credential.',
          );
        }
        final data = <String, dynamic>{
          for (final f in [
            'name',
            'description',
            'endpointUrl',
            'provider',
            'authMode',
          ])
            f: v[f],
          if (creating && v['headerValue']!.isNotEmpty)
            'headers': {v['headerName']: v['headerValue']}
          else if (!creating &&
              (v['headerValue']!.isNotEmpty ||
                  (v['removeHeader'] ?? '').isNotEmpty))
            'credentialPatch': {
              'upsertHeaders': {
                if (v['headerValue']!.isNotEmpty)
                  v['headerName']: v['headerValue'],
              },
              'removeHeaderNames': [
                if ((v['removeHeader'] ?? '').isNotEmpty) v['removeHeader'],
              ],
            },
        };
        if (creating) {
          await w.client.post('/mcp/servers', data: data);
        } else {
          await w.client.patch('/mcp/servers/${server['id']}', data: data);
        }
      },
      submit: creating ? 'Add' : 'Save',
    );
  }

  Future<void> removeHeader(Map<String, dynamic> server) async {
    final names = managementStrings(server['credentialHeaderNames']);
    if (names.isEmpty) return;
    await form(
      'Remove encrypted header',
      [
        RaftFormField(
          'header',
          'Credential header name',
          choices: {for (final name in names) name: name},
        ),
      ],
      (v) async {
        await w.client.patch(
          '/mcp/servers/${server['id']}',
          data: {
            'credentialPatch': {
              'upsertHeaders': <String, String>{},
              'removeHeaderNames': [v['header']],
            },
          },
        );
      },
      submit: 'Remove',
      destructive: true,
      description:
          'Remove this stored header. Other saved credentials are preserved. To remove every credential, change authentication to None.',
    );
  }

  Future<void> testConfiguration([Map<String, dynamic>? server]) async {
    Map<String, dynamic> result = {};
    final tested = await form(
      'Test MCP configuration',
      [
        RaftFormField(
          'endpointUrl',
          'Endpoint URL',
          initial: server?['endpointUrl'] ?? '',
          required: true,
          validator: (v) =>
              managementHttpUrl(v) ??
              (Uri.tryParse(v)?.hasQuery == true
                  ? 'Put credentials in encrypted headers, not the URL.'
                  : null),
        ),
        RaftFormField(
          'authMode',
          'Authentication',
          initial: server?['authMode'] == 'headers' ? 'headers' : 'none',
          choices: const {'none': 'None', 'headers': 'Encrypted headers'},
        ),
        const RaftFormField('headerName', 'Credential header name'),
        const RaftFormField(
          'headerValue',
          'Credential header value',
          obscure: true,
          trim: false,
          help:
              'Leave empty to use the saved credential when testing an existing connection.',
        ),
      ],
      (v) async {
        if (v['headerName']!.isEmpty != v['headerValue']!.isEmpty) {
          throw const RaftUserError(
            'Credential header names must be unique, and new or renamed headers need a value.',
          );
        }
        if (v['authMode'] != 'headers' && v['headerValue']!.isNotEmpty) {
          throw const RaftUserError(
            'Select encrypted headers to test a credential.',
          );
        }
        result = managementMap(
          await w.client.post(
            '/mcp/servers/test-configuration',
            data: {
              'endpointUrl': v['endpointUrl'],
              'authMode': v['authMode'],
              if (server != null) 'mcpServerId': server['id'],
              if (v['headerValue']!.isNotEmpty)
                if (server == null)
                  'headers': {v['headerName']: v['headerValue']}
                else
                  'credentialPatch': {
                    'upsertHeaders': {v['headerName']: v['headerValue']},
                    'removeHeaderNames': <String>[],
                  },
            },
          ),
        );
      },
      submit: 'Test',
      description:
          'Connect and list tools without saving these configuration changes.',
    );
    if (tested) {
      await scopedDialog<void>(
        (dialog) => AlertDialog(
          title: Text(raftText(context, 'Connection test succeeded')),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final tool in managementRows(result['tools']))
                    ListTile(
                      title: Text('${tool['name']}'),
                      subtitle: Text('${tool['description'] ?? ''}'),
                    ),
                  if (managementRows(result['tools']).isEmpty)
                    Text(
                      raftText(
                        context,
                        'This connection currently exposes no tools.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(raftText(context, 'Close')),
            ),
          ],
        ),
      );
    }
  }

  Future<void> assignment(Map<String, dynamic> server) async {
    final current = managementMap(server['assignment']);
    final names = managementRows(
      server['toolCatalog'],
    ).map((t) => '${t['name']}').toList();
    await form(
      'Agent tool access',
      [
        RaftFormField(
          'enabled',
          'Connection access',
          initial: current['enabled'] == true ? 'true' : 'false',
          choices: const {'true': 'Enabled', 'false': 'Disabled'},
        ),
        RaftFormField(
          'tools',
          'Allowed tools',
          initial: managementStrings(current['allowedTools']).join(', '),
          help:
              'Leave blank to allow all tools in this connection. Available: ${names.join(', ')}',
          validator: (v) {
            final chosen = v
                .split(RegExp(r'[,\s]+'))
                .where((t) => t.isNotEmpty);
            return chosen.any((t) => !names.contains(t))
                ? 'Choose tools from this connection catalog.'
                : null;
          },
        ),
      ],
      (v) async {
        await w.client.request(
          'PUT',
          '/mcp/agents/${widget.agentId}/assignments/${server['id']}',
          data: {
            'enabled': v['enabled'] == 'true',
            'allowedTools': v['tools']!.isEmpty
                ? null
                : v['tools']!
                      .split(RegExp(r'[,\s]+'))
                      .where((s) => s.isNotEmpty)
                      .toSet()
                      .toList(),
          },
        );
      },
      description: 'Allow this agent to invoke only the tools you approve.',
    );
  }

  /// Settings > MCP Servers (AgentMcpTab scope="server").
  Widget serverCatalog(BuildContext context) {
    final manage = w.can('manageIntegrations');
    return RaftMcpServersSection(
      scrollable: true,
      loading: loading && servers.isEmpty,
      error: error == null ? null : raftText(context, error!),
      onAddServer: manage ? () => run(() => edit()) : null,
      servers: [
        for (final server in servers)
          () {
            final oauth = server['authMode'] == 'oauth';
            final connected = server['oauthStatus'] == 'connected';
            final ready = !oauth || connected;
            final name = '${server['name']}';
            return RaftMcpServerRow(
              id: '${server['id']}',
              name: name,
              provider: '${server['provider'] ?? 'custom'}',
              endpointUrl: '${server['endpointUrl'] ?? ''}',
              enabled: server['enabled'] != false,
              authMode: '${server['authMode'] ?? 'none'}',
              oauthStatus: server['oauthStatus'] as String?,
              hasCredentials: server['hasCredentials'] == true,
              description: server['description'] as String?,
              lastCheckError: server['lastCheckError'] as String?,
              tools: [
                for (final tool in managementRows(server['toolCatalog']))
                  RaftMcpTool(
                    '${tool['title'] ?? tool['name']}',
                    tool['description'] as String?,
                  ),
              ],
              actions: !manage
                  ? const []
                  : [
                      if (oauth && !connected)
                        RaftMcpAction(
                          glyph: RaftGlyph.link2,
                          tooltip: 'Connect $name',
                          variant: RaftButtonRecipeVariant.success,
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                  final result = await w.client.post(
                                    '/mcp/servers/${server['id']}/oauth/start',
                                  );
                                  await launchManaged(
                                    result['authorizationUrl'],
                                  );
                                }, refresh: false),
                        ),
                      if (oauth && connected)
                        RaftMcpAction(
                          glyph: RaftGlyph.unplug,
                          tooltip: 'Disconnect $name',
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                  await confirm(
                                    'Disconnect account?',
                                    'This connection will no longer be authorized to access the provider account.',
                                    () async {
                                      await w.client.delete(
                                        '/mcp/servers/${server['id']}/oauth',
                                      );
                                    },
                                    submit: 'Disconnect',
                                    destructive: true,
                                  );
                                }),
                        ),
                      RaftMcpAction(
                        glyph: RaftGlyph.flaskConical,
                        tooltip: 'Test and refresh tools',
                        onPressed: busy || !ready
                            ? null
                            : () => run(() async {
                                await w.client.post(
                                  '/mcp/servers/${server['id']}/test',
                                );
                              }),
                      ),
                      RaftMcpAction(
                        glyph: RaftGlyph.pencil,
                        tooltip: 'Edit server',
                        onPressed: busy ? null : () => run(() => edit(server)),
                      ),
                      RaftMcpAction(
                        glyph: RaftGlyph.trash2,
                        tooltip: 'Delete server',
                        variant: RaftButtonRecipeVariant.danger,
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await confirm(
                                  'Delete $name?',
                                  'Remove this connection and its agent tool assignments.',
                                  () async {
                                    await w.client.delete(
                                      '/mcp/servers/${server['id']}',
                                    );
                                  },
                                  submit: 'Delete',
                                  destructive: true,
                                );
                              }),
                      ),
                    ],
            );
          }(),
      ],
      recommendations: !manage
          ? const []
          : [
              for (final r in recommendations)
                RaftMcpRecommendation(
                  id: '${r['id']}',
                  name: '${r['name']}',
                  description: '${r['description'] ?? ''}',
                  added: servers.any((s) => s['provider'] == r['provider']),
                  onAdd: busy
                      ? null
                      : () => run(() => edit({...r, 'id': null})),
                ),
            ],
    );
  }

  /// AgentMcpTab scope="agent": the read-only usage list (only servers this
  /// Agent has called), in the tab's `px-5 py-4` scroll column.
  Widget agentUsage(BuildContext context) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    String used(String? iso) {
      final at = DateTime.tryParse(iso ?? '')?.toLocal();
      return at == null
          ? ''
          : '${DateFormat.yMMMd(locale).format(at)} ${DateFormat('hh:mm a', locale).format(at)}';
    }

    return ListView(
      primary: false,
      padding: raftScrollPadding(
        context,
        const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      ),
      children: [
        RaftMcpServersSection(
          usage: true,
          loading: loading && servers.isEmpty,
          error: error == null ? null : raftText(context, error!),
          servers: [
            for (final server in servers)
              if (server['usage'] is Map)
                RaftMcpServerRow(
                  id: '${server['id']}',
                  name: '${server['name']}',
                  provider: '${server['provider'] ?? 'custom'}',
                  endpointUrl: '${server['endpointUrl'] ?? ''}',
                  enabled: server['enabled'] != false,
                  authMode: '${server['authMode'] ?? 'none'}',
                  oauthStatus: server['oauthStatus'] as String?,
                  hasCredentials: server['hasCredentials'] == true,
                  description: server['description'] as String?,
                  lastCheckError: server['lastCheckError'] as String?,
                  usageCalls: () {
                    final n = (server['usage']['invocationCount'] as num)
                        .toInt();
                    return '$n ${n == 1 ? 'call' : 'calls'}';
                  }(),
                  usageLastUsed: used(server['usage']['lastInvokedAt']),
                  usageLastTool: '${server['usage']['lastToolName']}',
                  tools: [
                    for (final tool in managementRows(server['toolCatalog']))
                      RaftMcpTool(
                        '${tool['title'] ?? tool['name']}',
                        tool['description'] as String?,
                      ),
                  ],
                ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      widget.agentId == null ? serverCatalog(context) : agentUsage(context);
}
