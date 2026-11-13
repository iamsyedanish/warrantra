/**
 * Measured profitability per active paid account-month, cohort CAC/payback and
 * margin alerts. Traces: gross subscription revenue -> net of store fee,
 * refunds and RevenueCat -> variable costs (AI, infra, support) -> amortized CAC
 * by new-paying cohort -> fixed + founder + free-user subsidy -> after-tax.
 * Acquisition spend is only ever counted through CAC (never also as overhead).
 */
import { check } from '../../lib/errors.js';
import { serviceClient } from '../../lib/supabase.js';
import { netReceiptsFactor } from './calculator.js';

type Row = Record<string, unknown>;

const monthStart = (d: Date) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1));
const addMonthsUtc = (d: Date, n: number) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + n, 1));
const ymd = (d: Date) => d.toISOString().slice(0, 10);
const money = (n: number) => Math.round(n * 100) / 100;

function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const s = [...values].sort((a, b) => a - b);
  const idx = (s.length - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  return s[lo]! + (s[hi]! - s[lo]!) * (idx - lo);
}

/** Recognise gross revenue in month M: monthly transactions in M, plus 1/12 of annual transactions in the previous 12 months. */
export function recognisedRevenue(transactions: Row[], month: Date, defaultFee: number) {
  const start = month.getTime();
  const end = addMonthsUtc(month, 1).getTime();
  let gross = 0;
  let fees = 0;
  let refunds = 0;
  for (const t of transactions) {
    const at = new Date(String(t.occurred_at)).getTime();
    const amount = Number(t.gross_usd);
    const fee = t.platform_fee_rate === null || t.platform_fee_rate === undefined ? defaultFee : Number(t.platform_fee_rate);
    if (t.kind === 'refund') {
      if (at >= start && at < end) refunds += -amount;
      continue;
    }
    if (t.billing_period === 'annual') {
      if (at < end && at >= addMonthsUtc(month, -11).getTime()) {
        gross += amount / 12;
        fees += (amount / 12) * fee;
      }
    } else if (at >= start && at < end) {
      gross += amount;
      fees += amount * fee;
    }
  }
  return { gross, fees, refunds, effectiveFeeRate: gross > 0 ? fees / gross : defaultFee };
}

