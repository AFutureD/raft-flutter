import 'source_time_formatter.dart' show sourceTimeNow;

/// Source shared `getEffectiveLimits(plan).messageHistoryDays` and
/// `PLAN_CONFIG[plan].displayName` for the history-limit notice
/// (HistoryLimitBanner.tsx): the Free plan keeps 30 days once the full-featured
/// trial (TRIAL_START_DATE .. TRIAL_END_DATE) is over; every other plan and an
/// active trial are unlimited (-1).
final _trialStart = DateTime.utc(2026, 4, 18);
final _trialEnd = DateTime.utc(2026, 6, 23, 12);

({String plan, int days}) planHistoryLimit(String? plan, {DateTime? now}) {
  final id = switch (plan) {
    'founder' || 'partner' || 'pro' => plan!,
    _ => 'free',
  };
  final name = '${id[0].toUpperCase()}${id.substring(1)}';
  if (id != 'free') return (plan: name, days: -1);
  final at = (now ?? sourceTimeNow()).toUtc();
  final trial = !at.isBefore(_trialStart) && at.isBefore(_trialEnd);
  return (plan: name, days: trial ? -1 : 30);
}
