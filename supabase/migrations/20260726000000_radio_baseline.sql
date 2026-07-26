-- RADI0 — radio backend baseline.
--
-- Snapshotted from the live OFFICIAL ONESYNC project (tgkgdquivdoquxamtgcr)
-- on 2026-07-25, after the streaming world + broadcaster shipped. Until this
-- file, the entire backend existed only in prod; this makes it reproducible.
-- Apply to a fresh project and you get the whole station: shared clock,
-- votes, presence, battles, call-ins, drops, live shows.
--
-- Companions this file assumes:
--   • Edge Functions in supabase/functions/ (battle-submit, callin-submit,
--     live-ingest) — deployed separately.
--   • pg_cron + pgcrypto available (both ship enabled on Supabase).
--   • An operator key inserted into radio_admin by hand — minting a
--     credential is a deliberate act, not a migration (see
--     Tools/live-radio-setup.sql for the recipe).
--
-- Deliberately NOT migrated (data, not schema):
--   • radio_admin rows — credentials never enter version control.
--   • radio_config.listen_html — a legacy copy of the web player stashed in
--     the DB before the player had a real host. The canonical player is
--     web/listen.html in this repo, served from GitHub Pages.
--
-- Everything is guarded (if not exists / on conflict) so re-running against
-- a project that already carries some of it converges instead of failing.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Operator keys. A row here IS the credential that gates call-in approval
-- and going live. Public can never read it (RLS on, no policies).
create table if not exists public.radio_admin (
  key text primary key
);

-- The server-side catalog: every track the directors can air. `kind`
-- distinguishes songs from drops and approved call-ins.
create table if not exists public.radio_tracks (
  track_id uuid primary key,
  title text not null,
  artist text not null,
  artist_id uuid not null,
  duration_seconds double precision not null,
  audio_url text,
  kind text not null default 'song'
);

-- Which tracks rotate on which station.
create table if not exists public.radio_station_tracks (
  station_id uuid not null,
  track_id uuid not null references public.radio_tracks(track_id) on delete cascade,
  primary key (station_id, track_id)
);

