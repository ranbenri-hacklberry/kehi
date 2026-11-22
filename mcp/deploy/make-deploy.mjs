// Generates a Cloudflare-API deploy function (for the Cloudflare MCP "execute" tool) from dist/index.js.
// Usage: node deploy/make-deploy.mjs wrangler.nahat.jsonc > /tmp/deploy-nahat-mcp.js
import fs from "node:fs";
const cfgPath = process.argv[2];
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8").replace(/^\s*\/\/.*$/gm, ""));
const code = fs.readFileSync(new URL("../dist/index.js", import.meta.url), "utf8");
const fn = `async () => {
  if (accountId !== ${JSON.stringify(cfg.account_id)}) throw new Error("wrong account");
  const name = ${JSON.stringify(cfg.name)};
  const kvTitle = name + "-oauth";
  let kvId;
  const ns = await cloudflare.request({ method: "GET", path: \`/accounts/\${accountId}/storage/kv/namespaces\`, query: { per_page: 100 } });
  const found = ns.result.find((n) => n.title === kvTitle);
  if (found) kvId = found.id;
  else kvId = (await cloudflare.request({ method: "POST", path: \`/accounts/\${accountId}/storage/kv/namespaces\`, body: { title: kvTitle } })).result.id;
  const vars = ${JSON.stringify(cfg.vars)};
  const bindings = [{ type: "kv_namespace", name: "OAUTH_KV", namespace_id: kvId }]
    .concat(Object.entries(vars).map(([k, v]) => ({ type: "plain_text", name: k, text: v })));
  const metadata = { main_module: "index.js", compatibility_date: ${JSON.stringify(cfg.compatibility_date)}, compatibility_flags: ${JSON.stringify(cfg.compatibility_flags)}, bindings, keep_bindings: ["secret_text"] };
  const code = ${JSON.stringify(code)};
  const form = new FormData();
  form.append("metadata", new Blob([JSON.stringify(metadata)], { type: "application/json" }));
  form.append("index.js", new Blob([code], { type: "application/javascript+module" }), "index.js");
  const up = await cloudflare.request({ method: "PUT", path: \`/accounts/\${accountId}/workers/scripts/\${name}\`, body: form });
  const sd = await cloudflare.request({ method: "POST", path: \`/accounts/\${accountId}/workers/scripts/\${name}/subdomain\`, body: { enabled: true, previews_enabled: false } });
  const sub = await cloudflare.request({ method: "GET", path: \`/accounts/\${accountId}/workers/subdomain\` });
  return { kvTitle, kvCreated: !found, uploaded: up.success, modified: up.result && up.result.modified_on, subdomain: sd.result, url: \`https://\${name}.\${sub.result.subdomain}.workers.dev\` };
}`;
process.stdout.write(fn);
