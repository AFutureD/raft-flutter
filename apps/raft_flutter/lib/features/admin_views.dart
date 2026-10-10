import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import 'management_support.dart';
import 'server_views.dart';
import 'server_setup_gate.dart';

class AdministrationView extends StatefulWidget {
  const AdministrationView({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  State<AdministrationView> createState() => _AdministrationState();
}

class _AdministrationState extends ManagementState<AdministrationView> {
  @override
  WorkspaceController get w => widget.controller;
  Map<String, dynamic> analytics = {},
      translation = {},
      agreement = {},
      onboarding = {},
      setup = {},
      public = {};
  bool publicEnabled = false, guestEnabled = false;
  String get base => '/servers/${w.server!.id}';
  bool get edit => w.can('editServerSettings');
  bool get owner => w.server?.string('role') == 'owner';
  @override
  void initState() {
    super.initState();
    startManagement();
  }

  @override
  void clearData() {
    analytics = {};
    translation = {};
    agreement = {};
    onboarding = {};
    setup = {};
    public = {};
    publicEnabled = false;
    guestEnabled = false;
  }

  @override
  String get snapshotKey => 'administration';
  @override
  Map<String, Object?> captureSnapshot() => {
    'analytics': analytics,
    'translation': translation,
    'agreement': agreement,
    'onboarding': onboarding,
    'setup': setup,
    'public': public,
    'publicEnabled': publicEnabled,
    'guestEnabled': guestEnabled,
  };
  @override
  bool restoreSnapshot(Map<String, Object?> fields) {
    analytics = fields['analytics'] as Map<String, dynamic>;
    translation = fields['translation'] as Map<String, dynamic>;
    agreement = fields['agreement'] as Map<String, dynamic>;
    onboarding = fields['onboarding'] as Map<String, dynamic>;
    setup = fields['setup'] as Map<String, dynamic>;
    public = fields['public'] as Map<String, dynamic>;
    publicEnabled = fields['publicEnabled'] as bool;
    guestEnabled = fields['guestEnabled'] as bool;
    return true;
  }

  @override
  Future<void> loadData(int request, int generation) async {
    final flags = managementMap(
      await w.client.post(
        '/feature-flags/evaluate',
        data: {
          'keys': ['public_server_v0', 'server_guest_v0'],
          'serverId': w.server?.id,
          'platform': 'web',
        },
      ),
    );
    if (!accepts(generation, request)) return;
    final evaluated = managementRows(flags['evaluations']);
    final enablePublic =
        owner &&
        evaluated.any(
          (f) => f['key'] == 'public_server_v0' && f['enabled'] == true,
        );
    final enableGuest = evaluated.any(
      (f) => f['key'] == 'server_guest_v0' && f['enabled'] == true,
    );
    final results = await Future.wait([
      w.client.get('$base/product-analytics-settings'),
      w.client.get('$base/translation-settings'),
      w.client.get('$base/onboarding-settings'),
      w.client.get('$base/setup-projection'),
      if (edit) w.client.get('$base/agreement'),
      if (enablePublic) w.client.get('$base/public-visibility'),
    ]);
    if (!accepts(generation, request)) return;
    analytics = managementMap(results[0]);
    translation = managementMap(results[1]);
    onboarding = managementMap(results[2]);
    setup = managementMap(results[3]);
    var index = 4;
    agreement = edit ? managementMap(results[index++]) : {};
    public = enablePublic ? managementMap(results[index]) : {};
    publicEnabled = enablePublic;
    guestEnabled = enableGuest;
  }

  Future<void> editAgreement() async {
    final current = managementMap(agreement['agreement']);
    await form(
      'Pre-join agreement',
      [
        RaftFormField(
          'enabled',
          'Require agreement',
          initial: agreement['enabled'] == true ? 'true' : 'false',
          choices: const {'true': 'Required', 'false': 'Disabled'},
        ),
        RaftFormField(
          'title',
          'Agreement title',
          initial: current['title'] ?? '',
        ),
        RaftFormField(
          'bodyMarkdown',
          'Agreement text',
          initial: current['bodyMarkdown'] ?? '',
          multiline: true,
        ),
      ],
      (v) async {
        if (v['enabled'] == 'true' &&
            (v['title']!.isEmpty || v['bodyMarkdown']!.isEmpty)) {
          throw StateError('A title and agreement text are required.');
        }
        await w.client.request(
          'PUT',
          '$base/agreement',
          data: {
            'enabled': v['enabled'] == 'true',
            'title': v['title'],
            'bodyMarkdown': v['bodyMarkdown'],
          },
        );
      },
      description: 'New invitees must explicitly accept the active agreement before joining.',
    );
  }

  Future<void> onboardingAgent() async {
    final data = await w.client.get('/agents');
    final agents = managementRows(
      data is List ? data : managementMap(data)['agents'],
    );
    await form(
      'Onboarding agent',
      [
        RaftFormField(
          'agentId',
          'Agent',
          initial: onboarding['onboardingAgentId'] ?? '',
          choices: {
            '': 'None',
            for (final a in agents)
              '${a['id']}': '${a['displayName'] ?? a['name']}',
          },
        ),
        RaftFormField(
          'greeting',
          'Greet new agents in #all',
          initial: onboarding['agentAllChannelGreetingEnabled'] == true
              ? 'true'
              : 'false',
          choices: const {'true': 'Enabled', 'false': 'Disabled'},
        ),
      ],
      (v) async {
        await w.client.patch(
          '$base/onboarding-settings',
          data: {
            'onboardingAgentId': v['agentId']!.isEmpty ? null : v['agentId'],
            'agentAllChannelGreetingEnabled': v['greeting'] == 'true',
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => page('Workspace administration', [
    WorkspaceAccessSettings(controller: w),
    heading('Usage data'),
    SwitchListTile(
      title: const Text('Share product usage data'),
      subtitle: const Text(
        'Allow the workspace to contribute product analytics.',
      ),
      value: analytics['productAnalyticsEnabled'] == true,
      onChanged: busy || !edit || analytics['canManageProductAnalytics'] != true
          ? null
          : (v) => run(() async {
              await w.client.patch(
                '$base/product-analytics-settings',
                data: {'productAnalyticsEnabled': v},
              );
            }),
    ),
    heading('Translation'),
    SwitchListTile(
      title: const Text('Message translation'),
      subtitle: Text(
        translation['translationAvailable'] == true
            ? 'Allow message translations in this workspace.'
            : 'A translation provider is not configured on this server.',
      ),
      value: translation['translationEnabled'] == true,
      onChanged:
          busy ||
              !edit ||
              translation['canManageTranslation'] != true ||
              translation['translationAvailable'] != true
          ? null
          : (v) => run(() async {
              final accepted = await w.client.patch(
                '$base/translation-settings',
                data: {'translationEnabled': v},
              );
              // Web `updateServerTranslationEnabled`: message rows follow
              // the accepted gate without a reload.
              w.translations.adoptServerSettings(accepted);
            }),
    ),
    if (edit) ...[
      heading('Pre-join agreement'),
      ListTile(
        title: Text(
          agreement['enabled'] == true
              ? managementMap(agreement['agreement'])['title'] ??
                    'Agreement required'
              : 'Agreement disabled',
        ),
        subtitle: agreement['enabled'] == true
            ? Text(
                'Version ${managementMap(agreement['agreement'])['version']}',
              )
            : null,
        trailing: action('Edit agreement', () => run(editAgreement)),
      ),
    ],
    if (publicEnabled) ...[
      heading('Public access'),
      SwitchListTile(
        title: const Text('Make workspace publicly visible'),
        subtitle: const Text(
          'Guest-visible channels can be read by anyone with the public workspace address.',
        ),
        value: public['publiclyVisible'] == true,
        onChanged: busy
            ? null
            : (v) => run(() async {
                final accepted = await confirm(
                  v ? 'Make workspace public?' : 'Turn off public access?',
                  v
                      ? 'The following channels will be publicly visible:\n${managementRows(public['exposedChannels']).map((c) => '#${c['name']}').join('\n')}'
                      : 'Public access and public guest admission will be disabled.',
                  () async {
                    await w.client.patch(
                      '$base/public-visibility',
                      data: {'publiclyVisible': v},
                    );
                  },
                  submit: v ? 'Make public' : 'Disable',
                );
                if (!accepted) return;
              }),
      ),
      if (guestEnabled)
        SwitchListTile(
          title: const Text('Allow visitors to join as guests'),
          subtitle: const Text(
            'Requires public access. Guests only receive permissions explicitly granted to them.',
          ),
          value: public['publicGuestJoinEnabled'] == true,
          onChanged: busy || public['publiclyVisible'] != true
              ? null
              : (v) => run(() async {
                  await confirm(
                    v ? 'Allow guest admission?' : 'Disable guest admission?',
                    v
                        ? 'Visitors will be able to join this workspace as guests.'
                        : 'New visitors will no longer be able to join without an invitation.',
                    () async {
                      await w.client.patch(
                        '$base/public-guest-join',
                        data: {'publicGuestJoinEnabled': v},
                      );
                    },
                    submit: v ? 'Allow guests' : 'Disable',
                  );
                }),
        ),
      for (final channel in managementRows(public['exposedChannels']))
        ListTile(
          leading: const RaftIcon(RaftGlyph.hash, size: 14, strokeWidth: 2.5),
          title: Text('#${channel['name']}'),
          subtitle: Text('${channel['description'] ?? ''}'),
        ),
    ],
    heading('Onboarding'),
    if (edit)
      ListTile(
        title: const Text('Welcome agent'),
        subtitle: Text(
          onboarding['onboardingAgentId'] == null
              ? 'No welcome agent assigned.'
              : 'A welcome agent is assigned.',
        ),
        trailing: action('Configure', () => run(onboardingAgent)),
      ),
    Text('Setup: ${setup['phase'] ?? 'No setup required'}'),
    if (setup['gateReason'] != null)
      Text('Setup requires attention: ${setup['gateReason']}'),
    Text(
      'Computer: ${setup['computerStatus'] ?? 'Unknown'} · Runtime: ${setup['runtimeStatus'] ?? 'Unknown'}',
    ),
    for (final computer in managementRows(setup['offlineComputers']))
      Text('${computer['name']} is offline.'),
    if (setup['currentStep'] == 'computer_runtime')
      const Text(
        'Connect a computer and make a supported runtime available to continue.',
      ),
    if (setup['currentStep'] == 'create_agent')
      const Text('Create Cindy from the workspace setup screen to continue.'),
    if (owner && managementMap(setup['postSetup'])['handoffPending'] == true)
      action(
        'Let’s go',
        () => run(() async {
          await w.client.post('$base/setup-handoff');
          refreshServerSetup(w);
        }),
      ),
    if (managementMap(setup['sideEffectState'])['transitions'] == 'enabled' &&
        setup['phase'] == 'not_started')
      action(
        'Start setup',
        () => run(() async {
          await w.client.post(
            '$base/setup-transition',
            data: {'action': 'start'},
          );
          refreshServerSetup(w);
        }),
      ),
    if (managementStrings(setup['allowedExits']).contains('reset'))
      action(
        'Start over',
        () => run(() async {
          await confirm(
            'Start setup over?',
            'Revoke the computers connected during unfinished setup. Their old credentials will stop working. This is only available before an agent has existed.',
            () async {
              await w.client.post('$base/setup-reset');
              refreshServerSetup(w);
            },
            submit: 'Start over',
            destructive: true,
          );
        }),
      ),
  ]);
}
