// POST /api/qa-log and /api/qa-flag: anonymous chat Q&A log. Origin-locked, size capped, per-isolate rate limit.
// Stored: question + shown answer (after the sensitive-detail / entry-code strip), record ids, source, latency, time.
// Never stored: user id, name, phone, email, IP, device id. The caller IP is used only in memory for rate limiting.
const QA_ORIGIN = "__QA_ORIGIN__";
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
async function handleQa(req, env, kind){
  if (req.method !== "POST") return qaJson(405, {error:"method"});
  const origin = req.headers.get("origin"), site = req.headers.get("sec-fetch-site");
  if (origin !== QA_ORIGIN || (site && site !== "same-origin")) return qaJson(403, {error:"origin"});
  if (!(req.headers.get("content-type") || "").startsWith("application/json")) return qaJson(415, {error:"type"});
  if (qaLimited(req.headers.get("cf-connecting-ip") || "0", kind === "flag" ? 20 : 30)) return qaJson(429, {error:"rate"});
  if (!env.QA_LOG_KEY) return qaJson(503, {error:"unconfigured"});
  const raw = await req.text();
  if (raw.length > 8000) return qaJson(413, {error:"size"});
  let p; try { p = JSON.parse(raw); } catch (e) { return qaJson(400, {error:"json"}); }
  try {
    if (kind === "flag") {
      const tk = typeof p.token === "string" ? p.token : "";
      if (!/^[A-Za-z0-9_-]{22,64}$/.test(tk)) return qaJson(400, {error:"input"});
      return qaJson(200, {ok: (await qaRpc("chat_qa_flag", {p_key: env.QA_LOG_KEY, p_token: tk})) === true});
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
    await qaRpc("chat_qa_insert", {p_key: env.QA_LOG_KEY, p_token: token, p_question: q.text, p_answer: a.text, p_record_ids: ids, p_source: source, p_latency_ms: ms, p_scrubbed: q.hit || a.hit});
    return qaJson(200, {token});
  } catch (e) {
    return qaJson(502, {error:"store"});
  }
}