export async function computeSnapshot(monthIso?: string) {
  const svc = serviceClient();
  const month = monthStart(monthIso ? new Date(`${monthIso.slice(0, 7)}-01T00:00:00Z`) : new Date());
  const next = addMonthsUtc(month, 1);
  const monthEnd = next.getTime() > Date.now() ? new Date() : new Date(next.getTime() - 1);

  const settings = check(await svc.from('profit_model_settings').select('*').lte('effective_from', ymd(month))
    .order('version', { ascending: false }).limit(1).maybeSingle()) as Row | null
    ?? (check(await svc.from('profit_model_settings').select('*').order('version').limit(1).single()) as Row);
  const L = Number(settings.cac_recovery_months);
  const t = Number(settings.tax_rate);
  const r = Number(settings.refund_reserve_rate);
  const c = Number(settings.revenuecat_rate);
  const target = Number(settings.target_after_tax_usd);

  // Active paying at month end (production only).
  const activeRows = check(await svc.from('entitlements').select('user_id').eq('environment', 'PRODUCTION')
    .in('state', ['active', 'grace_period', 'billing_retry']).lte('valid_from', monthEnd.toISOString())
    .gte('valid_until', monthEnd.toISOString())) as Row[];
  const paidUsers = new Set(activeRows.map((x) => String(x.user_id)));
  const N = paidUsers.size;
  const totalProfiles = (await svc.from('profiles').select('id', { count: 'exact', head: true }).lt('created_at', next.toISOString())).count ?? 0;
  const freeAccounts = Math.max(0, totalProfiles - N);

  const txs = check(await svc.from('revenue_transactions').select('*').eq('environment', 'PRODUCTION')
    .gte('occurred_at', addMonthsUtc(month, -11).toISOString()).lt('occurred_at', next.toISOString())) as Row[];
  const rev = recognisedRevenue(txs, month, Number(settings.default_platform_fee_rate));
  const factor = netReceiptsFactor(r, rev.effectiveFeeRate, c);
  const netReceipts = rev.gross * factor;
  const platformFees = rev.gross * rev.effectiveFeeRate;
  const revenuecatFees = rev.gross * c;

  const costs = check(await svc.from('operating_costs').select('*').eq('month', ymd(month))) as Row[];
  const sumCost = (cls: string) => costs.filter((x) => x.cost_class === cls).reduce((a, x) => a + Number(x.amount_usd), 0);

  const ai = check(await svc.from('usage_events').select('user_id, cost_usd').gte('created_at', month.toISOString()).lt('created_at', next.toISOString())) as Row[];
  const aiPaid = ai.filter((x) => x.user_id && paidUsers.has(String(x.user_id))).reduce((a, x) => a + Number(x.cost_usd), 0);
  const aiFree = ai.filter((x) => !x.user_id || !paidUsers.has(String(x.user_id))).reduce((a, x) => a + Number(x.cost_usd), 0);
  const aiCosts = ai.map((x) => Number(x.cost_usd)).filter((x) => x > 0);

  const tickets = check(await svc.from('support_tickets').select('support_minutes').gte('created_at', month.toISOString()).lt('created_at', next.toISOString())) as Row[];
  const supportMinutes = tickets.reduce((a, x) => a + Number(x.support_minutes ?? 0), 0);

  let variablePaid = sumCost('variable_paid') + aiPaid;
  const measuredVariable = variablePaid > 0;
  if (!measuredVariable) variablePaid = N * Number(settings.paid_variable_cost_floor);
  const freeSubsidy = sumCost('variable_free') + aiFree + (sumCost('variable_free') === 0 ? freeAccounts * Number(settings.free_account_monthly_cost) : 0);
  const fixed = sumCost('fixed');

  // CAC amortization: each cohort's acquisition spend is spread over L months.
  const spend = check(await svc.from('acquisition_spend').select('month, amount_usd').gte('month', ymd(addMonthsUtc(month, -(L - 1)))).lte('month', ymd(month))) as Row[];
  const cacAmortized = spend.reduce((a, x) => a + Number(x.amount_usd), 0) / L;
  const monthSpend = spend.filter((x) => x.month === ymd(month)).reduce((a, x) => a + Number(x.amount_usd), 0);
  const newPaying = (await svc.from('customer_acquisitions').select('user_id', { count: 'exact', head: true }).eq('cohort_month', ymd(month))).count ?? 0;

  // Churn: paid access that ended (expired/refunded) during the month / paying at month start.
  const atStart = check(await svc.from('entitlements').select('user_id').eq('environment', 'PRODUCTION')
    .lte('valid_from', month.toISOString()).gte('valid_until', month.toISOString())) as Row[];
  const ended = check(await svc.from('entitlements').select('user_id').eq('environment', 'PRODUCTION')
    .in('state', ['expired', 'refunded']).gte('valid_until', month.toISOString()).lt('valid_until', next.toISOString())) as Row[];
  const startSet = new Set(atStart.map((x) => String(x.user_id)));
  const churned = ended.filter((x) => startSet.has(String(x.user_id))).length;

  const pretaxTotal = netReceipts - variablePaid - freeSubsidy - fixed - cacAmortized;
  const pretaxPerPaid = N > 0 ? pretaxTotal / N : null;
  const afterTaxPerPaid = pretaxPerPaid === null ? null : pretaxPerPaid - Math.max(pretaxPerPaid, 0) * t;
  const purchases = txs.filter((x) => x.kind !== 'refund' && new Date(String(x.occurred_at)) >= month).reduce((a, x) => a + Number(x.gross_usd), 0);
  const refundRate = purchases > 0 ? rev.refunds / purchases : null;

  const snapshot = {
    month: ymd(month),
    settings_version: settings.version,
    active_paying: N,
    free_accounts: freeAccounts,
    new_paying: newPaying,
    gross_revenue_usd: money(rev.gross),
    refunds_usd: money(rev.refunds),
    platform_fees_usd: money(platformFees),
    revenuecat_fees_usd: money(revenuecatFees),
    net_receipts_usd: money(netReceipts),
    ai_cost_usd: Math.round((aiPaid + aiFree) * 10_000) / 10_000,
    variable_paid_cost_usd: money(variablePaid),
    free_subsidy_usd: money(freeSubsidy),
    fixed_cost_usd: money(fixed),
    acquisition_spend_usd: money(monthSpend),
    cac_per_new_payer_usd: newPaying > 0 ? money(monthSpend / newPaying) : null,
    cac_allocation_per_paid_usd: N > 0 ? Math.round((cacAmortized / N) * 10_000) / 10_000 : 0,
    pretax_per_paid_usd: pretaxPerPaid === null ? null : Math.round(pretaxPerPaid * 10_000) / 10_000,
    after_tax_per_paid_usd: afterTaxPerPaid === null ? null : Math.round(afterTaxPerPaid * 10_000) / 10_000,
    target_after_tax_usd: target,
    meets_target: afterTaxPerPaid === null ? null : afterTaxPerPaid >= target,
    ai_cost_p50_usd: percentile(aiCosts, 0.5),
    ai_cost_p95_usd: percentile(aiCosts, 0.95),
    support_minutes: supportMinutes,
    refund_rate: refundRate === null ? null : Math.round(refundRate * 10_000) / 10_000,
    details: {
      net_receipts_factor: Math.round(factor * 10_000) / 10_000,
      effective_platform_fee_rate: Math.round(rev.effectiveFeeRate * 10_000) / 10_000,
      variable_cost_source: measuredVariable ? 'measured' : 'model_floor',
      churn: { definition: 'Paying at month start whose paid access ended (expired/refunded) during the month',
               numerator: churned, denominator: startSet.size,
               rate: startSet.size ? Math.round((churned / startSet.size) * 10_000) / 10_000 : null },
      cac_amortized_total_usd: money(cacAmortized),
      warnings: [
        ...(fixed === 0 ? ['No fixed/founder costs entered for this month — profit is overstated.'] : []),
        'Upfront development, legal/privacy review, financing and payroll on-costs must be entered as operating costs or profit is overstated.',
        'Income-tax treatment is illustrative; obtain jurisdiction-specific advice.',
      ],
    },
    computed_at: new Date().toISOString(),
  };
  check(await svc.from('profitability_snapshots').upsert(snapshot, { onConflict: 'month' }));
  await raiseAlerts(snapshot, settings);
  await computeCohorts(month);
  return snapshot;
}

