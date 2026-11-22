// Kehi private store: the community's private records live on a machine the community owns (Mitzpe: Studio Max,
// Klili: Efrat's Mac), not in Supabase/Cloudflare. Public content (approved places/events/posts) stays in Supabase.
// - Listens on 127.0.0.1 only; exposed through one Tailscale Funnel path (e.g. /kehi-store).
// - Every request must be signed (ECDSA P-256 / SHA-256, same scheme as the relay) by a known caller key.
//   Public keys only: ~/.kehi-store/keys/<caller>.pem. Each caller may run only its listed ops.
// - SQLite file ~/.kehi-store/kehi.db (owner-only), daily local backup (VACUUM INTO, 14 kept), 30-day retention for chat reports.
// - Logs op, status and timing only, never record text. No npm dependencies (node:sqlite).
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

process.umask(0o077);
const DIR = process.env.KEHI_STORE_DIR || path.join(os.homedir(), '.kehi-store');
const PORT = Number(process.env.KEHI_STORE_PORT || 8798);
const MAX_BODY = 24 * 1024, SKEW_MS = 60_000;
fs.mkdirSync(path.join(DIR, 'backups'), { recursive: true, mode: 0o700 });
fs.chmodSync(DIR, 0o700);
// Which caller key may run which op. Callers verify the admin themselves before signing admin ops.
const ACL = {
  app: ['qa.insert', 'qa.flag', 'qa.list', 'fb.add', 'fb.list', 'fb.update', 'health'],
  mcp: ['qa.list', 'fb.add', 'fb.list', 'fb.update', 'health'],
};
const KEYS = {};
for (const f of fs.readdirSync(path.join(DIR, 'keys'))) {
  const m = f.match(/^([a-z0-9_-]+)\.pem$/); if (m && ACL[m[1]]) KEYS[m[1]] = crypto.createPublicKey(fs.readFileSync(path.join(DIR, 'keys', f), 'utf8'));
}

const DBF = path.join(DIR, 'kehi.db');
const db = new DatabaseSync(DBF);
db.exec(`pragma journal_mode = wal; pragma foreign_keys = on;
create table if not exists qa_log (id integer primary key, created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  token_hash text not null unique, question text not null, answer text, record_ids text not null default '[]',
  source text not null check (source in ('model','fallback','refusal')), latency_ms integer, scrubbed integer not null default 0,
  flagged integer not null default 0, flagged_at text);
create index if not exists qa_log_created on qa_log (created_at desc);
create table if not exists admin_feedback (id integer primary key, created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  author_email text, kind text not null check (kind in ('הערה','תגובה','בקשת שיפור','תקלה')), body text not null,
  related_kind text check (related_kind in ('place','event','post','qa','other')), related_id text,
  status text not null default 'פתוח' check (status in ('פתוח','בטיפול','טופל')), reply text,
  updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_by_email text);
create index if not exists admin_feedback_created on admin_feedback (created_at desc);`);
for (const f of fs.readdirSync(DIR)) if (f.startsWith('kehi.db')) fs.chmodSync(path.join(DIR, f), 0o600);

const seen = new Map();
const log = (o) => fs.appendFile(path.join(DIR, 'store.log'), JSON.stringify({ t: new Date().toISOString(), ...o }) + '\n', () => {});
const send = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(obj)); };
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const now = () => new Date().toISOString();

