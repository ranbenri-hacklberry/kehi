// POST /api/qa-report: a chat question + answer the user chose to report ("תשובה לא טובה" -> confirm "לשלוח למנהלים").
// Nothing is stored unless the user confirms in the app. The old automatic /api/qa-log and /api/qa-flag are closed (410).
// Origin-locked, size capped, per-isolate rate limit.
// Stored: question + shown answer (after the sensitive-detail / entry-code strip), record ids, source, latency, time.
// Never stored: user id, name, phone, email, IP, device id. The caller IP is used only in memory for rate limiting.
// Storage interface: if QA_STORE is set, private records (chat reports, admin feedback) go ONLY to the community's own
// private store (SQLite on a machine the community owns, reached through a Tailscale Funnel path), signed with
// KEHI_RELAY_JWK. If that store is offline the call fails with a clear "private_store_offline" error; there is no
// fallback to Supabase. If QA_STORE is empty (communities whose private machine is not reachable yet) the Supabase
// RPC backend is used.
const QA_ORIGIN = "__QA_ORIGIN__";
const QA_STORE = "__STORE_URL__".startsWith("__") ? "" : "__STORE_URL__";
const QA_SB = "__SB_URL__";
const QA_SB_KEY = "__SB_KEY__";
const QA_HITS = new Map();
function qaJson(code, obj){ return new Response(JSON.stringify(obj), {status:code, headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff"}}); }
function qaB64u(b){ let s = ""; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,""); }
function qaLimited(ip, max){ const now = Date.now(), w = (QA_HITS.get(ip) || []).filter(t => now - t < 60000); w.push(now); QA_HITS.set(ip, w); if (QA_HITS.size > 5000) QA_HITS.clear(); return w.length > max; }
const QA_HEALTH = /(אסתמה|סכרת|אפילפס|סרטן|כימותרפ|דיכאון|חרדה|הפרע(ה|ת)|אוטיז|ADHD|לקות|נכות|תרופ(ה|ות)|ניתוח|הריון|בהריון|מחל(ה|ת)|אשפוז|פסיכיאטר|HIV)\S*/gi;
function qaScrub(t){
  let s = String(t == null ? "" : t), hit = false;
  const P = globalThis.KehiPipeline;
  if (P && P.stripDoorCodes) { const d = P.stripDoorCodes(s); if (d.hit) { s = d.text + " [קוד הוסר]"; hit = true; } }
  if (P && P.sensitiveScan) for (const n of P.sensitiveScan(s).names) { s = s.split(n).join("[שם]"); hit = true; }
  const R = [
    [/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, "[מייל]"],
    [/(?:\+972[-\s]?|\b0)(?:5\d|[2-9])[-\s]?\d{3}[-\s]?\d{4}\b/g, "[טלפון]"],
    [/(ת["״]ז|תעודת זהות|מספר זהות)\s*:?\s*\d*/g, "[ת״ז]"],
    [/\b\d{9}\b/g, "[מספר]"],
    // entry / parcel codes and passwords: the label stays, only the value is cut
    [/(קוד\s+(?:ה)?(?:כניסה|לבניין|בניין|חבילה|איסוף|דלת|שער)|סיסמ[\u05d0-\u05ea]*)(\s*(?:היא|הוא|זה|זו)?\s*:?\s*)([#*]?[\w-]*\d[\w-]*#?|(?<=:\s*)\S+)/g, "$1 [הוסר]"],
    [/קוד\s*:?\s*[#*]?\d{3,}#?/g, "קוד [הוסר]"],
    [QA_HEALTH, "[מידע רפואי]"]
  ];
  for (const [re, rep] of R) { const n = s.replace(re, rep); if (n !== s) { s = n; hit = true; } }
  return {text: s.replace(/\s{2,}/g, " ").trim(), hit};
}
async function qaRpc(fn, args){
  const r = await fetch(QA_SB + "/rest/v1/rpc/" + fn, {method:"POST", headers:{"content-type":"application/json", apikey: QA_SB_KEY}, body: JSON.stringify(args), signal: AbortSignal.timeout(8000)});
  if (!r.ok) throw new Error("rpc " + r.status);
  return r.json();
}
let QA_STORE_KEY = null;
class StoreOffline extends Error {}
async function storeCall(env, op, args){
  if (!QA_STORE_KEY) QA_STORE_KEY = await crypto.subtle.importKey("jwk", JSON.parse(env.KEHI_RELAY_JWK), {name:"ECDSA", namedCurve:"P-256"}, false, ["sign"]);
  const body = JSON.stringify({op, ...args}), ts = String(Date.now()), nonce = qaB64u(crypto.getRandomValues(new Uint8Array(18)));
  const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body)))].map(b => b.toString(16).padStart(2, "0")).join("");
  const sig = await crypto.subtle.sign({name:"ECDSA", hash:"SHA-256"}, QA_STORE_KEY, new TextEncoder().encode(ts + "\n" + nonce + "\n" + hash));
  let r;
  try { r = await fetch(QA_STORE, {method:"POST", body, headers:{"content-type":"application/json","x-kehi-ts":ts,"x-kehi-nonce":nonce,"x-kehi-sig":qaB64u(new Uint8Array(sig)),"x-kehi-caller":"app"}, signal: AbortSignal.timeout(8000)}); }
  catch (e) { throw new StoreOffline("unreachable"); }
  if (r.status === 502 || r.status === 503 || r.status === 504) throw new StoreOffline("status " + r.status);
  const j = await r.json().catch(() => null);
  if (!r.ok) { const e = new Error((j && j.error) || ("store " + r.status)); e.status = r.status; throw e; }
  return j;
}
const QA_OFFLINE = {error:"private_store_offline", message:"שרת הקהילה הפרטי לא זמין כרגע. שום דבר לא נשמר במקום אחר; נסו שוב מאוחר יותר."};
const QA_DB = {
  async insert(env, rec){ if (QA_STORE) return storeCall(env, "qa.insert", rec);
    return qaRpc("chat_qa_insert", {p_key: env.QA_LOG_KEY, p_token: rec.token, p_question: rec.question, p_answer: rec.answer, p_record_ids: rec.record_ids, p_source: rec.source, p_latency_ms: rec.latency_ms, p_scrubbed: rec.scrubbed}); },
  async flag(env, token){ if (QA_STORE) return (await storeCall(env, "qa.flag", {token})).ok === true;
    return (await qaRpc("chat_qa_flag", {p_key: env.QA_LOG_KEY, p_token: token})) === true; }
};
// POST /api/admin/store {op, ...}: the admin page's private-store reads/writes. The worker checks the caller is an admin
// with their own Supabase session (admin_whoami), then signs the call. Only for communities with a private store.
const ADMIN_OPS = {"qa.list":1, "fb.list":1, "fb.add":1, "fb.update":1};
async function handleAdminStore(req, env){
  if (req.method !== "POST") return qaJson(405, {error:"method"});
  const origin = req.headers.get("origin"), site = req.headers.get("sec-fetch-site");
  if (origin !== QA_ORIGIN || (site && site !== "same-origin")) return qaJson(403, {error:"origin"});
  if (!QA_STORE || !env.KEHI_RELAY_JWK) return qaJson(404, {error:"no_private_store"});
  if (qaLimited("adm:" + (req.headers.get("cf-connecting-ip") || "0"), 60)) return qaJson(429, {error:"rate"});
  const auth = req.headers.get("authorization") || "";
  if (!/^Bearer [\w.-]{20,4000}$/.test(auth)) return qaJson(401, {error:"auth"});
  const raw = await req.text(); if (raw.length > 8000) return qaJson(413, {error:"size"});
  let p; try { p = JSON.parse(raw); } catch (e) { return qaJson(400, {error:"json"}); }
  if (!p || !ADMIN_OPS[p.op]) return qaJson(400, {error:"op"});
  let who = null;
  try { const r = await fetch(QA_SB + "/rest/v1/rpc/admin_whoami", {method:"POST", headers:{"content-type":"application/json", apikey: QA_SB_KEY, authorization: auth}, body:"{}", signal: AbortSignal.timeout(8000)}); if (r.ok) who = await r.json(); } catch (e) {}
  if (!who || who.is_admin !== true) return qaJson(403, {error:"not_admin"});
  const args = {};
  for (const k of ["only_flagged","limit","status","kind","since","body","related_kind","related_id","id","reply"]) if (p[k] !== undefined) args[k] = p[k];
  if (p.op === "fb.add" || p.op === "fb.update") { args.actor_email = String(who.email || "").slice(0, 200);
    for (const k of ["body","reply"]) if (typeof args[k] === "string") args[k] = qaScrub(args[k].slice(0, 4000)).text; }
  try { return qaJson(200, await storeCall(env, p.op, args)); }
  catch (e) { if (e instanceof StoreOffline) return qaJson(503, QA_OFFLINE); return qaJson(e.status === 400 || e.status === 404 ? e.status : 502, {error: String(e.message || "store").slice(0, 40)}); }
}
async function handleQa(req, env, kind){
  if (kind !== "report") return qaJson(410, {error:"gone"});
  if (req.method !== "POST") return qaJson(405, {error:"method"});
  const origin = req.headers.get("origin"), site = req.headers.get("sec-fetch-site");
  if (origin !== QA_ORIGIN || (site && site !== "same-origin")) return qaJson(403, {error:"origin"});
  if (!(req.headers.get("content-type") || "").startsWith("application/json")) return qaJson(415, {error:"type"});
  if (qaLimited(req.headers.get("cf-connecting-ip") || "0", 20)) return qaJson(429, {error:"rate"});
  if (QA_STORE ? !env.KEHI_RELAY_JWK : !env.QA_LOG_KEY) return qaJson(503, {error:"unconfigured"});
  const raw = await req.text();
  if (raw.length > 8000) return qaJson(413, {error:"size"});
  let p; try { p = JSON.parse(raw); } catch (e) { return qaJson(400, {error:"json"}); }
  try {
    if (kind === "flag") {
      const tk = typeof p.token === "string" ? p.token : "";
      if (!/^[A-Za-z0-9_-]{22,64}$/.test(tk)) return qaJson(400, {error:"input"});
      return qaJson(200, {ok: await QA_DB.flag(env, tk)});
    }
    const q0 = typeof p.q === "string" ? p.q.trim().slice(0, 500) : "";
    const a0 = typeof p.a === "string" ? p.a.slice(0, 2000) : "";
    const source = ["model", "fallback", "refusal"].includes(p.source) ? p.source : null;
    const ids = Array.isArray(p.ids) ? p.ids.filter(x => typeof x === "string" && /^[\w.:-]{1,80}$/.test(x)).slice(0, 12) : [];
    const ms = Number.isFinite(p.ms) ? Math.max(0, Math.min(600000, Math.round(p.ms))) : null;
    if (!q0 || !source) return qaJson(400, {error:"input"});
    const q = qaScrub(q0), a = qaScrub(a0);
    if (!q.text) return qaJson(400, {error:"input"});
    const token = qaB64u(crypto.getRandomValues(new Uint8Array(24)));
    await QA_DB.insert(env, {token, question: q.text, answer: a.text, record_ids: ids, source, latency_ms: ms, scrubbed: q.hit || a.hit});
    await QA_DB.flag(env, token);
    return qaJson(200, {ok: true});
  } catch (e) {
    if (e instanceof StoreOffline) return qaJson(503, QA_OFFLINE);
    return qaJson(502, {error:"store"});
  }
}
