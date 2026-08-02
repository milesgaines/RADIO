// RADI0 — AI A&R agent. "AI in every market that can do indie market research
// and drop records in and out."
//
// Reads the server-side aggregate resonance per station (radio_resonance, kept
// current by the radio-compute-resonance cron), asks Claude to produce a
// per-market A&R read plus proposed rotation directives (promote / bench /
// hold), and writes those directives to radio_rotation_directives in ADVISORY
// mode. Nothing changes what real listeners hear until radio_config
// ('ar_agent_apply') = 'true' and the director is wired to consume directives.
//
// Invoke (admin-gated): POST with header `x-radio-admin: <key in radio_admin>`
// and the project's publishable `apikey`. Schedule it (e.g. every 15 min) via
// pg_cron + pg_net, or run on demand.
//
// Deno edge runtime. Talks to the Messages API over raw fetch (no npm import to
// resolve in Deno) and to Postgres via the service-role Supabase client.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const MODEL = "claude-opus-5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-radio-admin, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

  // --- admin gate: the x-radio-admin header must match a row in radio_admin ---
  const adminKey = req.headers.get("x-radio-admin") ?? "";
  if (!adminKey) return json({ error: "missing x-radio-admin" }, 401);
  const { data: adminRow } = await db.from("radio_admin").select("key").eq("key", adminKey).maybeSingle();
  if (!adminRow) return json({ error: "unauthorized" }, 401);

  if (!ANTHROPIC_KEY) return json({ error: "ANTHROPIC_API_KEY not set" }, 500);

  // --- gather the research board: markets + top resonance rows per station ---
  const { data: markets } = await db.from("radio_markets").select("code,name").order("sort");
  const { data: rows } = await db
    .from("radio_resonance")
    .select("station_id, track_id, resonance, velocity, density, boosts, buries, listeners")
    .order("resonance", { ascending: false })
    .limit(60);

  if (!rows || rows.length === 0) return json({ note: "no resonance rows yet", directives: 0 });

  // hydrate track titles/artists
  const trackIds = [...new Set(rows.map((r) => r.track_id))];
  const { data: tracks } = await db.from("radio_tracks").select("track_id,title,artist").in("track_id", trackIds);
  const meta = new Map((tracks ?? []).map((t) => [t.track_id, t]));
  const board = rows.map((r) => ({
    station_id: r.station_id,
    track_id: r.track_id,
    title: meta.get(r.track_id)?.title ?? "—",
    artist: meta.get(r.track_id)?.artist ?? "—",
    resonance: round(r.resonance),
    velocity: round(r.velocity),
    density: round(r.density),
    boosts: r.boosts,
    buries: r.buries,
    listeners: r.listeners,
  }));

  // --- ask Claude for per-market reads + proposed directives ---
  const system =
    "You are the A&R director for RADI0, a fan-voted live radio network. You read a live " +
    "audience-research board (a PPM-style resonance signal per record, aggregated from real " +
    "listener votes) and decide, per market, which records to PUSH harder (promote), which to " +
    "PULL (bench), and which to HOLD. Resonance is [-1,1]; velocity is vote momentum; density is " +
    "love-per-listener; boosts/buries are raw counts. Be decisive but conservative: only promote " +
    "records with genuine positive momentum, only bench records the room is clearly turning on. " +
    "Markets are seeded pending real geo data — treat market differences as light. Your reads are " +
    "shown to a human PD; your directives are ADVISORY and are not auto-applied.";

  const schema = {
    type: "object",
    additionalProperties: false,
    required: ["reads", "directives"],
    properties: {
      reads: {
        type: "array",
        items: {
          type: "object", additionalProperties: false,
          required: ["market", "line"],
          properties: { market: { type: "string" }, line: { type: "string" } },
        },
      },
      directives: {
        type: "array",
        items: {
          type: "object", additionalProperties: false,
          required: ["station_id", "track_id", "market", "action", "reason", "confidence"],
          properties: {
            station_id: { type: "string" },
            track_id: { type: "string" },
            // structured outputs support anyOf but not type arrays
            market: { anyOf: [{ type: "string" }, { type: "null" }] },
            action: { type: "string", enum: ["promote", "bench", "hold"] },
            reason: { type: "string" },
            confidence: { type: "number" },
          },
        },
      },
    },
  };

  const userPrompt =
    `Markets: ${JSON.stringify(markets ?? [])}\n\n` +
    `Research board (top records by resonance across all stations):\n${JSON.stringify(board, null, 0)}\n\n` +
    `Produce: (1) one short A&R "read" per market (plain English, name a record and what's happening), ` +
    `and (2) rotation directives for the clear cases only — promote the records with real momentum, ` +
    `bench the ones the room has turned on, hold the rest. Use the exact station_id/track_id strings from the board.`;

  const ar = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
      // Server-side refusal fallback: if a safety classifier declines, the API
      // re-serves the request on Anthropic's recommended fallback model in the
      // same call instead of returning the refusal.
      "anthropic-beta": "server-side-fallback-2026-07-01",
    },
    body: JSON.stringify({
      model: MODEL,
      // Thinking is on by default on this model and max_tokens caps
      // thinking + response text together — leave real headroom.
      max_tokens: 16000,
      fallbacks: "default",
      system,
      output_config: { format: { type: "json_schema", schema } },
      messages: [{ role: "user", content: userPrompt }],
    }),
  });

  if (!ar.ok) return json({ error: "anthropic", status: ar.status, body: await ar.text() }, 502);
  const msg = await ar.json();
  if (msg.stop_reason === "refusal") return json({ note: "model refused", directives: 0 });

  const text = (msg.content ?? []).find((b: any) => b.type === "text")?.text ?? "{}";
  let parsed: any;
  try { parsed = JSON.parse(text); } catch { return json({ error: "unparseable", text }, 502); }

  // --- deactivate the prior batch, write the new advisory directives ---
  await db.from("radio_rotation_directives").update({ active: false }).eq("source", "ai").eq("active", true);

  const directives = (parsed.directives ?? [])
    .filter((d: any) => d.action === "promote" || d.action === "bench") // 'hold' = no-op, don't store
    .map((d: any) => ({
      station_id: d.station_id,
      track_id: d.track_id,
      market: d.market ?? null,
      action: d.action,
      reason: String(d.reason ?? "").slice(0, 500),
      confidence: clamp01(Number(d.confidence ?? 0.5)),
      source: "ai",
      active: true,
    }));

  if (directives.length > 0) {
    const { error } = await db.from("radio_rotation_directives").insert(directives);
    if (error) return json({ error: "insert", detail: error.message }, 500);
  }

  return json({ reads: parsed.reads ?? [], directives: directives.length, applied: false });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });
}
const round = (x: number) => Math.round((x ?? 0) * 100) / 100;
const clamp01 = (x: number) => Math.max(0, Math.min(1, Number.isFinite(x) ? x : 0.5));
