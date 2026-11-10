// Ad network + offerwall postback receiver.
// Deploy with:  supabase functions deploy postback --no-verify-jwt
// (--no-verify-jwt is required: ad networks do not send a Supabase login token.)
//
// Postback URL to give the network:
//   https://YOURPROJECT.supabase.co/functions/v1/postback?type=ad&secret=YOUR_SECRET&user_id={user_id}&txn_id={transaction_id}
// For the offerwall use type=offer and add &network=cpagrip (or cpalead).
// Replace {user_id} and {transaction_id} with the macro names your network documents.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SECRET = Deno.env.get("POSTBACK_SECRET") ?? "";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function same(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const text = (body: string, status = 200) => new Response(body, { status, headers: { "content-type": "text/plain" } });

Deno.serve(async (req) => {
  if (!SECRET) return text("Server not configured", 500);

  const p: Record<string, string> = Object.fromEntries(new URL(req.url).searchParams);
  if (req.method === "POST") {
    try {
      const ct = req.headers.get("content-type") ?? "";
      const body = ct.includes("json")
        ? await req.json()
        : Object.fromEntries((await req.formData()).entries());
      for (const [k, v] of Object.entries(body)) p[k] = String(v);
    } catch (_) { /* ignore unreadable body, query string may be enough */ }
  }

  if (!same(String(p.secret ?? ""), SECRET)) return text("Forbidden", 403);

  const user = String(p.user_id ?? "");
  const txn = String(p.txn_id ?? "");
  if (!UUID.test(user) || txn.length < 3 || txn.length > 100) return text("Bad request", 400);

  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || null;

  const { data, error } = p.type === "offer"
    ? await sb.rpc("credit_offer", { p_user: user, p_txn: txn, p_network: p.network ?? null })
    : await sb.rpc("credit_ad", { p_user: user, p_txn: txn, p_ip: ip });

  if (error) return text("Error", 500); // network will retry; txn_id uniqueness makes retries safe
  // 200 for every business outcome (credited, duplicate, capped, budget, blocked)
  // so the network does not keep retrying something we deliberately declined.
  return text(String(data));
});
