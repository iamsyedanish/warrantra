-- Free plan: 5 items and 20 MB of storage (was 10 items and 100 MB).
--
-- Limits are versioned: version 1 is closed now and version 2 starts now, with
-- every other Free limit unchanged. Nothing is deleted. A Free account already
-- above the new limits keeps all its items and files; it just can't add more
-- (additions_paused) until it deletes some or upgrades. Pro is unchanged.

update public.plan_limits
   set effective_to = now()
 where plan_code = 'free' and version = 1 and effective_to is null;

insert into public.plan_limits (
  plan_code, version, effective_from, effective_to, max_items, storage_bytes, ai_actions_per_month, ai_lifetime_trial_actions,
  max_file_bytes, max_pdf_pages_stored, max_ai_pages_per_action, max_ai_input_chars, claim_pack_level, ai_claim_draft,
  workspaces_enabled, max_workspace_members, business_portfolio_enabled, email_forwarding_enabled, notes)
select plan_code, 2, now(), null, 5, 20 * 1024 * 1024, ai_actions_per_month, ai_lifetime_trial_actions,
       max_file_bytes, max_pdf_pages_stored, max_ai_pages_per_action, max_ai_input_chars, claim_pack_level, ai_claim_draft,
       workspaces_enabled, max_workspace_members, business_portfolio_enabled, email_forwarding_enabled,
       'Free tightened to 5 items / 20 MB (2026-11-28). Other Free limits unchanged from version 1.'
  from public.plan_limits
 where plan_code = 'free' and version = 1
on conflict (plan_code, version) do nothing;
