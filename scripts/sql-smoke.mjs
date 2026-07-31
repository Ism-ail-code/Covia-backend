/**
 * SQL smoke test for the Supabase migrations.
 *
 * Boots a scratch database in the local embedded PostgreSQL (see
 * `dev-db.mjs`) and applies every `supabase/migrations/*.sql` file,
 * stubbing the Supabase-managed schemas (`auth`, `storage`) that don't
 * exist in a vanilla Postgres. Then asserts the Phase 3 behaviours
 * (profiles, usernames, privacy, RLS) and the Phase 4 verification
 * behaviours (submissions, admin review, profile badges, notifications,
 * private document storage).
 *
 * Usage (with the embedded database running):
 *   node scripts/sql-smoke.mjs
 */

import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import pg from 'pg';

const { Client } = pg;

const DSN = 'postgresql://covia:covia_dev_password@localhost:5433';
const TEST_DB = 'covia_phase3_test';

let failures = 0;

function assert(condition, label, detail = '') {
  if (condition) {
    console.log(`  PASS  ${label}`);
  } else {
    failures += 1;
    console.error(`  FAIL  ${label}${detail ? ` â€” ${detail}` : ''}`);
  }
}

const STUBS = `
  create schema if not exists auth;
  create table if not exists auth.users (
    id uuid primary key,
    email text,
    email_confirmed_at timestamptz,
    raw_user_meta_data jsonb default '{}'::jsonb
  );
  create or replace function auth.uid()
  returns uuid language sql stable
  as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

  create schema if not exists storage;
  create table if not exists storage.buckets (
    id text primary key,
    name text,
    public boolean default false,
    file_size_limit bigint,
    allowed_mime_types text[]
  );
  create table if not exists storage.objects (
    id uuid primary key default gen_random_uuid(),
    bucket_id text,
    name text,
    owner uuid
  );
  create or replace function storage.foldername(name text)
  returns text[] language sql immutable
  as $$ select string_to_array(name, '/') $$;
  alter table storage.objects enable row level security;

  -- Mirrors Supabase's default grants; RLS still governs row access.
  grant usage on schema storage to authenticated, anon;
  grant all privileges on table storage.objects to authenticated, anon;
  grant all privileges on table storage.buckets to authenticated, anon;

  do $$ begin
    create role authenticated;
  exception when duplicate_object then null; end $$;
  do $$ begin
    create role anon;
  exception when duplicate_object then null; end $$;
`;

