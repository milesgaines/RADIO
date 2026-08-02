-- RADI0 — seed PWR DAMIZZA (the flagship) into the server rotation, and retire
-- the 3 orphan stations left by the old swell/album/singles seed.
--
-- Track/station ids are the app's deterministic FNV-1a stableID() values
-- (station:pwr damizza -> bb940e5c-...; track:<filename> for each bundled
-- master), so the server clock references exactly the ids every device
-- computes locally. audio_url stays NULL: app listeners resolve the bundled
-- masters; hosting for web/fresh installs is a later, separate step.
-- APPLIED TO PROD 2026-08-02 via execute_sql; idempotent (safe to re-run).

begin;
-- 1) Ensure all 21 PWR masters exist as tracks (idempotent; some already exist via the old station)
insert into radio_tracks (track_id, title, artist, artist_id, duration_seconds, audio_url, kind) values
('de8d4343-487f-86a9-850e-8c506bce5ad1','2 Dope Boys','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',111.383,null,'song'),
('05d6faa8-8a93-8ddf-9695-6ea0e2a8bf3f','2MPH','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',207.805,null,'song'),
('93cc6d58-15af-86b1-bc55-e724cb5b127d','Dancin','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',222.222,null,'song'),
('87753929-4fe4-869f-aace-79866c0d1617','Draft Day','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',280.976,null,'song'),
('e6a0288d-fb59-8b69-a07c-b8ce5bdea94d','Find a Way','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',165.161,null,'song'),
('550a3f20-33f4-8cce-b5a3-0736a67e12aa','Freeway City','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',195.349,null,'song'),
('14c127be-2ee2-87c0-a394-6f247373fcaa','Happy','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',89.302,null,'song'),
('c7238b50-741b-8e67-89b9-3f00bb0c0977','Heavy Is the Crown','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',208.696,null,'song'),
('741caf27-131e-8a9b-b5b8-6633c64fd5ab','I Miss the Old Hip Hop','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',128.519,null,'song'),
('3eefb8af-560e-8ec6-8b1e-3f6a45133068','Is It (Interlude)','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',113.258,null,'song'),
('c9c00005-08e4-8578-9d27-3ce8fd70622a','Laughin to the Bank','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',147.692,null,'song'),
('b4d1d46e-9942-89e1-a5d7-048c45aa65ad','Never Forget','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',161.798,null,'song'),
('5faeeffb-59b7-8e5f-9474-b61e91358bdf','On Beat with Game','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',181.098,null,'song'),
('64bbcbe7-9f4a-8002-b532-153f1cc50238','Ride My Wave (Explicit)','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',234.95,null,'song'),
('fbd05c53-6e7c-8bcf-b1b6-ac5e7ad93dcf','Ride My Wave','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',258.713,null,'song'),
('29d42f68-8217-8373-acad-a56b18617ddb','Safe','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',179.104,null,'song'),
('cd5e17f6-967d-8b9b-8501-ebec00e410a3','Scoring','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',168.247,null,'song'),
('370be8f9-8ecb-80de-b80c-9f49008a5ac4','Skrt Skrt','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',222.222,null,'song'),
('b860b9da-e154-8efe-8990-3f25b331cdb4','Stained Glass','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',229.064,null,'song'),
('edcde6ff-0a58-86d9-8cd1-b4660adf2491','Waiting','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',178.537,null,'song'),
('c3a10051-f37b-8702-bb37-946b4244d08e','Westside','Miles Gaines','ae3cc0ae-5a14-8481-88d5-a690f5d40d01',149.583,null,'song')
on conflict (track_id) do update set
  title = excluded.title, artist = excluded.artist,
  artist_id = excluded.artist_id, duration_seconds = excluded.duration_seconds;
-- 2) Enroll all 21 into PWR DAMIZZA so the director drives the flagship
insert into radio_station_tracks (station_id, track_id) values
('bb940e5c-0a54-852c-b00c-81434978757c','de8d4343-487f-86a9-850e-8c506bce5ad1'),
('bb940e5c-0a54-852c-b00c-81434978757c','05d6faa8-8a93-8ddf-9695-6ea0e2a8bf3f'),
('bb940e5c-0a54-852c-b00c-81434978757c','93cc6d58-15af-86b1-bc55-e724cb5b127d'),
('bb940e5c-0a54-852c-b00c-81434978757c','87753929-4fe4-869f-aace-79866c0d1617'),
('bb940e5c-0a54-852c-b00c-81434978757c','e6a0288d-fb59-8b69-a07c-b8ce5bdea94d'),
('bb940e5c-0a54-852c-b00c-81434978757c','550a3f20-33f4-8cce-b5a3-0736a67e12aa'),
('bb940e5c-0a54-852c-b00c-81434978757c','14c127be-2ee2-87c0-a394-6f247373fcaa'),
('bb940e5c-0a54-852c-b00c-81434978757c','c7238b50-741b-8e67-89b9-3f00bb0c0977'),
('bb940e5c-0a54-852c-b00c-81434978757c','741caf27-131e-8a9b-b5b8-6633c64fd5ab'),
('bb940e5c-0a54-852c-b00c-81434978757c','3eefb8af-560e-8ec6-8b1e-3f6a45133068'),
('bb940e5c-0a54-852c-b00c-81434978757c','c9c00005-08e4-8578-9d27-3ce8fd70622a'),
('bb940e5c-0a54-852c-b00c-81434978757c','b4d1d46e-9942-89e1-a5d7-048c45aa65ad'),
('bb940e5c-0a54-852c-b00c-81434978757c','5faeeffb-59b7-8e5f-9474-b61e91358bdf'),
('bb940e5c-0a54-852c-b00c-81434978757c','64bbcbe7-9f4a-8002-b532-153f1cc50238'),
('bb940e5c-0a54-852c-b00c-81434978757c','fbd05c53-6e7c-8bcf-b1b6-ac5e7ad93dcf'),
('bb940e5c-0a54-852c-b00c-81434978757c','29d42f68-8217-8373-acad-a56b18617ddb'),
('bb940e5c-0a54-852c-b00c-81434978757c','cd5e17f6-967d-8b9b-8501-ebec00e410a3'),
('bb940e5c-0a54-852c-b00c-81434978757c','370be8f9-8ecb-80de-b80c-9f49008a5ac4'),
('bb940e5c-0a54-852c-b00c-81434978757c','b860b9da-e154-8efe-8990-3f25b331cdb4'),
('bb940e5c-0a54-852c-b00c-81434978757c','edcde6ff-0a58-86d9-8cd1-b4660adf2491'),
('bb940e5c-0a54-852c-b00c-81434978757c','c3a10051-f37b-8702-bb37-946b4244d08e')
on conflict (station_id, track_id) do nothing;
-- 3) Retire the 3 stale orphan stations (old swell/album/singles seed; not on the dial)
delete from radio_now_playing    where station_id in ('ce9c44f8-3044-8e10-995f-b18464d21374','3015197d-2d01-84ee-b27d-275073ebb488','6fd3d3af-f3e3-8780-abdb-34b90570ddd4');
delete from radio_station_tracks where station_id in ('ce9c44f8-3044-8e10-995f-b18464d21374','3015197d-2d01-84ee-b27d-275073ebb488','6fd3d3af-f3e3-8780-abdb-34b90570ddd4');
commit;