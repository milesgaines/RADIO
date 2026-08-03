-- RADI0 — hidden role registry for Sign in with Apple.
--
-- Three implicit roles, none of them visible in the UI: FAN (default —
-- listen, vote) and the staff pair (DJ/HOST + PROGRAMMER) for anyone who
-- signs in with a verified @onesync.music address. The apple-role Edge
-- Function verifies Apple's identityToken server-side and records who's
-- who here; staff sign-ins get the operator host key back and the existing
-- host machinery (GO LIVE console, THE BOARD) just works.
--
-- Why the table exists at all: Apple only reliably includes the `email`
-- claim on the FIRST authorization. apple-role persists the verified email
-- per stable Apple user id (`sub`) so later email-less sign-ins can fall
-- back to it — staff stay staff.
--
-- Companions this file assumes:
--   • Edge Function supabase/functions/apple-role — deployed separately
--     (with --no-verify-jwt; the Apple identityToken IS the auth on that
--     call, not a Supabase JWT).
--
-- Everything is guarded (if not exists / idempotent DDL) so re-running
-- against a project that already carries it converges instead of failing.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

-- One row per Apple identity ever seen. `email` is only ever written from a
-- VERIFIED token claim (apple-role's rule), so reading it back is safe to
-- trust for the staff-domain check.
create table if not exists public.radio_identities (
  apple_user_id text primary key,
  email text,
  role text not null default 'fan' check (role in ('fan', 'staff')),
  first_seen timestamptz default now(),
  last_seen timestamptz default now()
);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
-- Same posture as radio_secrets: RLS on, NO policies, and explicit revokes —
-- belt and suspenders. Unreadable and unwritable from the client, ever; only
-- the service role (apple-role) reaches it. Emails are personal data and the
-- roles are meant to be invisible — nothing here is broadcast material.

alter table public.radio_identities enable row level security;

revoke all on table public.radio_identities from anon, authenticated;
