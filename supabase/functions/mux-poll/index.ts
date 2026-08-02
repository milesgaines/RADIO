// MUX WATCHER — the pro-path live switch + replay filer. The phone path
// (live-ingest) shovels HLS itself; the pro path points OBS at Mux and Mux
// does the transcoding. Nothing tells us when the encoder connects, so cron
// pokes this function every 30 seconds and it reconciles reality:
//
//   • Mux stream active  → flip `radio_live` to the Mux HLS URL (only if it
//     isn't already, and never over a phone-path broadcast — the phone URL
//     is supabase storage, and seizing an occupied mic is not reconciling).
//   • Mux stream idle    → clear `radio_live`, but ONLY if the row holds a
//     stream.mux.com URL. Phone shows are live-ingest's to start and stop.
//   • Recordings ready   → file them into `radio_episodes` via
//     radio_add_episode; the unique provider_asset_id dedupes re-polls.
//
// Gate: the x-radio-admin header, checked against `radio_admin` — the same
// operator credential live-ingest demands. The cron job builds the header
// from the radio_admin table at call time. The Mux API token pair lives in
// `radio_secrets` (RLS on, no policies), readable only from down here.
// Deploy with --no-verify-jwt; the admin key is the gate, not a JWT.
import { createClient } from "npm:@supabase/supabase-js@2";

const MUX_API = "https://api.mux.com";

// Base titles per station; anything unmapped broadcasts as plain RADI0.
const STATION_TITLES: Record<string, string> = {
  "bb940e5c-0a54-852c-b00c-81434978757c": "PWR DAMIZZA",
};

const supa = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "apikey, authorization, content-type, x-radio-admin",
};

function json(x: unknown, status = 200) {
  return new Response(JSON.stringify(x), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });
}

async function isHostKey(key: string): Promise<boolean> {
  if (!key) return false;
  const { data } = await supa.from("radio_admin").select("key").eq("key", key).limit(1);
  return !!data && data.length > 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const adminKey = req.headers.get("x-radio-admin") ?? "";
  if (!(await isHostKey(adminKey))) return json({ error: "not_host" }, 401);

  // The Mux token pair — seeded by hand into radio_secrets, never deployed.
  const { data: secrets, error: secErr } = await supa
    .from("radio_secrets")
    .select("key, value")
    .in("key", ["mux_token_id", "mux_token_secret"]);
  if (secErr) return json({ error: secErr.message }, 500);
  const sec = Object.fromEntries((secrets ?? []).map((r) => [r.key, r.value]));
  if (!sec.mux_token_id || !sec.mux_token_secret) {
    return json({ error: "mux_secrets_missing" }, 500);
  }
  const muxAuth = "Basic " + btoa(`${sec.mux_token_id}:${sec.mux_token_secret}`);

  const mux = (path: string) =>
    fetch(`${MUX_API}${path}`, { headers: { authorization: muxAuth } });

  const { data: stations, error: mapErr } = await supa
    .from("radio_mux")
    .select("station_id, live_stream_id, playback_id");
  if (mapErr) return json({ error: mapErr.message }, 500);

  let checked = 0;
  let live = 0;
  let episodesAdded = 0;
  const errors: string[] = [];

  for (const st of stations ?? []) {
    checked++;
    const base = STATION_TITLES[st.station_id] ?? "RADI0";
    const muxUrl = `https://stream.mux.com/${st.playback_id}.m3u8`;

    // --- The live switch -------------------------------------------------
    const lsRes = await mux(`/video/v1/live-streams/${st.live_stream_id}`);
    if (!lsRes.ok) {
      errors.push(`${st.station_id}: live-stream ${lsRes.status}`);
      continue;
    }
    const ls = (await lsRes.json()).data;

    const { data: liveRows } = await supa
      .from("radio_live")
      .select("live, hls_url")
      .eq("station_id", st.station_id)
      .limit(1);
    const cur = liveRows?.[0];
    const curIsMux = !!cur?.hls_url?.includes("stream.mux.com");

    if (ls.status === "active") {
      live++;
      if (cur?.live && cur.hls_url === muxUrl) {
        // Already on air with this URL — don't churn the realtime row.
      } else if (cur?.live && cur.hls_url && !curIsMux) {
        // A phone-path show holds the air; the encoder can wait its turn.
      } else {
        const { data: ok, error } = await supa.rpc("radio_set_live", {
          p_station: st.station_id,
          p_live: true,
          p_title: `${base} — LIVE`,
          p_hls: muxUrl,
          p_key: adminKey,
        });
        if (error || ok !== true) {
          errors.push(`${st.station_id}: set_live ${error?.message ?? "not_host"}`);
        }
      }
    } else if (cur?.live && curIsMux) {
      // Encoder gone: clear the row — but only a Mux URL is ours to clear.
      const { error } = await supa.rpc("radio_set_live", {
        p_station: st.station_id,
        p_live: false,
        p_title: "",
        p_hls: "",
        p_key: adminKey,
      });
      if (error) errors.push(`${st.station_id}: clear_live ${error.message}`);
    }

    // --- The replay shelf ------------------------------------------------
    const asRes = await mux(`/video/v1/assets?live_stream_id=${st.live_stream_id}&limit=10`);
    if (!asRes.ok) {
      errors.push(`${st.station_id}: assets ${asRes.status}`);
      continue;
    }
    const assets = (await asRes.json()).data ?? [];
    for (const asset of assets) {
      if (asset.status !== "ready") continue;
      const playback = asset.playback_ids?.[0]?.id;
      if (!playback) continue;
      const recordedAt = asset.created_at
        ? new Date(Number(asset.created_at) * 1000).toISOString()
        : new Date().toISOString();
      const title = asset.passthrough ??
        `${base} — ${recordedAt.slice(0, 10)}`;
      const { data: added, error } = await supa.rpc("radio_add_episode", {
        p_station: st.station_id,
        p_title: title,
        p_host: null,
        p_source: "mux",
        p_provider_asset_id: asset.id,
        p_hls: `https://stream.mux.com/${playback}.m3u8`,
        p_duration: asset.duration ?? null,
        p_recorded_at: recordedAt,
      });
      if (error) errors.push(`${st.station_id}: add_episode ${error.message}`);
      else if (added === true) episodesAdded++;
    }
  }

  return json({ checked, live, episodes_added: episodesAdded, errors });
});
