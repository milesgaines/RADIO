// GO LIVE — live-show ingest. The phone can't run a media server, so it
// segments the mic into Apple-HLS fragments itself (AVAssetWriter) and pushes
// them here. This function is the host's shovel into public storage plus the
// switch that flips the `radio_live` row every tuned device watches.
//
// Actions, all multipart/form-data:
//   start    → validate the host key, write the live row (title + playlist
//              URL), return that URL.
//   segment  → store one fMP4 fragment (init.mp4 or segNNNNN.m4s), immutable,
//              long-cached so the CDN serves it fast.
//   playlist → overwrite live.m3u8, NO-cache so listeners see new segments.
//   stop     → flip the live row off.
//   purge    → delete a cold show's stored fragments (storage hygiene).
//
// Gate: the coarse publishable key (matches battle-submit / callin-submit)
// plus the fine host key, checked against `radio_admin` on every call —
// seizing every listener's speaker is not an open mic.
import { createClient } from "npm:@supabase/supabase-js@2";

const PUBLISHABLE = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii";
const BUCKET = "radio-live";

const supa = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "apikey, authorization, content-type",
};

function json(x: unknown, status = 200) {
  return new Response(JSON.stringify(x), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Segment names are ours to define — never trust the client with a path.
const NAME_RE = /^(init\.mp4|seg\d{5}\.m4s)$/;

async function isHostKey(key: string): Promise<boolean> {
  if (!key) return false;
  const { data } = await supa.from("radio_admin").select("key").eq("key", key).limit(1);
  return !!data && data.length > 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  if (req.headers.get("apikey") !== PUBLISHABLE) return json({ error: "key" }, 401);

  const form = await req.formData().catch(() => null);
  if (!form) return json({ error: "form" }, 400);

  const action = String(form.get("action") ?? "");
  const station = String(form.get("station_id") ?? "").toLowerCase();
  const session = String(form.get("session") ?? "");
  const key = String(form.get("key") ?? "");

  if (!UUID_RE.test(station) || !UUID_RE.test(session)) return json({ error: "fields" }, 400);
  if (!(await isHostKey(key))) return json({ error: "not_host" }, 403);

  const dir = `${station}/${session}`;
  const playlistPath = `${dir}/live.m3u8`;

  switch (action) {
    case "start": {
      const title = String(form.get("title") ?? "").slice(0, 80);
      const { data: pub } = supa.storage.from(BUCKET).getPublicUrl(playlistPath);
      const hls = pub.publicUrl;
      // radio_set_live re-checks the key and upserts the row the clients watch.
      const { data: ok, error } = await supa.rpc("radio_set_live", {
        p_station: station,
        p_live: true,
        p_title: title,
        p_hls: hls,
        p_key: key,
      });
      if (error) return json({ error: error.message }, 500);
      if (ok !== true) return json({ error: "not_host" }, 403);
      return json({ ok: true, hls_url: hls });
    }

    case "segment": {
      const name = String(form.get("name") ?? "");
      const file = form.get("file");
      if (!NAME_RE.test(name)) return json({ error: "name" }, 400);
      if (!(file instanceof File)) return json({ error: "file" }, 400);
      // A voice fragment is small; a fat one is abuse, not audio.
      if (file.size > 3 * 1024 * 1024) return json({ error: "too_big" }, 413);
      const contentType = name.endsWith(".mp4") ? "video/mp4" : "video/iso.segment";
      const up = await supa.storage.from(BUCKET).upload(`${dir}/${name}`, file, {
        contentType,
        cacheControl: "31536000", // immutable: unique name, never rewritten
        upsert: true,
      });
      if (up.error) return json({ error: up.error.message }, 500);
      return json({ ok: true });
    }

    case "playlist": {
      const text = String(form.get("playlist") ?? "");
      if (!text.startsWith("#EXTM3U")) return json({ error: "playlist" }, 400);
      if (text.length > 64 * 1024) return json({ error: "too_big" }, 413);
      const body = new Blob([text], { type: "application/vnd.apple.mpegurl" });
      const up = await supa.storage.from(BUCKET).upload(playlistPath, body, {
        contentType: "application/vnd.apple.mpegurl",
        cacheControl: "0", // must revalidate — this is the live edge
        upsert: true,
      });
      if (up.error) return json({ error: up.error.message }, 500);
      return json({ ok: true });
    }

    case "stop": {
      const { error } = await supa.rpc("radio_set_live", {
        p_station: station,
        p_live: false,
        p_title: "",
        p_hls: "",
        p_key: key,
      });
      if (error) return json({ error: error.message }, 500);
      return json({ ok: true });
    }

    // Storage hygiene: a finished show's fragments live on so late joiners can
    // drain the last window. Once it's cold, the host (or a cron) purges the
    // session's objects so the bucket doesn't grow without bound.
    case "purge": {
      const { data: listed, error: listErr } = await supa.storage.from(BUCKET).list(dir, { limit: 1000 });
      if (listErr) return json({ error: listErr.message }, 500);
      const paths = (listed ?? []).map((o) => `${dir}/${o.name}`);
      if (paths.length) {
        const { error: rmErr } = await supa.storage.from(BUCKET).remove(paths);
        if (rmErr) return json({ error: rmErr.message }, 500);
      }
      return json({ ok: true, removed: paths.length });
    }

    default:
      return json({ error: "action" }, 400);
  }
});
