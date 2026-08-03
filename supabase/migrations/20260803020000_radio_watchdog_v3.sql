-- Watchdog v3 — detect an abandoned phone show FAST. v2 waited 3 hours on
-- radio_live.updated_at, but that column is only set at start (segments go to
-- storage, not the row), so it could never tell a dead show from a long one.
-- The honest signal is the PLAYLIST FILE: an active encoder rewrites live.m3u8
-- every ~4s. If it hasn't moved in 90s, the host is gone — clear the flag.

CREATE OR REPLACE FUNCTION public.radio_watchdog()
 RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  s record;
  np record;
  lv record;
  obj_name text;
  pl_mtime timestamptz;
  stalled boolean;
begin
  for s in select distinct station_id from radio_station_tracks loop
    select * into lv from radio_live l where l.station_id = s.station_id and l.live;

    if lv.station_id is not null then
      if lv.hls_url like '%/storage/v1/object/public/radio-live/%' then
        obj_name := substring(lv.hls_url from '/radio-live/(.*)$');
        select o.updated_at into pl_mtime
        from storage.objects o
        where o.bucket_id = 'radio-live' and o.name = obj_name;

        if pl_mtime is null or pl_mtime < now() - interval '90 seconds' then
          update radio_live set live = false, title = '', hls_url = '', updated_at = now()
          where station_id = s.station_id;
          insert into radio_alerts (station_id, kind, message)
          values (s.station_id, 'live_abandoned',
                  'phone show stopped pushing (playlist stale); flag cleared, rotation resumed');
        else
          update radio_alerts set cleared_at = now()
          where station_id = s.station_id and kind = 'stalled' and cleared_at is null;
          continue;
        end if;
      else
        update radio_alerts set cleared_at = now()
        where station_id = s.station_id and kind = 'stalled' and cleared_at is null;
        continue;
      end if;
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
