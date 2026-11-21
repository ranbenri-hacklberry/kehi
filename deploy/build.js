// Builds a Cloudflare Worker deploy script from the Kehi app template.
// Reads ../community.config.json (copy from community.config.example.json; do not commit it).
// The generated deploy-*.js embeds your account id and is gitignored.
const fs = require("fs");
const path = require("path");
const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "deploy");
const cfgPath = path.join(ROOT, "community.config.json");
if (!fs.existsSync(cfgPath)) {
  console.error("Missing community.config.json. Copy community.config.example.json and fill it in.");
  process.exit(1);
}
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
for (const k of ["community_id","brand","supabase_url","publishable_key","cloudflare_account_id","worker_name","app_url"]) {
  if (!cfg[k] || String(cfg[k]).includes("YOUR_")) {
    console.error("community.config.json is missing a real value for " + k);
    process.exit(1);
  }
}

const T = {".html":"text/html; charset=utf-8",".json":"application/manifest+json; charset=utf-8",".js":"text/javascript; charset=utf-8",".txt":"text/plain; charset=utf-8",".svg":"image/svg+xml",".png":"image/png",".webp":"image/webp"};
const BIN = new Set([".png",".webp"]);

function escRe(s){ return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

function applyTokens(t){
  const place = cfg.place_name || cfg.brand;
  const map = {
    "__COMMUNITY_ID__": cfg.community_id,
    "__BRAND__": cfg.brand,
    "__TITLE__": cfg.title || cfg.brand,
    "__HELLO_SUB__": cfg.hello_sub || ("מה קורה ב" + place + " השבוע"),
    "__ASK_PLACEHOLDER__": cfg.ask_placeholder || ("שאלו את " + cfg.brand + "…"),
    "__PLACE_NAME__": place,
    "__PLACE_NAME_RE__": JSON.stringify(escRe(place)),
    "__SUPABASE_URL__": String(cfg.supabase_url).replace(/\/$/, ""),
    "__PUBLISHABLE_KEY__": cfg.publishable_key,
    "__CACHE_NAME__": cfg.cache_name || ("kehi-" + cfg.community_id + "-v1"),
    "__FONTS__": cfg.fonts || "family=Noto+Serif+Hebrew:wght@400;600&family=Assistant:wght@300;400;600",
  };
  for (const [k,v] of Object.entries(map)) t = t.split(k).join(v);
  if (cfg.kehi_url) {
    t = t.replace(/window\.KEHI_URL='https:\/\/kehi\.ranbenri\.workers\.dev'/g, "window.KEHI_URL="+JSON.stringify(cfg.kehi_url));
    t = t.replace(/window\.KEHI_URL=window\.KEHI_URL\|\|'https:\/\/kehi\.ranbenri\.workers\.dev'/g, "window.KEHI_URL=window.KEHI_URL||"+JSON.stringify(cfg.kehi_url));
  }
  if (/__[A-Z0-9_]+__/.test(t)) {
    const leftover = t.match(/__[A-Z0-9_]+__/g);
    console.warn("unreplaced tokens", Array.from(new Set(leftover||[])));
  }
  return t;
}

function add(F, url, file, transform){
  const ext = path.extname(file);
  const buf = fs.readFileSync(file);
  if (BIN.has(ext)) F[url] = {b64: buf.toString("base64"), type: T[ext] || "application/octet-stream"};
  else {
    let text = buf.toString("utf8");
    text = applyTokens(text);
    if (transform) text = transform(text);
    F[url] = {body: text, type: T[ext] || "text/plain; charset=utf-8"};
  }
}

const { execSync } = require("child_process");
execSync("python3 " + JSON.stringify(path.join(ROOT, "admin/render_admin.py")), {stdio:"inherit"});
const adminFile = path.join(ROOT, "admin", "out-" + cfg.community_id + ".html");

const A = {};
const ad = path.join(ROOT, "app");
for (const f of ["index.html","manifest.json","sw.js","robots.txt"]) add(A, "/"+f, path.join(ad,f));
for (const f of fs.readdirSync(path.join(ad,"icons"))) add(A, "/icons/"+f, path.join(ad,"icons",f));
const adminHtml = applyTokens(fs.readFileSync(adminFile, "utf8"));
for (const u of ["/admin","/admin/","/admin/index.html"]) A[u] = {body: adminHtml, type: T[".html"]};

function worker(F){
  return `const FILES = ${JSON.stringify(F)};
export default { async fetch(req) {
  const u = new URL(req.url);
  if (req.method !== "GET" && req.method !== "HEAD") return new Response("Method not allowed", {status:405, headers:{allow:"GET, HEAD"}});
  const p = u.pathname === "/" ? "/index.html" : u.pathname;
  const f = FILES[p];
  const h = {"x-robots-tag":"noindex, nofollow","x-content-type-options":"nosniff","referrer-policy":"strict-origin-when-cross-origin"};
  if (!f) return new Response("Not found", {status:404, headers:{...h,"content-type":"text/plain; charset=utf-8"}});
  h["content-type"] = f.type;
  h["cache-control"] = p === "/sw.js" || p === "/index.html" || p.startsWith("/admin") ? "no-cache" : (f.b64 ? "public, max-age=86400" : "public, max-age=300");
  if (p === "/sw.js") h["service-worker-allowed"] = "/";
  if (f.b64) {
    const s = atob(f.b64); const b = new Uint8Array(s.length);
    for (let i=0;i<s.length;i++) b[i]=s.charCodeAt(i);
    return new Response(req.method==="HEAD"?null:b, {headers:h});
  }
  return new Response(req.method==="HEAD"?null:f.body, {headers:h});
} };`;
}

function deploy(name, code, accountId){
  return `async () => {
  if (accountId !== ${JSON.stringify(accountId)}) throw new Error("wrong account");
  const name = ${JSON.stringify(name)};
  const list = await cloudflare.request({method:"GET", path:\`/accounts/\${accountId}/workers/scripts\`});
  const exists = list.result.some(s => s.id === name);
  const code = ${JSON.stringify(code)};
  const metadata = { main_module: "worker.js", compatibility_date: "2026-11-21" };
  const form = new FormData();
  form.append("metadata", new Blob([JSON.stringify(metadata)], {type:"application/json"}));
  form.append("worker.js", new Blob([code], {type:"application/javascript+module"}), "worker.js");
  const up = await cloudflare.request({method:"PUT", path:\`/accounts/\${accountId}/workers/scripts/\${name}\`, body: form});
  const sd = await cloudflare.request({method:"POST", path:\`/accounts/\${accountId}/workers/scripts/\${name}/subdomain\`, body:{enabled:true, previews_enabled:false}});
  return {existedBefore: exists, uploaded: up.success, id: up.result && up.result.id, modified: up.result && up.result.modified_on, subdomain: sd.result};
}`;
}

const code = worker(A);
const outFile = path.join(OUT, "deploy-" + cfg.worker_name + ".js");
fs.writeFileSync(outFile, deploy(cfg.worker_name, code, cfg.cloudflare_account_id));
console.log("wrote", outFile, "files", Object.keys(A).length);
