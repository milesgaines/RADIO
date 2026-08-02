-- RADI0 — director wiring: let resonance + the AI A&R agent bias real rotation.
--
-- This is the "deferred, intentional" step described at the bottom of
-- 20260728120000_radio_market_research.sql. It rewrites radio_advance_stations()
-- so the crowd's next-track pick (step 3) is scaled by:
--   • radio_resonance   — the cross-device, server-side "PPM for music" signal
--   • radio_rotation_directives — the AI A&R agent's promote/bench/hold calls
--
-- SAFETY — this changes NOTHING until you flip a switch:
--   Everything is gated on radio_config('ar_agent_apply'). When it is absent or
--   'false' (the default this migration seeds), the AI factor collapses to 1.0
--   and the ORDER BY weight is BYTE-IDENTICAL to the current function — same
--   rotation, same never-silent floor, no autonomous model on real air. The two
--   new LEFT JOINs cannot change the candidate set (radio_resonance is keyed
--   (station_id, track_id); the directive join is LATERAL … LIMIT 1), so the
--   pick is provably unchanged while the flag is off.
--
-- WHEN 'ar_agent_apply' = 'true':
--   resonance factor (only when fresh — computed_at within 15 min, else neutral):
--     resonance <= -0.6  → weight × 0.05   (soft-bench; still never fully silent)
--     resonance >=  0.35 → weight × least(4, 1 + 1.5·resonance)   (promote)
--   directive factor (active, market IS NULL only — geo slices stay client-side
--   until geo-tagged votes exist; an explicit directive rides ON TOP of raw
--   resonance):
--     action = 'bench'   → × 0.05
--     action = 'promote' → × least(4, 1 + 1.5·confidence)
--     action = 'hold'    → × 1.0 (no-op)
--   The 0.05 floors compose with the existing greatest(0.05, …) base floor, so a
--   benched record keeps a positive weight — the station is never silent.
--
-- Reversible: to pull the AI back off the air, set ar_agent_apply='false' (or
-- delete the row). No redeploy needed — the next 7-second tick is neutral again.

-- Make the gate explicit and OFF. Never overwrite a value you already set to
-- 'true' — this only seeds the row when it's missing.
insert into public.radio_config(key, value)
select 'ar_agent_apply', 'false'
where not exists (select 1 from public.radio_config where key = 'ar_agent_apply');

CREATE OR REPLACE FUNCTION public.radio_advance_stations()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s record;
  cur record;
  nxt record;
  new_start timestamptz;
  drop_n int;
  apply_ai boolean;
begin
  select coalesce((select value::int from radio_config where key = 'drop_every_n'), 5)
    into drop_n;
  -- The one gate. Read once per tick; false/absent = today's behaviour exactly.
  select coalesce((select value from radio_config where key = 'ar_agent_apply'), 'false') = 'true'
    into apply_ai;

  for s in select distinct station_id from public.radio_station_tracks loop
    if exists (select 1 from public.radio_live l
               where l.station_id = s.station_id and l.live) then
      continue;
    end if;

    select * into cur from public.radio_now_playing where station_id = s.station_id;

    if cur.station_id is null
       or cur.started_at + make_interval(secs => cur.duration_seconds) <= now() then

      -- 1) The air queue.
      select t.track_id, t.title, t.artist, t.duration_seconds, q.id as qid into nxt
      from public.radio_air_queue q
      join public.radio_tracks t on t.track_id = q.track_id
      where q.station_id = s.station_id and q.aired_at is null
      order by q.enqueued_at
      limit 1;

      if nxt.track_id is not null then
        update public.radio_air_queue set aired_at = now() where id = nxt.qid;
      else
        -- 2) Drop cadence: only when drops exist, the station has history,
        -- and the last drop_n spins were all songs.
        if exists (select 1 from public.radio_drops d
                   where d.active and (d.station_id = s.station_id or d.station_id is null))
           and (select count(*) from public.radio_play_history h
                where h.station_id = s.station_id) >= drop_n
           and not exists (
             select 1 from (
               select h.track_id from public.radio_play_history h
               where h.station_id = s.station_id
               order by h.played_at desc limit drop_n) r
             join public.radio_tracks t on t.track_id = r.track_id
             where t.kind <> 'song')
        then
          select t.track_id, t.title, t.artist, t.duration_seconds into nxt
          from public.radio_drops d
          join public.radio_tracks t on t.track_id = d.track_id
          where d.active and (d.station_id = s.station_id or d.station_id is null)
          order by random()
          limit 1;
        end if;

        -- 3) The crowd's pick — vote-weighted, never a literal request. When
        -- ar_agent_apply is on, resonance + AI directives scale that weight;
        -- when off, the ai_factor is 1.0 and this is the original pick exactly.
        if nxt.track_id is null then
          select t.track_id, t.title, t.artist, t.duration_seconds into nxt
          from public.radio_tracks t
          join public.radio_station_tracks st on st.track_id = t.track_id
          left join public.radio_resonance rr
            on rr.station_id = s.station_id and rr.track_id = t.track_id
          left join lateral (
            select d.action, d.confidence
            from public.radio_rotation_directives d
            where d.station_id = s.station_id and d.track_id = t.track_id
              and d.active and d.market is null
            order by d.created_at desc
            limit 1
          ) dir on true
          where st.station_id = s.station_id
            and t.kind = 'song'
            and (cur.track_id is null or t.track_id <> cur.track_id)
            and t.track_id not in (
              select h.track_id from public.radio_play_history h
              where h.station_id = s.station_id
              order by h.played_at desc limit 3)
          order by -ln(random()) / (
            greatest(0.05,
              1 + 0.15 * coalesce((
                select sum(v.direction)::double precision
                from public.radio_votes v
                where upper(v.station_id) = upper(s.station_id::text)  -- text col, app sends uppercase
                  and v.track_id = t.track_id                          -- uuid = uuid
                  and v.created_at > now() - interval '30 minutes'), 0))
            * case when apply_ai then
                -- resonance factor (fresh signal only, else neutral)
                (case
                   when rr.computed_at is not null
                        and rr.computed_at > now() - interval '15 minutes'
                        and rr.resonance <= -0.6 then 0.05
                   when rr.computed_at is not null
                        and rr.computed_at > now() - interval '15 minutes'
                        and rr.resonance >= 0.35 then least(4.0, 1 + 1.5 * rr.resonance)
                   else 1.0 end)
                -- directive factor (explicit AI call rides on top)
                * (case
                     when dir.action = 'bench'   then 0.05
                     when dir.action = 'promote' then least(4.0, 1 + 1.5 * coalesce(dir.confidence, 0.5))
                     else 1.0 end)
              else 1.0 end)
          limit 1;
        end if;
      end if;

      if nxt.track_id is null then continue; end if;

      if cur.station_id is null
         or now() - (cur.started_at + make_interval(secs => cur.duration_seconds)) > interval '30 seconds' then
        new_start := now();
      else
        new_start := cur.started_at + make_interval(secs => cur.duration_seconds);
      end if;

      insert into public.radio_now_playing as np
        (station_id, track_id, title, artist, started_at, duration_seconds, updated_at)
      values
        (s.station_id, nxt.track_id, nxt.title, nxt.artist, new_start, nxt.duration_seconds, now())
      on conflict (station_id) do update
        set track_id = excluded.track_id,
            title = excluded.title,
            artist = excluded.artist,
            started_at = excluded.started_at,
            duration_seconds = excluded.duration_seconds,
            updated_at = now();

      insert into public.radio_play_history (station_id, track_id, played_at)
      values (s.station_id, nxt.track_id, new_start);
    end if;
  end loop;
end $function$;
