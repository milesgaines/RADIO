// TRACK UPLOAD — the PD loads a master from the phone. Key-gated multipart:
// the file lands in the public radio-tracks bucket and the public URL comes
// back; the client then files the record via radio_add_track. Cap 25MB
// (bucket-enforced too) — phones upload AAC/MP3, not raw session WAVs.
import { createClient } from "npm:@supabase/supabase-js@2";

const PUBLISHABLE = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii";
const BUCKET = "radio-tracks";

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

const EXT_TYPES: Record<string, string> = {
  mp3: "audio/mpeg", m4a: "audio/mp4", aac: "audio/aac", wav: "audio/wav",
};

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

  const key = String(form.get("key") ?? "");
  if (!(await isHostKey(key))) return json({ error: "not_host" }, 403);

  const file = form.get("file");
  if (!(file instanceof File)) return json({ error: "file" }, 400);
  if (file.size > 25 * 1024 * 1024) return json({ error: "too_big" }, 413);

  const ext = (file.name.split(".").pop() ?? "").toLowerCase();
  const type = EXT_TYPES[ext];
  if (!type) return json({ error: "format" }, 415);

  // Content-addressed name: the same bytes land at the same path — re-uploads
  // converge instead of piling up.
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  const hash = Array.from(new Uint8Array(digest)).slice(0, 16)
    .map((b) => b.toString(16).padStart(2, "0")).join("");
  const path = `${hash}.${ext}`;

  const bytes = new Blob([await file.slice().arrayBuffer()], { type });
  const up = await supa.storage.from(BUCKET).upload(path, bytes, {
    contentType: type,
    cacheControl: "31536000",
    upsert: true,
  });
  if (up.error) return json({ error: up.error.message }, 500);

  const { data: pub } = supa.storage.from(BUCKET).getPublicUrl(path);
  return json({ ok: true, url: pub.publicUrl });
});
