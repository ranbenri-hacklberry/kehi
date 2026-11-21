// Optional: pack landing/index.html into a gitignored deploy script.
// Usage: CLOUDFLARE_ACCOUNT_ID=... WORKER_NAME=kehi node landing/build.js
const fs = require("fs");
const path = require("path");
const html = fs.readFileSync(path.join(__dirname, "index.html"), "utf8");
const account = process.env.CLOUDFLARE_ACCOUNT_ID;
const name = process.env.WORKER_NAME || "kehi";
if (!account) { console.error("Set CLOUDFLARE_ACCOUNT_ID"); process.exit(1); }
const worker = `const HTML = ${JSON.stringify(html)};
export default { async fetch(req) {
  const u = new URL(req.url);
  const h = {"x-content-type-options":"nosniff","referrer-policy":"strict-origin-when-cross-origin","cache-control":"no-cache"};
  if (u.pathname === "/" || u.pathname === "/index.html") {
    return new Response(HTML, {headers:{...h,"content-type":"text/html; charset=utf-8"}});
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
const out = path.join(__dirname, "deploy-" + name + ".js");
fs.writeFileSync(out, deploy);
console.log("wrote", out);
