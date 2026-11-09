/**
 * Profit-first model (spec §10). Pure functions, unit-tested against the
 * spec's planning table. All inputs are assumptions until replaced by measured data.
 *
 *   Net receipts factor = (1 - r) × (1 - s) - c
 *   Pre-tax per paid    = P × factor - v - CAC/L - F/N
 *   After-tax           = pre-tax - max(pre-tax, 0) × t
 *   Min monthly price   = [target/(1-t) + v + CAC/L + F/N] / factor
 */
export interface ProfitInputs {
  /** Monthly gross price (annual price / 12 for annual subscribers). */
  monthlyPrice: number;
  refundReserve: number;      // r
  platformFee: number;        // s
  revenueCatRate: number;     // c
  variableCostPerPaid: number; // v (AI + infra + support)
  cacPerNewPayer: number;     // CAC = spend / NEW paying customers in the cohort
  cacRecoveryMonths: number;  // L
  fixedMonthly: number;       // fixed overhead + founder compensation
  freeAccounts: number;
  freeAccountMonthlyCost: number;
  activePaying: number;       // N
  taxRate: number;            // t
  targetAfterTax?: number;    // default 6
}

export interface ProfitResult {
  netReceiptsFactor: number;
  netReceiptsPerPaid: number;
  cacAllocationPerPaid: number;
  fixedAllocationPerPaid: number; // F/N where F includes free-user subsidy
  pretaxPerPaid: number;
  afterTaxPerPaid: number;
  meetsTarget: boolean;
  minMonthlyPriceForTarget: number;
  minAnnualPriceForTarget: number;
  breakEvenPayingForTarget: number | null;
}

const round = (n: number, d = 4) => Math.round(n * 10 ** d) / 10 ** d;

export function netReceiptsFactor(r: number, s: number, c: number): number {
  return (1 - r) * (1 - s) - c;
}

export function computeProfit(i: ProfitInputs): ProfitResult {
  const target = i.targetAfterTax ?? 6;
  const factor = netReceiptsFactor(i.refundReserve, i.platformFee, i.revenueCatRate);
  const F = i.fixedMonthly + i.freeAccounts * i.freeAccountMonthlyCost;
  const fixedPerPaid = i.activePaying > 0 ? F / i.activePaying : Infinity;
  const cacPerPaid = i.cacPerNewPayer / i.cacRecoveryMonths;
  const net = i.monthlyPrice * factor;
  const pretax = net - i.variableCostPerPaid - cacPerPaid - fixedPerPaid;
  const afterTax = pretax - Math.max(pretax, 0) * i.taxRate;
  const minMonthly = (target / (1 - i.taxRate) + i.variableCostPerPaid + cacPerPaid + fixedPerPaid) / factor;
  // N such that after-tax == target: F/N = net - v - CAC/L - target/(1-t)
  const headroom = net - i.variableCostPerPaid - cacPerPaid - target / (1 - i.taxRate);
  const breakEven = headroom > 0 ? Math.ceil(F / headroom) : null;
  return {
    netReceiptsFactor: round(factor),
    netReceiptsPerPaid: round(net, 2),
    cacAllocationPerPaid: round(cacPerPaid, 2),
    fixedAllocationPerPaid: round(fixedPerPaid, 2),
    pretaxPerPaid: round(pretax, 2),
    afterTaxPerPaid: round(afterTax, 2),
    meetsTarget: afterTax >= target,
    minMonthlyPriceForTarget: round(minMonthly, 2),
    minAnnualPriceForTarget: round(minMonthly * 12, 2),
    breakEvenPayingForTarget: breakEven,
  };
}

/** The spec's illustrative planning case (every value is an assumption). */
export const PLANNING_CASE: Omit<ProfitInputs, 'monthlyPrice' | 'platformFee'> = {
  refundReserve: 0.03,
  revenueCatRate: 0.01,
  variableCostPerPaid: 0.45,
  cacPerNewPayer: 15,
  cacRecoveryMonths: 12,
  fixedMonthly: 300 + 3000,
  freeAccounts: 10_000,
  freeAccountMonthlyCost: 0.02,
  activePaying: 2000,
  taxRate: 0.2,
  targetAfterTax: 6,
};
