-- RADI0 — the PD DESK: the Program Director's real levers, key-gated —
-- plus the station watchdog (dead air never goes unnoticed).
-- Applied to prod 2026-08-03. The watchdog here is v2: v1's staleness test
-- (updated_at > 3 min) false-alarmed on any record longer than 3 minutes,
-- and its first hour on duty caught a REAL incident — a phone show that
-- died without sending stop held PWR's clock frozen for 3 hours. v2 tests
-- "the record should have ended by now" and auto-heals abandoned phone
-- shows (storage-hosted live rows older than 3h → flag off, alert filed).

CREATE OR REPLACE FUNCTION public.radio_queue_premiere(
  p_station uuid, p_track uuid, p_key text
) RETURNS boolean
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from radio_admin a where a.key = p_key) then
    return false;
  end if;
  if not exists (select 1 from radio_station_tracks st
                 where st.station_id = p_station and st.track_id = p_track) then
    return false;
  end if;
  if exists (select 1 from radio_air_queue q
             where q.station_id = p_station and q.track_id = p_track
               and q.aired_at is null) then
    return false;
  end if;
  insert into radio_air_queue (station_id, track_id) values (p_station, p_track);
  return true;
end $function$;

CREATE OR REPLACE FUNCTION public.radio_pending_queue(p_station uuid)
 RETURNS TABLE(id bigint, track_id uuid, title text, artist text, enqueued_at timestamptz)
 LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select q.id, q.track_id, t.title, t.artist, q.enqueued_at
  from radio_air_queue q join radio_tracks t on t.track_id = q.track_id
  where q.station_id = p_station and q.aired_at is null
  order by q.enqueued_at;
$function$;

CREATE OR REPLACE FUNCTION public.radio_cancel_premiere(p_id bigint, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from radio_admin a where a.key = p_key) then
    return false;
  end if;
  delete from radio_air_queue where id = p_id and aired_at is null;
  return found;
end $function$;

CREATE OR REPLACE FUNCTION public.radio_set_drop_active(
  p_id uuid, p_active boolean, p_key text
) RETURNS boolean
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from radio_admin a where a.key = p_key) then
    return false;
  end if;
  update radio_drops set active = p_active where id = p_id;
  return found;
end $function$;

grant execute on function public.radio_queue_premiere(uuid, uuid, text) to anon, authenticated;
grant execute on function public.radio_pending_queue(uuid) to anon, authenticated;
grant execute on function public.radio_cancel_premiere(bigint, text) to anon, authenticated;
grant execute on function public.radio_set_drop_active(uuid, boolean, text) to anon, authenticated;

create table if not exists public.radio_alerts (
  id bigint generated always as identity primary key,
  station_id uuid not null,
  kind text not null default 'stalled',
  message text not null default '',
  created_at timestamptz not null default now(),
  cleared_at timestamptz
);

alter table public.radio_alerts enable row level security;
do $$ begin
  create policy "radio alerts readable" on public.radio_alerts
    for select using (true);
exception when duplicate_object then null; end $$;
grant select on public.radio_alerts to anon, authenticated;

CREATE OR REPLACE FUNCTION public.radio_watchdog()
 RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  s record;
  np record;
  lv record;
  stalled boolean;
begin
  for s in select distinct station_id from radio_station_tracks loop
    select * into lv from radio_live l where l.station_id = s.station_id and l.live;

    if lv.station_id is not null then
      if lv.hls_url like '%/storage/v1/object/public/radio-live/%'
         and lv.updated_at < now() - interval '3 hours' then
        update radio_live set live = false, title = '', hls_url = '', updated_at = now()
        where station_id = s.station_id;
        insert into radio_alerts (station_id, kind, message)
        values (s.station_id, 'live_abandoned',
                'phone show never sent stop; flag auto-cleared after 3h, rotation resumed');
      end if;
      update radio_alerts set cleared_at = now()
      where station_id = s.station_id and kind = 'stalled' and cleared_at is null;
      continue;
    end if;

    select * into np from radio_now_playing where station_id = s.station_id;
    stalled := (np.station_id is null)
      or (np.started_at + make_interval(secs => np.duration_seconds)
          + interval '45 seconds' < now());
    if stalled then
      if not exists (select 1 from radio_alerts a
                     where a.station_id = s.station_id
                       and a.kind = 'stalled' and a.cleared_at is null) then
        insert into radio_alerts (station_id, kind, message)
        values (s.station_id, 'stalled',
                coalesce('clock last moved ' || to_char(np.updated_at, 'YYYY-MM-DD HH24:MI:SSZ'),
                         'no now-playing row'));
      end if;
    else
      update radio_alerts set cleared_at = now()
      where station_id = s.station_id and kind = 'stalled' and cleared_at is null;
    end if;
  end loop;
end $function$;

do $$ begin
  perform cron.unschedule('radio-watchdog');
exception when others then null; end $$;
select cron.schedule('radio-watchdog', '*/2 * * * *', $cmd$ select public.radio_watchdog(); $cmd$);
