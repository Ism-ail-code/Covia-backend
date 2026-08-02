-- =============================================================
-- 0037: Fix moderation engine polarity for reliability rules
-- =============================================================
-- Found live (2026-08-02 E2E): run_moderation_engine fired every
-- reliability_* rule on healthy accounts. The rules are described as
-- "score drops BELOW the threshold" (e.g. reliability_below_warning
-- fires below 60) but the engine compared `v_value >= threshold`,
-- so the default score of 90 tripped severity 1, 2 AND 4 rules —
-- suspending every new user the moment any reliability event was
-- recorded (e.g. the first completed ride). The smoke suite never
-- caught it because it disables the reliability rules for most
-- phases and the Phase 9 section only exercises the count-based
-- rules (cancellations_*, confirmed_reports_*, no_show_*).
--
-- Fix: the comparison direction depends on the metric kind —
-- counts fire at "at least threshold", reliability fires strictly
-- below the threshold.

create or replace function public.run_moderation_engine(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.moderation_rules;
  v_value numeric;
  v_active_severity integer;
  v_target_severity integer;
  v_action_type text;
  v_duration integer;
begin
  if p_user_id is null then
    return;
  end if;

  v_active_severity := public.user_active_moderation_severity(p_user_id);
  v_target_severity := 0;

  for v_rule in
    select * from public.moderation_rules
     where enabled = true
     order by severity
  loop
    v_value := public.metric_value(p_user_id, public.rule_metric(v_rule.rule_name));
    if v_value is not null then
      -- Polarity: counts fire at or above the threshold; the
      -- reliability score fires when it drops strictly below it.
      if public.rule_metric(v_rule.rule_name) = 'reliability' then
        if v_value < v_rule.threshold then
          v_target_severity := greatest(v_target_severity, v_rule.severity);
        end if;
      elsif v_value >= v_rule.threshold then
        v_target_severity := greatest(v_target_severity, v_rule.severity);
      end if;
    end if;
  end loop;

  if v_target_severity = 0 then
    return; -- nothing triggered
  end if;

  -- Graduated: escalate past the current level, never repeat it.
  if v_target_severity <= v_active_severity then
    v_target_severity := least(v_active_severity + 1, 4);
  end if;

  select action_type, duration_hours into v_action_type, v_duration
    from public.moderation_rules
   where severity = v_target_severity
     and enabled = true
   order by case action_type when 'suspension' then 0 else 1 end, threshold desc
   limit 1;

  if v_action_type is null then
    return;
  end if;

  insert into public.moderation_actions (
    user_id, action_type, status, reason, details, source,
    starts_at, ends_at
  ) values (
    p_user_id, v_action_type, 'active',
    'Automatic enforcement (severity ' || v_target_severity || ')',
    jsonb_build_object('triggered_severity', v_target_severity),
    'automatic', now(),
    case when v_duration is not null then now() + make_interval(hours => v_duration) else null end
  );

  -- Notify the user: warnings tell them what happened; restrictions too.
  begin
    if v_action_type = 'warning' then
      perform public.record_notification(
        p_user_id, 'warning_issued',
        'Account warning',
        'Your account has been issued a warning for behaviour that breaches our community guidelines.',
        jsonb_build_object('action_type', v_action_type)
      );
    else
      perform public.record_notification(
        p_user_id, 'account_restricted',
        'Account restriction',
        'Your account has been restricted from creating and joining rides. You can appeal this decision.',
        jsonb_build_object('action_type', v_action_type)
      );
    end if;
  exception when others then
    -- Notification failures must never break enforcement.
    null;
  end;
end;
$$;

-- Grants unchanged (internal helper, not exposed to clients):
revoke all on function public.run_moderation_engine(uuid) from public;