-- The shared clock: one row per station, what's on air and exactly when it
-- started. Realtime-published; every device renders the same second.
create table if not exists public.radio_now_playing (
  station_id uuid primary key,
  track_id uuid not null,
  title text not null,
  artist text not null,
  started_at timestamptz not null,
  duration_seconds double precision not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.radio_play_history (
  id bigint generated always as identity primary key,
  station_id uuid not null,
  track_id uuid not null,
  played_at timestamptz not null default now()
);

-- The live vote stream. station_id is TEXT (the app sends uppercase UUID
-- strings) — compare with upper() against radio_now_playing's uuid column.
create table if not exists public.radio_votes (
  id uuid primary key default gen_random_uuid(),
  station_id text not null,
  track_id uuid not null,
  listener_key text not null,
  direction smallint not null,
  constraint radio_votes_direction_check check (direction = any (array['-1'::integer, 1])),
  created_at timestamptz not null default now()
);

-- Presence heartbeats (fallback path; live counts ride realtime presence).
create table if not exists public.radio_listeners (
  station_id uuid not null,
  listener_key text not null,
  last_seen timestamptz not null default now(),
  primary key (station_id, listener_key)
);

-- Director tunables (drop_every_n, battle_minutes). Functions carry
-- defaults, so rows are optional.
create table if not exists public.radio_config (
  key text primary key,
  value text not null
);

-- THE RING — song battles.
create table if not exists public.radio_battle_entries (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  artist text not null,
  listener_key text not null default '',
  audio_url text not null,
  duration_seconds double precision not null default 0,
  status text not null default 'queued',
  created_at timestamptz not null default now()
);

create table if not exists public.radio_battles (
  id uuid primary key default gen_random_uuid(),
  entry_a uuid not null references public.radio_battle_entries(id),
  entry_b uuid not null references public.radio_battle_entries(id),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  status text not null default 'open',
  a_score integer not null default 0,
  b_score integer not null default 0,
  winner uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.radio_battle_votes (
  battle_id uuid not null references public.radio_battles(id) on delete cascade,
  listener_key text not null,
  side text not null,
  constraint radio_battle_votes_side_check check (side = any (array['a'::text, 'b'::text])),
  created_at timestamptz not null default now(),
  primary key (battle_id, listener_key)
);

-- THE LINE — call-ins (pending → approved/rejected; approved airs via the
-- air queue).
create table if not exists public.radio_callins (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null,
  listener_key text not null default '',
  handle text not null default '',
  audio_url text not null,
  duration_seconds double precision not null default 0,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  aired_at timestamptz
);

-- Station idents/drops, aired on a cadence between songs.
create table if not exists public.radio_drops (
  id uuid primary key default gen_random_uuid(),
  station_id uuid,
  track_id uuid not null references public.radio_tracks(track_id) on delete cascade,
  active boolean not null default true
);

-- Priority queue the director drains before the crowd pick.
create table if not exists public.radio_air_queue (
  id bigint generated always as identity primary key,
  station_id uuid not null,
  track_id uuid not null references public.radio_tracks(track_id) on delete cascade,
  enqueued_at timestamptz not null default now(),
  aired_at timestamptz
);

-- Live shows: one row per station; when live, hls_url overrides the clock.
create table if not exists public.radio_live (
  station_id uuid primary key,
  live boolean not null default false,
  title text not null default '',
  hls_url text not null default '',
  started_at timestamptz,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Indexes (beyond primary keys)
-- ---------------------------------------------------------------------------

create index if not exists radio_votes_station_time
  on public.radio_votes (station_id, created_at desc);
create index if not exists radio_play_history_station_idx
  on public.radio_play_history (station_id, played_at desc);
create index if not exists radio_listeners_station_seen
  on public.radio_listeners (station_id, last_seen);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
-- The pattern everywhere: RLS on; the public reads what a radio makes public
-- anyway; anonymous writes exist ONLY where the product needs them (votes,
-- heartbeats) and carry a listener-key length sanity check. Everything else
-- writes through SECURITY DEFINER functions or service-role Edge Functions.
-- radio_admin has RLS on and NO policies: unreadable and unwritable from
-- the client, ever.

alter table public.radio_admin enable row level security;
alter table public.radio_tracks enable row level security;
alter table public.radio_station_tracks enable row level security;
alter table public.radio_now_playing enable row level security;
alter table public.radio_play_history enable row level security;
alter table public.radio_votes enable row level security;
alter table public.radio_listeners enable row level security;
alter table public.radio_config enable row level security;
alter table public.radio_battle_entries enable row level security;
alter table public.radio_battles enable row level security;
alter table public.radio_battle_votes enable row level security;
alter table public.radio_callins enable row level security;
alter table public.radio_drops enable row level security;
alter table public.radio_air_queue enable row level security;
alter table public.radio_live enable row level security;

do $$ begin
  create policy "radio tracks readable" on public.radio_tracks
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "radio station tracks readable" on public.radio_station_tracks
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "radio now playing readable" on public.radio_now_playing
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "radio history readable" on public.radio_play_history
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "radio votes are readable" on public.radio_votes
    for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "anyone can cast a radio vote" on public.radio_votes
    for insert to anon, authenticated
    with check (char_length(listener_key) >= 8 and char_length(listener_key) <= 64);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "radio listener presence is readable" on public.radio_listeners
    for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "radio listeners can heartbeat" on public.radio_listeners
    for insert to anon, authenticated
    with check (char_length(listener_key) >= 8 and char_length(listener_key) <= 64);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "radio listeners can refresh a heartbeat" on public.radio_listeners
    for update to anon, authenticated using (true)
    with check (char_length(listener_key) >= 8 and char_length(listener_key) <= 64);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "public read config" on public.radio_config
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "public read battle entries" on public.radio_battle_entries
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "public read battles" on public.radio_battles
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "public read callins" on public.radio_callins
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "public read drops" on public.radio_drops
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "public read live" on public.radio_live
    for select using (true);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- The director: every tick, for every station with a catalog, if the current
-- record has run out — air the next thing. Priority: live show halts
-- everything → air queue (approved call-ins, battle winners) → drop cadence →
-- the crowd's vote-weighted pick (never a literal request; Arista v. Launch
-- Media is the line).
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
begin
  select coalesce((select value::int from radio_config where key = 'drop_every_n'), 5)
    into drop_n;

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

        -- 3) The crowd's pick — vote-weighted, never a literal request.
        if nxt.track_id is null then
          select t.track_id, t.title, t.artist, t.duration_seconds into nxt
          from public.radio_tracks t
          join public.radio_station_tracks st on st.track_id = t.track_id
          where st.station_id = s.station_id
            and t.kind = 'song'
            and (cur.track_id is null or t.track_id <> cur.track_id)
            and t.track_id not in (
              select h.track_id from public.radio_play_history h
              where h.station_id = s.station_id
              order by h.played_at desc limit 3)
          order by -ln(random()) / greatest(0.05,
            1 + 0.15 * coalesce((
              select sum(v.direction)::double precision
              from public.radio_votes v
              where upper(v.station_id) = upper(s.station_id::text)  -- text col, app sends uppercase
                and v.track_id = t.track_id                          -- uuid = uuid
                and v.created_at > now() - interval '30 minutes'), 0))
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

-- Battles: settle every expired battle (tie → entry_a, a stated rule — the
-- ring must always settle), promote the winner into rotation on THE
-- UNDERGROUND, then pair the next two queued entries.
CREATE OR REPLACE FUNCTION public.radio_battle_director()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b record;
  e record;
  a_cnt int; b_cnt int;
  win uuid; lose uuid;
  minutes int;
  underground constant uuid := 'ba13d3b9-a9c7-807d-b73b-065938f474b5';
begin
  for b in select * from radio_battles where status = 'open' and ends_at <= now() loop
    select count(*) filter (where side = 'a'), count(*) filter (where side = 'b')
      into a_cnt, b_cnt
      from radio_battle_votes where battle_id = b.id;
    -- Tie goes to entry_a: first into the ring holds it. A stated rule, not
    -- a bug — battles must always settle.
    if a_cnt >= b_cnt then win := b.entry_a; lose := b.entry_b;
    else win := b.entry_b; lose := b.entry_a; end if;

    update radio_battles
      set status = 'settled', a_score = a_cnt, b_score = b_cnt, winner = win
      where id = b.id;
    update radio_battle_entries set status = 'won' where id = win;
    update radio_battle_entries set status = 'lost' where id = lose;

    select * into e from radio_battle_entries where id = win;
    if e.audio_url is not null and e.audio_url <> '' then
      insert into radio_tracks (track_id, title, artist, artist_id, duration_seconds, audio_url, kind)
      values (e.id, e.title, e.artist,
              md5('battle-artist:' || lower(e.artist))::uuid,
              greatest(e.duration_seconds, 30), e.audio_url, 'song')
      on conflict (track_id) do update set audio_url = excluded.audio_url;
      insert into radio_station_tracks (station_id, track_id)
        values (underground, e.id) on conflict do nothing;
      insert into radio_air_queue (station_id, track_id) values (underground, e.id);
    end if;
  end loop;

  if not exists (select 1 from radio_battles where status = 'open') then
    select coalesce((select value::int from radio_config where key = 'battle_minutes'), 60)
      into minutes;
    insert into radio_battles (entry_a, entry_b, starts_at, ends_at, status)
    select q.a, q.b, now(), now() + make_interval(mins => minutes), 'open'
    from (
      select (array_agg(id order by created_at))[1] as a,
             (array_agg(id order by created_at))[2] as b
      from (select id, created_at from radio_battle_entries
            where status = 'queued' order by created_at limit 2) x
    ) q
    where q.a is not null and q.b is not null;
    update radio_battle_entries set status = 'battling'
      where status = 'queued'
        and id in (select entry_a from radio_battles where status = 'open'
                   union select entry_b from radio_battles where status = 'open');
  end if;
end $function$;

-- One vote per listener per battle, switching sides allowed. Scores live on
-- the battle row so realtime UPDATE events carry them.
CREATE OR REPLACE FUNCTION public.radio_cast_battle_vote(p_battle uuid, p_listener text, p_side text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_side not in ('a','b') then return; end if;
  if p_listener is null or length(p_listener) not between 8 and 64 then return; end if;
  if not exists (select 1 from radio_battles b
                 where b.id = p_battle and b.status = 'open'
                   and now() between b.starts_at and b.ends_at) then
    return;
  end if;
  insert into radio_battle_votes (battle_id, listener_key, side)
  values (p_battle, p_listener, p_side)
  on conflict (battle_id, listener_key) do update
    set side = excluded.side, created_at = now();
  -- Scores live on the battle row so realtime UPDATE events carry them.
  update radio_battles b set
    a_score = (select count(*) from radio_battle_votes v where v.battle_id = b.id and v.side = 'a'),
    b_score = (select count(*) from radio_battle_votes v where v.battle_id = b.id and v.side = 'b')
  where b.id = p_battle;
end $function$;

-- Moderation: approve turns a pending call into a playable track + an air
-- queue entry; reject just closes it. Both gate on the operator key.
CREATE OR REPLACE FUNCTION public.radio_approve_callin(p_id uuid, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record;
begin
  if not exists (select 1 from radio_admin a where a.key = p_key) then return false; end if;
  select * into c from radio_callins where id = p_id and status = 'pending';
  if c.id is null then return false; end if;
  update radio_callins set status = 'approved' where id = p_id;
  insert into radio_tracks (track_id, title, artist, artist_id, duration_seconds, audio_url, kind)
  values (c.id,
          'ON THE LINE' || case when c.handle <> '' then ' — ' || upper(c.handle) else '' end,
          'THE LINE',
          md5('the-line')::uuid,
          greatest(c.duration_seconds, 3),
          c.audio_url,
          'callin')
  on conflict (track_id) do nothing;
  insert into radio_air_queue (station_id, track_id) values (c.station_id, c.id);
  return true;
end $function$;

CREATE OR REPLACE FUNCTION public.radio_reject_callin(p_id uuid, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from radio_admin a where a.key = p_key) then return false; end if;
  update radio_callins set status = 'rejected' where id = p_id and status = 'pending';
  return found;
end $function$;

-- Live shows: the key-gated switch the live-ingest Edge Function flips.
CREATE OR REPLACE FUNCTION public.radio_set_live(p_station uuid, p_live boolean, p_title text, p_hls text, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from radio_admin a where a.key = p_key) then return false; end if;
  insert into radio_live (station_id, live, title, hls_url, started_at, updated_at)
  values (p_station, p_live, coalesce(p_title, ''), coalesce(p_hls, ''),
          case when p_live then now() end, now())
  on conflict (station_id) do update
    set live = excluded.live,
        title = excluded.title,
        hls_url = excluded.hls_url,
        started_at = case when excluded.live and not radio_live.live then now() else radio_live.started_at end,
        updated_at = now();
  return true;
end $function$;

-- Heartbeat timestamps are server-authoritative.
CREATE OR REPLACE FUNCTION public.radio_touch_listener()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  new.last_seen := now();
  return new;
end
$function$;

drop trigger if exists radio_listeners_touch on public.radio_listeners;
create trigger radio_listeners_touch
  before insert or update on public.radio_listeners
  for each row execute function radio_touch_listener();

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
-- Only what devices genuinely watch live: votes, the shared clock, live
-- flips, and battle scores.

do $$ begin
  alter publication supabase_realtime add table public.radio_votes;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.radio_now_playing;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.radio_live;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.radio_battles;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Cron directors
-- ---------------------------------------------------------------------------
-- unschedule-then-schedule so re-running converges on the right cadence.

do $$ begin
  perform cron.unschedule('radio-director');
exception when others then null; end $$;
select cron.schedule('radio-director', '7 seconds', 'select public.radio_advance_stations()');

do $$ begin
  perform cron.unschedule('radio-battle-director');
exception when others then null; end $$;
select cron.schedule('radio-battle-director', '30 seconds', 'select public.radio_battle_director()');

-- ---------------------------------------------------------------------------
-- Storage buckets
-- ---------------------------------------------------------------------------
-- Public by design: battle entries, aired calls, and live HLS segments are
-- broadcast material. Writes go through the service-role Edge Functions only.
-- Size limits and MIME whitelists are enforced at the bucket too — the Edge
-- Functions check first, but bucket-level caps hold even if a function
-- regresses. (Bucket limits bind service-role uploads as well.)

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('radio-battles', 'radio-battles', true, 20971520,
   array['audio/mpeg','audio/mp4','audio/x-m4a','audio/aac','audio/wav','audio/x-wav','audio/vnd.wave']),
  ('radio-callins', 'radio-callins', true, 4194304,
   array['audio/mp4','audio/x-m4a','audio/aac','audio/mpeg']),
  ('radio-live', 'radio-live', true, 4194304,
   array['video/mp4','video/iso.segment','application/vnd.apple.mpegurl'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- Config defaults
-- ---------------------------------------------------------------------------
-- The functions coalesce to these same values; rows exist so operators can
-- tune them without a deploy.

insert into public.radio_config (key, value) values
  ('drop_every_n', '5'),
  ('battle_minutes', '60')
on conflict (key) do nothing;
