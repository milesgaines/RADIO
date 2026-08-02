-- RADI0 — "PPM for music" market-research backend.
--
-- Turns the live vote stream (radio_votes) into a server-side, cross-device
-- aggregate RESONANCE per (station, track) — the real-time research signal the
-- app computes locally today, now measured across every listener at once and
-- consumable by the AI A&R agent (see supabase/functions/ar-agent).
--
-- Honest scope: resonance here is REAL (real votes, real listener counts). The
-- per-MARKET slice is still applied client-side via a deterministic seed until
-- geo-tagged votes exist — this migration ships the markets table and the
-- directive surface so a real geo feed and the AI agent slot straight in.
--
-- GOTCHA baked in: radio_votes.station_id is TEXT (uppercase UUID strings from
-- the app); every other table uses uuid. We cast v.station_id::uuid (Postgres
-- uuid parsing is case-insensitive) so joins line up.

-- ---------------------------------------------------------------------------
-- 1. Markets (seeded; a real geo backend replaces the seed, not this table)
-- ---------------------------------------------------------------------------
create table if not exists public.radio_markets (
  code text primary key,   -- "LA"
  name text not null,      -- "Los Angeles"
  sort int  not null default 0
);

insert into public.radio_markets(code, name, sort) values
  ('LA',  'Los Angeles', 1),
  ('ATL', 'Atlanta',     2),
  ('NYC', 'New York',    3),
  ('LDN', 'London',      4)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Materialized resonance per (station, track) — market-neutral base.
--    resonance ∈ [-1, 1] (0 = neutral), mirroring the client ResonanceEngine.
-- ---------------------------------------------------------------------------
create table if not exists public.radio_resonance (
  station_id  uuid   not null,
  track_id    uuid   not null,
  resonance   double precision not null default 0,   -- [-1, 1]
  velocity    double precision not null default 0,   -- [-1, 1]
  density     double precision not null default 0,   -- [0, 1]
  retention   double precision not null default 0.5, -- [0, 1] (neutral server-side)
  boosts      integer not null default 0,            -- recent boosts (velocity window)
  buries      integer not null default 0,            -- recent buries (velocity window)
  listeners   integer not null default 1,
  computed_at timestamptz not null default now(),
  primary key (station_id, track_id)
);
create index if not exists radio_resonance_station_idx on public.radio_resonance(station_id, resonance desc);

