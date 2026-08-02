-- RADI0 — Mux live streaming + auto-replay.
--
-- The phone path (live-ingest) shovels HLS fragments into storage; this adds
-- the pro path: a Mux live stream per station. A host points OBS (or any
-- RTMPS/SRT encoder) at Mux, Mux transcodes to HLS, and the mux-poll Edge
-- Function flips `radio_live` so every tuned device switches — the app needs
-- zero changes. Every broadcast auto-records to a Mux asset; mux-poll files
-- ready recordings into `radio_episodes` for replay.
--
-- Companions this file assumes:
--   • Edge Function supabase/functions/mux-poll — deployed separately
--     (with --no-verify-jwt; it gates on x-radio-admin, not a JWT).
--   • supabase/seed-mux-secrets.sql applied BY HAND once — the Mux API token
--     and stream key never enter version control (same rule as radio_admin).
--   • pg_cron + pg_net available (both ship enabled on Supabase).
--
-- Everything is guarded (if not exists / on conflict) so re-running converges.

-- The cron below calls the edge function over HTTP — pg_net provides that.
-- (Found missing on prod during first deploy: every tick failed with
-- `schema "net" does not exist` until this line ran.)
create extension if not exists pg_net;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Server-side secrets (Mux API token, stream keys). Same posture as
-- radio_admin: RLS on, NO policies — unreadable and unwritable from the
-- client, ever. Only service-role / SECURITY DEFINER paths reach it.
-- Rows are seeded by hand via supabase/seed-mux-secrets.sql (gitignored).
create table if not exists public.radio_secrets (
  key text primary key,
  value text not null
);

-- One Mux live stream per station. The playback id is public by design
-- (it's in every listener's HLS URL anyway); the stream KEY is a secret and
-- lives in radio_secrets, never here.
create table if not exists public.radio_mux (
  station_id uuid primary key,
  live_stream_id text not null,
  playback_id text not null,
  created_at timestamptz not null default now()
);

-- The replay shelf: every finished broadcast, from either path. `source`
-- distinguishes Mux auto-recordings from phone-path captures.
-- provider_asset_id is unique so re-polling Mux dedupes instead of piling up.
create table if not exists public.radio_episodes (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null,
  title text not null default '',
  host text,
  source text not null check (source in ('mux', 'phone')),
  provider_asset_id text unique,
  hls_url text not null,
  duration_seconds double precision,
  recorded_at timestamptz not null default now()
);

create index if not exists radio_episodes_station_recorded
  on public.radio_episodes (station_id, recorded_at desc);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
-- radio_secrets: RLS on, no policies, and explicit revokes — belt and
-- suspenders. radio_mux and radio_episodes: public read (both hold only
-- public playback material), writes through service role only.

alter table public.radio_secrets enable row level security;
alter table public.radio_mux enable row level security;
alter table public.radio_episodes enable row level security;

revoke all on table public.radio_secrets from anon, authenticated;

do $$ begin
  create policy "radio mux mapping readable" on public.radio_mux
    for select using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "radio episodes readable" on public.radio_episodes
    for select using (true);
exception when duplicate_object then null; end $$;

grant select on public.radio_mux to anon, authenticated;
grant select on public.radio_episodes to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Station → stream mapping (public identifiers only)
-- ---------------------------------------------------------------------------
-- PWR DAMIZZA, the flagship. Created 2026-08-02 via the Mux API
-- (audio_only, reconnect_window 300, auto-recording to public assets).

insert into public.radio_mux (station_id, live_stream_id, playback_id) values
  ('bb940e5c-0a54-852c-b00c-81434978757c',
   'VJBOq9KmniP9hq6dRsM5CFzJR6Qc02S15aN5uEXepFjg',
   'pLeaN01o1yEhGSqG8ySVe9jumJKukiAOymPKNtTmW2Kk')
on conflict (station_id) do update
  set live_stream_id = excluded.live_stream_id,
      playback_id = excluded.playback_id;

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- File a finished broadcast onto the replay shelf. SECURITY DEFINER with no
-- public execute — only the service role (mux-poll) calls it. The unique
-- provider_asset_id makes re-polling idempotent.
CREATE OR REPLACE FUNCTION public.radio_add_episode(
  p_station uuid,
  p_title text,
  p_host text,
  p_source text,
  p_provider_asset_id text,
  p_hls text,
  p_duration double precision,
  p_recorded_at timestamptz default now()
)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_source not in ('mux', 'phone') then return false; end if;
  if p_hls is null or p_hls = '' then return false; end if;
  insert into radio_episodes
    (station_id, title, host, source, provider_asset_id, hls_url,
     duration_seconds, recorded_at)
  values
    (p_station, coalesce(p_title, ''), p_host, p_source, p_provider_asset_id,
     p_hls, p_duration, coalesce(p_recorded_at, now()))
  on conflict (provider_asset_id) do nothing;
  return found;
end $function$;

revoke execute on function public.radio_add_episode(uuid, text, text, text, text, text, double precision, timestamptz)
  from public, anon, authenticated;
grant execute on function public.radio_add_episode(uuid, text, text, text, text, text, double precision, timestamptz)
  to service_role;

-- ---------------------------------------------------------------------------
-- Cron: the Mux watcher
-- ---------------------------------------------------------------------------
-- Every 30 seconds, poke the mux-poll Edge Function. It checks each mapped
-- live stream: active → flip radio_live to the Mux HLS URL; idle → clear it
-- (Mux URLs only — a phone-path broadcast is never stomped); and file any
-- newly ready recordings as episodes. The x-radio-admin header is read from
-- radio_admin at call time, so the credential never appears in the cron
-- command or this file. unschedule-then-schedule so re-running converges.

do $$ begin
  perform cron.unschedule('radio-mux-poll');
exception when others then null; end $$;
select cron.schedule(
  'radio-mux-poll',
  '30 seconds',
  $cmd$
  select net.http_post(
    url := 'https://tgkgdquivdoquxamtgcr.supabase.co/functions/v1/mux-poll',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-radio-admin', (select key from public.radio_admin limit 1)
    ),
    body := '{}'::jsonb
  );
  $cmd$
);
