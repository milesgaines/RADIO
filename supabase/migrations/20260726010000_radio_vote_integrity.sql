-- Vote integrity: one vote per device per track, server-enforced. The crowd
-- is the whole premise; a single device must not be able to stuff the tally.
-- (Applied to prod 2026-07-26; this file versions it.)
--
-- NOT solved here: Sybil resistance (many fake devices). That needs a real
-- device identity — Sign in with Apple or anonymous Supabase auth bound to
-- the listener_key — and is tracked separately. This ends the trivial
-- one-device-unlimited-votes exploit, which was the open door.

-- 1) Dedupe existing rows — keep the most recent per (station, track, listener).
delete from public.radio_votes v
using public.radio_votes v2
where v.station_id = v2.station_id
  and v.track_id = v2.track_id
  and v.listener_key = v2.listener_key
  and (v.created_at < v2.created_at
       or (v.created_at = v2.created_at and v.id < v2.id));

-- 2) Normalize casing (app sends uppercase) and enforce one-per-listener.
update public.radio_votes set station_id = upper(station_id)
  where station_id <> upper(station_id);
alter table public.radio_votes
  add constraint radio_votes_one_per_listener unique (station_id, track_id, listener_key);

-- 3) The ONLY write path: validate, throttle, upsert a single vote.
create or replace function public.radio_cast_vote(
  p_station text, p_track uuid, p_listener text, p_direction int
) returns void
  language plpgsql security definer set search_path to 'public'
as $$
begin
  if p_direction not in (-1, 1) then return; end if;
  if p_listener is null or length(p_listener) not between 8 and 64 then return; end if;
  if (select count(*) from radio_votes r
      where r.listener_key = p_listener
        and r.created_at > now() - interval '5 seconds') >= 4 then
    return;
  end if;
  insert into radio_votes (station_id, track_id, listener_key, direction)
  values (upper(p_station), p_track, p_listener, p_direction)
  on conflict (station_id, track_id, listener_key)
    do update set direction = excluded.direction, created_at = now();
end $$;

-- 4) Close the direct door: only the definer RPC may write votes now.
drop policy if exists "anyone can cast a radio vote" on public.radio_votes;
revoke insert, update, delete, truncate on public.radio_votes from anon, authenticated;
grant execute on function public.radio_cast_vote(text, uuid, text, int) to anon, authenticated;