-- ---------------------------------------------------------------------------
-- 3. Rotation directives — the AI A&R agent's output (and any rule engine).
--    ADVISORY by default: nothing consumes these to change real rotation until
--    radio_config('ar_agent_apply') = 'true' (see the director wiring note at
--    the end). This keeps an autonomous model off real listeners' air until you
--    flip it on.
-- ---------------------------------------------------------------------------
create table if not exists public.radio_rotation_directives (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null,
  track_id   uuid not null,
  market     text references public.radio_markets(code),  -- null = all markets
  action     text not null check (action in ('promote','bench','hold')),
  reason     text not null default '',
  confidence double precision not null default 0.5,       -- [0, 1]
  source     text not null default 'ai',                  -- 'ai' | 'rule'
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists radio_directives_active_idx
  on public.radio_rotation_directives(station_id, active, created_at desc);

-- ---------------------------------------------------------------------------
-- 4. The compute function — aggregate real votes into resonance. SECURITY
--    DEFINER so pg_cron (and the edge agent) can run it; reads only, upserts
--    radio_resonance. Formula matches RadioKit's ResonanceEngine, minus the
--    per-track retention curve (no server-side presence-over-time), so the
--    retention term is neutral (0.5 → contributes 0). Anti-bot is already
--    enforced upstream by radio_votes' unique constraint + the rate-limited
--    radio_cast_vote RPC, so raw counts here are safe.
-- ---------------------------------------------------------------------------
create or replace function public.radio_compute_resonance()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  with
  live as (  -- approximate live audience per station
    select station_id, greatest(1, count(distinct listener_key))::int as l
    from radio_listeners
    where last_seen > now() - interval '2 minutes'
    group by station_id
  ),
  onair as (
    select station_id, track_id, started_at from radio_now_playing
  ),
  v as (  -- 30-min window of votes, station cast to uuid
    select (station_id)::uuid as station_id, track_id, direction, created_at
    from radio_votes
    where created_at > now() - interval '30 minutes'
  ),
  agg as (
    select
      v.station_id, v.track_id,
      count(*) filter (where v.direction =  1 and v.created_at > now() - interval '90 seconds') as boosts_recent,
      count(*) filter (where v.direction = -1 and v.created_at > now() - interval '90 seconds') as buries_recent,
      sum(v.direction)::double precision as net_window,
      count(*) filter (where v.direction = 1 and oa.started_at is not null and v.created_at >= oa.started_at) as boosts_thisplay
    from v
    left join onair oa on oa.station_id = v.station_id and oa.track_id = v.track_id
    group by v.station_id, v.track_id
  ),
  scored as (
    select
      a.station_id, a.track_id, a.boosts_recent, a.buries_recent,
      coalesce(li.l, 1) as l,
      tanh((((a.boosts_recent - a.buries_recent)::double precision / 90.0 * 60.0)
            / greatest(coalesce(li.l, 1), 1)) / 0.15)                       as velocity,
      ( (a.boosts_thisplay::double precision / greatest(coalesce(li.l,1),1))
        / (1 + (a.boosts_thisplay::double precision / greatest(coalesce(li.l,1),1))) ) as density,
      tanh(a.net_window / 4.0)                                              as standing
    from agg a
    left join live li on li.station_id = a.station_id
  )
  insert into radio_resonance
    (station_id, track_id, resonance, velocity, density, retention, boosts, buries, listeners, computed_at)
  select
    s.station_id, s.track_id,
    greatest(-1, least(1, 0.40 * s.velocity + 0.20 * s.density + 0.20 * s.standing)),
    s.velocity, s.density, 0.5, s.boosts_recent, s.buries_recent, s.l, now()
  from scored s
  on conflict (station_id, track_id) do update set
    resonance = excluded.resonance, velocity = excluded.velocity,
    density = excluded.density, retention = excluded.retention,
    boosts = excluded.boosts, buries = excluded.buries,
    listeners = excluded.listeners, computed_at = excluded.computed_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Run it every minute via pg_cron (unschedule first so re-running the
--    migration is idempotent).
-- ---------------------------------------------------------------------------
do $$
begin
  perform cron.unschedule('radio-compute-resonance')
  where exists (select 1 from cron.job where jobname = 'radio-compute-resonance');
exception when others then null;
end $$;
select cron.schedule('radio-compute-resonance', '* * * * *',
                     $cron$ select public.radio_compute_resonance(); $cron$);

-- ---------------------------------------------------------------------------
-- 6. RLS — resonance/markets/directives are readable by anyone (the app and
--    web player show them); writes happen only through the SECURITY DEFINER
--    function above and the service-role edge agent (which bypasses RLS).
-- ---------------------------------------------------------------------------
alter table public.radio_markets            enable row level security;
alter table public.radio_resonance          enable row level security;
alter table public.radio_rotation_directives enable row level security;

drop policy if exists radio_markets_read on public.radio_markets;
drop policy if exists radio_resonance_read on public.radio_resonance;
drop policy if exists radio_directives_read on public.radio_rotation_directives;
create policy radio_markets_read    on public.radio_markets            for select using (true);
create policy radio_resonance_read  on public.radio_resonance          for select using (true);
create policy radio_directives_read on public.radio_rotation_directives for select using (true);

grant select on public.radio_markets, public.radio_resonance, public.radio_rotation_directives
  to anon, authenticated;

-- Prime one computation now so the tables aren't empty on first read.
select public.radio_compute_resonance();

-- ---------------------------------------------------------------------------
-- DIRECTOR WIRING (deferred, intentional): to let the crowd/AI actually drop
-- records in and out server-side, radio_advance_stations() would, when
-- radio_config('ar_agent_apply')='true', bias its next-track pick by joining
-- active radio_rotation_directives (promote → weight up, bench → exclude) and
-- radio_resonance. Left OFF here so the agent runs advisory-only until you
-- flip the flag — no autonomous model touches real listeners' rotation yet.
-- ---------------------------------------------------------------------------