function verify(req, raw) {
  const ts = String(req.headers['x-kehi-ts'] || ''), nonce = String(req.headers['x-kehi-nonce'] || ''), sig = String(req.headers['x-kehi-sig'] || ''), who = String(req.headers['x-kehi-caller'] || '');
  if (!/^\d{13}$/.test(ts) || !/^[A-Za-z0-9_-]{16,64}$/.test(nonce) || !sig || !KEYS[who]) return { bad: 'missing' };
  if (Math.abs(Date.now() - Number(ts)) > SKEW_MS) return { bad: 'stale' };
  const t = Date.now(); for (const [k, exp] of seen) if (exp < t) seen.delete(k);
  if (seen.has(nonce)) return { bad: 'replay' };
  const msg = ts + '\n' + nonce + '\n' + sha(raw);
  let ok = false;
  try { ok = crypto.verify('sha256', Buffer.from(msg), { key: KEYS[who], dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url')); } catch { ok = false; }
  if (!ok) return { bad: 'badsig' };
  seen.set(nonce, t + 2 * SKEW_MS);
  return { who };
}

// Secrets and sensitive details never get stored, whatever the caller sent (same rules as the DB scrubber).
function scrub(t) {
  let s = String(t == null ? '' : t);
  const R = [
    [/-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----/g, '[הוסר]'],
    [/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[הוסר]'],
    [/(sb_secret_|sk-|sk_live_|sk_test_|rk_live_|ghp_|gho_|ghs_|github_pat_|xox[abprs]-|AKIA|AIza)[\w-]{8,}/g, '[הוסר]'],
    [/(password|passwd|pwd|token|secret|api[ _-]?key|סיסמה|סיסמא|סיסמת|קוד גישה)(\s*[:=]\s*|\s+)\S+/gi, '$1: [הוסר]'],
    [/קוד\s*(?:ל|של\s*)?(?:ה)?(?:דלת|שער|בניין|כניסה|לובי|אינטרקום)\s*:?\s*[#*]?\d{3,8}#?/g, '[קוד הוסר]'],
    [/(^|\D)\d{9}(?!\d)/g, '$1[הוסר]'],
    [/[A-Fa-f0-9]{32,}/g, '[הוסר]'],
  ];
  for (const [re, rep] of R) s = s.replace(re, rep);
  return s.trim();
}
const str = (v, n) => (typeof v === 'string' ? v : '').slice(0, n);
const FB_KINDS = ['הערה', 'תגובה', 'בקשת שיפור', 'תקלה'], FB_ST = ['פתוח', 'בטיפול', 'טופל'];
const qaRow = (r) => ({ ...r, record_ids: JSON.parse(r.record_ids || '[]'), scrubbed: !!r.scrubbed, flagged: !!r.flagged, token_hash: undefined });

const OPS = {
  health: () => ({ ok: true, qa: db.prepare('select count(*) n from qa_log').get().n, feedback: db.prepare('select count(*) n from admin_feedback').get().n }),
  'qa.insert': (p) => {
    const tk = str(p.token, 64), q = str(p.question, 500).trim();
    if (!/^[A-Za-z0-9_-]{22,64}$/.test(tk) || !q || !['model', 'fallback', 'refusal'].includes(p.source)) throw new Error('bad_input');
    const ids = Array.isArray(p.record_ids) ? p.record_ids.filter(x => typeof x === 'string' && /^[\w.:-]{1,80}$/.test(x)).slice(0, 12) : [];
    const ms = Number.isFinite(p.latency_ms) ? Math.max(0, Math.min(600000, Math.round(p.latency_ms))) : null;
    const ins = db.prepare('insert into qa_log (token_hash, question, answer, record_ids, source, latency_ms, scrubbed) values (?,?,?,?,?,?,?)'); const sq = scrub(q), sa = scrub(str(p.answer, 2000));
    ins.run(sha(tk), sq, sa, JSON.stringify(ids), p.source, ms, (p.scrubbed || sq !== q || sa !== str(p.answer, 2000).trim()) ? 1 : 0);
    return { ok: true };
  },
  'qa.flag': (p) => {
    const tk = str(p.token, 64); if (!/^[A-Za-z0-9_-]{22,64}$/.test(tk)) throw new Error('bad_input');
    const r = db.prepare("update qa_log set flagged = 1, flagged_at = coalesce(flagged_at, ?) where token_hash = ? and created_at >= strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days')").run(now(), sha(tk));
    return { ok: r.changes > 0 };
  },
  'qa.list': (p) => {
    const lim = Math.max(1, Math.min(1000, Number(p.limit) || 300));
    const rows = db.prepare(`select * from qa_log where created_at >= strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days') ${p.only_flagged ? 'and flagged = 1' : ''} order by created_at desc limit ?`).all(lim);
    return { rows: rows.map(qaRow) };
  },
  'fb.add': (p) => {
    const body = scrub(str(p.body, 4000)); if (!body || !FB_KINDS.includes(p.kind)) throw new Error('bad_input');
    const rk = ['place', 'event', 'post', 'qa', 'other'].includes(p.related_kind) ? p.related_kind : null;
    const r = db.prepare('insert into admin_feedback (author_email, kind, body, related_kind, related_id) values (?,?,?,?,?) returning *')
      .get(str(p.actor_email, 200) || null, p.kind, body, rk, str(p.related_id, 120).trim() || null);
    return { row: r };
  },
  'fb.list': (p) => {
    const w = [], a = [];
    if (FB_ST.includes(p.status)) { w.push('status = ?'); a.push(p.status); }
    if (FB_KINDS.includes(p.kind)) { w.push('kind = ?'); a.push(p.kind); }
    if (typeof p.since === 'string' && !isNaN(Date.parse(p.since))) { w.push('created_at >= ?'); a.push(new Date(p.since).toISOString()); }
    a.push(Math.max(1, Math.min(1000, Number(p.limit) || 200)));
    return { rows: db.prepare(`select * from admin_feedback ${w.length ? 'where ' + w.join(' and ') : ''} order by created_at desc limit ?`).all(...a) };
  },
  'fb.update': (p) => {
    const id = Number(p.id); if (!Number.isInteger(id)) throw new Error('bad_input');
    if (p.status != null && !FB_ST.includes(p.status)) throw new Error('bad_input');
    const reply = p.reply == null ? null : scrub(str(p.reply, 4000));
    const r = db.prepare('update admin_feedback set status = coalesce(?, status), reply = case when ? = 1 then ? else reply end, updated_at = ?, updated_by_email = ? where id = ? returning *')
      .get(p.status ?? null, p.reply == null ? 0 : 1, reply || null, now(), str(p.actor_email, 200) || null, id);
    if (!r) throw new Error('not_found');
    return { row: r };
  },
};

function housekeeping() {
  try { db.prepare("delete from qa_log where created_at < strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 days')").run(); } catch (e) { log({ s: 'retention_err' }); }
  try {
    const day = new Date().toISOString().slice(0, 10), bdir = path.join(DIR, 'backups'), f = path.join(bdir, `kehi-${day}.db`);
    if (!fs.existsSync(f)) { db.exec(`vacuum into '${f.replace(/'/g, "''")}'`); fs.chmodSync(f, 0o600); log({ s: 'backup', day }); }
    const all = fs.readdirSync(bdir).filter(x => /^kehi-\d{4}-\d{2}-\d{2}\.db$/.test(x)).sort();
    for (const old of all.slice(0, Math.max(0, all.length - 14))) fs.unlinkSync(path.join(bdir, old));
  } catch (e) { log({ s: 'backup_err' }); }
}
housekeeping(); setInterval(housekeeping, 60 * 60 * 1000);

http.createServer((req, res) => {
  const t0 = Date.now();
  if (req.method !== 'POST') return send(res, 404, { error: 'not_found' });
  const chunks = []; let size = 0, aborted = false;
  req.on('data', c => { size += c.length; if (size > MAX_BODY) { aborted = true; send(res, 413, { error: 'too_large' }); req.destroy(); } else chunks.push(c); });
  req.on('end', () => {
    if (aborted) return;
    const raw = Buffer.concat(chunks);
    const v = verify(req, raw);
    if (v.bad) { log({ s: 401, why: v.bad }); return send(res, 401, { error: 'unauthorized' }); }
    let p; try { p = JSON.parse(raw.toString('utf8')); } catch { return send(res, 400, { error: 'bad_json' }); }
    const op = String(p.op || '');
    if (!OPS[op] || !ACL[v.who].includes(op)) { log({ s: 403, op, who: v.who }); return send(res, 403, { error: 'op_not_allowed' }); }
    try { const out = OPS[op](p); log({ s: 200, op, who: v.who, ms: Date.now() - t0 }); send(res, 200, out); }
    catch (e) { const m = String(e && e.message || e); const code = m === 'bad_input' ? 400 : m === 'not_found' ? 404 : 500; log({ s: code, op, who: v.who }); send(res, code, { error: code === 500 ? 'store_error' : m }); }
  });
}).listen(PORT, '127.0.0.1', () => log({ s: 'start', port: PORT, callers: Object.keys(KEYS) }));
