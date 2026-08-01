/**
 * SQL smoke test for the Supabase migrations.
 *
 * Boots a scratch database in the local embedded PostgreSQL (see
 * `dev-db.mjs`) and applies every `supabase/migrations/*.sql` file,
 * stubbing the Supabase-managed schemas (`auth`, `storage`) that don't
 * exist in a vanilla Postgres. Then asserts the Phase 3 behaviours
 * (profiles, usernames, privacy, RLS), the Phase 4 verification
 * behaviours (submissions, admin review, profile badges, notifications,
 * private document storage) and the Phase 5 ride behaviours (creation,
 * publishing, requests + approvals, capacity, lifecycle transitions,
 * search/discovery, timeline, RLS).
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

  // ── Phase 5: rides ─────────────────────────────────────────────────
  const rideClient = new Client({ connectionString: `${DSN}/${TEST_DB}` });
  await rideClient.connect();
  // Deterministic date handling: the JS assertions compare UTC dates, so
  // the session timezone is pinned to UTC (the server default on Supabase).
  await rideClient.query(`set timezone to 'UTC'`);
  await rideClient.query(`set role authenticated`);
  const asUser = (id) =>
    rideClient.query(`select set_config('request.jwt.claim.sub', $1, false)`, [id]);
  const t0 = new Date();
  const dep = (h) => new Date(t0.getTime() + h * 3600 * 1000).toISOString();
  const createRide = async (origin, dest, pickup, h, seats, fare = 'fixed', fixedFare = null, student = false, women = false) => {
    const r = await rideClient.query(
      `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, $5, $6, $7, null, null, $8, $9, $10, null, null, null)`,
      [
        JSON.stringify({ display_name: origin, latitude: 6.5, longitude: 3.36 }),
        JSON.stringify({ display_name: dest, latitude: 6.4, longitude: 3.42 }),
        JSON.stringify({ display_name: pickup, latitude: 6.52, longitude: 3.36 }),
        dep(h), seats, fare, fixedFare, student, women, 'bus_stop',
      ],
    );
    return r.rows[0];
  };
  const publishRide = async (id) => {
    const r = await rideClient.query(`select * from public.publish_ride($1)`, [id]);
    return r.rows[0];
  };
  const timelineEvents = async (rideId) => {
    const r = await rideClient.query(
      `select event_type from public.ride_timeline where ride_id = $1 order by created_at`,
      [rideId],
    );
    return r.rows.map((row) => row.event_type);
  };

  // Schema: rides / requests / participants / timeline columns.
  const rideCols = await rideClient.query(
    `select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'rides'`,
  );
  const rideNames = rideCols.rows.map((c) => c.column_name);
  for (const col of ['id', 'host_id', 'origin', 'destination', 'pickup_point', 'destination_point', 'origin_lat', 'origin_lng', 'destination_lat', 'destination_lng', 'origin_loc', 'destination_loc', 'pickup_point_loc', 'destination_point_loc', 'pickup_type', 'visible_at', 'smart_fare_details', 'departure_time', 'estimated_arrival', 'total_seats', 'available_seats', 'fare_mode', 'fixed_fare', 'ride_status', 'is_student_only', 'is_women_only', 'notes', 'created_at', 'updated_at']) {
    assert(rideNames.includes(col), `rides has ${col}`);
  }
  const reqCols = await rideClient.query(
    `select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'ride_requests'`,
  );
  const reqNames = reqCols.rows.map((c) => c.column_name);
  for (const col of ['id', 'ride_id', 'passenger_id', 'status', 'requested_at', 'responded_at']) {
    assert(reqNames.includes(col), `ride_requests has ${col}`);
  }
  const partCols = await rideClient.query(
    `select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'ride_participants'`,
  );
  const partNames = partCols.rows.map((c) => c.column_name);
  for (const col of ['ride_id', 'user_id', 'role', 'joined_at', 'left_at']) {
    assert(partNames.includes(col), `ride_participants has ${col}`);
  }
  const tlCols = await rideClient.query(
    `select column_name from information_schema.columns
     where table_schema = 'public' and table_name = 'ride_timeline'`,
  );
  const tlNames = tlCols.rows.map((c) => c.column_name);
  for (const col of ['id', 'ride_id', 'event_type', 'actor_id', 'metadata', 'created_at']) {
    assert(tlNames.includes(col), `ride_timeline has ${col}`);
  }
  const tlDef = await rideClient.query(
    `select pg_get_constraintdef(oid) as def from pg_constraint
     where conrelid = 'public.ride_timeline'::regclass and contype = 'c'`,
  );
  const tlEvents = ['created', 'published', 'requested', 'request_cancelled', 'approved', 'rejected', 'joined', 'left', 'ride_full', 'edited', 'started', 'completed', 'cancelled', 'dropped', 'expired'];
  assert(tlEvents.every((e) => tlDef.rows.some((r) => r.def.includes(`'${e}'`))), 'ride_timeline event_type check covers all 15 events');

  const grants = await rideClient.query(
    `select
       has_function_privilege('authenticated', 'public.create_ride(jsonb,jsonb,jsonb,timestamptz,integer,text,numeric,text,jsonb,boolean,boolean,text,timestamptz,timestamptz,jsonb)', 'execute') as auth_create,
       has_function_privilege('anon', 'public.create_ride(jsonb,jsonb,jsonb,timestamptz,integer,text,numeric,text,jsonb,boolean,boolean,text,timestamptz,timestamptz,jsonb)', 'execute') as anon_create,
       has_function_privilege('public', 'public.record_ride_event(uuid,text,uuid,jsonb)', 'execute') as pub_evt,
       has_function_privilege('authenticated', 'public.search_rides(text,text,date,time,integer,boolean,boolean,text,numeric,numeric,integer,integer,boolean)', 'execute') as auth_search`,
  );
  assert(grants.rows[0].auth_create === true, 'authenticated can execute create_ride');
  assert(grants.rows[0].anon_create === false, 'anon cannot execute create_ride');
  assert(grants.rows[0].pub_evt === false, 'record_ride_event revoked from public');
  assert(grants.rows[0].auth_search === true, 'authenticated can execute search_rides');

  // Make carol a verified user (bob is the admin who approves her).
  const user3 = crypto.randomUUID();
  await rideClient.query('reset role');
  await rideClient.query(
    `insert into auth.users (id, email, raw_user_meta_data) values
       ($1, 'carol@example.com', '{"full_name":"Carol Example"}')`,
    [user3],
  );
  await rideClient.query(`set role authenticated`);
  await asUser(user3);
  const cSub = await rideClient.query(
    `select * from public.submit_verification('government_id', $1, $2, null, null, null, 'national_id')`,
    [`verification/${user3}/front.png`, `verification/${user3}/back.png`],
  );
  await asUser(user2);
  await rideClient.query(`select * from public.admin_review_verification($1, 'approve')`, [cSub.rows[0].id]);
  await asUser(user3);
  const cVer = await rideClient.query(`select public.is_user_verified() as v`);
  assert(cVer.rows[0].v === true, 'carol verified after admin approval');

  // Unverified users cannot create rides or request seats.
  await asUser(user2);
  const locJson = (name) => JSON.stringify({ display_name: name, latitude: 6.5, longitude: 3.36 });
  const unverCreate = await rideClient.query(
    `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, 3, 'fixed', 1500, null, null, false, false, 'bus_stop')`,
    [locJson('Ikeja'), locJson('VI'), locJson('Jibowu'), dep(10)],
  ).then(() => null).catch((e) => e);
  assert(unverCreate && typeof unverCreate.message === 'string' && unverCreate.message.includes('verified'), 'unverified user cannot create a ride');

  // Create validation (verified host).
  await asUser(user1);
  const vPast = await rideClient.query(
    `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, 3, 'fixed', 1500, null, null, false, false, 'bus_stop')`,
    [locJson('Ikeja'), locJson('VI'), locJson('Jibowu'), new Date(t0.getTime() - 3600 * 1000).toISOString()],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof vPast === 'string' && vPast.includes('future'), 'past departure rejected');
  const vOrigin = await rideClient.query(
    `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, 3, 'fixed', 1500, null, null, false, false, 'bus_stop')`,
    [locJson(''), locJson('VI'), locJson('Jibowu'), dep(10)],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof vOrigin === 'string' && vOrigin.includes('Origin'), 'empty origin rejected');
  const vSeats = await rideClient.query(
    `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, 0, 'fixed', 1500, null, null, false, false, 'bus_stop')`,
    [locJson('Ikeja'), locJson('VI'), locJson('Jibowu'), dep(10)],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof vSeats === 'string' && vSeats.includes('between 1 and 10'), 'zero seats rejected');
  const vSeatsBig = await rideClient.query(
    `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, 11, 'fixed', 1500, null, null, false, false, 'bus_stop')`,
    [locJson('Ikeja'), locJson('VI'), locJson('Jibowu'), dep(10)],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof vSeatsBig === 'string' && vSeatsBig.includes('between 1 and 10'), 'eleven seats rejected');
  const vNoFare = await rideClient.query(
    `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, 3, 'fixed', null, null, null, false, false, 'bus_stop')`,
    [locJson('Ikeja'), locJson('VI'), locJson('Jibowu'), dep(10)],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof vNoFare === 'string' && vNoFare.includes('per-seat fare'), 'fixed fare missing rejected');
  const vSmartFare = await rideClient.query(
    `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, 3, 'smart', 1500, null, null, false, false, 'bus_stop')`,
    [locJson('Ikeja'), locJson('VI'), locJson('Jibowu'), dep(10)],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof vSmartFare === 'string' && vSmartFare.includes('Smart fares'), 'smart fare with amount rejected');
  const vStudent = await rideClient.query(
    `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, 3, 'fixed', 1500, null, null, $5, $6, 'bus_stop')`,
    [locJson('Ikeja'), locJson('VI'), locJson('Jibowu'), dep(10), true, false],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof vStudent === 'string' && vStudent.includes('verified students'), 'student-only ride requires verified student');

  // Ride A: create + publish.
  const aRow = await createRide('Ikeja', 'Victoria Island', 'Jibowu Bus Stop', 10, 3, 'fixed', 1500);
  const aId = aRow.id;
  assert(aRow.ride_status === 'draft' && Number(aRow.available_seats) === 3 && Number(aRow.fixed_fare) === 1500, 'create_ride returns a draft with full seats');
  assert(JSON.stringify(await timelineEvents(aId)) === JSON.stringify(['created']), 'timeline starts with created');
  const pubA = await publishRide(aId);
  assert(pubA.ride_status === 'published', 'publish_ride flips draft to published');
  const aParts = await rideClient.query(
    `select * from public.get_ride_participants($1)`,
    [aId],
  );
  assert(aParts.rowCount === 1 && aParts.rows[0].role === 'Host' && aParts.rows[0].user_id === user1, 'host joins as participant on publish');
  assert(JSON.stringify(await timelineEvents(aId)) === JSON.stringify(['created', 'published']), 'publish event recorded');
  const repub = await rideClient.query(`select * from public.publish_ride($1)`, [aId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof repub === 'string' && repub.includes('Only draft rides'), 'republishing a published ride rejected');
  await asUser(user2);
  const notHostPub = await rideClient.query(`select * from public.publish_ride($1)`, [aId])
    .then(() => null).catch((e) => e.code);
  assert(notHostPub === '42501', 'non-host cannot publish');

  // Request workflow on A.
  await asUser(user2);
  const unverReq = await rideClient.query(`select * from public.request_to_join($1)`, [aId])
    .then(() => null).catch((e) => e);
  assert(unverReq && typeof unverReq.message === 'string' && unverReq.message.includes('verified'), 'unverified user cannot request to join');
  await asUser(user3);
  const reqA = await rideClient.query(`select * from public.request_to_join($1)`, [aId]);
  assert(reqA.rows[0].status === 'pending', 'carol request to join creates a pending request');
  const dupReq = await rideClient.query(`select * from public.request_to_join($1)`, [aId])
    .then(() => null).catch((e) => e.code);
  assert(dupReq === '23505', 'duplicate pending request rejected');
  await asUser(user2);
  const nonHostRespond = await rideClient.query(
    `select * from public.host_respond_to_request($1, true, null)`,
    [reqA.rows[0].id],
  ).then(() => null).catch((e) => e.code);
  assert(nonHostRespond === '42501', 'non-host cannot respond to a request');
  await asUser(user1);
  const okA = await rideClient.query(
    `select * from public.host_respond_to_request($1, true, null)`,
    [reqA.rows[0].id],
  );
  assert(okA.rows[0].status === 'approved', 'host approval flips request to approved');
  const aAvail = await rideClient.query(`select available_seats from public.rides where id = $1`, [aId]);
  assert(Number(aAvail.rows[0].available_seats) === 2, 'approval decrements available seats');
  const aEvents = await timelineEvents(aId);
  assert(aEvents.includes('approved') && aEvents.includes('joined'), 'approval records approved + joined events');
  await asUser(user3);
  const alreadyOn = await rideClient.query(`select * from public.request_to_join($1)`, [aId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof alreadyOn === 'string' && alreadyOn.includes('already on this ride'), 'approved passenger cannot re-request the same ride');

  // Ride B: overlap blocks carol (she holds a seat on A).
  await asUser(user1);
  const bRow = await createRide('Ikeja', 'VI', 'Jibowu', 12, 3, 'fixed', 1800);
  const bId = bRow.id;
  await publishRide(bId);
  await asUser(user3);
  const overlapPart = await rideClient.query(`select * from public.request_to_join($1)`, [bId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof overlapPart === 'string' && overlapPart.includes('already have a seat'), 'overlapping ride blocked for an existing passenger');

  // Bob becomes verified; pending-request overlap is blocked via C.
  await rideClient.query('reset role');
  await rideClient.query(
    `insert into public.verification_submissions (user_id, verification_type, status, government_id_kind, front_document_url)
     values ($1, 'government_id', 'approved', 'national_id', $2)`,
    [user2, `verification/${user2}/front.png`],
  );
  await rideClient.query(
    `update public.profiles set is_government_id_verified = true, verification_status = 'Verified' where id = $1`,
    [user2],
  );
  await rideClient.query(
    `update public.profiles set is_student_verified = true, verification_status = 'Verified' where id = $1`,
    [user1],
  );
  await rideClient.query(
    `update public.profiles set username = 'carol_03' where id = $1`,
    [user3],
  );
  await rideClient.query(`set role authenticated`);
  await asUser(user2);
  const reqB1 = await rideClient.query(`select * from public.request_to_join($1)`, [bId]);
  assert(reqB1.rows[0].status === 'pending', 'verified bob can request a seat on B');
  await asUser(user1);
  const cRow = await createRide('Ikeja', 'Lekki', 'Marina', 16, 3, 'fixed', 2200);
  const cId = cRow.id;
  await publishRide(cId);
  await asUser(user2);
  const overlapReq = await rideClient.query(`select * from public.request_to_join($1)`, [cId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof overlapReq === 'string' && overlapReq.includes('already have a request'), 'pending request blocks an overlapping ride');

  // Withdraw + reject workflow.
  const bReq1Id = reqB1.rows[0].id;
  await asUser(user3);
  const otherCancel = await rideClient.query(`select * from public.cancel_ride_request($1)`, [bReq1Id])
    .then(() => null).catch((e) => e.code);
  assert(otherCancel === '42501', 'another user cannot withdraw a request');
  await asUser(user2);
  const cancel1 = await rideClient.query(`select * from public.cancel_ride_request($1)`, [bReq1Id]);
  assert(cancel1.rows[0].status === 'cancelled' && cancel1.rows[0].responded_at !== null, 'passenger can withdraw a pending request');
  const cancelAgain = await rideClient.query(`select * from public.cancel_ride_request($1)`, [bReq1Id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof cancelAgain === 'string' && cancelAgain.includes('Only pending requests'), 'withdrawing twice rejected');
  const reqB2 = await rideClient.query(`select * from public.request_to_join($1)`, [bId]);
  await asUser(user1);
  const rejB = await rideClient.query(
    `select * from public.host_respond_to_request($1, false, 'Not the right fit')`,
    [reqB2.rows[0].id],
  );
  assert(rejB.rows[0].status === 'rejected' && rejB.rows[0].responded_at !== null, 'host rejection recorded with response time');
  const bEvents = await timelineEvents(bId);
  for (const ev of ['created', 'published', 'requested', 'request_cancelled', 'rejected']) {
    assert(bEvents.includes(ev), `ride B timeline includes ${ev}`);
  }

  // Editing rules.
  const editedSeats = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, $2, null, null)`,
    [bId, 4],
  );
  assert(Number(editedSeats.rows[0].total_seats) === 4 && Number(editedSeats.rows[0].available_seats) === 4, 'seat increase recalculates available seats');
  const pastEdit = await rideClient.query(
    `select * from public.update_ride($1, $2, null, null, null, null, null)`,
    [bId, new Date(t0.getTime() - 3600 * 1000).toISOString()],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof pastEdit === 'string' && pastEdit.includes('future'), 'editing departure to the past rejected');
  const badSeats = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, $2, null, null)`,
    [bId, 0],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof badSeats === 'string' && badSeats.includes('between 1 and 10'), 'editing seats out of range rejected');
  const smartEdit = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, null, $2, null)`,
    [bId, 'smart'],
  );
  assert(smartEdit.rows[0].fare_mode === 'smart' && smartEdit.rows[0].fixed_fare === null, 'switching to smart fare clears the fixed amount');
  const fixedEdit = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, null, $2, $3)`,
    [bId, 'fixed', 2000],
  );
  assert(fixedEdit.rows[0].fare_mode === 'fixed' && Number(fixedEdit.rows[0].fixed_fare) === 2000, 'switching back to fixed fare sets the amount');
  await asUser(user2);
  const notHostEdit = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, $2, null, null)`,
    [bId, 5],
  ).then(() => null).catch((e) => e.code);
  assert(notHostEdit === '42501', 'non-host cannot edit a ride');

  // Ride D: capacity, full status, leave.
  await asUser(user1);
  const dRow = await createRide('Ikeja', 'VI', 'Jibowu', 20, 1, 'fixed', 1000);
  const dId = dRow.id;
  await publishRide(dId);
  await asUser(user3);
  const reqD = await rideClient.query(`select * from public.request_to_join($1)`, [dId]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [reqD.rows[0].id]);
  const fullD = await rideClient.query(`select ride_status, available_seats from public.rides where id = $1`, [dId]);
  assert(fullD.rows[0].ride_status === 'full' && Number(fullD.rows[0].available_seats) === 0, 'last seat approval auto-flips ride to full');
  const dEvents = await timelineEvents(dId);
  assert(dEvents.includes('ride_full'), 'ride_full event recorded');
  await asUser(user2);
  const fullReq = await rideClient.query(`select * from public.request_to_join($1)`, [dId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof fullReq === 'string' && fullReq.includes('full'), 'requesting a full ride rejected');
  await asUser(user3);
  const leaveD = await rideClient.query(`select * from public.leave_ride($1)`, [dId]);
  assert(leaveD.rows[0].ride_status === 'published' && Number(leaveD.rows[0].available_seats) === 1, 'leaving frees a seat and re-opens the ride');
  const dLeft = await rideClient.query(
    `select left_at from public.ride_participants where ride_id = $1 and user_id = $2`,
    [dId, user3],
  );
  assert(dLeft.rows[0].left_at !== null, 'departure marked on the participant row');
  assert((await timelineEvents(dId)).includes('left'), 'left event recorded');
  await asUser(user2);
  const reqD2 = await rideClient.query(`select * from public.request_to_join($1)`, [dId]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [reqD2.rows[0].id]);
  const fullAgain = await rideClient.query(`select ride_status from public.rides where id = $1`, [dId]);
  assert(fullAgain.rows[0].ride_status === 'full', 'bob approval re-fills ride D');

  // Lifecycle: start → complete (host only), cancel rules.
  await asUser(user2);
  const bobStart = await rideClient.query(`select * from public.start_ride($1)`, [dId])
    .then(() => null).catch((e) => e.code);
  assert(bobStart === '42501', 'non-host cannot start a ride');
  await asUser(user1);
  const started = await rideClient.query(`select * from public.start_ride($1)`, [dId]);
  assert(started.rows[0].ride_status === 'in_progress', 'start_ride moves to in_progress');
  assert((await timelineEvents(dId)).includes('started'), 'started event recorded');
  const startAgain = await rideClient.query(`select * from public.start_ride($1)`, [dId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof startAgain === 'string' && startAgain.includes('Only published rides'), 'starting twice rejected');
  const completed = await rideClient.query(`select * from public.complete_ride($1)`, [dId]);
  assert(completed.rows[0].ride_status === 'completed', 'complete_ride finishes the ride');
  assert((await timelineEvents(dId)).includes('completed'), 'completed event recorded');
  const cancelStarted = await rideClient.query(`select * from public.cancel_ride($1)`, [dId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof cancelStarted === 'string' && cancelStarted.includes('cannot be cancelled'), 'cancelling a started ride rejected');
  await rideClient.query('reset role');
  const counters = await rideClient.query(
    `select id, total_completed_rides, total_cancelled_rides from public.profiles
     where id in ($1, $2, $3) order by id`,
    [user1, user2, user3],
  );
  await rideClient.query(`set role authenticated`);
  await asUser(user1);
  const counterRow = (id) => counters.rows.find((r) => r.id === id);
  assert(Number(counterRow(user1).total_completed_rides) === 1, 'host completed counter incremented');
  assert(Number(counterRow(user2).total_completed_rides) === 1, 'riding passenger completed counter incremented');
  assert(Number(counterRow(user3).total_completed_rides) === 0, 'passenger who left is not counted as completed');

  // Cancel A (host), then the guards around a cancelled ride.
  const cancelledA = await rideClient.query(`select * from public.cancel_ride($1)`, [aId]);
  assert(cancelledA.rows[0].ride_status === 'cancelled', 'cancel_ride ends a published ride');
  assert((await timelineEvents(aId)).includes('cancelled'), 'cancelled event recorded');
  const cancelTwice = await rideClient.query(`select * from public.cancel_ride($1)`, [aId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof cancelTwice === 'string' && cancelTwice.includes('already cancelled'), 'cancelling twice rejected');
  const startCancelled = await rideClient.query(`select * from public.start_ride($1)`, [aId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof startCancelled === 'string' && startCancelled.includes('Only published rides'), 'cancelled ride cannot be started');
  const editCancelled = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, $2, null, null)`,
    [aId, 5],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof editCancelled === 'string' && editCancelled.includes('can no longer be edited'), 'cancelled ride cannot be edited');

  // Ride E: seat floor — cannot drop below the approved headcount.
  const eRow = await createRide('Ikeja', 'VI', 'Jibowu', 23, 3, 'fixed', 1500);
  const eId = eRow.id;
  await publishRide(eId);
  await asUser(user3);
  const reqE1 = await rideClient.query(`select * from public.request_to_join($1)`, [eId]);
  await asUser(user2);
  const reqE2 = await rideClient.query(`select * from public.request_to_join($1)`, [eId]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [reqE1.rows[0].id]);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [reqE2.rows[0].id]);
  const floorOk = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, $2, null, null)`,
    [eId, 2],
  );
  assert(floorOk.rows[0].ride_status === 'full' && Number(floorOk.rows[0].available_seats) === 0, 'reducing seats to the approved headcount is allowed (ride full)');
  const floorEdit = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, $2, null, null)`,
    [eId, 1],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof floorEdit === 'string' && floorEdit.includes('approved passengers'), 'seats cannot drop below approved passengers');
  await asUser(user3);
  await rideClient.query(`select * from public.leave_ride($1)`, [eId]);
  await asUser(user2);
  await rideClient.query(`select * from public.leave_ride($1)`, [eId]);
  await asUser(user1);
  const shrinkE = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, $2, null, null)`,
    [eId, 1],
  );
  assert(Number(shrinkE.rows[0].total_seats) === 1 && Number(shrinkE.rows[0].available_seats) === 1, 'seat reduction allowed after passengers left');

  // Ride F: full ride re-opened by seat increase.
  const fRow = await createRide('Ikeja', 'VI', 'Jibowu', 24, 1, 'fixed', 1200);
  const fId = fRow.id;
  await publishRide(fId);
  await asUser(user3);
  const reqF = await rideClient.query(`select * from public.request_to_join($1)`, [fId]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [reqF.rows[0].id]);
  const growF = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, $2, null, null)`,
    [fId, 2],
  );
  assert(growF.rows[0].ride_status === 'published' && Number(growF.rows[0].available_seats) === 1, 'adding a seat re-opens a full ride');

  // Student-only + women-only rides (alice is now a verified student).
  const gRow = await createRide('Ikeja', 'VI', 'Marina', 26, 2, 'fixed', 800, true, false);
  const gId = gRow.id;
  await publishRide(gId);
  assert(gRow.is_student_only === true, 'student-only ride created by verified student');
  const hRow = await createRide('Ikeja', 'VI', 'Marina', 27, 2, 'fixed', 900, false, true);
  const hId = hRow.id;
  await publishRide(hId);
  assert(hRow.is_women_only === true, 'women-only ride created');

  // Ride I: cancelling closes pending requests.
  const iRow = await createRide('Ikeja', 'VI', 'Marina', 30, 2, 'fixed', 1300);
  const iId = iRow.id;
  await publishRide(iId);
  await asUser(user3);
  const reqI = await rideClient.query(`select * from public.request_to_join($1)`, [iId]);
  assert(reqI.rows[0].status === 'pending', 'carol can request a ride 6h after her other ride');
  await asUser(user1);
  await rideClient.query(`select * from public.cancel_ride($1)`, [iId]);
  const closedReq = await rideClient.query(`select status, responded_at from public.ride_requests where id = $1`, [reqI.rows[0].id]);
  assert(closedReq.rows[0].status === 'cancelled' && closedReq.rows[0].responded_at !== null, 'cancelling the ride closes pending requests');
  const iEvents = await timelineEvents(iId);
  assert(iEvents.includes('requested') && iEvents.includes('cancelled'), 'ride I timeline shows request then cancel');

  // Draft ride J (never published).
  const jRow = await createRide('Ikeja', 'Badagry', 'Mile 2', 28, 3, 'fixed', 2000);
  const jId = jRow.id;

  // Search & discovery.
  const searchRides = async (origin = null, dest = null, date = null, timeFrom = null, seats = null, student = null, women = null, sort = null, page = 1, pageSize = 20) => {
    const r = await rideClient.query(
      `select * from public.search_rides($1, $2, $3, $4, $5, $6, $7, $8, null, null, $9, $10)`,
      [origin, dest, date, timeFrom, seats, student, women, sort, page, pageSize],
    );
    return r.rows;
  };
  await asUser(user3);
  const allSearch = await searchRides();
  assert(allSearch.length === 6 && Number(allSearch[0].total_count) === 6, 'search returns only published/full rides (6)');
  const ikejaSearch = await searchRides('ikeja');
  assert(ikejaSearch.length === 6, 'origin filter matches case-insensitively');
  const missSearch = await searchRides('Lagos');
  assert(missSearch.length === 0, 'no matches for unknown origin');
  const destSearch = await searchRides(null, 'lekki');
  assert(destSearch.length === 1 && destSearch[0].id === cId, 'destination filter narrows results');
  const destSearch2 = await searchRides(null, 'VI');
  assert(destSearch2.length === 5, 'destination filter with multiple matches');
  const seatSearch = await searchRides(null, null, null, null, 2);
  assert(seatSearch.length === 4, 'available seats filter applies');
  const stuSearch = await searchRides(null, null, null, null, null, true);
  assert(stuSearch.length === 1 && stuSearch[0].id === gId, 'student-only filter');
  const womSearch = await searchRides(null, null, null, null, null, null, true);
  assert(womSearch.length === 1 && womSearch[0].id === hId, 'women-only filter');
  const nonStuSearch = await searchRides(null, null, null, null, null, false);
  assert(nonStuSearch.length === 5, 'non-student rides returned when filter is false');
  const recentSearch = await searchRides(null, null, null, null, null, null, null, 'recent');
  assert(recentSearch[0].id === hId, 'sort by recent returns newest first');
  const depSearch = await searchRides(null, null, null, null, null, null, null, 'departure');
  assert(depSearch[0].id === bId, 'sort by departure returns soonest first');
  const distSearch = await searchRides(null, null, null, null, null, null, null, 'distance');
  assert(distSearch.length === 6, 'distance sort without coordinates falls back to departure');
  const page1 = await searchRides(null, null, null, null, null, null, null, null, 1, 2);
  const page2 = await searchRides(null, null, null, null, null, null, null, null, 2, 2);
  const page3 = await searchRides(null, null, null, null, null, null, null, null, 3, 2);
  const page4 = await searchRides(null, null, null, null, null, null, null, null, 4, 2);
  assert(page1.length === 2 && page2.length === 2 && page3.length === 2 && page4.length === 0, 'pagination pages over results');
  assert(Number(page1[0].total_count) === 6, 'total_count stable across pages');
  const gDate = dep(26).slice(0, 10);
  const dateSearch = await searchRides(null, null, gDate);
  assert(dateSearch.every((r) => r.departure_time.toISOString().slice(0, 10) === gDate), 'date filter only returns that day');
  const timeSearch = await searchRides(null, null, null, '00:00:00');
  assert(timeSearch.length === 6, 'time-from filter at midnight matches everything');
  assert(allSearch.every((r) => r.host_username === 'alice_example'), 'search joins host public profile');

  // Ride detail.
  const detailA = await rideClient.query(`select * from public.get_ride($1)`, [aId]);
  assert(detailA.rowCount === 1 && detailA.rows[0].ride_status === 'cancelled' && detailA.rows[0].host_username === 'alice_example', 'cancelled ride still visible to anyone');
  const draftHidden = await rideClient.query(`select * from public.get_ride($1)`, [jId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof draftHidden === 'string' && draftHidden.includes('Ride not found'), 'draft ride hidden from non-hosts');
  const missingRide = await rideClient.query(`select * from public.get_ride($1)`, [crypto.randomUUID()])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof missingRide === 'string' && missingRide.includes('Ride not found'), 'unknown ride id rejected');
  await asUser(user1);
  const draftOwn = await rideClient.query(`select * from public.get_ride($1)`, [jId]);
  assert(draftOwn.rowCount === 1 && draftOwn.rows[0].ride_status === 'draft', 'host sees their own draft');

  // Participants / requests / timeline RPCs.
  await asUser(user3);
  const fParts = await rideClient.query(`select * from public.get_ride_participants($1)`, [fId]);
  assert(fParts.rowCount === 2 && fParts.rows[0].role === 'Host' && fParts.rows[0].username === 'alice_example' && fParts.rows[1].username === 'carol_03', 'participants list with host first');
  await asUser(user2);
  const nonMemberParts = await rideClient.query(`select * from public.get_ride_participants($1)`, [fId])
    .then(() => null).catch((e) => e.code);
  assert(nonMemberParts === '42501', 'non-member cannot list participants');
  await asUser(user1);
  const bRequests = await rideClient.query(`select * from public.get_ride_requests($1)`, [bId]);
  assert(bRequests.rowCount === 2, 'host sees both requests on B');
  assert(bRequests.rows.every((r) => r.passenger_username === 'bob_02'), 'request queue joins passenger profile');
  assert(bRequests.rows.some((r) => r.status === 'cancelled') && bRequests.rows.some((r) => r.status === 'rejected'), 'request queue shows all statuses');
  await asUser(user2);
  const nonHostQueue = await rideClient.query(`select * from public.get_ride_requests($1)`, [bId])
    .then(() => null).catch((e) => e.code);
  assert(nonHostQueue === '42501', 'non-host cannot read the request queue');
  await asUser(user1);
  const aTimeline = await timelineEvents(aId);
  for (const ev of ['created', 'published', 'requested', 'approved', 'joined', 'cancelled']) {
    assert(aTimeline.includes(ev), `ride A timeline includes ${ev}`);
  }
  await asUser(user3);
  const fEvents = await timelineEvents(fId);
  const fExpected = ['created', 'published', 'requested', 'approved', 'joined', 'ride_full', 'edited'];
  assert(JSON.stringify([...fEvents].sort()) === JSON.stringify([...fExpected].sort()), 'ride F timeline contains every event');
  const fTl = await rideClient.query(`select event_type, created_at from public.get_ride_timeline($1)`, [fId]);
  const fTimes = fTl.rows.map((r) => r.created_at.getTime());
  assert(fTimes.every((t, i) => i === 0 || t >= fTimes[i - 1]), 'timeline events are time-ordered');
  await asUser(user2);
  const nonMemberTl = await rideClient.query(`select * from public.get_ride_timeline($1)`, [fId])
    .then(() => null).catch((e) => e.code);
  assert(nonMemberTl === '42501', 'non-member cannot read the timeline');

  // RLS on direct reads/writes.
  await asUser(user3);
  const draftCount = await rideClient.query(`select count(*)::int as n from public.rides where ride_status = 'draft'`);
  assert(draftCount.rows[0].n === 0, 'draft rides invisible to non-hosts');
  const nonDraftCount = await rideClient.query(`select count(*)::int as n from public.rides where ride_status <> 'draft'`);
  assert(nonDraftCount.rows[0].n === 9, 'all non-draft rides visible to authenticated users');
  const directUpdate = await rideClient.query(`update public.rides set ride_status = 'completed' where id = $1`, [fId])
    .then(() => null).catch((e) => e.code);
  assert(directUpdate === '42501', 'client cannot update rides directly');
  const directInsert = await rideClient.query(
    `insert into public.rides (host_id, origin, destination, pickup_point, departure_time, total_seats, available_seats, fare_mode, fixed_fare)
     values ($1, 'X', 'Y', 'Z', now() + interval '1 day', 2, 2, 'fixed', 500)`,
    [user1],
  ).then(() => null).catch((e) => e.code);
  assert(directInsert === '42501', 'RLS blocks direct ride inserts');
  const directReq = await rideClient.query(
    `insert into public.ride_requests (ride_id, passenger_id) values ($1, $2)`,
    [fId, user3],
  ).then(() => null).catch((e) => e.code);
  assert(directReq === '42501', 'RLS blocks direct request inserts');
  const carolRequests = await rideClient.query(
    `select count(*)::int as n from public.ride_requests where passenger_id = $1`,
    [user3],
  );
  assert(carolRequests.rows[0].n === 5, 'passenger sees their own requests only');

  // Final counters.
  await rideClient.query('reset role');
  const finalCounters = await rideClient.query(
    `select id, total_completed_rides, total_cancelled_rides from public.profiles where id in ($1, $2) order by id`,
    [user1, user2],
  );
  await rideClient.query(`set role authenticated`);
  const finalRow = (id) => finalCounters.rows.find((r) => r.id === id);
  assert(Number(finalRow(user1).total_completed_rides) === 1 && Number(finalRow(user1).total_cancelled_rides) === 2, 'host final counters: 1 completed, 2 cancelled');
  assert(Number(finalRow(user2).total_completed_rides) === 1 && Number(finalRow(user2).total_cancelled_rides) === 0, 'passenger final counters: 1 completed, 0 cancelled');

  // ── Phase 5b: structured locations, visibility, expiry, history ──────
  const loc = (name, lat = 6.5, lng = 3.36, placeId = null, address = null) =>
    JSON.stringify({
      display_name: name,
      latitude: lat,
      longitude: lng,
      place_id: placeId,
      full_address: address,
    });
  const createLocRide = async (opts = {}) => {
    const r = await rideClient.query(
      `select * from public.create_ride($1::jsonb, $2::jsonb, $3::jsonb, $4, $5, $6, $7, $8, null, $9, $10, $11, $12, null, $13::jsonb)`,
      [
        opts.originLoc ?? loc('Ikeja', 6.6018, 3.3515, 'ChIJIkeja', 'Ikeja, Lagos'),
        opts.destLoc ?? loc('Victoria Island', 6.4281, 3.4219, 'ChIJVI', 'Victoria Island, Lagos'),
        opts.pickupLoc ?? loc('Jibowu Bus Stop', 6.5216, 3.3608, 'ChIJJibowu', 'Jibowu, Yaba, Lagos'),
        opts.hours != null ? dep(opts.hours) : dep(36),
        opts.seats ?? 3,
        opts.fare ?? 'fixed',
        opts.fixedFare !== undefined ? opts.fixedFare : 1500,
        opts.notes ?? null,
        opts.student ?? false,
        opts.women ?? false,
        opts.pickupType !== undefined ? opts.pickupType : 'bus_stop',
        opts.visibleAt ?? null,
        opts.smartDetails ?? null,
      ],
    );
    return r.rows[0];
  };

  await asUser(user1);

  // Structured location creation + pickup rules.
  const kRow = await createLocRide();
  const kId = kRow.id;
  assert(kRow.ride_status === 'draft', 'location create_ride returns a draft');
  assert(kRow.origin === 'Ikeja' && kRow.pickup_point === 'Jibowu Bus Stop', 'display names extracted to searchable text columns');
  assert(Number(kRow.origin_lat) === 6.6018 && Number(kRow.origin_lng) === 3.3515, 'coordinates stored from the location object');
  assert(kRow.origin_loc?.display_name === 'Ikeja' && kRow.pickup_type === 'bus_stop', 'full location object + pickup type stored');

  const noPickupType = await createLocRide({ pickupType: null })
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof noPickupType === 'string' && noPickupType.includes('Pickup must be a main-road point'), 'missing pickup kind rejected');
  const badPickupType = await createLocRide({ pickupType: 'residential' })
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof badPickupType === 'string' && badPickupType.includes('Pickup must be a main-road point'), 'residential pickup kind rejected');
  const badName = await createLocRide({ originLoc: JSON.stringify({ latitude: 1 }) })
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof badName === 'string' && badName.includes('display name'), 'location without a display name rejected');
  const badCoords = await createLocRide({ originLoc: JSON.stringify({ display_name: 'X', latitude: 'abc' }) })
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof badCoords === 'string' && badCoords.includes('coordinates must be numbers'), 'non-numeric coordinates rejected');
  const fixedWithSmart = await createLocRide({ smartDetails: JSON.stringify({ base_fare: 500 }) })
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof fixedWithSmart === 'string' && fixedWithSmart.includes('only apply to smart fares'), 'smart fare details rejected on a fixed fare');

  // Smart fare: details stored, engine not implemented yet.
  const mRow = await createLocRide({ fare: 'smart', fixedFare: null, smartDetails: JSON.stringify({ base_fare: 400, per_km: 90 }) });
  const mId = mRow.id;
  assert(mRow.fare_mode === 'smart' && mRow.fixed_fare === null, 'smart fare ride created without a fixed amount');
  assert(mRow.smart_fare_details?.per_km === 90, 'smart fare details payload stored for the future engine');

  // Visibility window: hidden from discovery until released.
  const nRow = await createLocRide({ hours: 48, visibleAt: dep(40) });
  const nId = nRow.id;
  await rideClient.query(`select * from public.publish_ride($1)`, [nId]);
  const vBad = await createLocRide({ visibleAt: dep(50) })
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof vBad === 'string' && vBad.includes('before the departure'), 'visibility after departure rejected');
  const vVisPast = await createLocRide({ visibleAt: dep(-1) })
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof vVisPast === 'string' && vVisPast.includes('future'), 'visibility in the past rejected');

  // Publish the structured rides.
  await rideClient.query(`select * from public.publish_ride($1)`, [kId]);
  await rideClient.query(`select * from public.publish_ride($1)`, [mId]);

  // Search: visibility gating + verified-host filter + new columns.
  await asUser(user3);
  const visSearch = await rideClient.query(
    `select * from public.search_rides(null, null, null, null, null, null, null, 'departure', null, null, 1, 50, null)`,
  );
  assert(!visSearch.rows.some((r) => r.id === nId), 'ride with a future visibility window hidden from search');
  assert(visSearch.rows.some((r) => r.id === kId && r.pickup_type === 'bus_stop' && r.origin_loc?.display_name === 'Ikeja'), 'search returns structured location columns');
  await asUser(user2);
  const visDetail = await rideClient.query(`select * from public.get_ride($1)`, [nId]).then(() => null).catch((e) => e.message ?? '');
  assert(typeof visDetail === 'string' && visDetail.includes('Ride not found'), 'ride hidden from detail until its visibility window opens (non-host)');
  const verifiedSearch = await rideClient.query(
    `select * from public.search_rides(null, null, null, null, null, null, null, null, null, null, 1, 50, true)`,
  );
  assert(verifiedSearch.rowCount > 0 && verifiedSearch.rows.every((r) => r.host_verified === true), 'verified-host filter keeps verified hosts');
  const unverifiedSearch = await rideClient.query(
    `select * from public.search_rides(null, null, null, null, null, null, null, null, null, null, 1, 50, false)`,
  );
  assert(unverifiedSearch.rowCount === 0, 'verified-host filter excludes unverified hosts');
  await rideClient.query('reset role');
  await rideClient.query(`update public.rides set visible_at = now() - interval '1 minute' where id = $1`, [nId]);
  await rideClient.query(`set role authenticated`);
  await asUser(user3);
  const visReleased = await rideClient.query(
    `select * from public.search_rides(null, null, null, null, null, null, null, null, null, null, 1, 50, null)`,
  );
  assert(visReleased.rows.some((r) => r.id === nId), 'ride becomes searchable after its visibility window opens');

  // Expiry: past departure without start -> archived as expired.
  await asUser(user1);
  const eRow2 = await createLocRide({ hours: 60 });
  const eId2 = eRow2.id;
  await rideClient.query(`select * from public.publish_ride($1)`, [eId2]);
  await asUser(user3);
  const eReq = await rideClient.query(`select * from public.request_to_join($1)`, [eId2]);
  await rideClient.query('reset role');
  await rideClient.query(`update public.rides set departure_time = now() - interval '10 minutes' where id = $1`, [eId2]);
  await rideClient.query(`set role authenticated`);
  await asUser(user1);
  const expiredCount = await rideClient.query(`select public.expire_overdue_rides() as n`);
  assert(Number(expiredCount.rows[0].n) === 1, 'expire_overdue_rides archives one overdue ride');
  const expiredRide = await rideClient.query(`select ride_status from public.rides where id = $1`, [eId2]);
  assert(expiredRide.rows[0].ride_status === 'expired', 'overdue ride archived as expired');
  assert((await timelineEvents(eId2)).includes('expired'), 'expired timeline event recorded');
  const expiredReq = await rideClient.query(`select status, responded_at from public.ride_requests where id = $1`, [eReq.rows[0].id]);
  assert(expiredReq.rows[0].status === 'cancelled' && expiredReq.rows[0].responded_at !== null, 'expiry closes pending requests');
  await asUser(user3);
  const expiredSearch = await rideClient.query(
    `select * from public.search_rides(null, null, null, null, null, null, null, null, null, null, 1, 50, null)`,
  );
  assert(!expiredSearch.rows.some((r) => r.id === eId2), 'expired rides excluded from discovery');
  const expiredDetail = await rideClient.query(`select * from public.get_ride($1)`, [eId2]);
  assert(expiredDetail.rowCount === 1 && expiredDetail.rows[0].ride_status === 'expired', 'expired ride still readable (history preserved)');

  // Delete draft.
  await asUser(user1);
  const oRow = await createLocRide({ hours: 70 });
  const oId = oRow.id;
  await asUser(user2);
  const notHostDelete = await rideClient.query(`select * from public.delete_draft($1)`, [oId])
    .then(() => null).catch((e) => e.code);
  assert(notHostDelete === '42501', 'non-host cannot delete a draft');
  await asUser(user1);
  const deletePub = await rideClient.query(`select * from public.delete_draft($1)`, [kId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof deletePub === 'string' && deletePub.includes('Only draft rides'), 'published ride cannot be deleted');
  const delOk = await rideClient.query(`select * from public.delete_draft($1)`, [oId]);
  assert(delOk.rows[0].delete_draft === true, 'host deletes their draft');
  const delGone = await rideClient.query(`select * from public.get_ride($1)`, [oId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof delGone === 'string' && delGone.includes('Ride not found'), 'deleted draft gone from detail');

  // Host removes a passenger before departure.
  await asUser(user3);
  const pReq = await rideClient.query(`select * from public.request_to_join($1)`, [kId]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [pReq.rows[0].id]);
  await asUser(user2);
  const notHostRemove = await rideClient.query(`select * from public.remove_passenger($1, $2)`, [kId, user3])
    .then(() => null).catch((e) => e.code);
  assert(notHostRemove === '42501', 'non-host cannot remove a passenger');
  await asUser(user1);
  const removed = await rideClient.query(`select * from public.remove_passenger($1, $2)`, [kId, user3]);
  assert(Number(removed.rows[0].available_seats) === 3, 'removing a passenger frees the seat');
  const droppedPart = await rideClient.query(
    `select left_at from public.ride_participants where ride_id = $1 and user_id = $2`,
    [kId, user3],
  );
  assert(droppedPart.rows[0].left_at !== null, 'removed passenger marked as left');
  assert((await timelineEvents(kId)).includes('dropped'), 'dropped timeline event recorded');
  const removeGhost = await rideClient.query(`select * from public.remove_passenger($1, $2)`, [kId, user2])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof removeGhost === 'string' && removeGhost.includes('not on this ride'), 'removing a non-passenger rejected');

  // Editing with structured fields (legacy 7-arg call still resolves).
  const editLoc = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, null, null, null, null, null, null, null, $2::jsonb, $3::jsonb, null, null, null)`,
    [kId, loc('Ikeja Along', 6.6025, 3.3521, 'ChIJIkeja2'), loc('Ajah', 6.47, 3.6, 'ChIJAjah')],
  );
  assert(editLoc.rows[0].origin === 'Ikeja Along' && editLoc.rows[0].destination === 'Ajah', 'structured origin/destination editable');
  assert(editLoc.rows[0].origin_loc?.display_name === 'Ikeja Along', 'location object updated on edit');
  assert(editLoc.rows[0].ride_status === 'published', 'edit keeps a published ride published');
  const badTypeEdit = await rideClient.query(
    `select * from public.update_ride($1, null, null, null, null, null, null, null, null, $2, null, null, null, null, null, null)`,
    [kId, 'home'],
  ).then(() => null).catch((e) => e.message ?? '');
  assert(typeof badTypeEdit === 'string' && badTypeEdit.includes('Pickup must be a main-road point'), 'invalid pickup kind on edit rejected');
  const legacyEdit = await rideClient.query(
    `select * from public.update_ride($1, null, null, $2, null, null, null)`,
    [kId, 'Updated notes'],
  );
  assert(legacyEdit.rows[0].notes === 'Updated notes', 'legacy 7-argument update_ride call still works');

  // Ride history.
  await asUser(user1);
  const hosted = await rideClient.query(`select * from public.get_ride_history('hosted', null, 1, 50)`);
  assert(hosted.rowCount > 0 && hosted.rows.every((r) => r.relation === 'hosted'), 'host sees their hosted history');
  assert(hosted.rows.some((r) => r.ride_status === 'expired') && hosted.rows.some((r) => r.ride_status === 'cancelled') && hosted.rows.some((r) => r.ride_status === 'completed'), 'hosted history covers archived statuses');
  const hostedCancelled = await rideClient.query(`select * from public.get_ride_history('hosted', 'cancelled', 1, 50)`);
  assert(hostedCancelled.rowCount > 0 && hostedCancelled.rows.every((r) => r.ride_status === 'cancelled'), 'history status filter works');
  await asUser(user3);
  const joined = await rideClient.query(`select * from public.get_ride_history('joined', null, 1, 50)`);
  assert(joined.rows.every((r) => r.relation === 'joined'), 'passenger sees their joined history');
  const joinedDep = joined.rows.map((r) => r.departure_time.getTime());
  assert(joinedDep.every((t, i) => i === 0 || t <= joinedDep[i - 1]), 'history ordered by departure desc');
  const requested = await rideClient.query(`select * from public.get_ride_history('requested', null, 1, 50)`);
  assert(requested.rows.every((r) => r.relation === 'requested' && r.request_status !== null), 'request history carries the request status');
  const reqPending = await rideClient.query(`select * from public.get_ride_history('requested', 'pending', 1, 50)`);
  assert(reqPending.rows.every((r) => r.request_status === 'pending'), 'request history filtered by request status');
  const badRelation = await rideClient.query(`select * from public.get_ride_history('watching', null, 1, 50)`)
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof badRelation === 'string' && badRelation.includes('hosted, joined or requested'), 'invalid history relation rejected');
  const histP1 = await rideClient.query(`select * from public.get_ride_history(null, null, 1, 2)`);
  const histP2 = await rideClient.query(`select * from public.get_ride_history(null, null, 2, 2)`);
  assert(histP1.rowCount === 2 && histP2.rowCount === 2 && Number(histP1.rows[0].total_count) === 12, 'history paginates with a stable total_count');
  const histView = await rideClient.query(`select * from public.ride_history`);
  assert(histView.rowCount > 0 && histView.rows.every((r) => r.user_id === user3), 'ride_history view only exposes own rows');

  // RLS: expired rides readable via the policy too.
  await asUser(user2);
  const expiredViaPolicy = await rideClient.query(`select count(*)::int as n from public.rides where ride_status = 'expired'`);
  assert(expiredViaPolicy.rows[0].n === 1, 'RLS policy allows reading expired rides');

  // ── Phase 6: notifications, preferences, push tokens, realtime ────
  const unread = async () => {
    const r = await rideClient.query(`select public.get_unread_notification_count() as n`);
    return Number(r.rows[0].n);
  };
  const notifRows = async (page = 1, pageSize = 20, unreadOnly = false, type = null) =>
    rideClient.query(
      `select * from public.get_notifications($1, $2, $3, $4)`,
      [page, pageSize, unreadOnly, type],
    );

  // Baseline: read everything accumulated through Phases 4-5b so the
  // remaining assertions count only Phase 6 activity. The rows stay in
  // the feed, so baseline totals are captured for delta assertions.
  const base = {};
  for (const u of [user1, user2, user3]) {
    await asUser(u);
    await rideClient.query(`select * from public.mark_all_notifications_read()`);
    const b = await notifRows(1, 1);
    base[u] = Number(b.rows[0]?.total_count ?? 0);
    assert((await unread()) === 0, 'baseline unread count is zero');
  }

  // Preferences defaults.
  await asUser(user2);
  const prefRow = await rideClient.query(`select * from public.get_notification_preferences()`);
  assert(prefRow.rows[0].user_id === user2, 'preferences row belongs to the caller');
  assert(prefRow.rows[0].ride_enabled === true && prefRow.rows[0].push_enabled === true, 'ride + push prefs default on');
  assert(prefRow.rows[0].email_enabled === false && prefRow.rows[0].marketing_enabled === false, 'email + marketing prefs default off');
  assert(prefRow.rows[0].verification_enabled === true && prefRow.rows[0].safety_enabled === true, 'verification + safety prefs default on');

  // Creating/publishing a ride emits no notifications.
  await asUser(user1);
  const p6Row = await createLocRide({ hours: 50 });
  const p6Id = p6Row.id;
  await publishRide(p6Id);
  assert((await unread()) === 0, 'draft creation + publish produce no notifications');

  // Request → host receives ride_request_received.
  await asUser(user2);
  const p6Req = await rideClient.query(`select * from public.request_to_join($1)`, [p6Id]);
  await asUser(user1);
  const recv = await notifRows(1, 50, true);
  assert(recv.rowCount === 1 && recv.rows[0].type === 'ride_request_received', 'host gets a ride request notification');
  assert(recv.rows[0].actor_user_id === user2, 'request notification actor is the passenger');
  assert(recv.rows[0].data?.request_id === p6Req.rows[0].id, 'request notification carries the request id');
  assert(recv.rows[0].data?.passenger_id === user2, 'request notification carries the passenger id');
  assert(recv.rows[0].message.includes('requested to join'), 'request notification message is user-friendly');
  assert((await unread()) === 1, 'host unread count after the request');

  // Approval → passenger gets approved, host gets passenger joined.
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [p6Req.rows[0].id]);
  await asUser(user2);
  const appr = await notifRows(1, 50, true);
  assert(appr.rows[0].type === 'ride_request_approved' && appr.rows[0].data?.request_id === p6Req.rows[0].id, 'passenger gets an approval notification');
  assert((await unread()) === 1, 'passenger unread after approval');
  await asUser(user1);
  const joinedN = await notifRows(1, 50, true);
  assert(joinedN.rows[0].type === 'passenger_joined' && joinedN.rows[0].data?.passenger_id === user2, 'host gets a passenger joined notification');
  assert(joinedN.rows[0].message.includes('joined your ride'), 'joined message names the passenger');
  assert((await unread()) === 2, 'host unread count after approval');

  // Second passenger: request + approval.
  await asUser(user3);
  const p6Req2 = await rideClient.query(`select * from public.request_to_join($1)`, [p6Id]);
  await asUser(user1);
  assert((await unread()) === 3, 'host unread count after second request');
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [p6Req2.rows[0].id]);
  await asUser(user3);
  const appr2 = await notifRows(1, 50, true);
  assert(appr2.rows[0].type === 'ride_request_approved' && appr2.rows[0].data?.request_id === p6Req2.rows[0].id, 'second passenger gets an approval notification');
  await asUser(user1);
  assert((await unread()) === 4, 'host unread count after second approval');

  // Edit → every member except the host gets ride_updated.
  await asUser(user1);
  await rideClient.query(
    `select * from public.update_ride($1, null, null, $2, null, null, null)`,
    [p6Id, 'Phase 6 notification test edit'],
  );
  await asUser(user2);
  assert((await unread()) === 2, 'member gets a ride updated notification');
  await asUser(user3);
  const upd = await notifRows(1, 50, false, 'ride_updated');
  assert(upd.rows[0].type === 'ride_updated' && upd.rows[0].message.includes('updated'), 'ride updated notification text');
  assert((await unread()) === 2, 'second member gets a ride updated notification');

  // Cancel → every member except the host gets ride_cancelled.
  await asUser(user1);
  await rideClient.query(`select * from public.cancel_ride($1)`, [p6Id]);
  await asUser(user2);
  const canc2 = await notifRows(1, 50, true);
  assert(canc2.rows[0].type === 'ride_cancelled', 'member gets a ride cancelled notification');
  assert((await unread()) === 3, 'member unread count after cancel');
  await asUser(user3);
  assert((await unread()) === 3, 'second member unread count after cancel');
  await asUser(user1);
  assert((await unread()) === 4, 'host (excluded from updates/cancel) still at 4');

  // Feed: pagination, filtering, total_count, clamping.
  await asUser(user2);
  const feedP1 = await notifRows(1, 2);
  assert(feedP1.rowCount === 2 && Number(feedP1.rows[0].total_count) === base[user2] + 3, 'feed paginates with a stable total_count');
  assert(feedP1.rows[0].type === 'ride_cancelled', 'feed is newest-first');
  const feedP2 = await notifRows(2, 2);
  assert(feedP2.rowCount === 2 && feedP2.rows[0].type === 'ride_request_approved', 'second feed page continues in order');
  const feedUnread = await notifRows(1, 50, true);
  assert(feedUnread.rowCount === 3, 'unread-only filter returns unread rows');
  const feedTyped = await notifRows(1, 50, false, 'ride_updated');
  assert(feedTyped.rowCount >= 1 && feedTyped.rows.every((r) => r.type === 'ride_updated') && feedTyped.rows[0].is_read === false, 'type filter narrows the feed');
  const feedClamped = await notifRows(1, 999);
  assert(feedClamped.rowCount === base[user2] + 3 && feedClamped.rowCount <= 50, 'page size is clamped to 50');
  const badType = await rideClient.query(`select * from public.get_notifications(1, 20, false, 'bogus_type')`)
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof badType === 'string' && badType.includes('Unknown notification type'), 'invalid feed type filter rejected');

  // Read + delete semantics.
  const cancId = feedP1.rows[0].id;
  const marked = await rideClient.query(`select * from public.mark_notification_read($1)`, [cancId]);
  assert(marked.rows[0].is_read === true && marked.rows[0].read_at !== null, 'mark_notification_read flips the row');
  assert((await unread()) === 2, 'unread count drops after marking read');
  await asUser(user3);
  const u3Canc = await notifRows(1, 50, false, 'ride_cancelled');
  const u3CancId = u3Canc.rows[0].id;
  await asUser(user2);
  const foreignMark = await rideClient.query(`select * from public.mark_notification_read($1)`, [u3CancId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof foreignMark === 'string' && foreignMark.includes('Notification not found'), 'cannot mark another user\'s notification');
  const readRowId = marked.rows[0].id;
  await rideClient.query(`select * from public.delete_notification($1)`, [readRowId]);
  const afterDel = await notifRows();
  assert(Number(afterDel.rows[0].total_count) === base[user2] + 2, 'deleted notification leaves the feed');
  const delForeign = await rideClient.query(`select * from public.delete_notification($1)`, [u3CancId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof delForeign === 'string' && delForeign.includes('Notification not found'), 'cannot delete another user\'s notification');
  await rideClient.query(`select * from public.mark_all_notifications_read()`);
  assert((await unread()) === 0, 'mark-all clears the unread badge');

  // RLS on the notifications table: own rows only, no direct writes.
  await asUser(user2);
  const notifRls = await rideClient.query(`select count(*)::int as n from public.notifications where recipient_user_id = $1`, [user2]);
  assert(notifRls.rows[0].n === base[user2] + 2, 'user reads only their own notifications');
  const notifRlsHidden = await rideClient.query(`select count(*)::int as n from public.notifications where recipient_user_id = $1`, [user3]);
  assert(notifRlsHidden.rows[0].n === 0, 'other users\' notifications are invisible');
  const notifDirectWrite = await rideClient.query(
    `insert into public.notifications (recipient_user_id, type, title) values ($1, 'welcome', 'x')`,
    [user2],
  ).then(() => null).catch((e) => e.code);
  assert(notifDirectWrite === '42501', 'direct notification insert is denied');

  // Preference gating: with ride_enabled off the recipient gets nothing.
  await asUser(user3);
  await rideClient.query(`select * from public.update_notification_preferences(p_ride_enabled => false)`);
  const prefGated = await rideClient.query(`select * from public.get_notification_preferences()`);
  assert(prefGated.rows[0].ride_enabled === false && prefGated.rows[0].push_enabled === true, 'partial preference update keeps other toggles');
  await asUser(user1);
  const n3Row = await createLocRide({ hours: 52 });
  const n3Id = n3Row.id;
  await publishRide(n3Id);
  await asUser(user3);
  const n3Req = await rideClient.query(`select * from public.request_to_join($1)`, [n3Id]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [n3Req.rows[0].id]);
  await asUser(user3);
  assert((await unread()) === 3, 'ride notification skipped for a recipient with ride_enabled off');
  await rideClient.query(`select * from public.update_notification_preferences(p_ride_enabled => true)`);
  assert((await unread()) === 3, 'preference flip alone does not backfill notifications');
  await asUser(user1);
  assert((await unread()) === 6, 'host notifications unaffected by passenger preferences');

  // Push tokens: register, upsert-on-token, ownership move, remove.
  await asUser(user2);
  const tok1 = await rideClient.query(`select * from public.register_push_token($1, $2, $3)`, ['tok-bob-1', 'dev-1', 'android']);
  assert(tok1.rows[0].token === 'tok-bob-1' && tok1.rows[0].user_id === user2, 'push token registered for the caller');
  const tok1b = await rideClient.query(`select * from public.register_push_token($1, $2, $3)`, ['tok-bob-1', 'dev-2', 'ios']);
  assert(tok1b.rows[0].platform === 'ios' && tok1b.rows[0].device_id === 'dev-2', 're-registering the same token updates device info');
  await asUser(user3);
  const tokMove = await rideClient.query(`select * from public.register_push_token($1)`, ['tok-bob-1']);
  assert(tokMove.rows[0].user_id === user3, 'same token moves to the new owner on re-sign-in');
  const badPlat = await rideClient.query(`select * from public.register_push_token($1, null, $2)`, ['tok-x', 'web'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof badPlat === 'string' && badPlat.includes('android or ios'), 'invalid platform rejected');
  const longTok = await rideClient.query(`select * from public.register_push_token($1)`, ['x'.repeat(513)])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof longTok === 'string' && longTok.includes('too long'), 'oversized push token rejected');
  const emptyTok = await rideClient.query(`select * from public.register_push_token($1)`, ['   '])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof emptyTok === 'string' && emptyTok.includes('required'), 'empty push token rejected');
  const tok2 = await rideClient.query(`select * from public.register_push_token($1, null, $2)`, ['tok-bob-2', 'ios']);
  assert(tok2.rows[0].user_id === user3, 'second token registered');
  await rideClient.query(`select * from public.remove_push_token($1)`, ['tok-bob-2']);
  await rideClient.query(`select * from public.remove_push_token($1)`, ['tok-bob-2']);
  await rideClient.query('reset role');
  const pushRemaining = await rideClient.query(`select user_id from public.push_tokens`);
  await rideClient.query(`set role authenticated`);
  assert(pushRemaining.rowCount === 1 && pushRemaining.rows[0].user_id === user3, 'remove_push_token is idempotent and removes only own tokens');

  // Duplicate request notifications are blocked by the unique index.
  const dupA = '00000000-0000-0000-0000-0000000000aa';
  await rideClient.query('reset role');
  await rideClient.query(
    `insert into public.notifications (recipient_user_id, type, title, message, data)
     values ($1, 'ride_request_received', 'd1', 'm1', $2)`,
    [user3, JSON.stringify({ request_id: dupA })],
  );
  const dupB = await rideClient.query(
    `insert into public.notifications (recipient_user_id, type, title, message, data)
     values ($1, 'ride_request_received', 'd2', 'm2', $2)`,
    [user3, JSON.stringify({ request_id: dupA })],
  ).then(() => null).catch((e) => e.code);
  assert(dupB === '23505', 'duplicate (recipient, type, request_id) notification blocked');
  await rideClient.query(
    `delete from public.notifications where recipient_user_id = $1 and data->>'request_id' = $2`,
    [user3, dupA],
  );
  await rideClient.query(`set role authenticated`);

  // Account lifecycle: welcome + email verified for a fresh signup.
  const user4 = crypto.randomUUID();
  await rideClient.query('reset role');
  await rideClient.query(
    `insert into auth.users (id, email, raw_user_meta_data) values
       ($1, 'dora@example.com', '{"full_name":"Dora Example"}')`,
    [user4],
  );
  const welcomeRows = await rideClient.query(
    `select count(*)::int as n from public.notifications where recipient_user_id = $1 and type = 'welcome'`,
    [user4],
  );
  assert(welcomeRows.rows[0].n === 1, 'signup creates a welcome notification');
  await rideClient.query(
    `update auth.users set email_confirmed_at = now() where id = $1`,
    [user4],
  );
  const emailRows = await rideClient.query(
    `select count(*)::int as n from public.notifications where recipient_user_id = $1 and type = 'email_verified'`,
    [user4],
  );
  assert(emailRows.rows[0].n === 1, 'email confirmation creates an email_verified notification');
  await rideClient.query(`set role authenticated`);
  await asUser(user4);
  assert((await unread()) === 2, 'new user sees welcome + email verified as unread');
  const doraFeed = await notifRows();
  assert(doraFeed.rowCount === 2 && Number(doraFeed.rows[0].total_count) === 2, 'new user feed is complete');
  await rideClient.query(`select * from public.mark_all_notifications_read()`);
  assert((await unread()) === 0, 'new user can read everything');

  // Helper validation + internal functions stay client-inaccessible.
  await asUser(user2);
  const vtOk = await rideClient.query(`select public.is_valid_notification_type('ride_request_approved') as v`);
  assert(vtOk.rows[0].v === true, 'valid notification type accepted');
  const vtBad = await rideClient.query(`select public.is_valid_notification_type('bogus') as v`);
  assert(vtBad.rows[0].v === false, 'invalid notification type rejected');
  const directRec = await rideClient.query(`select public.record_notification($1, 'welcome', 'x', 'y')`, [user2])
    .then(() => null).catch((e) => e.code);
  assert(directRec === '42501', 'record_notification is not client-callable');
  const directBcast = await rideClient.query(`select public.broadcast_covia_event('x', '{}')`)
    .then(() => null).catch((e) => e.code);
  assert(directBcast === '42501', 'broadcast_covia_event is not client-callable');
  await rideClient.query('reset role');
  const bogusType = await rideClient.query(`select public.record_notification($1, 'not_a_type', 'x', 'y')`, [user4])
    .then(() => null).catch((e) => e.message ?? '');
  await rideClient.query(`set role authenticated`);
  assert(typeof bogusType === 'string' && bogusType.includes('Unknown notification type'), 'record_notification validates its type');

  // Realtime event bus: covia_events NOTIFY + the supabase_realtime
  // broadcast branch (guarded by publication presence).
  const listenClient = new Client({ connectionString: `${DSN}/${TEST_DB}` });
  await listenClient.connect();
  const seen = [];
  listenClient.on('notification', (m) => seen.push(m));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  await listenClient.query('listen covia_events');
  await sleep(250);
  await rideClient.query('reset role');
  const pubCount = await rideClient.query(`select count(*)::int as n from pg_publication where pubname = 'supabase_realtime'`);
  await rideClient.query(`set role authenticated`);
  assert(pubCount.rows[0].n === 0, 'test DB starts without the supabase_realtime publication');

  await asUser(user1);
  const n4Row = await createLocRide({ hours: 54 });
  const n4Id = n4Row.id;
  await publishRide(n4Id);
  await rideClient.query(
    `select * from public.update_ride($1, null, null, $2, null, null, null)`,
    [n4Id, 'realtime test edit'],
  );
  await sleep(500);
  const gotUpdated = seen.some((m) => m.channel === 'covia_events' && JSON.parse(m.payload).event === 'covia.ride.updated');
  assert(gotUpdated, 'edit broadcasts covia.ride.updated on covia_events');
  await rideClient.query(`select * from public.cancel_ride($1)`, [n4Id]);
  await sleep(500);
  const gotCancelled = seen.some((m) => m.channel === 'covia_events' && JSON.parse(m.payload).event === 'covia.ride.cancelled');
  assert(gotCancelled, 'cancel broadcasts covia.ride.cancelled on covia_events');

  // With the publication present the same event also goes to the
  // supabase_realtime broadcast channel.
  await rideClient.query('reset role');
  await rideClient.query(`create publication supabase_realtime`);
  await rideClient.query(`set role authenticated`);
  await listenClient.query('listen supabase_realtime');
  await sleep(250);
  await asUser(user1);
  const n5Row = await createLocRide({ hours: 56 });
  const n5Id = n5Row.id;
  await publishRide(n5Id);
  await rideClient.query(
    `select * from public.update_ride($1, null, null, $2, null, null, null)`,
    [n5Id, 'realtime dual channel edit'],
  );
  await sleep(500);
  const gotDual = seen.filter((m) => JSON.parse(m.payload).event === 'covia.ride.updated');
  assert(gotDual.some((m) => m.channel === 'covia_events') && gotDual.some((m) => m.channel === 'supabase_realtime'), 'broadcast reaches both channels when the publication exists');
  await rideClient.query('reset role');
  await rideClient.query(`drop publication supabase_realtime`);
  await rideClient.query(`set role authenticated`);
  await listenClient.end();
  await sleep(100);

  // ── Phase 7: ride chat & communication ────────────────────────────
  for (const u of [user1, user2, user3]) {
    await asUser(u);
    await rideClient.query(`select * from public.mark_all_notifications_read()`);
  }

  // Lifecycle: chats exist only for rides with approved passengers.
  await rideClient.query('reset role');
  const chatCount = await rideClient.query(
    `select count(*)::int as n from public.ride_chats where ride_id in ($1, $2, $3, $4)`,
    [p6Id, n3Id, n4Id, n5Id],
  );
  const p6Chat = await rideClient.query(`select id, archived_at, locked_at from public.ride_chats where ride_id = $1`, [p6Id]);
  const p6ChatId = p6Chat.rows[0].id;
  const n3Chat = await rideClient.query(`select id from public.ride_chats where ride_id = $1`, [n3Id]);
  const n3ChatId = n3Chat.rows[0].id;
  await rideClient.query(`set role authenticated`);
  assert(chatCount.rows[0].n === 2, 'chat rooms exist only for rides with approved passengers');
  assert(p6Chat.rows[0].archived_at !== null && p6Chat.rows[0].locked_at !== null, 'cancelled ride chat is archived and locked immediately');

  // Pinned ride information.
  await asUser(user2);
  const header = await rideClient.query(`select * from public.get_chat($1)`, [p6ChatId]);
  assert(header.rows[0].ride_status === 'cancelled' && header.rows[0].origin === 'Ikeja', 'chat header carries ride origin/status');
  assert(header.rows[0].destination === 'Victoria Island' && header.rows[0].pickup_point === 'Jibowu Bus Stop', 'chat header carries destination + pickup');
  assert(header.rows[0].host_id === user1 && header.rows[0].host_name === 'Alice Example', 'chat header names the host');
  assert(Number(header.rows[0].participant_count) === 3, 'chat header counts host + approved passengers');

  // Outsiders cannot see the chat.
  await asUser(user4);
  const outsiderChat = await rideClient.query(`select * from public.get_chat($1)`, [p6ChatId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof outsiderChat === 'string' && outsiderChat.includes('Chat not found'), 'outsider cannot open the chat');
  const outsiderMsgs = await rideClient.query(`select * from public.get_chat_messages($1)`, [p6ChatId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof outsiderMsgs === 'string' && outsiderMsgs.includes('Chat not found'), 'outsider cannot read messages');

  // Fresh published ride with three participants for the messaging tests
  // (the cancelled-ride chat is archived and read-only by design).
  await asUser(user1);
  const c7Row = await createLocRide({ hours: 64 });
  const c7Id = c7Row.id;
  await publishRide(c7Id);
  await asUser(user2);
  const c7Req1 = await rideClient.query(`select * from public.request_to_join($1)`, [c7Id]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [c7Req1.rows[0].id]);
  await rideClient.query('reset role');
  const chatAfterFirst = await rideClient.query(`select count(*)::int as n from public.ride_chats where ride_id = $1`, [c7Id]);
  await rideClient.query(`set role authenticated`);
  assert(chatAfterFirst.rows[0].n === 1, 'chat room is created on the first approval');
  await asUser(user3);
  const c7Req2 = await rideClient.query(`select * from public.request_to_join($1)`, [c7Id]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [c7Req2.rows[0].id]);
  await rideClient.query('reset role');
  const c7Chat = await rideClient.query(`select id from public.ride_chats where ride_id = $1`, [c7Id]);
  const c7ChatId = c7Chat.rows[0].id;
  await rideClient.query(`set role authenticated`);
  assert(c7Chat.rowCount === 1, 'one chat room per ride');

  // Re-baseline unread counts so messaging assertions count only
  // chat-message notifications.
  for (const u of [user1, user2, user3]) {
    await asUser(u);
    await rideClient.query(`select * from public.mark_all_notifications_read()`);
  }

  // System messages generated by the lifecycle.
  await asUser(user2);
  const sysMsgs = await rideClient.query(`select * from public.get_chat_messages($1, null, 100)`, [p6ChatId]);
  const sysText = sysMsgs.rows.filter((r) => r.message_type === 'system').map((r) => r.message);
  assert(sysMsgs.rows.every((r) => r.message_type !== 'system' || r.sender_id === null), 'system messages have no sender');
  assert(sysText.some((m) => m.includes('Bob Example joined')), 'approval produces a joined system message');
  assert(sysText.some((m) => m.includes('Carol Example joined')), 'second approval produces a joined system message');
  assert(sysText.some((m) => m.includes('cancelled')), 'cancellation produces a system message');

  // Sending + validation.
  await asUser(user1);
  const hello = await rideClient.query(`select * from public.send_chat_message($1, $2)`, [c7ChatId, 'Hello team']);
  assert(hello.rows[0].message === 'Hello team' && hello.rows[0].sender_id === user1 && hello.rows[0].message_type === 'text', 'host sends a text message');
  const emptyMsg = await rideClient.query(`select * from public.send_chat_message($1, $2)`, [c7ChatId, '   '])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof emptyMsg === 'string' && emptyMsg.includes('A message is required'), 'empty message rejected');
  const longMsg = await rideClient.query(`select * from public.send_chat_message($1, $2)`, [c7ChatId, 'x'.repeat(2001)])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof longMsg === 'string' && longMsg.includes('2000 characters'), 'oversized message rejected');
  const p7BadType = await rideClient.query(`select * from public.send_chat_message($1, null, $2)`, [c7ChatId, 'video'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof p7BadType === 'string' && p7BadType.includes('text or image'), 'unsupported message type rejected');
  await asUser(user2);
  const ok2 = await rideClient.query(`select * from public.send_chat_message($1, $2)`, [c7ChatId, 'Sounds good']);
  await asUser(user3);
  const ok3 = await rideClient.query(`select * from public.send_chat_message($1, $2)`, [c7ChatId, 'Me too']);
  assert(ok3.rows[0].sender_id === user3, 'every approved passenger can send');

  // Realtime broadcast + notifications for chat messages.
  const chatListen = new Client({ connectionString: `${DSN}/${TEST_DB}` });
  await chatListen.connect();
  const chatSeen = [];
  chatListen.on('notification', (m) => chatSeen.push(m));
  await chatListen.query('listen covia_events');
  await sleep(250);
  await asUser(user1);
  await rideClient.query(`select * from public.send_chat_message($1, $2)`, [c7ChatId, 'Realtime hello']);
  await sleep(500);
  const gotChatEvent = chatSeen.some((m) => m.channel === 'covia_events'
    && JSON.parse(m.payload).event === 'covia.chat.new_message'
    && JSON.parse(m.payload).payload.chat_id === c7ChatId);
  assert(gotChatEvent, 'new messages broadcast covia.chat.new_message');
  await asUser(user2);
  assert((await unread()) === 3, 'chat members get a chat notification');
  await asUser(user3);
  assert((await unread()) === 3, 'second member notified too');
  await asUser(user1);
  assert((await unread()) === 2, 'sender is not notified of their own messages');
  const chatNotif = await notifRows(1, 50, true, 'chat_message');
  assert(chatNotif.rows[0].data?.chat_id === c7ChatId, 'chat notification carries the chat id');
  await chatListen.end();

  // Feed pagination (newest-first, cursor-based).
  await asUser(user2);
  const chatP1 = await rideClient.query(`select * from public.get_chat_messages($1, null, $2)`, [c7ChatId, 3]);
  assert(chatP1.rowCount === 3 && Number(chatP1.rows[0].total_count) > 3, 'feed pages newest-first with total_count');
  assert(chatP1.rows[0].message === 'Realtime hello', 'newest message first');
  const p2Cursor = (await rideClient.query(`select sent_at::text as t from public.chat_messages where id = $1`, [chatP1.rows[2].id])).rows[0].t;
  const chatP2 = await rideClient.query(`select * from public.get_chat_messages($1, $2, $3)`, [c7ChatId, p2Cursor, 3]);
  assert(chatP2.rowCount === 3 && chatP2.rows.every((r) => r.sent_at < chatP1.rows[2].sent_at), 'cursor loads older messages');
  const p3Cursor = (await rideClient.query(`select sent_at::text as t from public.chat_messages where id = $1`, [chatP2.rows[2].id])).rows[0].t;
  const chatP3 = await rideClient.query(`select * from public.get_chat_messages($1, $2, $3)`, [c7ChatId, p3Cursor, 100]);
  assert(chatP3.rowCount === 0, 'cursor reaches the end of history');
  assert(Number(chatP2.rows[0].total_count) === Number(chatP1.rows[0].total_count), 'total_count is stable across pages');

  // Read receipts.
  await asUser(user1);
  const marked1 = await rideClient.query(`select * from public.mark_messages_read($1)`, [c7ChatId]);
  assert(Number(marked1.rows[0].mark_messages_read) === 6, 'host marks all existing messages read');
  const sentAfter = await rideClient.query(`select * from public.send_chat_message($1, $2)`, [c7ChatId, 'Read this']);
  const marked2 = await rideClient.query(`select * from public.mark_messages_read($1, $2)`, [c7ChatId, sentAfter.rows[0].sent_at]);
  assert(Number(marked2.rows[0].mark_messages_read) === 1, 'only the new message is newly read');
  const receipt = await rideClient.query(`select * from public.get_chat_messages($1, null, 1)`, [c7ChatId]);
  assert(receipt.rows[0].message === 'Read this' && Number(receipt.rows[0].read_count) === 1, 'read_count reflects the reader');
  const markedAgain = await rideClient.query(`select * from public.mark_messages_read($1)`, [c7ChatId]);
  assert(Number(markedAgain.rows[0].mark_messages_read) === 0, 're-marking is a no-op');
  await asUser(user4);
  const outsiderRead = await rideClient.query(`select * from public.mark_messages_read($1)`, [c7ChatId])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof outsiderRead === 'string' && outsiderRead.includes('Chat not found'), 'outsider cannot mark reads');

  // Edit + soft delete (sender only).
  await asUser(user2);
  const edited = await rideClient.query(`select * from public.edit_chat_message($1, $2)`, [ok2.rows[0].id, 'Sounds much better']);
  assert(edited.rows[0].message === 'Sounds much better' && edited.rows[0].edited_at !== null, 'sender edits their own text message');
  const editForeign = await rideClient.query(`select * from public.edit_chat_message($1, $2)`, [hello.rows[0].id, 'hijack'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof editForeign === 'string' && editForeign.includes('Message not found'), 'cannot edit another sender\'s message');
  const editEmpty = await rideClient.query(`select * from public.edit_chat_message($1, $2)`, [ok2.rows[0].id, ''])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof editEmpty === 'string' && editEmpty.includes('required'), 'empty edit rejected');
  await rideClient.query(`select * from public.delete_chat_message($1)`, [ok2.rows[0].id]);
  const delGoneMsg = await rideClient.query(`select * from public.get_chat_messages($1, null, 100)`, [c7ChatId]);
  assert(!delGoneMsg.rows.some((r) => r.id === ok2.rows[0].id), 'deleted message leaves the feed');
  const delMsgForeign = await rideClient.query(`select * from public.delete_chat_message($1)`, [hello.rows[0].id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof delMsgForeign === 'string' && delMsgForeign.includes('Message not found'), 'cannot delete another sender\'s message');
  await rideClient.query('reset role');
  const delRow = await rideClient.query(`select deleted_at, message from public.chat_messages where id = $1`, [ok2.rows[0].id]);
  await rideClient.query(`set role authenticated`);
  assert(delRow.rows[0].deleted_at !== null && delRow.rows[0].message === null, 'soft delete keeps an audit row with a hidden body');

  // Search within the ride.
  await asUser(user1);
  const found = await rideClient.query(`select * from public.search_chat_messages($1, $2)`, [c7ChatId, 'hello']);
  assert(found.rows.some((r) => r.message === 'Hello team') && Number(found.rows[0].total_count) === 2, 'search matches case-insensitively within the chat');
  const noHit = await rideClient.query(`select * from public.search_chat_messages($1, $2)`, [c7ChatId, 'zzzz']);
  assert(noHit.rowCount === 0, 'search returns nothing for a miss');
  const emptyQ = await rideClient.query(`select * from public.search_chat_messages($1, $2)`, [c7ChatId, '  '])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof emptyQ === 'string' && emptyQ.includes('query'), 'empty search query rejected');

  // Image uploads: storage RLS + send validation.
  const imgPath = `chat/${c7ChatId}/photo.jpg`;
  await rideClient.query('reset role');
  await rideClient.query(
    `insert into storage.objects (bucket_id, name, owner) values ('chat-media', $1, $2)`,
    [imgPath, user1],
  );
  await rideClient.query(`set role authenticated`);
  await asUser(user1);
  const imgMsg = await rideClient.query(`select * from public.send_chat_message($1, null, $2, $3)`, [c7ChatId, 'image', imgPath]);
  assert(imgMsg.rows[0].message_type === 'image' && imgMsg.rows[0].media_url === imgPath, 'participant sends an image with an owned object');
  const fakeImg = await rideClient.query(`select * from public.send_chat_message($1, null, $2, $3)`, [c7ChatId, 'image', `chat/${c7ChatId}/fake.jpg`])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof fakeImg === 'string' && fakeImg.includes('not found'), 'image without an owned object rejected');
  await asUser(user4);
  const outsiderUpload = await rideClient.query(
    `insert into storage.objects (bucket_id, name, owner) values ('chat-media', $1, $2)`,
    [`chat/${c7ChatId}/sneak.jpg`, user4],
  ).then(() => null).catch((e) => e.code);
  assert(outsiderUpload === '42501', 'outsider cannot upload into a chat folder');
  const outsiderReadObj = await rideClient.query(`select count(*)::int as n from storage.objects where bucket_id = 'chat-media'`);
  assert(outsiderReadObj.rows[0].n === 0, 'outsider cannot list chat media objects');
  await asUser(user2);
  const memberReadObj = await rideClient.query(`select count(*)::int as n from storage.objects where bucket_id = 'chat-media'`);
  assert(memberReadObj.rows[0].n === 1, 'participant sees chat media objects');

  // Notification gating via chat_enabled.
  await asUser(user3);
  await rideClient.query(`select * from public.update_notification_preferences(p_chat_enabled => false)`);
  const beforeGate = await unread();
  await asUser(user2);
  const gatedU2 = await unread();
  await asUser(user1);
  await rideClient.query(`select * from public.send_chat_message($1, $2)`, [c7ChatId, 'gated message']);
  await asUser(user3);
  assert((await unread()) === beforeGate, 'chat notification skipped when chat_enabled is off');
  await asUser(user2);
  assert((await unread()) === gatedU2 + 1, 'other members still notified when chat_enabled is on');
  await asUser(user3);
  await rideClient.query(`select * from public.update_notification_preferences(p_chat_enabled => true)`);

  // Lifecycle: started + completed → system messages, archive, lock+2h.
  await asUser(user1);
  await rideClient.query(`select * from public.start_ride($1)`, [n3Id]);
  await rideClient.query(`select * from public.complete_ride($1)`, [n3Id]);
  await rideClient.query('reset role');
  const n3sys = await rideClient.query(`select message from public.chat_messages where chat_id = $1 and message_type = 'system'`, [n3ChatId]);
  const n3lc = await rideClient.query(`select archived_at, locked_at from public.ride_chats where id = $1`, [n3ChatId]);
  await rideClient.query(`set role authenticated`);
  const n3sysText = n3sys.rows.map((r) => r.message);
  assert(n3sysText.some((m) => m.includes('started')) && n3sysText.some((m) => m.includes('completed')), 'start + complete produce system messages');
  assert(n3lc.rows[0].archived_at !== null, 'completed ride chat is archived');
  assert(n3lc.rows[0].locked_at !== null && n3lc.rows[0].locked_at > n3lc.rows[0].archived_at, 'completion schedules the lock 2h later');
  await asUser(user3);
  const archivedSend = await rideClient.query(`select * from public.send_chat_message($1, $2)`, [n3ChatId, 'too late'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof archivedSend === 'string' && archivedSend.includes('archived'), 'archived chat blocks new messages');

  // A chat whose lock has passed blocks sending; history stays readable.
  await rideClient.query('reset role');
  await rideClient.query(`update public.ride_chats set locked_at = now() - interval '1 minute', archived_at = null where id = $1`, [n3ChatId]);
  await rideClient.query(`set role authenticated`);
  await asUser(user3);
  const lockedSend = await rideClient.query(`select * from public.send_chat_message($1, $2)`, [n3ChatId, 'nope'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof lockedSend === 'string' && lockedSend.includes('locked'), 'locked chat blocks sending');
  const lockedRead = await rideClient.query(`select count(*)::int as n from public.get_chat_messages($1, null, 100)`, [n3ChatId]);
  assert(lockedRead.rows[0].n > 0, 'locked chat history remains viewable');

  // Retention: 90-day purge with the safety-preservation exception.
  await rideClient.query('reset role');
  const oldMsg = await rideClient.query(
    `insert into public.chat_messages (chat_id, sender_id, message_type, message, sent_at)
     values ($1, $2, 'text', 'ancient', now() - interval '91 days') returning id`,
    [p6ChatId, user1],
  );
  const preserved = await rideClient.query(
    `insert into public.chat_messages (chat_id, sender_id, message_type, message, sent_at)
     values ($1, $2, 'text', 'evidence', now() - interval '91 days') returning id`,
    [n3ChatId, user1],
  );
  await rideClient.query(`update public.ride_chats set preserve_until = now() + interval '1 day' where id = $1`, [n3ChatId]);
  const purged = await rideClient.query(`select public.purge_expired_chat_messages() as n`);
  const oldGone = await rideClient.query(`select count(*)::int as n from public.chat_messages where id = $1`, [oldMsg.rows[0].id]);
  const kept = await rideClient.query(`select count(*)::int as n from public.chat_messages where id = $1`, [preserved.rows[0].id]);
  await rideClient.query(`update public.ride_chats set preserve_until = null where id = $1`, [n3ChatId]);
  await rideClient.query(`set role authenticated`);
  assert(Number(purged.rows[0].n) === 1, 'purge deletes messages older than 90 days');
  assert(oldGone.rows[0].n === 0, 'expired message removed');
  assert(kept.rows[0].n === 1, 'preserved chat messages survive the purge');

  // RLS: direct table access.
  await asUser(user4);
  const rlsMsgs = await rideClient.query(`select count(*)::int as n from public.chat_messages where chat_id = $1`, [p6ChatId]);
  assert(rlsMsgs.rows[0].n === 0, 'RLS hides messages from outsiders');
  const rlsChats = await rideClient.query(`select count(*)::int as n from public.ride_chats where id = $1`, [p6ChatId]);
  assert(rlsChats.rows[0].n === 0, 'RLS hides the chat row from outsiders');
  const rlsReads = await rideClient.query(`select count(*)::int as n from public.message_reads`);
  assert(rlsReads.rows[0].n === 0, 'RLS hides read receipts from outsiders');
  await asUser(user2);
  const rlsInsert = await rideClient.query(
    `insert into public.chat_messages (chat_id, sender_id, message_type, message) values ($1, $2, 'text', 'x')`,
    [p6ChatId, user2],
  ).then(() => null).catch((e) => e.code);
  assert(rlsInsert === '42501', 'direct message insert is denied');
  const rlsUpdate = await rideClient.query(`update public.chat_messages set message = 'x' where chat_id = $1`, [p6ChatId])
    .then(() => null).catch((e) => e.code);
  assert(rlsUpdate === '42501', 'direct message update is denied');
  const rlsChatsU2 = await rideClient.query(`select count(*)::int as n from public.ride_chats`);
  const expectChatsU2 = await rideClient.query(`
    select count(*)::int as n from public.ride_chats rc
    join public.rides r on r.id = rc.ride_id
    where r.host_id = $1 or exists (
      select 1 from public.ride_participants p
      where p.ride_id = r.id and p.user_id = $1 and p.role = 'Passenger' and p.left_at is null
    )`, [user2]);
  assert(rlsChatsU2.rows[0].n === expectChatsU2.rows[0].n,
    'participant sees exactly the chats they belong to (not n3 / other rides)');
  const rlsMsgsOther = await rideClient.query(`select count(*)::int as n from public.chat_messages where chat_id = $1`, [n3ChatId]);
  assert(rlsMsgsOther.rows[0].n === 0, 'participant cannot see messages from chats they are not in');

  // ── Phase 8: safety, emergency & trust ──────────────────────────────
  const cnt = async (u, type) => {
    await asUser(u);
    const r = await notifRows(1, 1, false, type);
    return Number(r.rows[0]?.total_count ?? 0);
  };
  const listenFor = async () => {
    const c = new Client({ connectionString: `${DSN}/${TEST_DB}` });
    await c.connect();
    const seen = [];
    c.on('notification', (m) => seen.push(m));
    await c.query('listen covia_events');
    await sleep(250);
    return { client: c, seen, end: async () => c.end() };
  };
  const gotEvent = (seen, name, rideId) => seen.some((m) => m.channel === 'covia_events'
    && JSON.parse(m.payload).event === name
    && (rideId === undefined || JSON.parse(m.payload).payload.ride_id === rideId));

  // Emergency contacts: add / update / delete + validation + RLS.
  await asUser(user1);
  const mom = await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3, $4)`, ['Mom', '+2348012345678', 'Mother', true]);
  assert(mom.rows[0].is_primary === true && mom.rows[0].name === 'Mom', 'a primary contact can be added');
  const dad = await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3)`, ['Dad', '+234 901 2345 678', 'Father']);
  const mate = await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3)`, ['Roommate', '+15551234567', 'Friend']);
  assert(mate.rows[0].is_primary === false, 'extra contacts are non-primary by default');
  const ecBadName = await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3)`, ['  ', '+2348012345678', 'Mother'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof ecBadName === 'string' && ecBadName.includes('A contact name is required'), 'contact name is validated');
  const ecBadPhone = await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3)`, ['X', 'call me', 'Mother'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof ecBadPhone === 'string' && ecBadPhone.includes('A valid phone number is required'), 'contact phone is validated');
  const ecBadRel = await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3)`, ['X', '+2348012345678', ' '])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof ecBadRel === 'string' && ecBadRel.includes('A relationship is required'), 'contact relationship is validated');
  const newPrimary = await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3, $4)`, ['Sister', '+2348123456789', 'Sibling', true]);
  const momNow = await rideClient.query(`select is_primary from public.emergency_contacts where id = $1`, [mom.rows[0].id]);
  assert(momNow.rows[0].is_primary === false, 'adding a new primary demotes the old one');
  const list1 = await rideClient.query(`select * from public.get_emergency_contacts()`);
  assert(list1.rows.length === 4 && list1.rows[0].id === newPrimary.rows[0].id, 'contacts list primary first');
  const contactUpd = await rideClient.query(`select * from public.update_emergency_contact($1, $2, $3)`, [dad.rows[0].id, 'Dad', '+2348011122233']);
  assert(contactUpd.rows[0].phone === '+2348011122233', 'contact phone can be updated');
  const updBadPhone = await rideClient.query(`select * from public.update_emergency_contact($1, $2, $3)`, [dad.rows[0].id, 'Dad', 'call me'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof updBadPhone === 'string' && updBadPhone.includes('A valid phone number is required'), 'update validates the phone');
  await asUser(user2);
  const updOther = await rideClient.query(`select * from public.update_emergency_contact($1, $2)`, [dad.rows[0].id, 'Nope'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof updOther === 'string' && updOther.includes('Contact not found'), 'contacts cannot be edited by other users');
  const delOther = await rideClient.query(`select * from public.delete_emergency_contact($1)`, [mom.rows[0].id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof delOther === 'string' && delOther.includes('Contact not found'), 'contacts cannot be deleted by other users');
  await asUser(user1);
  await rideClient.query(`select * from public.delete_emergency_contact($1)`, [mate.rows[0].id]);
  const list2 = await rideClient.query(`select * from public.get_emergency_contacts()`);
  assert(list2.rows.length === 3, 'a contact can be deleted by its owner');
  const ecRLS = await rideClient.query(`select count(*)::int as n from public.emergency_contacts where user_id = $1`, [user2]);
  assert(ecRLS.rows[0].n === 0, 'RLS hides contacts from other users');
  const ecInsert = await rideClient.query(`insert into public.emergency_contacts (user_id, name, phone, relationship) values ($1, 'X', '+2348012345678', 'X')`, [user1])
    .then(() => null).catch((e) => e.code);
  assert(ecInsert === '42501', 'direct contact insert is denied');

  // user2's contacts drive the SOS + escalation outbound assertions.
  await asUser(user2);
  await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3, $4)`, ['Brother', '+2347000000001', 'Sibling', true]);
  await rideClient.query(`select * from public.add_emergency_contact($1, $2, $3)`, ['Sister', '+2347000000002', 'Sibling']);

  // Safety config: readable defaults; mutations are server-only.
  const safetyCfg = await rideClient.query(`select * from public.get_safety_config()`);
  assert(Number(safetyCfg.rows[0].route_deviation_meters) === 500 && safetyCfg.rows[0].stop_threshold_seconds === 120, 'deviation + stop thresholds default');
  assert(safetyCfg.rows[0].safety_check_timeout_seconds === 60 && safetyCfg.rows[0].never_started_minutes === 15, 'escalation + never-started thresholds default');
  assert(safetyCfg.rows[0].exceeded_duration_minutes === 45 && safetyCfg.rows[0].notify_participants_on_sos === true, 'duration + sos notify defaults');
  assert(safetyCfg.rows[0].sos_repeat_window_seconds === 120 && safetyCfg.rows[0].live_location_retention_hours === 24, 'sos window + retention defaults');
  const cfgWrite = await rideClient.query(`select * from public.update_safety_config(p_stop_threshold_seconds => 1)`)
    .then(() => null).catch((e) => e.code);
  assert(cfgWrite === '42501', 'clients cannot change safety config');
  const cfgTable = await rideClient.query(`update public.safety_config set stop_threshold_seconds = 1`)
    .then(() => null).catch((e) => e.code);
  assert(cfgTable === '42501', 'safety config is not directly writable');

  // Active ride for monitoring + SOS tests.
  await asUser(user1);
  const p8Row = await createLocRide({ hours: 72 });
  const p8Id = p8Row.id;
  await publishRide(p8Id);
  await asUser(user2);
  const p8Req2 = await rideClient.query(`select * from public.request_to_join($1)`, [p8Id]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [p8Req2.rows[0].id]);
  await asUser(user3);
  const p8Req3 = await rideClient.query(`select * from public.request_to_join($1)`, [p8Id]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [p8Req3.rows[0].id]);
  const monPre = await rideClient.query(`select count(*)::int as n from public.ride_monitoring where ride_id = $1`, [p8Id]);
  assert(monPre.rows[0].n === 0, 'no monitoring before the ride starts');
  await rideClient.query(`select * from public.start_ride($1)`, [p8Id]);
  const monStart = await rideClient.query(`select * from public.ride_monitoring where ride_id = $1`, [p8Id]);
  assert(monStart.rows[0].status === 'active' && monStart.rows[0].started_at !== null, 'starting a ride activates monitoring');

  // Second ride: sos-gate + duration-exceeded tests. Third ride: never-started.
  const p8bRow = await createLocRide({ hours: 80 });
  const p8bId = p8bRow.id;
  await publishRide(p8bId);
  await asUser(user2);
  const p8bReq = await rideClient.query(`select * from public.request_to_join($1)`, [p8bId]);
  await asUser(user1);
  await rideClient.query(`select * from public.host_respond_to_request($1, true, null)`, [p8bReq.rows[0].id]);
  await rideClient.query(`select * from public.start_ride($1)`, [p8bId]);
  const p8cRow = await createLocRide({ hours: 88 });
  const p8cId = p8cRow.id;
  await publishRide(p8cId);

  // Live location sharing + RLS (before the route exists, so no deviation).
  await asUser(user2);
  const share2 = await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lat: 6.51, lng: 3.37, speed: 0 })]);
  assert(share2.rows[0].user_id === user2 && share2.rows[0].is_active === true, 'a passenger can share their location');
  await asUser(user3);
  await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lat: 6.5, lng: 3.36, speed: 0 })]);
  await asUser(user1);
  const locsVisible = await rideClient.query(`select count(*)::int as n from public.live_locations where ride_id = $1`, [p8Id]);
  assert(locsVisible.rows[0].n === 2, 'participants see each others live locations');
  await asUser(user4);
  const locsHidden = await rideClient.query(`select count(*)::int as n from public.live_locations where ride_id = $1`, [p8Id]);
  assert(locsHidden.rows[0].n === 0, 'RLS hides live locations from outsiders');
  await asUser(user2);
  const locInvalid = await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lng: 3.37 })])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof locInvalid === 'string' && locInvalid.includes('A valid location is required'), 'invalid locations are rejected');
  await asUser(user3);
  const locInactive = await rideClient.query(`select * from public.update_live_location($1, $2)`, [n3Id, JSON.stringify({ lat: 6.5, lng: 3.36 })])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof locInactive === 'string' && locInactive.includes('Live location is only shared during an active ride'), 'sharing requires an active ride');
  await rideClient.query(`select * from public.stop_live_location($1)`, [p8Id]);
  const locsAfterStop = await rideClient.query(`select count(*)::int as n from public.live_locations where ride_id = $1`, [p8Id]);
  assert(locsAfterStop.rows[0].n === 1, 'a passenger can stop sharing their location');
  const locInsert = await rideClient.query(`insert into public.live_locations (ride_id, user_id, location) values ($1, $2, '{"lat":6.5,"lng":3.36}')`, [p8Id, user2])
    .then(() => null).catch((e) => e.code);
  assert(locInsert === '42501', 'direct live-location insert is denied');

  // Planned route (host-only, validated).
  await asUser(user2);
  const routeByPassenger = await rideClient.query(`select * from public.set_planned_route($1, $2)`, [p8Id, JSON.stringify([{ lat: 6.5, lng: 3.3 }, { lat: 6.5, lng: 3.42 }])])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof routeByPassenger === 'string' && routeByPassenger.includes('Only the host can set the planned route'), 'passengers cannot set the route');
  await asUser(user1);
  const routeShort = await rideClient.query(`select * from public.set_planned_route($1, $2)`, [p8Id, JSON.stringify([{ lat: 6.5, lng: 3.3 }])])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof routeShort === 'string' && routeShort.includes('at least two points'), 'a route needs at least two points');
  const routeNoLat = await rideClient.query(`select * from public.set_planned_route($1, $2)`, [p8Id, JSON.stringify([{ lng: 3.3 }, { lat: 6.5, lng: 3.42 }])])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof routeNoLat === 'string' && routeNoLat.includes('lat/lng coordinates'), 'route points need coordinates');
  await rideClient.query(`select * from public.set_planned_route($1, $2)`, [p8Id, JSON.stringify([{ lat: 6.5, lng: 3.3 }, { lat: 6.5, lng: 3.42 }])]);

  // SOS: one tap, broadcast, notifications, outbound queue, idempotency.
  const sosBaseline = { host: await cnt(user1, 'emergency_alert'), p2: await cnt(user2, 'emergency_alert'), p3: await cnt(user3, 'emergency_alert') };
  const sosListen = await listenFor();
  await asUser(user2);
  const sos1 = await rideClient.query(`select * from public.trigger_sos($1, $2)`, [p8Id, JSON.stringify({ lat: 6.51, lng: 3.37 })]);
  await sleep(500);
  assert(sos1.rows[0].event_type === 'sos' && sos1.rows[0].severity === 'critical', 'SOS creates a critical event');
  assert(Number(sos1.rows[0].location.lat) === 6.51 && sos1.rows[0].resolved_at === null, 'SOS records the pressed location');
  assert(gotEvent(sosListen.seen, 'covia.safety.sos', p8Id), 'SOS broadcasts covia.safety.sos');
  const sosDup = await rideClient.query(`select * from public.trigger_sos($1, $2)`, [p8Id, JSON.stringify({ lat: 6.51, lng: 3.37 })]);
  assert(sosDup.rows[0].id === sos1.rows[0].id, 'duplicate SOS returns the same event (idempotent)');
  assert(await cnt(user1, 'emergency_alert') === sosBaseline.host + 1, 'host is notified of the SOS');
  assert(await cnt(user3, 'emergency_alert') === sosBaseline.p3 + 1, 'fellow passengers are notified of the SOS');
  assert(await cnt(user2, 'emergency_alert') === sosBaseline.p2, 'the SOS sender is not notified');
  await rideClient.query('reset role');
  const outbound = await rideClient.query(
    `select * from public.outbound_notifications where kind = 'sos_alert' and payload->>'ride_id' = $1`, [p8Id]);
  await rideClient.query('set role authenticated');
  assert(outbound.rowCount === 2 && outbound.rows.every((r) => r.sent_at === null), 'SOS queues one SMS per emergency contact');
  assert(outbound.rows.some((r) => r.recipient_name === 'Brother'), 'outbound row names the primary contact');
  await sosListen.end();
  await asUser(user4);
  const sosOutsider = await rideClient.query(`select * from public.trigger_sos($1, $2)`, [p8Id, JSON.stringify({ lat: 6.5, lng: 3.36 })])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof sosOutsider === 'string' && sosOutsider.includes('You are not on this ride'), 'outsiders cannot trigger SOS');
  await asUser(user3);
  const sosInactive = await rideClient.query(`select * from public.trigger_sos($1)`, [n3Id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof sosInactive === 'string' && sosInactive.includes('SOS is only available during an active ride'), 'SOS requires an active ride');

  // SOS participant notifications are config-gated.
  await rideClient.query('reset role');
  await rideClient.query(`select * from public.update_safety_config(p_notify_participants_on_sos => false)`);
  await rideClient.query('set role authenticated');
  const gateHost = await cnt(user1, 'emergency_alert');
  await asUser(user2);
  const sosGate = await rideClient.query(`select * from public.trigger_sos($1)`, [p8bId]);
  assert(sosGate.rows[0].event_type === 'sos', 'SOS still fires when notifications are gated off');
  assert(await cnt(user1, 'emergency_alert') === gateHost, 'gated SOS notifies no participants');
  await rideClient.query('reset role');
  await rideClient.query(`select * from public.update_safety_config(p_notify_participants_on_sos => true)`);
  await rideClient.query('set role authenticated');

  // Route deviation → "Are you safe?" prompt.
  await asUser(user2);
  const devListen = await listenFor();
  const devDelta = await cnt(user2, 'safety_check');
  await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lat: 6.55, lng: 3.36, speed: 8 })]);
  await sleep(500);
  const devEvent = await rideClient.query(
    `select * from public.safety_events where ride_id = $1 and event_type = 'safety_check' order by created_at desc limit 1`, [p8Id]);
  assert(devEvent.rows[0].metadata.check_kind === 'route_deviation', 'an off-route move raises a route_deviation check');
  assert(gotEvent(devListen.seen, 'covia.safety.check_required', p8Id), 'deviation broadcasts check_required');
  assert(await cnt(user2, 'safety_check') === devDelta + 1, 'the rider is asked to confirm they are safe');
  await devListen.end();

  // "I'm Safe" needs biometric confirmation; plain taps are rejected.
  const bioError = await rideClient.query(`select * from public.respond_safety_check($1, true, false)`, [p8Id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof bioError === 'string' && bioError.includes('Biometric confirmation is required'), 'a tap cannot dismiss the alert');
  const resolvedListen = await listenFor();
  const resolved = await rideClient.query(`select * from public.respond_safety_check($1, true, true)`, [p8Id]);
  await sleep(500);
  assert(resolved.rows[0].event_type === 'safety_confirmed' && resolved.rows[0].metadata.confirmed_by_biometric === true, 'biometric confirmation resolves the alert');
  const checkCleared = await rideClient.query(`select check_required_at from public.ride_monitoring where ride_id = $1`, [p8Id]);
  assert(checkCleared.rows[0].check_required_at === null, 'the open prompt is cleared');
  assert(gotEvent(resolvedListen.seen, 'covia.safety.resolved', p8Id), 'confirmation broadcasts covia.safety.resolved');
  await resolvedListen.end();

  // Unexpected stop → prompt (with a tuned-down stop threshold).
  await rideClient.query('reset role');
  await rideClient.query(`select * from public.update_safety_config(p_stop_threshold_seconds => 1)`);
  await rideClient.query('set role authenticated');
  await asUser(user2);
  await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lat: 6.5, lng: 3.36, speed: 0 })]);
  await sleep(1200);
  await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lat: 6.5, lng: 3.36, speed: 0 })]);
  const stopEvent = await rideClient.query(
    `select * from public.safety_events where ride_id = $1 and event_type = 'safety_check' order by created_at desc limit 1`, [p8Id]);
  assert(stopEvent.rows[0].metadata.check_kind === 'long_stop', 'a stationary ride raises a long_stop check');

  // "Need Help" escalates immediately (repeat window opened for a fresh SOS).
  const helpBaseline = { host: await cnt(user1, 'emergency_alert'), p3: await cnt(user3, 'emergency_alert') };
  await rideClient.query('reset role');
  await rideClient.query(`select * from public.update_safety_config(p_sos_repeat_window_seconds => 0)`);
  await rideClient.query('set role authenticated');
  await asUser(user2);
  const help = await rideClient.query(`select * from public.respond_safety_check($1, false)`, [p8Id]);
  assert(help.rows[0].event_type === 'sos' && help.rows[0].metadata.source === 'safety_check_response', 'Need Help raises a fresh SOS');
  assert(help.rows[0].id !== sos1.rows[0].id, 'Need Help is not a duplicate SOS');
  const helpMon = await rideClient.query(`select check_required_at, escalated_at from public.ride_monitoring where ride_id = $1`, [p8Id]);
  assert(helpMon.rows[0].check_required_at === null && helpMon.rows[0].escalated_at !== null, 'the prompt is cleared and the ride is flagged');
  assert(await cnt(user1, 'emergency_alert') === helpBaseline.host + 1, 'participants are alerted on Need Help');
  assert(await cnt(user3, 'emergency_alert') === helpBaseline.p3 + 1, 'fellow passengers are alerted on Need Help');

  // SOS without a pressed location falls back to the last known position.
  const fallback = await rideClient.query(`select * from public.trigger_sos($1)`, [p8Id]);
  assert(Number(fallback.rows[0].location.lat) === 6.5, 'SOS falls back to the last known location');

  // Timeout → emergency escalation (monitor engine: escalation, never-started, duration).
  await asUser(user2);
  await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lat: 6.5, lng: 3.36, speed: 0 })]);
  const escCheck = await rideClient.query(
    `select * from public.safety_events where ride_id = $1 and event_type = 'safety_check' order by created_at desc limit 1`, [p8Id]);
  const escBaseline = { host: await cnt(user1, 'emergency_alert'), p3: await cnt(user3, 'emergency_alert'), hostSafety: await cnt(user1, 'safety_check') };
  await rideClient.query('reset role');
  await rideClient.query(`select * from public.update_safety_config(p_safety_check_timeout_seconds => 1)`);
  await rideClient.query(`update public.rides set departure_time = now() - interval '7 hours' where id = $1`, [p8bId]);
  await rideClient.query(`update public.rides set departure_time = now() - interval '1 hour' where id = $1`, [p8cId]);
  const monListen = await listenFor();
  await sleep(1300);
  const monitorRes = await rideClient.query(`select public.run_safety_monitor() as actions`);
  await rideClient.query('set role authenticated');
  await sleep(500);
  assert(Number(monitorRes.rows[0].actions) >= 3, 'the monitor engine takes action');
  const escEvent = await rideClient.query(
    `select * from public.safety_events where ride_id = $1 and event_type = 'emergency_escalation'`, [p8Id]);
  assert(escEvent.rows[0].severity === 'critical' && escEvent.rows[0].user_id === user2, 'an unanswered prompt escalates');
  assert(escEvent.rows[0].metadata.check_event_id === escCheck.rows[0].id, 'escalation links the unanswered check');
  assert(gotEvent(monListen.seen, 'covia.safety.escalated', p8Id), 'escalation broadcasts covia.safety.escalated');
  assert(await cnt(user1, 'emergency_alert') === escBaseline.host + 1, 'escalation alerts the host');
  assert(await cnt(user3, 'emergency_alert') === escBaseline.p3 + 1, 'escalation alerts the passengers');
  await rideClient.query('reset role');
  const escOut = await rideClient.query(
    `select * from public.outbound_notifications where kind = 'escalation_alert' and payload->>'ride_id' = $1`, [p8Id]);
  assert(escOut.rowCount === 2, 'escalation queues SMS rows for the contacts');
  const neverEvt = await rideClient.query(
    `select * from public.safety_events where ride_id = $1 and event_type = 'ride_never_started'`, [p8cId]);
  assert(neverEvt.rows[0].user_id === user1, 'a ride that never starts is flagged');
  const durEvt = await rideClient.query(
    `select * from public.safety_events where ride_id = $1 and event_type = 'ride_duration_exceeded'`, [p8bId]);
  assert(durEvt.rows[0].user_id === user1, 'an over-duration ride is flagged');
  await rideClient.query('set role authenticated');
  assert(gotEvent(monListen.seen, 'covia.safety.ride_never_started', p8cId), 'never-started broadcasts its event');
  assert(gotEvent(monListen.seen, 'covia.safety.ride_duration_exceeded', p8bId), 'duration-exceeded broadcasts its event');
  assert(await cnt(user1, 'safety_check') === escBaseline.hostSafety + 2, 'host is notified of never-started + duration issues');
  await monListen.end();

  // Suspension pauses detection (sharing continues); host-only control.
  await asUser(user2);
  const suspPass = await rideClient.query(`select * from public.suspend_ride_monitoring($1)`, [p8Id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof suspPass === 'string' && suspPass.includes('Only the host can control ride monitoring'), 'passengers cannot suspend monitoring');
  const checksBefore = await rideClient.query(
    `select count(*)::int as n from public.safety_events where ride_id = $1 and event_type = 'safety_check'`, [p8Id]);
  await asUser(user1);
  await rideClient.query(`select * from public.suspend_ride_monitoring($1)`, [p8Id]);
  const suspTwice = await rideClient.query(`select * from public.suspend_ride_monitoring($1)`, [p8Id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof suspTwice === 'string' && suspTwice.includes('No active monitoring'), 'monitoring cannot be suspended twice');
  await asUser(user2);
  await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lat: 6.5, lng: 3.36, speed: 0 })]);
  const checksAfter = await rideClient.query(
    `select count(*)::int as n from public.safety_events where ride_id = $1 and event_type = 'safety_check'`, [p8Id]);
  assert(checksAfter.rows[0].n === checksBefore.rows[0].n, 'suspended monitoring skips detection');
  const resumePass = await rideClient.query(`select * from public.resume_ride_monitoring($1)`, [p8Id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof resumePass === 'string' && resumePass.includes('Only the host can control ride monitoring'), 'passengers cannot resume monitoring');
  await asUser(user1);
  await rideClient.query(`select * from public.resume_ride_monitoring($1)`, [p8Id]);
  const resumeTwice = await rideClient.query(`select * from public.resume_ride_monitoring($1)`, [p8Id])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof resumeTwice === 'string' && resumeTwice.includes('Monitoring is not suspended'), 'monitoring cannot be resumed twice');

  // Manual incident report.
  await asUser(user4);
  const incidentOutsider = await rideClient.query(`select * from public.report_safety_incident($1, $2)`, [p8Id, 'test'])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof incidentOutsider === 'string' && incidentOutsider.includes('You are not on this ride'), 'outsiders cannot report incidents');
  await asUser(user2);
  const incidentBlank = await rideClient.query(`select * from public.report_safety_incident($1, $2)`, [p8Id, '  '])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof incidentBlank === 'string' && incidentBlank.includes('A note is required'), 'incident reports need a note');
  const incidentListen = await listenFor();
  const incident = await rideClient.query(`select * from public.report_safety_incident($1, $2)`, [p8Id, 'Driver asked me to sit in the front.']);
  await sleep(500);
  assert(incident.rows[0].event_type === 'manual_report' && incident.rows[0].metadata.note.includes('front'), 'an incident report is logged');
  assert(gotEvent(incidentListen.seen, 'covia.safety.incident', p8Id), 'incidents broadcast covia.safety.incident');
  await incidentListen.end();

  // Lifecycle: completing the ride finishes monitoring and purges locations.
  await asUser(user1);
  await rideClient.query(`select * from public.complete_ride($1)`, [p8Id]);
  const monEnd = await rideClient.query(`select status, finished_at from public.ride_monitoring where ride_id = $1`, [p8Id]);
  assert(monEnd.rows[0].status === 'finished' && monEnd.rows[0].finished_at !== null, 'completion finishes monitoring');
  const locsEnd = await rideClient.query(`select count(*)::int as n from public.live_locations where ride_id = $1`, [p8Id]);
  assert(locsEnd.rows[0].n === 0, 'live locations are purged when the ride ends');
  await asUser(user2);
  const locAfterEnd = await rideClient.query(`select * from public.update_live_location($1, $2)`, [p8Id, JSON.stringify({ lat: 6.5, lng: 3.36 })])
    .then(() => null).catch((e) => e.message ?? '');
  assert(typeof locAfterEnd === 'string' && locAfterEnd.includes('Live location is only shared during an active ride'), 'sharing stops after completion');
  await asUser(user1);
  await rideClient.query(`select * from public.complete_ride($1)`, [p8bId]);
  const monEnd2 = await rideClient.query(`select status from public.ride_monitoring where ride_id = $1`, [p8bId]);
  assert(monEnd2.rows[0].status === 'finished', 'completion finishes monitoring on every ride');

  // Retention: stale finished-ride locations are cleaned by the monitor.
  await rideClient.query('reset role');
  await rideClient.query(
    `insert into public.live_locations (ride_id, user_id, location, updated_at)
     values ($1, $2, '{"lat":6.5,"lng":3.36}', now() - interval '25 hours')`, [p8Id, user2]);
  await rideClient.query(`select public.run_safety_monitor() as actions`);
  await rideClient.query('set role authenticated');
  const locsRetained = await rideClient.query(`select count(*)::int as n from public.live_locations where ride_id = $1`, [p8Id]);
  assert(locsRetained.rows[0].n === 0, 'stale finished-ride locations are retained only within the window');

  // RLS over the safety tables.
  await asUser(user4);
  const seOutsider = await rideClient.query(`select count(*)::int as n from public.safety_events where ride_id = $1`, [p8Id]);
  assert(seOutsider.rows[0].n === 0, 'RLS hides safety events from outsiders');
  const rmOutsider = await rideClient.query(`select count(*)::int as n from public.ride_monitoring where ride_id = $1`, [p8Id]);
  assert(rmOutsider.rows[0].n === 0, 'RLS hides monitoring rows from outsiders');
  const cfgRead = await rideClient.query(`select count(*)::int as n from public.safety_config`);
  assert(cfgRead.rows[0].n === 1, 'safety config is readable by all authenticated users');
  await asUser(user1);
  const seVisible = await rideClient.query(`select count(*)::int as n from public.safety_events where ride_id = $1`, [p8Id]);
  assert(seVisible.rows[0].n > 0, 'ride members can read safety events');
  const rmVisible = await rideClient.query(`select count(*)::int as n from public.ride_monitoring where ride_id = $1`, [p8Id]);
  assert(rmVisible.rows[0].n === 1, 'ride members can read monitoring state');
  const seInsert = await rideClient.query(`insert into public.safety_events (ride_id, user_id, event_type) values ($1, $1, 'sos')`, [p8Id])
    .then(() => null).catch((e) => e.code);
  assert(seInsert === '42501', 'safety events are append-only via RPCs');
  const seUpdate = await rideClient.query(`update public.safety_events set severity = 'info' where ride_id = $1`, [p8Id])
    .then(() => null).catch((e) => e.code);
  assert(seUpdate === '42501', 'safety events cannot be edited directly');
  const rmUpdate = await rideClient.query(`update public.ride_monitoring set status = 'suspended' where ride_id = $1`, [p8Id])
    .then(() => null).catch((e) => e.code);
  assert(rmUpdate === '42501', 'monitoring rows cannot be edited directly');
  const outboundDenied = await rideClient.query(`select count(*)::int as n from public.outbound_notifications`)
    .then(() => null).catch((e) => e.code);
  assert(outboundDenied === '42501', 'the outbound queue is invisible to clients');

  // Restore the default thresholds.
  await rideClient.query('reset role');
  await rideClient.query(`select * from public.update_safety_config(
    p_route_deviation_meters => 500, p_stop_threshold_seconds => 120,
    p_safety_check_timeout_seconds => 60, p_never_started_minutes => 15,
    p_exceeded_duration_minutes => 45, p_notify_participants_on_sos => true,
    p_sos_repeat_window_seconds => 120, p_live_location_retention_hours => 24)`);
  await rideClient.query('set role authenticated');

  await rideClient.query('reset role');
  await rideClient.end();

  console.log(failures === 0 ? '\nAll checks passed.' : `\n${failures} check(s) FAILED.`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
