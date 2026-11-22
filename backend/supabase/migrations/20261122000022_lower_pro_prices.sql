-- Lower Pro to a price that clears $6 profit per subscriber per month for a
-- self-funded app: no paid acquisition, no founder salary, ~$5/month hosting.
-- With Google Play's 15% subscription fee, a 3% refund reserve and ~$0.25/month
-- of AI, storage and email per subscriber (measured AI is ~$0.004 per receipt):
--   A: $7.99/mo  -> ~$6.16 profit; $79.99/yr ($6.67/mo) -> ~$5.07 (yearly a bit lower)
--   B: $9.99/mo  -> ~$7.81 profit; $99.99/yr ($8.33/mo) -> ~$6.44 (also clears $6 at a 30% fee)
-- Only the draft experiment is touched; a running or finished one keeps its
-- prices so assigned users never see a price change mid-test.
update public.price_experiments
   set variants = '[{"code":"A","label":"Pro $79.99/yr or $7.99/mo","annual_price_usd":79.99,"monthly_price_usd":7.99,"revenuecat_offering":"pro_79","weight":1},
                    {"code":"B","label":"Pro $99.99/yr or $9.99/mo","annual_price_usd":99.99,"monthly_price_usd":9.99,"revenuecat_offering":"pro_99","weight":1}]'::jsonb
 where key = 'pro_price_v1' and status = 'draft';
