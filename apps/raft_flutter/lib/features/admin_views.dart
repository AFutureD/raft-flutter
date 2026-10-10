import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import 'management_support.dart';

class BillingView extends StatefulWidget {
  const BillingView({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  State<BillingView> createState() => _BillingState();
}

class _BillingState extends ManagementState<BillingView> {
  @override
  WorkspaceController get w => widget.controller;
  Map<String, dynamic> summary = {};
  String? notice;
  @override
  void initState() {
    super.initState();
    startManagement();
  }

  @override
  void clearData() {
    summary = {};
    notice = null;
  }

  @override
  String get snapshotKey => 'billing';
  @override
  Map<String, Object?> captureSnapshot() => {'summary': summary};
  @override
  bool restoreSnapshot(Map<String, Object?> fields) {
    summary = fields['summary'] as Map<String, dynamic>;
    return true;
  }

  @override
  Future<void> loadData(int request, int generation) async {
    final next = managementMap(await w.client.get('/billing/subscription'));
    if (accepts(generation, request)) summary = next;
  }

  bool get canManage =>
      w.can('manageBilling') &&
      managementMap(summary['permissions'])['canManageBilling'] == true &&
      summary['stripeConfigured'] == true;
  bool get subscribed => [
    'active',
    'past_due',
  ].contains(managementMap(summary['subscription'])['status']);
  Future<void> portal() async {
    String? url;
    final opened = await form(
      'Manage billing',
      [
        const RaftFormField(
          'returnUrl',
          'Return address',
          required: true,
          validator: managementHttpUrl,
          help: 'The Raft web address to return to after billing.',
        ),
      ],
      (v) async {
        final result = await w.client.post(
          '/billing/portal',
          data: {'returnUrl': v['returnUrl']},
        );
        url = result['url'];
      },
      submit: 'Open billing portal',
    );
    if (opened && url != null) await launchManaged(url!);
  }

  Future<void> seats() async {
    final provisioned = managementMap(summary['provisioned']);
    await form(
      subscribed ? 'Update purchased seats' : 'Purchase Pro seats',
      [
        RaftFormField(
          'humans',
          'Human seats',
          initial: '${provisioned['humans'] ?? 1}',
          required: true,
          validator: nonNegativeSeat,
        ),
        RaftFormField(
          'agents',
          'Agent seats',
          initial: '${provisioned['agents'] ?? 10}',
          required: true,
          validator: nonNegativeSeat,
        ),
        if (!subscribed)
          const RaftFormField(
            'billingInterval',
            'Billing interval',
            initial: 'monthly',
            choices: {'monthly': 'Monthly', 'annual': 'Annual'},
          ),
        if (!subscribed)
          const RaftFormField(
            'returnUrl',
            'Return address',
            required: true,
            validator: managementHttpUrl,
            help: 'A permitted Raft web address to return to after checkout.',
          ),
        if (subscribed) const RaftFormField('promotionCode', 'Promotion code'),
      ],
      (v) async {
        final human = int.parse(v['humans']!), agent = int.parse(v['agents']!);
        final data = <String, dynamic>{
          'seatQuantity': human + agent / 10,
          'humanSeatQuantity': human,
          'agentSeatQuantity': agent,
        };
        if (!subscribed) {
          if (!await confirm(
            'Continue to checkout?',
            'Purchase $human human seats and $agent agent seats, billed ${v['billingInterval']}. Review the final total in checkout before paying.',
            () async {},
            submit: 'Continue',
          )) {
            throw StateError('Checkout was not confirmed.');
          }
          final result = await w.client.post(
            '/billing/checkout',
            data: {
              ...data,
              'targetPlan': 'pro',
              'billingInterval': v['billingInterval'],
              'successUrl': v['returnUrl'],
              'cancelUrl': v['returnUrl'],
            },
          );
          await launchManaged(result['url']);
        } else {
          final preview = managementMap(
            await w.client.post(
              '/billing/seat-pack-quantity/preview',
              data: {
                ...data,
                if (v['promotionCode']!.isNotEmpty)
                  'promotionCode': v['promotionCode'],
              },
            ),
          );
          final accepted = await confirm(
            'Confirm seat update',
            'Human seats: $human\nAgent seats: $agent\nProration: ${money(preview['prorationAmount'], preview['currency'])}\nRecurring amount: ${money(preview['recurringAmount'], preview['currency'])}\nDiscount: ${money(preview['discountAmount'], preview['currency'])}',
            () async {
              final result = await w.client.post(
                '/billing/seat-pack-quantity',
                data: {...data, 'previewToken': preview['previewToken']},
              );
              notice = switch (result['status']) {
                'pending_payment' => 'Seat update awaits payment confirmation.',
                'pending_webhook' =>
                  'Seat update awaits payment provider confirmation.',
                'scheduled_period_end' =>
                  'Seat change is scheduled for the end of the billing period.',
                'unchanged' => 'Purchased seats are unchanged.',
                'reactivated' => 'Subscription reactivated.',
                _ => 'Seat update confirmed.',
              };
            },
            submit: 'Confirm purchase',
          );
          if (!accepted) throw StateError('The seat update was not confirmed.');
        }
      },
      submit: subscribed ? 'Review changes' : 'Review purchase',
      description: 'Choose the total capacity after this purchase. Human seats and agent seats must cover current workspace usage.',
    );
  }

  @override
  Widget build(BuildContext context) => page('Billing', [
    if (summary.isNotEmpty) ...[
      Text(
        '${summary['displayName'] ?? summary['plan']}',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      Text(
        'Human seats: ${managementMap(summary['usage'])['humans'] ?? 0} used / ${managementMap(summary['provisioned'])['humans'] ?? 0} provisioned',
      ),
      Text(
        'Agent seats: ${managementMap(summary['usage'])['agents'] ?? 0} used / ${managementMap(summary['provisioned'])['agents'] ?? 0} provisioned',
      ),
      if (summary['price'] is Map)
        Text(
          'USD ${managementMap(summary['price'])['monthlyUsd']} per month${managementMap(summary['price'])['annualUsd'] == null ? '' : ' · USD ${managementMap(summary['price'])['annualUsd']} annually'}',
        ),
      if (summary['subscription'] is Map) ...[
        Text(
          'Subscription: ${managementMap(summary['subscription'])['status']}',
        ),
        if (managementMap(summary['subscription'])['currentPeriodEnd'] != null)
          Text(
            'Current period ends: ${managementMap(summary['subscription'])['currentPeriodEnd']}',
          ),
        if (managementMap(summary['subscription'])['cancelAtPeriodEnd'] == true)
          const Text(
            'Cancellation is scheduled for the end of this billing period.',
          ),
      ],
      if (summary['stripeConfigured'] != true)
        const Text('Online billing is not configured for this server.'),
      if (notice != null) Semantics(liveRegion: true, child: Text(notice!)),
      if (canManage)
        Wrap(
          children: [
            action(
              subscribed ? 'Manage purchased seats' : 'Purchase Pro seats',
              () => run(seats),
            ),
            if (subscribed)
              action('Billing portal', () => run(portal, refresh: false)),
            if (subscribed &&
                managementMap(summary['subscription'])['cancelAtPeriodEnd'] !=
                    true)
              action(
                'Cancel subscription',
                () => run(() async {
                  await confirm(
                    'Cancel subscription?',
                    'Keep current access until the billing period ends. Your subscription will stop renewing.',
                    () async {
                      await w.client.post('/billing/cancel');
                      notice = 'Cancellation scheduled for the end of the billing period.';
                    },
                    submit: 'Cancel subscription',
                    destructive: true,
                  );
                }),
              ),
          ],
        ),
    ],
  ]);
}

String? nonNegativeSeat(String value) =>
    int.tryParse(value) != null && int.parse(value) >= 0
    ? null
    : 'Enter a non-negative whole number.';
String money(dynamic amount, dynamic currency) => amount is num
    ? '${(currency ?? 'USD').toString().toUpperCase()} ${(amount / 100).toStringAsFixed(2)}'
    : 'Unavailable';
