// APPLE ROLE — the hidden role switch behind Sign in with Apple. Three
// implicit roles, none of them visible in the UI: FAN (default — listen,
// vote) and the staff pair (DJ/HOST + PROGRAMMER) for anyone who signs in
// with a verified @onesync.music address. No new login screens: the app
// POSTs the raw Apple identityToken here; staff silently get the operator
// host key back to stash in the Keychain, and the existing host machinery
// (GO LIVE console, THE BOARD) just works. Fans get {"role":"fan"} and
// nothing else.
//
// The client is NOT trusted about its email. The identityToken is a JWT
// signed by Apple; we verify it against Apple's JWKS (RS256), pin
// iss = appleid.apple.com and aud = our bundle id, and let jose enforce
// exp. Email comes from the verified claims only, and the domain match is
// exact — everything after the last "@" must equal "onesync.music", so
// "evil@onesync.music.attacker.com" and "fake-onesync.music@gmail.com"
// both stay fans.
//
// Apple only reliably includes `email` on the FIRST authorization, so
// verified emails are persisted in radio_identities and later email-less
// sign-ins fall back to the stored address — staff stay staff.
//
// Deploy with --no-verify-jwt: the Apple identityToken IS the auth on this
// call; there is no Supabase JWT. Never log the token or the host key.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5";

const APPLE_ISSUER = "https://appleid.apple.com";
const APP_BUNDLE_ID = "com.onesync.swellradio"; // the token's `aud`
const STAFF_DOMAIN = "onesync.music";

// Apple's signing keys. createRemoteJWKSet caches (and refreshes on
// unknown-kid) per instance, so warm invocations don't refetch.
const JWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

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

// Exact domain match: split at the LAST "@" and compare the domain part
// whole. A substring/suffix/like check would wave through
// "evil@onesync.music.attacker.com" or "fake-onesync.music@gmail.com".
function isStaffEmail(email: string | null | undefined): boolean {
  if (!email) return false;
  const at = email.lastIndexOf("@");
  if (at < 1) return false; // no "@", or empty local part
  return email.slice(at + 1).toLowerCase() === STAFF_DOMAIN;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const body = await req.json().catch(() => null);
  const token = body?.identity_token;
  if (typeof token !== "string" || token === "") {
    return json({ error: "identity_token" }, 400);
  }

  // 1) Verify. Signature against Apple's JWKS, issuer, audience (our bundle
  //    id), expiry — jose checks all four. Anything short of a fully valid
  //    Apple token is a 401, with no hint about which check failed.
  let claims;
  try {
    ({ payload: claims } = await jwtVerify(token, JWKS, {
      issuer: APPLE_ISSUER,
      audience: APP_BUNDLE_ID,
      algorithms: ["RS256"],
    }));
  } catch {
    return json({ error: "bad_token" }, 401);
  }

  const sub = typeof claims.sub === "string" ? claims.sub : "";
  if (sub === "") return json({ error: "bad_token" }, 401);

  // Apple encodes email_verified as boolean true or the string "true",
  // depending on the day. Only a VERIFIED claim email counts for anything.
  const verified = claims.email_verified === true ||
    claims.email_verified === "true";
  const claimEmail =
    verified && typeof claims.email === "string" && claims.email !== ""
      ? claims.email
      : null;

  // 2) Determine the email: the verified claim wins; otherwise whatever this
  //    Apple user registered before (Apple omits `email` after the first
  //    authorization, and the sub is stable across sign-ins).
  const { data: prior, error: priorErr } = await supa
    .from("radio_identities")
    .select("email")
    .eq("apple_user_id", sub)
    .maybeSingle();
  if (priorErr) return json({ error: priorErr.message }, 500);

  const email = claimEmail ?? prior?.email ?? null;
  const role = isStaffEmail(email) ? "staff" : "fan";

  // 3) Remember this identity. Only verified claim emails ever land in the
  //    email column (see above), so the fallback read can trust it.
  //    first_seen is omitted: set on insert by its default, untouched after.
  const { error: upErr } = await supa.from("radio_identities").upsert(
    {
      apple_user_id: sub,
      email,
      role,
      last_seen: new Date().toISOString(),
    },
    { onConflict: "apple_user_id" },
  );
  if (upErr) return json({ error: upErr.message }, 500);

  // 4) Fans get exactly what they had before this function existed.
  if (role !== "staff") return json({ role: "fan" });

  // 5) Staff get the operator host key — the same credential the GO LIVE
  //    console and THE BOARD already speak, so everything downstream just
  //    works. Empty radio_admin → staff-with-no-key; the app treats that as
  //    fan-with-a-title, which is harmless.
  const { data: admin, error: adminErr } = await supa
    .from("radio_admin")
    .select("key")
    .limit(1);
  if (adminErr) return json({ error: adminErr.message }, 500);

  const hostKey = admin?.[0]?.key;
  if (!hostKey) return json({ role: "staff" });
  return json({ role: "staff", host_key: hostKey });
});