async function raiseAlerts(s: Record<string, any>, settings: Row) {
  const svc = serviceClient();
  const alerts: Row[] = [];
  const add = (type: string, severity: string, value: number | null, threshold: number | null, message: string) =>
    alerts.push({ month: s.month, alert_type: type, severity, metric_value: value, threshold, message });
  if (s.after_tax_per_paid_usd !== null && s.after_tax_per_paid_usd < 0) {
    add('negative_margin', 'critical', s.after_tax_per_paid_usd, 0, 'Paid accounts are loss-making after full cost allocation.');
  } else if (s.after_tax_per_paid_usd !== null && !s.meets_target) {
    add('below_target', 'warning', s.after_tax_per_paid_usd, Number(settings.target_after_tax_usd),
      `After-tax profit per active paid account-month is below the $${settings.target_after_tax_usd} target.`);
  }
  if (s.fixed_cost_usd === 0) add('missing_cost_inputs', 'warning', 0, null, 'Fixed and founder costs are missing for this month.');
  if (s.refund_rate !== null && s.refund_rate > Number(settings.refund_rate_alert)) {
    add('refund_rate_high', 'warning', s.refund_rate, Number(settings.refund_rate_alert), 'Refund rate exceeds the alert threshold.');
  }
  if (s.ai_cost_p95_usd !== null && s.ai_cost_p95_usd > Number(settings.ai_cost_p95_alert_usd)) {
    add('ai_cost_p95_high', 'warning', s.ai_cost_p95_usd, Number(settings.ai_cost_p95_alert_usd), 'p95 AI cost per action is above threshold.');
  }
  const budget = (await svc.from('system_settings').select('value').eq('key', 'ai_global_monthly_budget_usd').maybeSingle()).data?.value;
  if (budget && s.ai_cost_usd > Number(budget) * 0.8) {
    add('ai_budget_near_limit', 'warning', s.ai_cost_usd, Number(budget), 'AI spend has passed 80% of the monthly budget.');
  }
  const cap = (await svc.from('system_settings').select('value').eq('key', 'acquisition_monthly_cap_usd').maybeSingle()).data?.value;
  if (cap !== undefined && cap !== null && s.acquisition_spend_usd > Number(cap)) {
    add('acquisition_cap_exceeded', 'critical', s.acquisition_spend_usd, Number(cap),
      'Acquisition spend is above the experiment spending cap. Pause paid acquisition until cohorts show payback.');
  }
  if (alerts.length) await svc.from('margin_alerts').upsert(alerts, { onConflict: 'month,alert_type' });
}

