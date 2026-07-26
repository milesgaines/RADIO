-- GO LIVE — storage for the live-show HLS.
--
-- The live-ingest Edge Function writes fMP4 segments + a rolling live.m3u8
-- here; listeners' AVPlayer fetches them by public URL. Public bucket, same
-- convention as radio-battles / radio-callins. Writes are service-role only
-- (the function); reads are public (a live radio stream is public by nature).
--
-- radio_live + radio_set_live(p_station,p_live,p_title,p_hls,p_key) already
-- exist in prod and are unchanged; this only adds the bucket.
--
-- Run in the Supabase SQL editor (or via the MCP) against OFFICIAL ONESYNC.

insert into storage.buckets (id, name, public)
values ('radio-live', 'radio-live', true)
on conflict (id) do update set public = true;

-- The host key that gates going live is a row in radio_admin (the same table
-- that approves call-ins). To mint a host key for the founder's device:
--
--   insert into radio_admin (key) values (encode(gen_random_bytes(24),'hex'))
--   returning key;   -- paste this into the app: long-press LOS ANGELES › HOST KEY
--
-- (Left commented — minting a credential is a deliberate act, not a migration.)
