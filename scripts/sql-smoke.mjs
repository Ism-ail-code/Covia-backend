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

  await rideClient.query('reset role');
  await rideClient.end();

  console.log(failures === 0 ? '\nAll checks passed.' : `\n${failures} check(s) FAILED.`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
