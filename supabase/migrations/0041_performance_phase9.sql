-- Covia - Phase 9: Performance Optimization
-- ------------------------------------------------------------------
-- Targeted index additions and query improvements identified during
-- the Phase 9 performance audit.

-- =============================================================
-- 1. Chat read count lookup acceleration
-- =============================================================
-- get_chat_messages runs a subquery per message to count reads.
-- This composite index covers the message_reads(message_id) lookup
-- and avoids heap fetches for the count.
create index if not exists message_reads_message_id_idx
  on public.message_reads (message_id);

-- =============================================================
-- 2. Notification data JSONB index
-- =============================================================
-- Notifications are filtered by data->>'ride_id' on the client.
-- A GIN index on the data column accelerates JSONB key lookups.
create index if not exists notifications_data_idx
  on public.notifications using gin (data);

-- =============================================================
-- 3. Ride search composite index for status + visibility
-- =============================================================
-- search_rides filters on ride_status IN ('published','full')
-- and visible_at. A partial index covers only active rides.
create index if not exists rides_search_active_idx
  on public.rides (departure_time asc, created_at desc)
  where ride_status in ('published', 'full')
    and (visible_at is null or visible_at <= now());

-- =============================================================
-- 4. Ride participant lookup for is_ride_member()
-- =============================================================
-- is_ride_member is called in get_ride visibility checks.
create index if not exists ride_participants_member_idx
  on public.ride_participants (ride_id, user_id)
  where left_at is null;

-- =============================================================
-- 5. Admin list_verifications pagination
-- =============================================================
-- admin_list_verifications sorts by submitted_at desc.
create index if not exists verification_submissions_status_submitted_idx
  on public.verification_submissions (status, submitted_at desc);

-- =============================================================
-- 6. Fresh planner statistics
-- =============================================================
analyze;
