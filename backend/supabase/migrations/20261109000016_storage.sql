-- =============================================================================
-- 0016 Supabase Storage: private buckets and operation-specific policies
--   * All buckets are private; files are served by short-lived signed URLs.
--   * Uploads are server-authorized (signed upload URLs created by the API after
--     the begin_attachment_upload reservation), so clients get NO direct
--     INSERT/UPDATE/DELETE policy on storage.objects.
--   * The SELECT policy checks the owning database record, not only a
--     user-chosen folder name.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('warranty-files', 'warranty-files', false, 10485760,
   array['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf']),
  ('exports', 'exports', false, 524288000, array['application/json', 'text/csv', 'application/zip']),
  ('claim-packs', 'claim-packs', false, 52428800, array['application/pdf', 'text/plain'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Read own ready originals (or those shared via a workspace) — tied to the attachments row.
create policy warranty_files_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'warranty-files'
    and exists (
      select 1 from public.attachments a
       where a.bucket = 'warranty-files'
         and a.storage_path = storage.objects.name
         and a.processing_state = 'ready'
         and a.deletion_state = 'active'
         and app_private.can_read_attachment(a.id)
    )
  );

create policy exports_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'exports'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (
      select 1 from public.export_jobs e
       where e.user_id = auth.uid()
         and e.state = 'ready'
         and e.expires_at > now()
         and (e.data_path = storage.objects.name or e.manifest_path = storage.objects.name)
    )
  );

create policy claim_packs_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'claim-packs'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (
      select 1 from public.claim_packs p
       where p.user_id = auth.uid() and p.storage_path = storage.objects.name
    )
  );
-- No INSERT / UPDATE / DELETE policies for authenticated or anon: default deny.
