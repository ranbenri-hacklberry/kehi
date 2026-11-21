// POST /api/ask: signed proxy to the Studio relay (local Gemma). Origin-locked, rate limited, size and time capped.
const ASK_ORIGIN = "https://<app-host>";
const RELAY_URL = "https://<studio-host>.ts.net/kehi-relay";
const ASK_HITS = new Map();
let ASK_KEY = null;
function askJson(code, obj){ return new Response(JSON.stringify(obj), {status:code, headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff"}}); }
function b64u(buf){ let s = ""; const b = new Uint8Array(buf); for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,""); }
async function askKey(env){ if (!ASK_KEY) ASK_KEY = await crypto.subtle.importKey("jwk", JSON.parse(env.KEHI_RELAY_JWK), {name:"ECDSA", namedCurve:"P-256"}, false, ["sign"]); return ASK_KEY; }
async function askLimited(env, ip){
  if (env.ASK_RL && env.ASK_RL.limit) { try { const r = await env.ASK_RL.limit({key: ip}); if (!r.success) return true; } catch (e) {} }
  const now = Date.now(), w = ASK_HITS.get(ip) || []; const recent = w.filter(t => now - t < 60000);
  recent.push(now); ASK_HITS.set(ip, recent); if (ASK_HITS.size > 5000) ASK_HITS.clear();
  return recent.length > 12;
}
async function handleAsk(req, env){
  if (req.method !== "POST") return askJson(405, {error:"method"});
  const origin = req.headers.get("origin"), site = req.headers.get("sec-fetch-site");
  if (origin !== ASK_ORIGIN || (site && site !== "same-origin")) return askJson(403, {error:"origin"});
  if (!(req.headers.get("content-type") || "").startsWith("application/json")) return askJson(415, {error:"type"});
  const ip = req.headers.get("cf-connecting-ip") || "0";
  if (await askLimited(env, ip)) return askJson(429, {error:"rate"});
  if (!env.KEHI_RELAY_JWK) return askJson(503, {error:"unconfigured"});
  const raw = await req.text();
  if (raw.length > 20000) return askJson(413, {error:"size"});
  let p; try { p = JSON.parse(raw); } catch (e) { return askJson(400, {error:"json"}); }
  const q = typeof p.q === "string" ? p.q.trim() : "";
  const ctx = Array.isArray(p.ctx) ? p.ctx : null;
  if (!q || q.length > 400 || !ctx || !ctx.length || ctx.length > 8 || ctx.some(r => !r || typeof r !== "object" || JSON.stringify(r).length > 2500)) return askJson(400, {error:"input"});
  const body = JSON.stringify({q, ctx});
  const ts = String(Date.now()), nonce = b64u(crypto.getRandomValues(new Uint8Array(18)));
  const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body)))].map(x => x.toString(16).padStart(2,"0")).join("");
  const sig = await crypto.subtle.sign({name:"ECDSA", hash:"SHA-256"}, await askKey(env), new TextEncoder().encode(ts + "\n" + nonce + "\n" + hash));
  const t0 = Date.now();
  try {
    const r = await fetch(RELAY_URL, {method:"POST", body, headers:{"content-type":"application/json","x-kehi-ts":ts,"x-kehi-nonce":nonce,"x-kehi-sig":b64u(sig)}, signal: AbortSignal.timeout(50000)});
    if (!r.ok) return askJson(r.status === 503 ? 503 : 502, {error:"relay", status:r.status});
    const o = await r.json();
    return askJson(200, {has_answer: o.has_answer === true, reply_he: String(o.reply_he || "").slice(0, 1200), cited_ids: Array.isArray(o.cited_ids) ? o.cited_ids.map(String).slice(0, 8) : [], model: String(o.model || ""), ms: Date.now() - t0});
  } catch (e) {
    return askJson(e && e.name === "TimeoutError" ? 504 : 502, {error:"relay_unreachable"});
  }
}
