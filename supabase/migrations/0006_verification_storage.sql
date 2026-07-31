-- Covia - verification document storage
-- ------------------------------------------------------------------
-- Private bucket for identity documents (ID scans, selfies, student
-- cards). Unlike avatars this bucket is NOT public: documents can only
-- be uploaded by their owner into `verification/<user-id>/...` and are
-- readable only by the owner and admins. Objects are referenced in
-- verification_submissions by their path, and owners/admins fetch
-- signed URLs on demand.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'verification-documents',
  'verification-documents',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Owners may upload into their own folder only.
drop policy if exists "verification docs insert own folder" on storage.objects;
create policy "verification docs insert own folder"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'verification-documents'
    and (storage.foldername(name))[1] = 'verification'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

drop policy if exists "verification docs update own folder" on storage.objects;
create policy "verification docs update own folder"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'verification-documents'
    and (storage.foldername(name))[1] = 'verification'
    and (storage.foldername(name))[2] = auth.uid()::text
  )
  with check (
    bucket_id = 'verification-documents'
    and (storage.foldername(name))[1] = 'verification'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

drop policy if exists "verification docs delete own folder" on storage.objects;
create policy "verification docs delete own folder"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'verification-documents'
    and (storage.foldername(name))[1] = 'verification'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

-- Readable by the owner and by admins only.
drop policy if exists "verification docs owner read" on storage.objects;
create policy "verification docs owner read"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'verification-documents'
    and (storage.foldername(name))[1] = 'verification'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

drop policy if exists "verification docs admin read" on storage.objects;
create policy "verification docs admin read"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'verification-documents'
    and public.is_admin()
  );