export async function computeCohorts(asOf: Date) {
  const svc = serviceClient();
  const acq = check(await svc.from('customer_acquisitions').select('user_id, cohort_month, channel, first_paid_at')
    .gte('cohort_month', ymd(addMonthsUtc(asOf, -24)))) as Row[];
  if (acq.length === 0) return 0;
  const userIds = acq.map((a) => String(a.user_id));
  const ents = check(await svc.from('entitlements').select('user_id, valid_until').eq('environment', 'PRODUCTION').in('user_id', userIds)) as Row[];
  const validUntil = new Map(ents.map((e) => [String(e.user_id), e.valid_until ? new Date(String(e.valid_until)).getTime() : 0]));
  const txs = check(await svc.from('revenue_transactions').select('user_id, kind, gross_usd, platform_fee_rate').eq('environment', 'PRODUCTION').in('user_id', userIds)) as Row[];
  const spend = check(await svc.from('acquisition_spend').select('month, channel, amount_usd')) as Row[];
  const settings = check(await svc.from('profit_model_settings').select('*').order('version', { ascending: false }).limit(1).single()) as Row;

  const groups = new Map<string, Row[]>();
  for (const a of acq) {
    const k = `${a.cohort_month}|${a.channel}`;
    groups.set(k, [...(groups.get(k) ?? []), a]);
  }
  const rows: Row[] = [];
  for (const [key, members] of groups) {
    const [cohort, channel] = key.split('|') as [string, string];
    const ids = new Set(members.map((m) => String(m.user_id)));
    const cohortSpend = spend.filter((s) => s.month === cohort && (s.channel === channel || (channel === 'paid_search' && s.channel === 'app_store_ads')))
      .reduce((a, s) => a + Number(s.amount_usd), 0);
    const retained = (days: number) => members.filter((m) => (validUntil.get(String(m.user_id)) ?? 0) >= new Date(String(m.first_paid_at)).getTime() + days * 86_400_000).length;
    const net = txs.filter((t) => ids.has(String(t.user_id))).reduce((a, t) => {
      const fee = t.platform_fee_rate === null ? Number(settings.default_platform_fee_rate) : Number(t.platform_fee_rate);
      return a + Number(t.gross_usd) * netReceiptsFactor(Number(settings.refund_reserve_rate), fee, Number(settings.revenuecat_rate));
    }, 0);
    const monthsElapsed = Math.max(1, (asOf.getUTCFullYear() - Number(cohort.slice(0, 4))) * 12 + asOf.getUTCMonth() - (Number(cohort.slice(5, 7)) - 1) + 1);
    const monthlyNet = net / monthsElapsed;
    rows.push({
      cohort_month: cohort, channel, as_of_month: ymd(asOf), new_paying: members.length, acquisition_spend_usd: money(cohortSpend),
      cac_usd: members.length ? money(cohortSpend / members.length) : null,
      retained_30d: retained(30), retained_90d: retained(90), retained_365d: retained(365),
      renewed_count: txs.filter((t) => ids.has(String(t.user_id)) && t.kind === 'renewal').length,
      cumulative_net_usd: money(net),
      payback_months: cohortSpend === 0 ? 0 : monthlyNet > 0 ? Math.round((cohortSpend / monthlyNet) * 100) / 100 : null,
    });
  }
  check(await svc.from('cohort_metrics').upsert(rows, { onConflict: 'cohort_month,channel,as_of_month' }));
  const breaches = rows.filter((r) => r.payback_months === null || Number(r.payback_months) > Number(settings.cac_payback_alert_months));
  if (breaches.length) {
    await svc.from('margin_alerts').upsert({
      month: ymd(asOf), alert_type: 'cac_payback_exceeded', severity: 'warning', metric_value: breaches.length,
      threshold: Number(settings.cac_payback_alert_months),
      message: `${breaches.length} acquisition cohort(s) have not recovered CAC within the payback threshold. Do not expand paid acquisition.`,
    }, { onConflict: 'month,alert_type' });
  }
  return rows.length;
}

/**
 * First-year cohort forecast (spec §10 launch gate). For each acquisition cohort,
 * project 12 paid months from its OBSERVED monthly retention and net receipts,
 * then compare after-tax profit per paid account-month with the target after the
 * full allocation (variable cost, CAC, fixed + founder + free subsidy).
 * It is a projection from early data, not a result.
 */
