-- =============================================================================
-- 0018 Service-role helper RPCs used by the API server and workers.
-- =============================================================================

create or replace function public.get_plan_limits_for_user(p_user_id uuid)
returns public.plan_limits
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_private.plan_limits_for(p_user_id);
$$;

create or replace function public.get_effective_plan_code(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_private.effective_plan_code(p_user_id);
$$;

-- AI spend this month (global when p_user_id is null) for budget alarms.
create or replace function public.get_ai_month_spend(p_user_id uuid default null)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_private.ai_month_spend_usd(p_user_id);
$$;

revoke all on function public.get_plan_limits_for_user(uuid) from public, anon, authenticated;
revoke all on function public.get_effective_plan_code(uuid) from public, anon, authenticated;
revoke all on function public.get_ai_month_spend(uuid) from public, anon, authenticated;
grant execute on function public.get_plan_limits_for_user(uuid) to service_role;
grant execute on function public.get_effective_plan_code(uuid) to service_role;
grant execute on function public.get_ai_month_spend(uuid) to service_role;

-- Server-ingested files (email forwarding): quota-checked atomically under the
-- same per-user storage lock as app uploads. The object must already be stored;
-- on refusal the caller deletes it.
create or replace function public.worker_register_server_attachment(
  p_user_id uuid, p_id uuid, p_path text, p_filename text, p_declared_mime text, p_verified_mime text,
  p_size bigint, p_pages integer, p_checksum text, p_source text
)
returns public.attachments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limits public.plan_limits;
  v_row public.attachments;
begin
  if (select account_state from public.profiles where id = p_user_id) is distinct from 'active' then
    raise exception 'account_not_active' using errcode = '42501';
  end if;
  perform app_private.lock_user(p_user_id, 'storage');
  v_limits := app_private.plan_limits_for(p_user_id);
  if p_size > v_limits.max_file_bytes then
    raise exception 'file_too_large:%', v_limits.max_file_bytes using errcode = 'P0001';
  end if;
  if app_private.storage_used_bytes(p_user_id) + p_size > v_limits.storage_bytes then
    raise exception 'quota_exceeded:storage_bytes:%', v_limits.storage_bytes using errcode = 'P0001';
  end if;
  insert into public.attachments (id, user_id, storage_path, file_type, original_filename, declared_mime_type, verified_mime_type,
                                  declared_byte_size, actual_byte_size, page_count, checksum_sha256, processing_state, verified_at, source)
  values (p_id, p_user_id, p_path, 'receipt', left(p_filename, 255), p_declared_mime, p_verified_mime, p_size, p_size, p_pages,
          p_checksum, 'ready', now(), p_source)
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public.worker_register_server_attachment(uuid, uuid, text, text, text, text, bigint, integer, text, text) from public, anon, authenticated;
grant execute on function public.worker_register_server_attachment(uuid, uuid, text, text, text, text, bigint, integer, text, text) to service_role;