async function main() {
  const root = new Client({ connectionString: DSN });
  await root.connect();
  await root.query(`drop database if exists ${TEST_DB} with (force)`);
  await root.query(`create database ${TEST_DB} with encoding 'UTF8' template template0`);
  await root.end();

  const client = new Client({ connectionString: `${DSN}/${TEST_DB}` });
  await client.connect();
  await client.query(`set client_encoding to 'UTF8'`);
  await client.query(STUBS);

  const dir = path.resolve('supabase/migrations');
  const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
  for (const file of files) {
    const sql = readFileSync(path.join(dir, file), 'utf8');
    await client.query(sql);
    console.log(`Applied ${file}`);
  }

  const [user1, user2] = [crypto.randomUUID(), crypto.randomUUID()];

  // â”€â”€ Profile auto-creation on signup â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  await client.query(
    `insert into auth.users (id, email, raw_user_meta_data) values
       ($1, 'alice@example.com', '{"full_name":"Alice Example","phone":"+2348000000000"}'),
       ($2, 'bob@example.com', '{"full_name":"Bob Example"}')`,
    [user1, user2],
  );

  const created = await client.query(
    'select id, email, display_name, phone, rating, reliability_score, total_completed_rides, total_cancelled_rides, verification_status, is_government_id_verified, is_student_verified from public.profiles order by id',
  );
  assert(created.rowCount === 2, 'profiles auto-created for both signups');
  const row = created.rows.find((r) => r.id === user1);
  assert(row && row.display_name === 'Alice Example', 'display_name from signup metadata');
  assert(row && row.phone === '+2348000000000', 'phone from signup metadata');
  assert(row && Number(row.rating) === 5 && row.reliability_score === 90, 'default rating/reliability');
  assert(row && row.total_completed_rides === 0 && row.total_cancelled_rides === 0, 'ride metrics default to 0');
  assert(row && row.verification_status === 'Pending', 'verification status defaults to Pending');
  assert(row && row.is_government_id_verified === false && row.is_student_verified === false, 'verification flags default false');

  // â”€â”€ Username rules â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  await client.query(
    `update public.profiles set username = '  Alice_Example  ' where id = $1`,
    [user1],
  );
  const normalized = await client.query('select username from public.profiles where id = $1', [user1]);
  assert(normalized.rows[0].username === 'alice_example', 'username trimmed + lowercased');

  const dup = await client.query(
    `update public.profiles set username = 'alice_example' where id = $1`,
    [user2],
  ).then(() => null).catch((e) => e.code);
  assert(dup === '23505', 'duplicate username rejected (unique)');

  const reserved = await client.query(
    `update public.profiles set username = 'admin' where id = $1`,
    [user2],
  ).then(() => null).catch((e) => e.message ?? null);
  assert(typeof reserved === 'string' && reserved.includes('reserved'), 'reserved username rejected');

  const format = await client.query(
    `update public.profiles set username = 'ab' where id = $1`,
    [user2],
  ).then(() => null).catch((e) => e.code);
  assert(format === '23514', 'invalid username format rejected');

  await client.query(
    `update public.profiles set username = 'bob_02' where id = $1`,
    [user2],
  );

  // â”€â”€ Public/private split â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const cols = await client.query(
    `select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'public_profiles'`,
  );
  const names = cols.rows.map((c) => c.column_name);
  for (const secret of ['email', 'phone', 'date_of_birth', 'gender', 'emergency_contact_name', 'emergency_contact_phone', 'updated_at']) {
    assert(!names.includes(secret), `public_profiles hides ${secret}`);
  }
  for (const pub of ['username', 'display_name', 'profile_photo_url', 'city', 'country', 'overall_rating', 'reliability_score']) {
    assert(names.includes(pub), `public_profiles exposes ${pub}`);
  }

  const publicRow = await client.query(
    `select * from public.get_public_profile($1)`,
    [user1],
  );
  assert(publicRow.rowCount === 1 && publicRow.rows[0].username === 'alice_example', 'get_public_profile works for another user');

  const search = await client.query(`select username from public.search_profiles('ali')`);
  assert(search.rows.length === 1 && search.rows[0].username === 'alice_example', 'search_profiles by prefix');

  const avail = await client.query(`select public.is_username_available('alice_example') as taken, public.is_username_available('fresh_pick') as free, public.is_username_available('admin') as reserved`);
  assert(avail.rows[0].taken === false, 'taken username unavailable');
  assert(avail.rows[0].free === true, 'fresh username available');
  assert(avail.rows[0].reserved === false, 'reserved username unavailable');

  // â”€â”€ Emergency contacts â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  await client.query(
    `update public.profiles set
       emergency_contact_name = 'Mum', emergency_contact_phone = '+2348012345678', emergency_contact_relationship = 'Parent'
     where id = $1`,
    [user1],
  );
  const ec = await client.query('select emergency_contact_name, emergency_contact_phone, emergency_contact_relationship from public.profiles where id = $1', [user1]);
  assert(ec.rows[0].emergency_contact_name === 'Mum' && ec.rows[0].emergency_contact_phone === '+2348012345678', 'emergency contact saved');

  const partial = await client.query(
    `update public.profiles set emergency_contact_name = 'Only Name' where id = $1`,
    [user2],
  ).then(() => null).catch((e) => e.code);
  assert(partial === '23514', 'partial emergency contact rejected');

  await client.query(
    `update public.profiles set emergency_contact_name = null, emergency_contact_phone = null, emergency_contact_relationship = null where id = $1`,
    [user1],
  );
  const cleared = await client.query('select emergency_contact_name from public.profiles where id = $1', [user1]);
  assert(cleared.rows[0].emergency_contact_name === null, 'emergency contact removed');

  // â”€â”€ RLS: own row only â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  await client.query(`set role authenticated`);
  await client.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user1]);
  const own = await client.query('select id from public.profiles');
  assert(own.rowCount === 1 && own.rows[0].id === user1, 'authenticated user sees only own profile row');

  const otherUpdate = await client.query(
    `update public.profiles set bio = 'hacked' where id = $1`,
    [user2],
  );
  assert(otherUpdate.rowCount === 0, 'user cannot update another profile');

  const ownUpdate = await client.query(
    `update public.profiles set bio = 'hello from alice' where id = $1`,
    [user1],
  );
  assert(ownUpdate.rowCount === 1, 'user can update own profile');

  await client.query('reset role');
  await client.end();

  // â”€â”€ Storage bucket â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const bucket = await new Client({ connectionString: `${DSN}/${TEST_DB}` }).connect()
    .then((c) => c.query(`select id, public, file_size_limit from storage.buckets where id = 'avatars'`).then((r) => [c, r]))
    .then(([c, r]) => {
      const b = r.rows[0];
      assert(b && b.public === true, 'avatars bucket public');
      assert(b && Number(b.file_size_limit) === 5242880, 'avatars bucket size limit');
      return c;
    });
  await bucket.end();

  // â”€â”€ Phase 4: verification schema â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const vClient = new Client({ connectionString: `${DSN}/${TEST_DB}` });
  await vClient.connect();

  const vCols = await vClient.query(
    `select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'verification_submissions'`,
  );
  const vNames = vCols.rows.map((c) => c.column_name);
  for (const col of ['id', 'user_id', 'verification_type', 'government_id_kind', 'status', 'submitted_at', 'reviewed_at', 'reviewed_by', 'rejection_reason', 'front_document_url', 'back_document_url', 'selfie_url', 'student_card_url', 'university_email', 'created_at', 'updated_at']) {
    assert(vNames.includes(col), `verification_submissions has ${col}`);
  }

  const statusDef = await vClient.query(
    `select pg_get_constraintdef(oid) as def from pg_constraint
     where conrelid = 'public.verification_submissions'::regclass and contype = 'c'`,
  );
  assert(statusDef.rows.some((r) => r.def.includes("'expired'")), 'verification status check includes expired');

  // Make bob an admin; alice starts a government ID verification.
  await vClient.query(`insert into public.admin_users (user_id) values ($1)`, [user2]);
  await vClient.query(`set role authenticated`);
  await vClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user1]);

  const gov = await vClient.query(
    `select * from public.submit_verification('government_id', $1, $2, null, null, null, 'national_id')`,
    [`verification/${user1}/front.png`, `verification/${user1}/back.png`],
  );
  assert(gov.rowCount === 1 && gov.rows[0].status === 'pending', 'submit_verification creates a pending government ID request');
  assert(gov.rows[0].submitted_at !== null && gov.rows[0].government_id_kind === 'national_id', 'submitted_at + ID kind recorded');
  const govId = gov.rows[0].id;

  const dupSubmit = await vClient.query(
    `select public.submit_verification('government_id', 'verification/${user1}/front2.png', null, null, null, null, 'passport')`,
  ).then(() => null).catch((e) => e.code);
  assert(dupSubmit === '23505', 'duplicate active submission rejected');

  const noEvidence = await vClient.query(
    `select public.submit_verification('student')`,
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof noEvidence === 'string' && noEvidence.includes('student card'), 'student submission without evidence rejected');

  const stu = await vClient.query(
    `select * from public.submit_verification('student', null, null, null, null, 'alice@uni.edu.ng', null)`,
  );
  assert(stu.rowCount === 1 && stu.rows[0].status === 'pending', 'student verification by university email');
  const stuId = stu.rows[0].id;

  const ownSubs = await vClient.query(`select id from public.verification_submissions`);
  assert(ownSubs.rowCount === 2, 'user sees only their own submissions');

  const preVerified = await vClient.query(`select public.is_user_verified() as v`);
  assert(preVerified.rows[0].v === false, 'is_user_verified false before approval');

  const nonAdmin = await vClient.query(`select public.admin_list_verifications('pending')`)
    .then(() => null).catch((e) => e.code);
  assert(nonAdmin === '42501', 'non-admin blocked from review queue');

  // â”€â”€ Phase 4: admin review â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  await vClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user2]);
  const queue = await vClient.query(`select * from public.admin_list_verifications('pending')`);
  assert(queue.rowCount === 2, 'admin sees the pending queue');
  assert(queue.rows.some((r) => r.user_id === user1 && r.user_email === 'alice@example.com'), 'queue joins user email');

  const approved = await vClient.query(`select * from public.admin_review_verification($1, 'approve')`, [govId]);
  assert(approved.rows[0].status === 'approved' && approved.rows[0].reviewed_by === user2, 'approve flips status and records reviewer');

  await vClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user1]);
  const prof = await vClient.query(
    `select verification_status, is_government_id_verified, is_student_verified from public.profiles where id = $1`,
    [user1],
  );
  assert(prof.rows[0].verification_status === 'Verified', 'profile verification_status set to Verified on approval');
  assert(prof.rows[0].is_government_id_verified === true && prof.rows[0].is_student_verified === false, 'only the government flag flips');

  await vClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user2]);

  const noReason = await vClient.query(`select public.admin_review_verification($1, 'reject')`, [stuId])
    .then(() => null).catch((e) => `${e.code} | ${e.message}`);
  assert(typeof noReason === 'string' && noReason.includes('rejection reason'), `reject without a reason refused (got: ${noReason})`);

  const rejected = await vClient.query(`select * from public.admin_review_verification($1, 'reject', 'Unknown email domain')`, [stuId]);
  assert(rejected.rows[0].status === 'rejected' && rejected.rows[0].rejection_reason === 'Unknown email domain', 'reject with reason recorded');

  const notif = await vClient.query(
    `select event_type from public.notification_events where user_id = $1 order by created_at`,
    [user1],
  );
  assert(notif.rows.some((r) => r.event_type === 'verification.approved'), 'approval notification created');
  assert(notif.rows.some((r) => r.event_type === 'verification.rejected'), 'rejection notification created');

  // â”€â”€ Phase 4: resubmit + gates â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  await vClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user1]);
  const resub = await vClient.query(
    `select * from public.resubmit_verification($1, null, null, null, $2, null, null)`,
    [stuId, `verification/${user1}/card.png`],
  );
  assert(resub.rows[0].status === 'pending' && resub.rows[0].student_card_url === `verification/${user1}/card.png` && resub.rows[0].university_email === null, 'resubmit returns to pending with new evidence');

  const verifiedNow = await vClient.query(`select public.is_user_verified() as v`);
  assert(verifiedNow.rows[0].v === true, 'is_user_verified true after approval');

  const direct = await vClient.query(
    `insert into public.verification_submissions (user_id, verification_type, status) values ($1, 'government_id', 'pending')`,
    [user1],
  ).then(() => null).catch((e) => e.code);
  assert(direct === '42501', 'client cannot insert submissions directly');

  const auditAlice = await vClient.query(`select id from public.verification_audit`);
  assert(auditAlice.rowCount === 0, 'non-admin cannot read the audit trail');

  await vClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user2]);
  const audit = await vClient.query(`select count(*)::int as n from public.verification_audit`);
  assert(audit.rows[0].n >= 4, 'admin can read the audit trail');

  // â”€â”€ Phase 4: private document storage â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  await vClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user1]);
  const upOwn = await vClient.query(
    `insert into storage.objects (bucket_id, name) values ('verification-documents', $1)`,
    [`verification/${user1}/front.png`],
  ).then(() => null).catch((e) => e.code);
  assert(upOwn === null, 'owner can upload into own verification folder');

  const upOther = await vClient.query(
    `insert into storage.objects (bucket_id, name) values ('verification-documents', $1)`,
    [`verification/${user2}/front.png`],
  ).then(() => null).catch((e) => e.code);
  assert(upOther === '42501', 'cannot upload into another user folder');

  const upWrong = await vClient.query(
    `insert into storage.objects (bucket_id, name) values ('verification-documents', $1)`,
    [`${user1}/front.png`],
  ).then(() => null).catch((e) => e.code);
  assert(upWrong === '42501', 'documents must live under verification/<uid>/');

  const selOwn = await vClient.query(`select name from storage.objects where bucket_id = 'verification-documents'`);
  assert(selOwn.rowCount === 1, 'owner reads only own verification documents');

  await vClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user2]);
  const selAdmin = await vClient.query(`select name from storage.objects where bucket_id = 'verification-documents'`);
  assert(selAdmin.rowCount === 1, 'admin reads all verification documents');

  const vBucket = await vClient.query(`select public, file_size_limit from storage.buckets where id = 'verification-documents'`);
  assert(vBucket.rows[0].public === false, 'verification bucket is private');
  assert(Number(vBucket.rows[0].file_size_limit) === 10485760, 'verification bucket size limit');

  await vClient.query('reset role');
  await vClient.end();

  console.log(failures === 0 ? '\nAll checks passed.' : `\n${failures} check(s) FAILED.`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