export async function cohortForecast() {
  const svc = serviceClient();
  const settings = check(await svc.from('profit_model_settings').select('*').order('version', { ascending: false }).limit(1).single()) as Row;
  const latest = check(await svc.from('profitability_snapshots').select('*').order('month', { ascending: false }).limit(1).maybeSingle()) as Row | null;
  const rows = check(await svc.from('cohort_metrics').select('*').order('as_of_month', { ascending: false })) as Row[];
  const latestByCohort = new Map<string, Row>();
  for (const r of rows) {
    const k = `${r.cohort_month}|${r.channel}`;
    if (!latestByCohort.has(k)) latestByCohort.set(k, r);
  }
  return forecastFromCohorts([...latestByCohort.values()], settings, latest, async (failing, target) => {
    await svc.from('margin_alerts').upsert({
      month: new Date().toISOString().slice(0, 8) + '01', alert_type: 'cohort_forecast_below_target', severity: 'warning',
      metric_value: failing, threshold: target,
      message: `${failing} cohort(s) are projected below the $${target} after-tax target in year one.`,
    }, { onConflict: 'month,alert_type' });
  });
}

/** Pure projection (unit-tested). */
export async function forecastFromCohorts(cohorts: Row[], settings: Row, latest: Row | null,
                                          onFailing?: (failing: number, target: number) => Promise<void>) {
  const t = Number(settings.tax_rate);
  const target = Number(settings.target_after_tax_usd);
  const N = Number(latest?.active_paying ?? 0);
  const fixedPerPaid = N > 0 ? (Number(latest?.fixed_cost_usd ?? 0) + Number(latest?.free_subsidy_usd ?? 0)) / N : null;
  const variablePerPaid = N > 0 ? Number(latest?.variable_paid_cost_usd ?? 0) / N : Number(settings.paid_variable_cost_floor);

  const forecasts = cohorts.map((c) => {
    const n = Number(c.new_paying);
    const asOf = new Date(String(c.as_of_month));
    const start = new Date(String(c.cohort_month));
    const months = Math.max(1, (asOf.getUTCFullYear() - start.getUTCFullYear()) * 12 + asOf.getUTCMonth() - start.getUTCMonth() + 1);
    const retainedNow = months >= 12 && c.retained_365d != null ? Number(c.retained_365d)
      : months >= 3 && c.retained_90d != null ? Number(c.retained_90d) : Number(c.retained_30d ?? n);
    const share = n > 0 ? Math.min(1, retainedNow / n) : 0;
    // Geometric monthly retention implied by what has been observed so far.
    const monthlyRetention = share <= 0 ? 0 : Math.pow(share, 1 / Math.max(1, Math.min(months, 12)));
    const sumMonths = (k: number) => Array.from({ length: k }, (_, i) => Math.pow(monthlyRetention, i)).reduce((a, b) => a + b, 0);
    const expectedPaidMonths = sumMonths(12);
    const observedPaidMonths = sumMonths(Math.min(months, 12));
    const netPerPaidMonth = n > 0 && observedPaidMonths > 0 ? Number(c.cumulative_net_usd) / n / observedPaidMonths : 0;
    const cac = Number(c.cac_usd ?? 0);
    const pretax = expectedPaidMonths > 0 ? netPerPaidMonth - variablePerPaid - cac / expectedPaidMonths - (fixedPerPaid ?? 0) : null;
    const afterTax = pretax === null ? null : pretax - Math.max(pretax, 0) * t;
    return {
      cohort_month: c.cohort_month, channel: c.channel, new_paying: n, months_observed: months,
      observed_retention_share: Math.round(share * 1000) / 1000,
      implied_monthly_retention: Math.round(monthlyRetention * 1000) / 1000,
      expected_paid_months_year1: Math.round(expectedPaidMonths * 100) / 100,
      net_receipts_per_paid_month_usd: Math.round(netPerPaidMonth * 100) / 100,
      cac_usd: cac,
      projected_after_tax_per_paid_month_usd: afterTax === null ? null : Math.round(afterTax * 100) / 100,
      meets_target: afterTax === null ? null : afterTax >= target,
      confidence: n < 30 || months < 3 ? 'low (small or young cohort)' : 'moderate',
    };
  });
  const failing = forecasts.filter((f) => f.meets_target === false && f.new_paying >= 10).length;
  if (failing && onFailing) await onFailing(failing, target);
  return {
    target_after_tax_usd: target,
    fixed_allocation_per_paid_usd: fixedPerPaid === null ? null : Math.round(fixedPerPaid * 100) / 100,
    variable_cost_per_paid_usd: Math.round(variablePerPaid * 100) / 100,
    forecasts,
    caveat: 'Projection from observed retention and receipts so far; early cohorts are noisy. Not a guarantee of profit.',
  };
}

