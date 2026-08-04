-- Fix O(n²) total_count in get_chat_messages
-- Previously, the count subquery ran once per row; now it runs once via CTE.

create or replace function public.get_chat_messages(
  p_chat_id uuid,
  p_before timestamptz default null,
  p_page_size int default 30
)
returns table (
  id uuid,
  chat_id uuid,
  sender_id uuid,
  sender_name text,
  message_type text,
  message text,
  media_url text,
  sent_at timestamptz,
  edited_at timestamptz,
  read_count bigint,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_total bigint;
begin
  perform public.assert_chat_access(p_chat_id, v_user);

  -- Compute total_count once (not per row)
  select count(*)::bigint into v_total
  from public.chat_messages allm
  where allm.chat_id = p_chat_id
    and allm.deleted_at is null;

  return query
  select m.id, m.chat_id, m.sender_id, pr.display_name as sender_name,
         m.message_type, m.message, m.media_url, m.sent_at, m.edited_at,
           (
             select count(*)::bigint
             from public.message_reads mr
             where mr.message_id = m.id
           ) as read_count,
         v_total as total_count
  from public.chat_messages m
  left join public.profiles pr on pr.id = m.sender_id
  where m.chat_id = p_chat_id
    and m.deleted_at is null
    and (p_before is null or m.sent_at < p_before)
  order by m.sent_at desc
  limit p_page_size;
end;
$$;
