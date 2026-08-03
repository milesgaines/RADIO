-- RADI0 — catalog tools: the PD loads the library. Applied 2026-08-03.
-- Public radio-tracks bucket (25MB, audio MIME) written only via the
-- key-gated track-upload edge fn; radio_add_track (URL-derived track_id,
-- md5('url:'||url) — same URL never duplicates; duration 30s..1h required,
-- the shared clock depends on it); radio_remove_station_track (unlink only,
-- refuses to empty a station — dead air guard).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('radio-tracks', 'radio-tracks', true, 26214400,
        array['audio/mpeg','audio/mp4','audio/aac','audio/x-m4a','audio/wav','audio/x-wav'])
on conflict (id) do update
  set public = true, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

CREATE OR REPLACE FUNCTION public.radio_add_track(
  p_key text, p_station uuid, p_title text, p_artist text,
  p_duration double precision, p_url text
) RETURNS uuid
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  tid uuid;
begin
  if not exists (select 1 from radio_admin a where a.key = p_key) then
    return null;
  end if;
  if p_url is null or p_url !~* '^https?://' then return null; end if;
  if p_duration is null or p_duration < 30 or p_duration > 3600 then return null; end if;
  if coalesce(trim(p_title), '') = '' then return null; end if;

  tid := md5('url:' || p_url)::uuid;
  insert into radio_tracks (track_id, title, artist, artist_id, duration_seconds, audio_url)
  values (tid, trim(p_title), coalesce(nullif(trim(p_artist), ''), 'RADI0'),
          md5('artist:' || coalesce(nullif(trim(p_artist), ''), 'RADI0'))::uuid,
          p_duration, p_url)
  on conflict (track_id) do update
    set title = excluded.title, artist = excluded.artist,
        duration_seconds = excluded.duration_seconds, audio_url = excluded.audio_url;
  insert into radio_station_tracks (station_id, track_id)
  values (p_station, tid)
  on conflict do nothing;
  return tid;
end $function$;

CREATE OR REPLACE FUNCTION public.radio_remove_station_track(
  p_key text, p_station uuid, p_track uuid
) RETURNS boolean
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from radio_admin a where a.key = p_key) then
    return false;
  end if;
  if (select count(*) from radio_station_tracks where station_id = p_station) <= 1 then
    return false;
  end if;
  delete from radio_station_tracks
  where station_id = p_station and track_id = p_track;
  return found;
end $function$;

grant execute on function public.radio_add_track(text, uuid, text, text, double precision, text) to anon, authenticated;
grant execute on function public.radio_remove_station_track(text, uuid, uuid) to anon, authenticated;
