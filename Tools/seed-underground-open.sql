-- THE UNDERGROUND: open music only. Drops the OneSync storage links,
-- seeds Audius public charts. Safe to re-run.
BEGIN;

-- 1. Unhook OneSync storage WAVs from the station (rows + orphaned tracks).
DELETE FROM radio_station_tracks s
USING radio_tracks t
WHERE s.station_id = 'ba13d3b9-a9c7-807d-b73b-065938f474b5'::uuid
  AND t.track_id = s.track_id
  AND t.audio_url LIKE '%/storage/v1/object/public/releases/%';

DELETE FROM radio_tracks t
WHERE t.audio_url LIKE '%/storage/v1/object/public/releases/%'
  AND NOT EXISTS (SELECT 1 FROM radio_station_tracks s WHERE s.track_id = t.track_id)
  AND NOT EXISTS (SELECT 1 FROM radio_now_playing np WHERE np.track_id = t.track_id)
  AND NOT EXISTS (SELECT 1 FROM radio_play_history h WHERE h.track_id = t.track_id);

-- 2. Seed the open catalog.
WITH new_tracks(track_id, title, artist, artist_id, duration_seconds, audio_url) AS (
  VALUES
    (md5('audius:Eqd36RR')::uuid,'Gorbunoff & Brandon Szabo & Alexiye - Yayu','Alexander Gorbunoff',md5('audius-artist:v2BWq46')::uuid,144,'https://discoveryprovider.audius.co/v1/tracks/Eqd36RR/stream?app_name=RADI0'),
    (md5('audius:agjG2vj')::uuid,'elevate','PERKZ',md5('audius-artist:xdArz')::uuid,262,'https://discoveryprovider.audius.co/v1/tracks/agjG2vj/stream?app_name=RADI0'),
    (md5('audius:aNVl2rj')::uuid,'CRaymak - Echo (feat. HVDES)','CRaymak',md5('audius-artist:lvAwWjw')::uuid,224,'https://discoveryprovider.audius.co/v1/tracks/aNVl2rj/stream?app_name=RADI0'),
    (md5('audius:rbR3QdV')::uuid,'BULLETPROOF CADDY','RafaelKaze',md5('audius-artist:MamB03Q')::uuid,184,'https://discoveryprovider.audius.co/v1/tracks/rbR3QdV/stream?app_name=RADI0'),
    (md5('audius:0Eb4JxK')::uuid,'Paulie Beats - Be With You (Radio)','Paulie Beats',md5('audius-artist:KbA9RP2')::uuid,190,'https://discoveryprovider.audius.co/v1/tracks/0Eb4JxK/stream?app_name=RADI0'),
    (md5('audius:la7RYXb')::uuid,'Jazcardan - Tropifresco','Jazcardan',md5('audius-artist:pPROo')::uuid,221,'https://discoveryprovider.audius.co/v1/tracks/la7RYXb/stream?app_name=RADI0'),
    (md5('audius:qxg9db')::uuid,'So Safe - Le Prof','Le Prof',md5('audius-artist:pzly520')::uuid,187,'https://discoveryprovider.audius.co/v1/tracks/qxg9db/stream?app_name=RADI0'),
    (md5('audius:WEEo8RZ')::uuid,'MI MUERTE- feat Mizil','Miguel Rea',md5('audius-artist:r2ZPVq8')::uuid,235,'https://discoveryprovider.audius.co/v1/tracks/WEEo8RZ/stream?app_name=RADI0'),
    (md5('audius:EXzZpQ')::uuid,'Detrox - DANZA RIDDIM','Detrox',md5('audius-artist:8EzY1YJ')::uuid,147,'https://discoveryprovider.audius.co/v1/tracks/EXzZpQ/stream?app_name=RADI0'),
    (md5('audius:g4vGmk9')::uuid,'Wonder','s.h.b.',md5('audius-artist:dpQXdpM')::uuid,323,'https://discoveryprovider.audius.co/v1/tracks/g4vGmk9/stream?app_name=RADI0'),
    (md5('audius:Xk5r9AJ')::uuid,'ILLIT - NOT CUTE ANYMORE (HALISKI edit)','HALISKI',md5('audius-artist:51K01')::uuid,204,'https://discoveryprovider.audius.co/v1/tracks/Xk5r9AJ/stream?app_name=RADI0'),
    (md5('audius:bmBbAvP')::uuid,'Maquina vs. Gold & Say It (Seduza & Nuwuyen Edit)','Nuwuyen',md5('audius-artist:4jR72J0')::uuid,235,'https://discoveryprovider.audius.co/v1/tracks/bmBbAvP/stream?app_name=RADI0'),
    (md5('audius:4WNKP2E')::uuid,'Chevelle - The Red (Stephanno Flip)','Stephanno',md5('audius-artist:4WE7y')::uuid,197,'https://discoveryprovider.audius.co/v1/tracks/4WNKP2E/stream?app_name=RADI0'),
    (md5('audius:MV362Ex')::uuid,'Fly Leaf - All Around Me (Spaceship Earth Remix)','Spaceship Earth',md5('audius-artist:ePWY0')::uuid,280,'https://discoveryprovider.audius.co/v1/tracks/MV362Ex/stream?app_name=RADI0'),
    (md5('audius:vRdav6V')::uuid,'modjo vs central cee - doja x lady (subtoll garage edit)','subtoll',md5('audius-artist:ngY6x')::uuid,183,'https://discoveryprovider.audius.co/v1/tracks/vRdav6V/stream?app_name=RADI0'),
    (md5('audius:7dY92Wr')::uuid,'josh pan, CURE97 & bauti - UNA UNA','bauti',md5('audius-artist:pzE9o')::uuid,186,'https://discoveryprovider.audius.co/v1/tracks/7dY92Wr/stream?app_name=RADI0'),
    (md5('audius:gW2j5O2')::uuid,'feel this weight','isaak',md5('audius-artist:D20d6')::uuid,287,'https://discoveryprovider.audius.co/v1/tracks/gW2j5O2/stream?app_name=RADI0'),
    (md5('audius:9p6MykO')::uuid,'Shimmer Remastered','Collizma',md5('audius-artist:D820W')::uuid,145,'https://discoveryprovider.audius.co/v1/tracks/9p6MykO/stream?app_name=RADI0'),
    (md5('audius:Wy9Rjj')::uuid,'Shizz Lo & Ewook - GO OFF!','Shizz Lo',md5('audius-artist:nVVky')::uuid,185,'https://discoveryprovider.audius.co/v1/tracks/Wy9Rjj/stream?app_name=RADI0'),
    (md5('audius:Eq8o634')::uuid,'RIGHT NOW','GETHEXED!',md5('audius-artist:Xlgwpgy')::uuid,199,'https://discoveryprovider.audius.co/v1/tracks/Eq8o634/stream?app_name=RADI0'),
    (md5('audius:OR1WXkX')::uuid,'Morning Coffee (Edit) - Luca Marney, B2B The Movement','Luca Marney',md5('audius-artist:7PWWEK7')::uuid,318,'https://discoveryprovider.audius.co/v1/tracks/OR1WXkX/stream?app_name=RADI0'),
    (md5('audius:5Rx2v1')::uuid,'WILD (Extended Mix)','JØEL',md5('audius-artist:y2lKX94')::uuid,276,'https://discoveryprovider.audius.co/v1/tracks/5Rx2v1/stream?app_name=RADI0'),
    (md5('audius:kpKw8p')::uuid,'JSSE - HtG','JSSE',md5('audius-artist:oaEG32')::uuid,320,'https://discoveryprovider.audius.co/v1/tracks/kpKw8p/stream?app_name=RADI0'),
    (md5('audius:ZOgM2BE')::uuid,'chief keef - hate being sober (kaito. remix)','kaito.',md5('audius-artist:D2W4p')::uuid,125,'https://discoveryprovider.audius.co/v1/tracks/ZOgM2BE/stream?app_name=RADI0'),
    (md5('audius:2PyK2j3')::uuid,'Ekonovah - Counting On You [Bassrush]','Ekonovah',md5('audius-artist:naObo')::uuid,160,'https://discoveryprovider.audius.co/v1/tracks/2PyK2j3/stream?app_name=RADI0'),
    (md5('audius:dGG52a2')::uuid,'Crunchy Roll','bvssbratt',md5('audius-artist:v737mWz')::uuid,217,'https://discoveryprovider.audius.co/v1/tracks/dGG52a2/stream?app_name=RADI0'),
    (md5('audius:gvkzA5W')::uuid,'Sandy Beach','Shell2Wig',md5('audius-artist:92kPoP2')::uuid,288,'https://discoveryprovider.audius.co/v1/tracks/gvkzA5W/stream?app_name=RADI0'),
    (md5('audius:jmXVl7j')::uuid,'I Might! - ZaZa Cade x Phrequency','Phrequency',md5('audius-artist:6NdXK8E')::uuid,153,'https://discoveryprovider.audius.co/v1/tracks/jmXVl7j/stream?app_name=RADI0'),
    (md5('audius:aANMYmw')::uuid,'Retro Vibes','Ljazz',md5('audius-artist:WgR5dAk')::uuid,139,'https://discoveryprovider.audius.co/v1/tracks/aANMYmw/stream?app_name=RADI0'),
    (md5('audius:b9do7AK')::uuid,'Belmondo','Maeki Maii',md5('audius-artist:v7O9O')::uuid,169,'https://discoveryprovider.audius.co/v1/tracks/b9do7AK/stream?app_name=RADI0'),
    (md5('audius:3Kzjaa0')::uuid,'Positive Progression','Aarr Kellz',md5('audius-artist:ZOkaq')::uuid,187,'https://discoveryprovider.audius.co/v1/tracks/3Kzjaa0/stream?app_name=RADI0'),
    (md5('audius:A9qpjJg')::uuid,'Olas Altas','Aarr Kellz',md5('audius-artist:ZOkaq')::uuid,132,'https://discoveryprovider.audius.co/v1/tracks/A9qpjJg/stream?app_name=RADI0'),
    (md5('audius:Wkl6zyv')::uuid,'Pavimento de Nylon','djteixo',md5('audius-artist:YZY9K')::uuid,178,'https://discoveryprovider.audius.co/v1/tracks/Wkl6zyv/stream?app_name=RADI0'),
    (md5('audius:mvpZMQv')::uuid,'Sol','Aarr Kellz',md5('audius-artist:ZOkaq')::uuid,203,'https://discoveryprovider.audius.co/v1/tracks/mvpZMQv/stream?app_name=RADI0'),
    (md5('audius:Q71O6GB')::uuid,'Phenomenon II','Tyler NichoLas Casey',md5('audius-artist:pZAxqKz')::uuid,419,'https://discoveryprovider.audius.co/v1/tracks/Q71O6GB/stream?app_name=RADI0'),
    (md5('audius:P9PJqVm')::uuid,'We Family (Feat. P0intblank)','V0cab',md5('audius-artist:G09RG')::uuid,231,'https://discoveryprovider.audius.co/v1/tracks/P9PJqVm/stream?app_name=RADI0'),
    (md5('audius:M6PWAMj')::uuid,'A Few Minutes Plz','V0cab',md5('audius-artist:G09RG')::uuid,172,'https://discoveryprovider.audius.co/v1/tracks/M6PWAMj/stream?app_name=RADI0'),
    (md5('audius:wV5jyAk')::uuid,'Art Of War','V0cab',md5('audius-artist:G09RG')::uuid,171,'https://discoveryprovider.audius.co/v1/tracks/wV5jyAk/stream?app_name=RADI0'),
    (md5('audius:X9A0Akb')::uuid,'znakomasbogom','NKNKT',md5('audius-artist:80XKX7J')::uuid,156,'https://discoveryprovider.audius.co/v1/tracks/X9A0Akb/stream?app_name=RADI0'),
    (md5('audius:82VjYYO')::uuid,'Silver.','Aarr Kellz',md5('audius-artist:ZOkaq')::uuid,192,'https://discoveryprovider.audius.co/v1/tracks/82VjYYO/stream?app_name=RADI0'),
    (md5('audius:lwPOoRw')::uuid,'We Family Part 2','V0cab',md5('audius-artist:G09RG')::uuid,104,'https://discoveryprovider.audius.co/v1/tracks/lwPOoRw/stream?app_name=RADI0'),
    (md5('audius:5xOrrX1')::uuid,'Tune In (Feat. Drastik)','V0cab',md5('audius-artist:G09RG')::uuid,185,'https://discoveryprovider.audius.co/v1/tracks/5xOrrX1/stream?app_name=RADI0'),
    (md5('audius:vjl2zA6')::uuid,'The Deep','Eve',md5('audius-artist:79l3q')::uuid,255,'https://discoveryprovider.audius.co/v1/tracks/vjl2zA6/stream?app_name=RADI0'),
    (md5('audius:agr7ymw')::uuid,'Dominant Frequency Projection (DFP)','Aarr Kellz',md5('audius-artist:ZOkaq')::uuid,140,'https://discoveryprovider.audius.co/v1/tracks/agr7ymw/stream?app_name=RADI0'),
    (md5('audius:vjPJpWV')::uuid,'Skill Recognize Skill','V0cab',md5('audius-artist:G09RG')::uuid,181,'https://discoveryprovider.audius.co/v1/tracks/vjPJpWV/stream?app_name=RADI0'),
    (md5('audius:32A9P8E')::uuid,'eye for an eye','phortran',md5('audius-artist:ngv3W')::uuid,203,'https://discoveryprovider.audius.co/v1/tracks/32A9P8E/stream?app_name=RADI0'),
    (md5('audius:l48gPE6')::uuid,'Beetlejuke & J.Velvet - Hustle Like Migos','Beetlejuke',md5('audius-artist:DBJrx')::uuid,226,'https://discoveryprovider.audius.co/v1/tracks/l48gPE6/stream?app_name=RADI0'),
    (md5('audius:PWOAb7')::uuid,'just a friend','phortran',md5('audius-artist:ngv3W')::uuid,187,'https://discoveryprovider.audius.co/v1/tracks/PWOAb7/stream?app_name=RADI0'),
    (md5('audius:Evw5wAJ')::uuid,'Sofasound x Kaiyo - Come On','Phuture Collective',md5('audius-artist:Wem1e')::uuid,181,'https://discoveryprovider.audius.co/v1/tracks/Evw5wAJ/stream?app_name=RADI0'),
    (md5('audius:RRZk0rX')::uuid,'Lick','Hotel Pools',md5('audius-artist:jZ1RQ10')::uuid,160,'https://discoveryprovider.audius.co/v1/tracks/RRZk0rX/stream?app_name=RADI0'),
    (md5('audius:mWkKop1')::uuid,'En un sueño te encontré (Remastered)','LionT_Music',md5('audius-artist:GR5Yv')::uuid,352,'https://discoveryprovider.audius.co/v1/tracks/mWkKop1/stream?app_name=RADI0'),
    (md5('audius:KbrjogY')::uuid,'everlasting','dharmonics',md5('audius-artist:Wx1rM2K')::uuid,170,'https://discoveryprovider.audius.co/v1/tracks/KbrjogY/stream?app_name=RADI0'),
    (md5('audius:QZvovYw')::uuid,'Fantasy - Produced by Mattrick x iLLPeTiL','MATTRICK',md5('audius-artist:lzwQ6')::uuid,194,'https://discoveryprovider.audius.co/v1/tracks/QZvovYw/stream?app_name=RADI0'),
    (md5('audius:EJg525M')::uuid,'Coming Up (Radio Edit)','Niza',md5('audius-artist:qzBXddM')::uuid,140,'https://discoveryprovider.audius.co/v1/tracks/EJg525M/stream?app_name=RADI0'),
    (md5('audius:pVJ6zXX')::uuid,'Mat Zo & Porter Robinson - Easy (The Sponges Remix)','The Sponges',md5('audius-artist:QxJZgKV')::uuid,276,'https://discoveryprovider.audius.co/v1/tracks/pVJ6zXX/stream?app_name=RADI0'),
    (md5('audius:bmvYW1J')::uuid,'UNREALITY // BLOSSOM','Digital Deity',md5('audius-artist:RN1OYBG')::uuid,303,'https://discoveryprovider.audius.co/v1/tracks/bmvYW1J/stream?app_name=RADI0'),
    (md5('audius:Qb5PdkR')::uuid,'forever','flutttr',md5('audius-artist:aKNwo')::uuid,141,'https://discoveryprovider.audius.co/v1/tracks/Qb5PdkR/stream?app_name=RADI0'),
    (md5('audius:jlN58kV')::uuid,'Big Deal  - Audius Summer Cypher - Remix','BOG Production''$',md5('audius-artist:KbBq2')::uuid,90,'https://discoveryprovider.audius.co/v1/tracks/jlN58kV/stream?app_name=RADI0'),
    (md5('audius:dRrOQZm')::uuid,'Chance','Hamber jane',md5('audius-artist:3OjYM68')::uuid,177,'https://discoveryprovider.audius.co/v1/tracks/dRrOQZm/stream?app_name=RADI0'),
    (md5('audius:8lbE3J')::uuid,'So We Meet Again','MATTRICK',md5('audius-artist:lzwQ6')::uuid,142,'https://discoveryprovider.audius.co/v1/tracks/8lbE3J/stream?app_name=RADI0'),
    (md5('audius:NPQ6p07')::uuid,'Party (Remix)','Manzobeat',md5('audius-artist:jNaGo')::uuid,157,'https://discoveryprovider.audius.co/v1/tracks/NPQ6p07/stream?app_name=RADI0'),
    (md5('audius:MadMG1x')::uuid,'Just Peachy','MATTRICK',md5('audius-artist:lzwQ6')::uuid,156,'https://discoveryprovider.audius.co/v1/tracks/MadMG1x/stream?app_name=RADI0'),
    (md5('audius:V45A046')::uuid,'TWO Audius Summer Cypher Remix Contest Prof . Manuel GAGO','El Hombre de las Nubes',md5('audius-artist:qJq2j2')::uuid,368,'https://discoveryprovider.audius.co/v1/tracks/V45A046/stream?app_name=RADI0'),
    (md5('audius:Kb9r1Br')::uuid,'Demise','MATTRICK',md5('audius-artist:lzwQ6')::uuid,167,'https://discoveryprovider.audius.co/v1/tracks/Kb9r1Br/stream?app_name=RADI0'),
    (md5('audius:6apN4XQ')::uuid,'BLACKFANG','MADTEK',md5('audius-artist:RN8j2PX')::uuid,185,'https://discoveryprovider.audius.co/v1/tracks/6apN4XQ/stream?app_name=RADI0'),
    (md5('audius:AkR29Mg')::uuid,'Stars','VR Vernon Rosser',md5('audius-artist:apbvA')::uuid,234,'https://discoveryprovider.audius.co/v1/tracks/AkR29Mg/stream?app_name=RADI0'),
    (md5('audius:oPwo6r5')::uuid,'Velocity Spike Type Beat (7-19-26)','Aleksandra',md5('audius-artist:EWWEx88')::uuid,119,'https://discoveryprovider.audius.co/v1/tracks/oPwo6r5/stream?app_name=RADI0'),
    (md5('audius:ap5X4Az')::uuid,'KYNIC - Our Eyes (Original Mix)','KYNIC',md5('audius-artist:rbg8mYO')::uuid,170,'https://discoveryprovider.audius.co/v1/tracks/ap5X4Az/stream?app_name=RADI0')
), ins AS (
  INSERT INTO radio_tracks (track_id, title, artist, artist_id, duration_seconds, audio_url)
  SELECT n.track_id, n.title, n.artist, n.artist_id, n.duration_seconds, n.audio_url
  FROM new_tracks n
  ON CONFLICT (track_id) DO UPDATE SET audio_url = EXCLUDED.audio_url
  RETURNING track_id
)
INSERT INTO radio_station_tracks (station_id, track_id)
SELECT 'ba13d3b9-a9c7-807d-b73b-065938f474b5'::uuid, track_id FROM ins
ON CONFLICT DO NOTHING;

COMMIT;