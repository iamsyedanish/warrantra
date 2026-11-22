-- Billing goes straight to Google Play (no RevenueCat).
--   * billing_events now also records Google Play real-time developer notifications.
--   * entitlements.original_transaction_id holds the Play purchase token; index it
--     so notifications can find the owning account.
--   * No third-party billing fee in the profit model any more.
alter table public.billing_events drop constraint if exists billing_events_provider_check;
alter table public.billing_events alter column provider set default 'google_play';
alter table public.billing_events add constraint billing_events_provider_check check (provider in ('revenuecat', 'google_play'));

create index if not exists entitlements_purchase_token_idx on public.entitlements (original_transaction_id)
  where original_transaction_id is not null;

update public.profit_model_settings set revenuecat_rate = 0 where revenuecat_rate <> 0;

update public.system_settings
   set description = 'Only entitlements from this Google Play environment grant access (licence-tester purchases are SANDBOX).'
 where key = 'billing_environment';
