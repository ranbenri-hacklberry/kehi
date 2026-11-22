// Pack landing HTML pages into a gitignored deploy script.
// Usage: CLOUDFLARE_ACCOUNT_ID=... WORKER_NAME=kehi node landing/build.js
// Optional: OUT=/path/to/deploy-kehi.js
const fs = require("fs");
const path = require("path");
const dir = __dirname;
const account = process.env.CLOUDFLARE_ACCOUNT_ID;
const name = process.env.WORKER_NAME || "kehi";
if (!account) { console.error("Set CLOUDFLARE_ACCOUNT_ID"); process.exit(1); }

function read(file) {
  return fs.readFileSync(path.join(dir, file), "utf8");
}
// Optional site.config.json (gitignored-safe to keep local): {"operator_contact": {"label": "…", "href": "https://wa.me/… or mailto:…"}}
// While it is missing or null, the operators section shows only the soft line "רוצים להפעיל קהילה? דברו איתנו."
const SITE = fs.existsSync(path.join(dir, "site.config.json")) ? JSON.parse(read("site.config.json")) : {};
const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const oc = SITE.operator_contact;
const index = read("index.html").replace("<!--OPERATOR_CONTACT-->",
  oc && oc.label && /^(https:\/\/wa\.me\/|mailto:)/.test(oc.href || "") ? `<a class="btn main" href="${esc(oc.href)}" rel="noopener">${esc(oc.label)}</a>` : "");
const privacy = read("privacy.html");
const terms = read("terms.html");
// Self-hosted fonts (no third-party requests).
const FONTS = {};
for (const f of fs.readdirSync(path.join(dir, "fonts"))) {
  const buf = fs.readFileSync(path.join(dir, "fonts", f));
  if (f.endsWith(".woff2")) FONTS["/fonts/" + f] = { b64: buf.toString("base64"), type: "font/woff2" };
  else if (f.endsWith(".css")) FONTS["/fonts/" + f] = { body: buf.toString("utf8"), type: "text/css; charset=utf-8" };
}

const worker = `const PAGES = {
  "/": ${JSON.stringify(index)},
  "/index.html": ${JSON.stringify(index)},
  "/privacy": ${JSON.stringify(privacy)},
  "/privacy/": ${JSON.stringify(privacy)},
  "/privacy.html": ${JSON.stringify(privacy)},
  "/terms": ${JSON.stringify(terms)},
  "/terms/": ${JSON.stringify(terms)},
  "/terms.html": ${JSON.stringify(terms)},
};
const FONTS = ${JSON.stringify(FONTS)};
export default { async fetch(req) {
  const u = new URL(req.url);
  const h = {"x-content-type-options":"nosniff","referrer-policy":"strict-origin-when-cross-origin","cache-control":"no-cache"};
  const page = PAGES[u.pathname];
  if (page) {
    return new Response(page, {headers:{...h,"content-type":"text/html; charset=utf-8"}});
  }
  const f = FONTS[u.pathname];
  if (f) {
    const body = f.b64 ? Uint8Array.from(atob(f.b64), c => c.charCodeAt(0)) : f.body;
    return new Response(body, {headers:{...h,"content-type":f.type,"cache-control":"public, max-age=604800"}});
  }
  if (u.pathname === "/robots.txt") {
    return new Response("User-agent: *\\nAllow: /\\n", {headers:{...h,"content-type":"text/plain; charset=utf-8"}});
  }
  return new Response("Not found", {status:404, headers:{...h,"content-type":"text/plain; charset=utf-8"}});
} };`;

const deploy = `async () => {
  if (accountId !== ${JSON.stringify(account)}) throw new Error("wrong account");
  const name = ${JSON.stringify(name)};
  const list = await cloudflare.request({method:"GET", path:\`/accounts/\${accountId}/workers/scripts\`});
  const exists = list.result.some(s => s.id === name);
  const code = ${JSON.stringify(worker)};
  const metadata = { main_module: "worker.js", compatibility_date: "2026-11-21" };
  const form = new FormData();
  form.append("metadata", new Blob([JSON.stringify(metadata)], {type:"application/json"}));
  form.append("worker.js", new Blob([code], {type:"application/javascript+module"}), "worker.js");
  const up = await cloudflare.request({method:"PUT", path:\`/accounts/\${accountId}/workers/scripts/\${name}\`, body: form});
  const sd = await cloudflare.request({method:"POST", path:\`/accounts/\${accountId}/workers/scripts/\${name}/subdomain\`, body:{enabled:true, previews_enabled:false}});
  return {existedBefore: exists, uploaded: up.success, id: up.result && up.result.id, modified: up.result && up.result.modified_on, subdomain: sd.result};
}`;

const out = process.env.OUT || path.join(__dirname, "..", "deploy", "deploy-" + name + ".js");
fs.writeFileSync(out, deploy);
console.log("wrote", out, "bytes", deploy.length);