/** Phase D launch gates (spec §10–§11), each with its evidence. null = not enough data yet. */
export async function launchGates() {
  const svc = serviceClient();
  const month = new Date().toISOString().slice(0, 8) + '01';
  const [snap, drill, health, alerts, forecast, cap, spend] = await Promise.all([
    svc.from('profitability_snapshots').select('*').order('month', { ascending: false }).limit(1).maybeSingle(),
    svc.from('restore_drills').select('passed, completed_at').eq('passed', true).order('completed_at', { ascending: false }).limit(1).maybeSingle(),
    svc.rpc('reminder_health'),
    svc.from('margin_alerts').select('alert_type, severity').is('acknowledged_at', null),
    cohortForecast(),
    svc.from('system_settings').select('value').eq('key', 'acquisition_monthly_cap_usd').maybeSingle(),
    svc.from('acquisition_spend').select('amount_usd').eq('month', month),
  ]);
  const s = snap.data as Row | null;
  const h = (health.data ?? {}) as Row;
  const drillAt = (drill.data as Row | null)?.completed_at as string | undefined;
  const drillFresh = Boolean(drillAt && Date.now() - new Date(drillAt).getTime() < 90 * 86_400_000);
  const monthSpend = ((spend.data ?? []) as Row[]).reduce((a, r) => a + Number(r.amount_usd), 0);
  const critical = ((alerts.data ?? []) as Row[]).filter((a) => a.severity === 'critical');
  const mature = forecast.forecasts.filter((f) => f.new_paying >= 10);
  const gate = (name: string, passed: boolean | null, evidence: unknown) => ({ name, passed, evidence });
  const gates = [
    gate('after_tax_profit_per_paid_month_meets_target', s && s.meets_target !== null ? Boolean(s.meets_target) : null,
      s ? { month: s.month, after_tax_per_paid_usd: s.after_tax_per_paid_usd, target: s.target_after_tax_usd } : 'no snapshot yet'),
    gate('cost_inputs_entered', s ? Number(s.fixed_cost_usd) > 0 : null, s ? { fixed_cost_usd: s.fixed_cost_usd } : 'no snapshot yet'),
    gate('first_year_cohort_forecast_clears_target', mature.length ? mature.every((f) => f.meets_target === true) : null,
      mature.length ? mature.map((f) => ({ cohort: f.cohort_month, channel: f.channel, projected: f.projected_after_tax_per_paid_month_usd }))
        : 'no cohort with 10+ paying customers yet'),
    gate('refund_rate_acceptable', s?.refund_rate == null ? null : Number(s.refund_rate) <= 0.08, { refund_rate: s?.refund_rate ?? null }),
    gate('acquisition_spend_within_cap', cap.data ? monthSpend <= Number(cap.data.value) : null, { month_spend_usd: monthSpend, cap_usd: cap.data?.value ?? null }),
    gate('restore_drill_passed_last_90_days', drillFresh, { last_passed_at: drillAt ?? null }),
    gate('reminder_handoff_within_5_minutes_99pct', h.within_5_min_24h_pct == null ? null : Number(h.within_5_min_24h_pct) >= 99,
      { within_5_min_24h_pct: h.within_5_min_24h_pct ?? null }),
    gate('no_open_critical_alerts', critical.length === 0, { open_critical: critical.map((a) => a.alert_type) }),
  ];
  return {
    ready: gates.every((g) => g.passed === true),
    gates,
    manual_gates: [
      'Real-device notification tests (permission denial, stale tokens, reinstall, long inactivity)',
      'Store disclosures: third-party AI data sharing and the account-deletion URL',
      'Observed beta with at least ten uncoached receipt-capture sessions',
      'Legal/privacy and security review',
      'Incident runbook reviewed',
    ],
    note: 'Do not expand paid acquisition until cohorts recover acquisition cost with an operating buffer.',
  };
}
