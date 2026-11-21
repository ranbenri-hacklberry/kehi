// Kehi admin MCP server (one deployment per community: nahat-mcp, klili-mcp).
// - OAuth 2.1 for MCP clients via @cloudflare/workers-oauth-provider (DCR + CIMD).
// - Sign-in is delegated to the community's Supabase Auth (Google provider, PKCE).
// - Only users with admin_whoami().is_admin = true are let in.
// - Every DB call uses the signed-in admin's Supabase JWT + the public anon key, through
//   security-definer RPCs that re-check is_admin. No service_role key exists in this worker.
// - Every mutating tool call is written to private.mcp_audit (via public.mcp_log) first.
import { OAuthProvider, OAuthError, type OAuthHelpers, type AuthRequest } from "@cloudflare/workers-oauth-provider";
import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler, getMcpAuthContext } from "agents/mcp/server";
import { z } from "zod";

export interface Env {
  OAUTH_KV: KVNamespace;
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string; // public anon/publishable key (not a secret)
  COMMUNITY_NAME: string; // Hebrew display name, e.g. "נחת · מצפה רמון"
  PUBLIC_URL: string; // e.g. https://nahat-mcp.ranbenri.workers.dev
  APP_ORIGIN?: string; // the community app origin allowed to call /app/mcp from a browser
  COMMUNITY_ID?: string; // optional community_id filter (e.g. "mitzpe")
  HIDE_GROUPS?: string; // comma-separated category_group values the app hides (e.g. "אירוח")
}

type Props = {
  uid: string;
  email: string | null;
  sbAccess: string;
  sbRefresh: string;
  sbExp: number; // unix seconds
};

// ---------- Supabase helpers ----------
async function sbAuth(env: Env, path: string, body: unknown) {
  const r = await fetch(`${env.SUPABASE_URL}/auth/v1/${path}`, {
    method: "POST",
    headers: { apikey: env.SUPABASE_ANON_KEY, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const j: any = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, j };
}

class RpcError extends Error {
  constructor(public status: number, public code: string | undefined, message: string) {
    super(message);
  }
}

async function rpc(env: Env, jwt: string, fn: string, args: Record<string, unknown> = {}) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      authorization: `Bearer ${jwt}`,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify(args),
  });
  const text = await r.text();
  let j: any = null;
  try { j = text ? JSON.parse(text) : null; } catch { j = text; }
  if (!r.ok) {
    const msg = (j && (j.message || j.error_description || j.msg)) || `HTTP ${r.status}`;
    throw new RpcError(r.status, j && j.code, String(msg));
  }
  return j;
}

function whoamiIsAdmin(w: any): boolean {
  const o = Array.isArray(w) ? w[0] : w;
  return !!(o && (o.is_admin === true || o.admin_whoami?.is_admin === true));
}

// ---------- OAuth provider (built lazily: resource URL comes from env) ----------
let provider: OAuthProvider<Env> | null = null;
function getProvider(env: Env) {
  if (provider) return provider;
  provider = new OAuthProvider<Env>({
    apiRoute: "/mcp",
    apiHandler: { fetch: mcpApi as any },
    defaultHandler: { fetch: defaultHandler as any },
    authorizeEndpoint: "/authorize",
    tokenEndpoint: "/token",
    clientRegistrationEndpoint: "/register",
    clientIdMetadataDocumentEnabled: true,
    scopesSupported: ["admin", "offline_access"],
    resourceMetadata: {
      resource: `${env.PUBLIC_URL}/mcp`,
      authorization_servers: [env.PUBLIC_URL],
      resource_name: `Kehi admin · ${env.COMMUNITY_NAME}`,
    } as any,
    accessTokenTTL: 3000,
    refreshTokenTTL: 30 * 24 * 3600,
    tokenExchangeCallback: async (opts: any) => {
      const env2: Env = opts.env;
      const props = opts.props as Props;
      const now = Math.floor(Date.now() / 1000);
      if (opts.grantType === "authorization_code") {
        return { accessTokenTTL: Math.max(60, Math.min(3000, props.sbExp - now - 60)) };
      }
      if (opts.grantType === "refresh_token") {
        const r = await sbAuth(env2, "token?grant_type=refresh_token", { refresh_token: props.sbRefresh });
        if (!r.ok) {
          if (r.status >= 500 || r.status === 429)
            throw new OAuthError("temporarily_unavailable", { description: "Supabase unavailable", statusCode: 503 } as any);
          throw new OAuthError("invalid_grant", { description: "Supabase session ended; sign in again" } as any);
        }
        const who = await rpc(env2, r.j.access_token, "admin_whoami").catch(() => null);
        if (!whoamiIsAdmin(who)) throw new OAuthError("invalid_grant", { description: "No longer an admin" } as any);
        const np: Props = {
          ...props,
          sbAccess: r.j.access_token,
          sbRefresh: r.j.refresh_token,
          sbExp: now + Number(r.j.expires_in || 3600),
        };
        return { newProps: np, accessTokenProps: np, accessTokenTTL: Math.max(60, Math.min(3000, Number(r.j.expires_in || 3600) - 120)) };
      }
    },
  });
  return provider;
}

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext) {
    // Resident tier: read-only public tools, outside the admin OAuth flow. Admin tools stay on /mcp only.
    if (new URL(request.url).pathname === RESIDENT_ROUTE) return residentApi(request, env, ctx);
    return getProvider(env).fetch(request, env, ctx);
  },
};

// ---------- pages ----------
const esc = (v: string) => String(v ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
function page(env: Env, title: string, body: string, headers?: Headers, status = 200) {
  const h = headers ?? new Headers();
  h.set("content-type", "text/html; charset=utf-8");
  h.set("x-robots-tag", "noindex, nofollow");
  h.set("cache-control", "no-store");
  const html = `<!doctype html><html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>${esc(title)}</title>
<style>body{font-family:Assistant,Rubik,Arial,sans-serif;background:#f8f1e7;color:#3a2a1f;margin:0;padding:24px;line-height:1.6}main{max-width:460px;margin:8vh auto;background:#fffaf4;border:1px solid #ead9c3;border-radius:18px;padding:24px}h1{font-size:22px;margin:0 0 12px}.warn{background:#f7e6c4;border-radius:12px;padding:8px 12px}button{font:inherit;border-radius:999px;padding:10px 20px;border:1px solid #3a2a1f;cursor:pointer;margin-inline-end:8px}button.ok{background:#3a2a1f;color:#fff}.muted{color:#6e5a4a;font-size:14px}</style></head>
<body><main>${body}<p class="muted">Kehi · ${esc(env.COMMUNITY_NAME)} · שרת MCP לאדמינים</p></main></body></html>`;
  return new Response(html, { status, headers: h });
}

async function s256(v: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v));
  return btoa(String.fromCharCode(...new Uint8Array(d))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function rand(n = 32) {
  const b = crypto.getRandomValues(new Uint8Array(n));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function defaultHandler(request: Request, env: Env & { OAUTH_PROVIDER: OAuthHelpers }): Promise<Response> {
  const url = new URL(request.url);
  const oauth = env.OAUTH_PROVIDER;
  try {
    if (url.pathname === "/" && request.method === "GET") {
      return page(env, "Kehi MCP", `<h1>שרת MCP לאדמינים · ${esc(env.COMMUNITY_NAME)}</h1>
<p>כתובת החיבור (קונקטור): <code dir="ltr">${esc(env.PUBLIC_URL)}/mcp</code></p>
<p class="muted">הכניסה עם חשבון Google, ורק משתמשים שמוגדרים אדמין בקהילה יכולים להיכנס.</p>`);
    }
    if (url.pathname === "/robots.txt") return new Response("User-agent: *\nDisallow: /\n", { headers: { "content-type": "text/plain" } });

    if (url.pathname === "/authorize" && request.method === "GET") {
      const req = await oauth.parseAuthRequest(request);
      const d: any = await (oauth as any).describeConsent(req);
      const consent = await oauth.beginConsent(req);
      const body = `<h1>לאשר ל-${esc(d.clientName || "אפליקציה")} גישת אדמין?</h1>
<p>האפליקציה <strong>${esc(d.clientName || "")}</strong> מבקשת לנהל את <strong>${esc(env.COMMUNITY_NAME)}</strong> בשמך: אישור ודחייה של מקומות ועסקים, עריכת תוכן, מנויים, יומנים וקורסים.</p>
<p>${d.clientDomain ? `מפרסם: <strong dir="ltr">${esc(d.clientDomain)}</strong>.` : "האפליקציה רשמה את עצמה, והשם שלה לא מאומת."} הגישה תישלח אל <strong dir="ltr">${esc(d.redirectHost)}</strong>.</p>
${d.redirectIsLoopback ? '<p class="warn">הגישה נשלחת לאפליקציה במחשב שלך. המשיכו רק אם התחלתם עכשיו התחברות ממנה.</p>' : ""}
<p class="muted">בשלב הבא תתבקשו להתחבר עם Google. רק אדמינים של הקהילה יוכלו להמשיך, וכל פעולה נרשמת ביומן.</p>
<form method="post" action="/authorize"><input type="hidden" name="handle" value="${esc(consent.handle)}">
<button class="ok" name="decision" value="approve">אישור והתחברות עם Google</button><button name="decision" value="deny">ביטול</button></form>`;
      return page(env, "אישור גישה", body, consent.headers);
    }

    if (url.pathname === "/authorize" && request.method === "POST") {
      const form = await request.formData();
      const handle = String(form.get("handle") || "");
      if (form.get("decision") !== "approve") {
        const denied = await oauth.denyConsent(request, handle);
        return new Response(null, { status: 302, headers: denied.headers });
      }
      const approved = await oauth.approveConsent(request, handle);
      const verifier = rand(48);
      const { state, headers } = await oauth.beginUpstream(approved.request, { data: { verifier }, headers: approved.headers });
      const redirectTo = `${env.PUBLIC_URL}/callback?state=${encodeURIComponent(state)}`;
      const sb = new URL(`${env.SUPABASE_URL}/auth/v1/authorize`);
      sb.searchParams.set("provider", "google");
      sb.searchParams.set("redirect_to", redirectTo);
      sb.searchParams.set("code_challenge", await s256(verifier));
      sb.searchParams.set("code_challenge_method", "s256");
      headers.set("Location", sb.toString());
      return new Response(null, { status: 302, headers });
    }

    if (url.pathname === "/callback" && request.method === "GET") {
      const { request: original, data, headers } = await oauth.finishUpstream<{ verifier: string }>(request);
      const code = url.searchParams.get("code");
      const fail = (msg: string, status = 403) => page(env, "אין גישה", `<h1>אין גישה</h1><p>${esc(msg)}</p>`, headers, status);
      if (!code) return fail("ההתחברות עם Google בוטלה או נכשלה. אפשר לנסות שוב מהצ'אט.", 400);
      const tok = await sbAuth(env, "token?grant_type=pkce", { auth_code: code, code_verifier: data.verifier });
      if (!tok.ok || !tok.j.access_token) return fail("לא הצלחתי להשלים את ההתחברות. נסו שוב.", 400);
      const who = await rpc(env, tok.j.access_token, "admin_whoami").catch(() => null);
      if (!whoamiIsAdmin(who)) return fail("החשבון הזה לא מוגדר אדמין בקהילה. השרת הזה פתוח לאדמינים בלבד.");
      const now = Math.floor(Date.now() / 1000);
      const props: Props = {
        uid: tok.j.user?.id,
        email: tok.j.user?.email ?? null,
        sbAccess: tok.j.access_token,
        sbRefresh: tok.j.refresh_token,
        sbExp: now + Number(tok.j.expires_in || 3600),
      };
      const { redirectTo } = await oauth.completeAuthorization({
        request: original as AuthRequest,
        userId: props.uid,
        metadata: { email: props.email },
        scope: (original as AuthRequest).scope,
        props,
      } as any);
      headers.set("Location", redirectTo);
      return new Response(null, { status: 302, headers });
    }
    return new Response("Not found", { status: 404 });
  } catch (e: any) {
    const msg = e?.description || e?.message || "שגיאה";
    return page(env, "שגיאה", `<h1>משהו השתבש</h1><p dir="ltr">${esc(msg)}</p><p>אפשר לסגור את החלון ולנסות שוב מהצ'אט.</p>`, undefined, 400);
  }
}

// ---------- MCP endpoint ----------
export async function mcpApi(request: Request, env: Env, ctx: ExecutionContext & { props?: Props }) {
  const props = (ctx as any).props as Props | undefined;
  const now = Math.floor(Date.now() / 1000);
  if (!props || !props.sbAccess || props.sbExp <= now + 15) {
    return new Response(JSON.stringify({ error: "invalid_token", error_description: "session expired" }), {
      status: 401,
      headers: {
        "content-type": "application/json",
        "www-authenticate": `Bearer error="invalid_token", resource_metadata="${env.PUBLIC_URL}/.well-known/oauth-protected-resource/mcp"`,
      },
    });
  }
  return createMcpHandler(() => buildServer(env), { route: "/mcp", authContext: { props } as any })(request, env, ctx);
}

const txt = (v: unknown) => ({ content: [{ type: "text" as const, text: typeof v === "string" ? v : JSON.stringify(v, null, 2) }] });
const errTxt = (m: string) => ({ content: [{ type: "text" as const, text: m }], isError: true });

function summarize(args: any) {
  // Args summary for the audit log. Truncates long strings. Never contains tokens.
  const out: any = {};
  for (const [k, v] of Object.entries(args || {})) {
    if (typeof v === "string") out[k] = v.length > 200 ? v.slice(0, 200) + "…" : v;
    else if (Array.isArray(v)) out[k] = v.length > 50 ? [...v.slice(0, 50), `…+${v.length - 50}`] : v;
    else out[k] = v;
  }
  return out;
}

export function buildServer(env: Env) {
  const props = getMcpAuthContext()?.props as unknown as Props;
  const jwt = props.sbAccess;
  const call = (fn: string, args: Record<string, unknown> = {}) => rpc(env, jwt, fn, args);
  const server = new McpServer({ name: `kehi-admin-${new URL(env.PUBLIC_URL).hostname.split(".")[0]}`, version: "1.0.0" });

  type H = (a: any) => Promise<any>;
  const tool = (name: string, description: string, schema: z.ZodObject<any>, mutating: boolean, handler: H) => {
    server.registerTool(
      name,
      {
        description,
        inputSchema: schema,
        annotations: { readOnlyHint: !mutating, destructiveHint: mutating },
      } as any,
      (async (args: any) => {
        try {
          const who = await call("admin_whoami");
          if (!whoamiIsAdmin(who)) return errTxt("not admin");
          if (mutating) await call("mcp_log", { p_tool: name, p_args: summarize(args) });
          return txt(await handler(args || {}));
        } catch (e: any) {
          if (e instanceof RpcError) return errTxt(`DB error${e.code ? ` ${e.code}` : ""}: ${e.message}`);
          return errTxt(String(e?.message || e));
        }
      }) as any,
    );
  };

  const placeLinks = (p: any) => ({
    google_maps: p.google_maps_url || p.maps_url || (p.lat && p.lng ? `https://www.google.com/maps/search/?api=1&query=${p.lat},${p.lng}` : `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${p.name_he || ""} ${p.address || ""}`)}`),
    website: p.website || null,
    facebook: p.facebook_url || null,
    instagram: p.instagram_url || null,
    sources: p.source_urls || [],
  });
  const compactPlace = (p: any) => ({
    id: p.id, name_he: p.name_he, name_en: p.name_en, status: p.status, category_group: p.category_group,
    category: p.category, address: p.address, phone: p.phone, hours: p.hours, search_only: p.search_only,
    badge: p.badge, review_note: p.review_note, version: p.version, updated_at: p.updated_at, links: placeLinks(p),
  });

  // ----- read tools -----
  tool("whoami", "Who is signed in and the community this server manages.", z.object({}), false, async () => ({
    community: env.COMMUNITY_NAME, user_id: props.uid, email: props.email, whoami: await call("admin_whoami"),
  }));
  tool("stats_summary", "Counts: places/events/posts by status, users, admins, business accounts, bookings, pending items.", z.object({}), false,
    () => call("mcp_admin_stats"));
  tool("list_pending", "Everything waiting for an admin: pending places, events, posts, business claims and resident verifications, with review links.", z.object({}), false, async () => {
    const [places, events, posts, biz, res] = await Promise.all([
      call("admin_list_places"), call("admin_list_events"), call("staff_list_posts"), call("staff_list_business_accounts"), call("staff_list_residents"),
    ]);
    return {
      places: (places || []).filter((p: any) => p.status === "pending_publish").map(compactPlace),
      events: (events || []).filter((e: any) => e.status === "pending_publish"),
      posts: (posts || []).filter((p: any) => p.status === "pending"),
      business_claims: (biz || []).filter((b: any) => b.claim_status === "pending"),
      residents: (res || []).filter((r: any) => r.status === "pending"),
    };
  });
  tool("list_places", "List/search places in any status. Filters: status, text query (name/address/category), category_group. Returns compact rows with Google/website/Facebook/Instagram/source links.",
    z.object({
      status: z.enum(["published", "pending_publish", "rejected", "hidden"]).optional(),
      query: z.string().optional(),
      category_group: z.string().optional(),
      limit: z.number().int().min(1).max(500).optional(),
    }), false, async (a) => {
      const q = (a.query || "").trim().toLowerCase();
      const rows = ((await call("admin_list_places")) || []).filter((p: any) =>
        (!a.status || p.status === a.status) &&
        (!a.category_group || p.category_group === a.category_group) &&
        (!q || [p.name_he, p.name_en, p.address, p.category, p.category_group, p.id].some((s) => String(s || "").toLowerCase().includes(q))));
      return { total: rows.length, places: rows.slice(0, a.limit || 50).map(compactPlace) };
    });
  tool("get_place", "Full details of one place: every field, links (Google Maps, website, Facebook, Instagram, sources), suggestions and linked business accounts.",
    z.object({ id: z.string() }), false, async (a) => {
      const r = await call("mcp_admin_get_place", { p_id: a.id });
      return { ...r, links: placeLinks(r.place || {}) };
    });
  tool("list_business_accounts", "Business accounts with claim status, plan, trial/expiry, comp flag, and the claimed place's details and links.",
    z.object({ claim_status: z.enum(["pending", "approved", "rejected"]).optional() }), false, async (a) => {
      const rows = (await call("staff_list_business_accounts")) || [];
      return rows.filter((b: any) => !a.claim_status || b.claim_status === a.claim_status);
    });
  tool("list_users", "All signed-up users with email, name, admin/manager flags, resident status and business plan.",
    z.object({ search: z.string().optional(), limit: z.number().int().min(1).max(1000).optional() }), false,
    (a) => call("mcp_admin_list_users", { p_search: a.search ?? null, p_limit: a.limit ?? 200 }));
  tool("list_residents", "Resident verification records (pending/verified/rejected).",
    z.object({ status: z.enum(["pending", "verified", "rejected"]).optional() }), false, async (a) =>
      ((await call("staff_list_residents")) || []).filter((r: any) => !a.status || r.status === a.status));
  tool("list_managers", "Users with the manager role.", z.object({}), false, () => call("admin_list_managers"));
  tool("list_pricing_plans", "Pricing plans (tiers, prices, storage, features).", z.object({}), false, () => call("list_pricing_plans"));
  tool("list_events", "Community events in any status.",
    z.object({ status: z.enum(["published", "pending_publish", "rejected", "hidden"]).optional(), query: z.string().optional() }), false, async (a) => {
      const q = (a.query || "").trim().toLowerCase();
      return ((await call("admin_list_events")) || []).filter((e: any) =>
        (!a.status || e.status === a.status) && (!q || [e.title, e.venue_name, e.organizer, e.id].some((s) => String(s || "").toLowerCase().includes(q))));
    });
  tool("list_posts", "Community board posts (rides, giveaways, help, recommendations, courses) in any status.",
    z.object({ type: z.enum(["ride", "giveaway", "help", "recommend", "course"]).optional(), status: z.enum(["pending", "open", "closed", "hidden", "rejected"]).optional() }), false,
    async (a) => ((await call("staff_list_posts")) || []).filter((p: any) => (!a.type || p.type === a.type) && (!a.status || p.status === a.status)));
  tool("list_course_slots", "Slots of a course/workshop post with capacity and remaining seats.", z.object({ post_id: z.string() }), false,
    (a) => call("list_post_slots", { p_post: a.post_id }));
  tool("list_course_attendees", "Attendees booked into a course/workshop post's slots.", z.object({ post_id: z.string() }), false,
    (a) => call("list_course_attendees", { p_post: a.post_id }));
  tool("list_business_bookings", "Business calendar bookings (requested/confirmed/rejected/cancelled), optionally for one business and a time window.",
    z.object({
      business_user_id: z.string().uuid().optional(), from: z.string().optional(), to: z.string().optional(),
      status: z.enum(["requested", "confirmed", "rejected", "cancelled"]).optional(),
    }), false,
    (a) => call("mcp_admin_list_business_bookings", { p_business: a.business_user_id ?? null, p_from: a.from ?? null, p_to: a.to ?? null, p_status: a.status ?? null }));
  tool("read_audit_log", "Recent admin actions made through this MCP server (who, tool, args summary, when).",
    z.object({ limit: z.number().int().min(1).max(500).optional(), tool: z.string().optional() }), false,
    (a) => call("mcp_audit_list", { p_limit: a.limit ?? 50, p_tool: a.tool ?? null }));

  // ----- mutating tools -----
  const statusEnum = z.enum(["published", "pending_publish", "rejected", "hidden"]);
  tool("set_place_status", "Approve (published), reject (needs reason), hide, or return to pending one or more places.",
    z.object({ ids: z.array(z.string()).min(1).max(500), status: statusEnum, reason: z.string().optional() }), true,
    async (a) => ({ updated: await call("admin_set_status", { p_kind: "places", p_ids: a.ids, p_status: a.status, p_reason: a.reason ?? null }) }));
  tool("update_place", "Edit a place. Basic fields: name_he, category_group, category, note, hours, phone, website, address, badge, search_only. Link fields: name_en, maps_url, google_maps_url, facebook_url, instagram_url, source_urls (array), lat, lng, hours_status, last_verified. Pass version to avoid overwriting someone else's change.",
    z.object({ id: z.string(), patch: z.record(z.string(), z.any()), version: z.number().int().optional() }), true, async (a) => {
      const base = ["name_he", "category_group", "category", "note", "hours", "phone", "website", "address", "badge", "search_only"];
      const links = ["name_en", "maps_url", "google_maps_url", "facebook_url", "instagram_url", "source_urls", "lat", "lng", "hours_status", "last_verified"];
      const bad = Object.keys(a.patch).filter((k) => !base.includes(k) && !links.includes(k));
      if (bad.length) throw new Error(`field not editable: ${bad.join(",")}`);
      const bp = Object.fromEntries(Object.entries(a.patch).filter(([k]) => base.includes(k)));
      const lp = Object.fromEntries(Object.entries(a.patch).filter(([k]) => links.includes(k)));
      let res: any = null;
      if (Object.keys(bp).length) res = await call("admin_update_place", { p_id: a.id, p_patch: bp, p_version: a.version ?? null });
      if (Object.keys(lp).length) res = await call("mcp_admin_update_place_links", { p_id: a.id, p_patch: lp });
      return res ? compactPlace(res) : "nothing to update";
    });
  tool("review_business_claim", "Approve or reject a pending business account claim (links the business to its place on approve).",
    z.object({ user_id: z.string().uuid(), decision: z.enum(["approved", "rejected"]), note: z.string().optional() }), true,
    (a) => call("staff_review_business_claim", { p_user: a.user_id, p_decision: a.decision, p_note: a.note ?? null }));
  tool("set_business_comp", "Give (comp=true) or remove (comp=false) a free plan for a user's business account. Default tier pro_monthly. Creates the business account if missing.",
    z.object({ user_id: z.string().uuid(), comp: z.boolean(), tier: z.string().optional(), reason: z.string().optional(), business_name: z.string().optional() }), true,
    (a) => call("mcp_admin_set_business_comp", { p_user: a.user_id, p_comp: a.comp, p_tier: a.tier ?? "pro_monthly", p_reason: a.reason ?? null, p_business_name: a.business_name ?? null }));
  tool("set_resident_status", "Verify, reject (needs reason) or reset to pending one or more residents.",
    z.object({ user_ids: z.array(z.string().uuid()).min(1).max(500), status: z.enum(["pending", "verified", "rejected"]), reason: z.string().optional() }), true,
    async (a) => ({ updated: await call("staff_set_resident_status", { p_ids: a.user_ids, p_status: a.status, p_reason: a.reason ?? null }) }));
  tool("set_manager_role", "Grant or revoke the manager role for a user. (Admin role itself is not changed through MCP.)",
    z.object({ user_id: z.string().uuid(), grant: z.boolean() }), true,
    (a) => call(a.grant ? "admin_grant_manager" : "admin_revoke_manager", { p_user: a.user_id }));
  tool("update_pricing_plan", "Update a pricing plan. patch keys: name_he, price_ils, monthly_equivalent_ils, storage_gb, allow_bit_applepay, features, highlight_he, savings_ils, founder_limit, active, sort_order.",
    z.object({ tier_id: z.string(), patch: z.record(z.string(), z.any()) }), true,
    (a) => call("admin_update_pricing_plan", { p_tier_id: a.tier_id, p_patch: a.patch }));
  tool("create_event", "Create a community event. Fields: title (required), starts_at, ends_at (ISO), start_date, when_text, venue_name, venue_place_id, address, price_text, organizer, description, source, status (published|pending_publish|hidden; default pending_publish).",
    z.object({ event: z.record(z.string(), z.any()) }), true, (a) => call("mcp_admin_create_event", { p_event: a.event }));
  tool("update_event", "Edit an event. patch keys: title, when_text, venue_name, address, price_text, organizer, description, start_date, starts_at, ends_at.",
    z.object({ id: z.string(), patch: z.record(z.string(), z.any()), version: z.number().int().optional() }), true,
    (a) => call("admin_update_event", { p_id: a.id, p_patch: a.patch, p_version: a.version ?? null }));
  tool("set_event_status", "Approve (published), reject (needs reason), hide or return to pending one or more events.",
    z.object({ ids: z.array(z.string()).min(1).max(500), status: statusEnum, reason: z.string().optional() }), true,
    async (a) => ({ updated: await call("admin_set_status", { p_kind: "events", p_ids: a.ids, p_status: a.status, p_reason: a.reason ?? null }) }));
  tool("delete_event", "Permanently delete an event (prefer set_event_status hidden).", z.object({ id: z.string() }), true,
    async (a) => ({ deleted: await call("mcp_admin_delete_event", { p_id: a.id }) }));
  tool("set_post_status", "Moderate board posts: open (approve), rejected (needs reason), hidden, closed, pending.",
    z.object({ ids: z.array(z.string()).min(1).max(500), status: z.enum(["pending", "open", "closed", "hidden", "rejected"]), reason: z.string().optional() }), true,
    async (a) => ({ updated: await call("staff_set_post_status", { p_ids: a.ids, p_status: a.status, p_reason: a.reason ?? null }) }));
  tool("create_course", "Create a course/workshop/tour post (as the signed-in admin) with slots [{starts_at, ends_at, capacity, location?, note?}]. It starts as pending; approve with set_post_status open.",
    z.object({
      title: z.string(), body: z.string().optional(), expires_at: z.string().optional(),
      slots: z.array(z.object({ starts_at: z.string(), ends_at: z.string(), capacity: z.number().int().min(1).max(500), location: z.string().optional(), note: z.string().optional() })).min(1).max(50),
    }), true, (a) => call("create_course_post", { p_title: a.title, p_body: a.body ?? null, p_slots: a.slots, p_expires_at: a.expires_at ?? null }));
  tool("upsert_course_slot", "Add a slot to a course post (omit slot_id) or edit an existing slot (pass slot_id).",
    z.object({ slot_id: z.number().int().optional(), post_id: z.string().optional(), starts_at: z.string(), ends_at: z.string(), capacity: z.number().int().min(1).max(500), location: z.string().optional(), note: z.string().optional() }), true,
    (a) => call("mcp_admin_upsert_slot", { p_id: a.slot_id ?? null, p_post: a.post_id ?? null, p_starts_at: a.starts_at, p_ends_at: a.ends_at, p_capacity: a.capacity, p_location: a.location ?? null, p_note: a.note ?? null }));
  tool("delete_course_slot", "Delete a course slot. Refuses if people are booked unless force=true (their bookings are removed).",
    z.object({ slot_id: z.number().int(), force: z.boolean().optional() }), true,
    async (a) => ({ deleted: await call("mcp_admin_delete_slot", { p_id: a.slot_id, p_force: a.force ?? false }) }));
  tool("cancel_course_booking", "Cancel one attendee's booking in a course slot.", z.object({ booking_id: z.number().int() }), true,
    (a) => call("staff_cancel_booking", { p_booking: a.booking_id }));

  return server;
}

// ---------- Resident tier (/app/mcp) ----------
// Read-only tools for the in-app chat agent and the local Gemma agent.
// - No OAuth: the caller may pass the signed-in user's own Supabase access token (Authorization: Bearer).
//   Without it the anon (public) key is used. Either way Postgres RLS decides what is visible:
//   anon/residents only ever see status=published places/events and status=open posts.
// - No admin tool is registered here, whatever the caller's role. Admin tools live only on /mcp behind OAuth.
// - Browser calls are accepted only from the community app origin (APP_ORIGIN).
const RESIDENT_ROUTE = "/app/mcp";
type Caller = { jwt: string | null; uid: string | null; role: "guest" | "member" | "admin" };

async function sbGet(env: Env, jwt: string | null, path: string) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
    headers: { apikey: env.SUPABASE_ANON_KEY, authorization: `Bearer ${jwt || env.SUPABASE_ANON_KEY}`, accept: "application/json" },
  });
  const text = await r.text();
  let j: any = null;
  try { j = text ? JSON.parse(text) : null; } catch { j = text; }
  if (!r.ok) throw new RpcError(r.status, j && j.code, String((j && j.message) || `HTTP ${r.status}`));
  return j;
}

async function residentApi(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const appOrigin = env.APP_ORIGIN || "";
  const corsH: Record<string, string> = appOrigin ? {
    "access-control-allow-origin": appOrigin,
    "access-control-allow-headers": "authorization, content-type, accept, mcp-protocol-version, mcp-session-id",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-max-age": "86400",
    vary: "origin",
  } : {};
  const origin = request.headers.get("origin");
  if (origin && origin !== appOrigin) return new Response("forbidden origin", { status: 403 });
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsH });
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { ...corsH, allow: "POST, OPTIONS" } });
  const json401 = (d: string) => new Response(JSON.stringify({ error: "invalid_token", error_description: d }), { status: 401, headers: { ...corsH, "content-type": "application/json" } });

  const caller: Caller = { jwt: null, uid: null, role: "guest" };
  const auth = request.headers.get("authorization") || "";
  if (auth) {
    const m = auth.match(/^Bearer\s+([A-Za-z0-9\-_.]+)$/);
    if (!m) return json401("malformed authorization header");
    const u = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, { headers: { apikey: env.SUPABASE_ANON_KEY, authorization: `Bearer ${m[1]}` } });
    if (!u.ok) return json401("Supabase session is not valid; sign in again");
    const uj: any = await u.json().catch(() => ({}));
    caller.jwt = m[1]; caller.uid = uj?.id || null; caller.role = "member";
    const who = await rpc(env, m[1], "admin_whoami").catch(() => null);
    if (whoamiIsAdmin(who)) caller.role = "admin";
  }
  const handler = createMcpHandler(() => buildResidentServer(env, caller), {
    route: RESIDENT_ROUTE,
    corsOptions: appOrigin ? { origin: appOrigin, methods: "POST, OPTIONS", headers: corsH["access-control-allow-headers"] } : false,
    allowedOriginHostnames: appOrigin ? [new URL(appOrigin).hostname] : [],
    responseMode: "json",
  } as any);
  const res = await handler(request, env, ctx);
  const h = new Headers(res.headers);
  for (const [k, v] of Object.entries(corsH)) h.set(k, v);
  h.set("cache-control", "no-store");
  return new Response(res.body, { status: res.status, headers: h });
}

const HEB_PREFIX = /^[והבלמשכ]{1,2}(?=[\u05d0-\u05ea]{3,})/;
const STOP = new Set("עם של יש את על אני מה איפה מי לי לנו הכי או גם אפשר איזה איזו כמה עכשיו היום מחר פה כאן שם זה זו יש? משהו מקום מקומות טוב טובה טובים רוצה רוצים צריך צריכה תמליצי תמליץ המלצה ממליצים מכירים מכיר בבקשה תודה the a an in of for and to is are".split(" "));
function tokens(q: string) {
  return String(q || "").toLowerCase().replace(/[^\p{L}\p{N}\s'"״׳-]/gu, " ").split(/\s+/).filter((t) => t.length >= 2 && !STOP.has(t)).slice(0, 12);
}
function scoreText(hay: string, toks: string[]) {
  const h = hay.toLowerCase();
  let s = 0;
  for (const t of toks) {
    if (h.includes(t)) s += t.length;
    else { const b = t.replace(HEB_PREFIX, ""); if (b !== t && b.length >= 3 && h.includes(b)) s += b.length; }
  }
  return s;
}

export function buildResidentServer(env: Env, caller: Caller) {
  const server = new McpServer({ name: `kehi-resident-${new URL(env.PUBLIC_URL).hostname.split(".")[0]}`, version: "1.0.0" });
  const comm = env.COMMUNITY_ID ? `&community_id=eq.${encodeURIComponent(env.COMMUNITY_ID)}` : "";
  const hidden = new Set(String(env.HIDE_GROUPS || "").split(",").map((x) => x.trim()).filter(Boolean));
  const LODGING = /[\/·,\s](צימר|צימרים|מלון|מלונות|הוסטל|גסטהאוס|יורט|דירת נופש)[\/·,\s]/;
  const PCOLS = "id,name_he,name_en,category,category_group,address,phone,hours,hours_status,website,maps_url,note,last_verified,updated_at,search_only,badge";
  const ECOLS = "id,title,starts_at,ends_at,start_date,when_text,venue_name,venue_place_id,address,price_text,organizer,description";
  const visible = (p: any) => !(hidden.has(p.category_group || "") || (hidden.size && LODGING.test(` ${p.category || ""} `)));
  const places = async () => ((await sbGet(env, caller.jwt, `places?select=${PCOLS}&status=eq.published${comm}&order=name_he`)) || []).filter(visible);
  const events = async () => (await sbGet(env, caller.jwt, `events?select=${ECOLS}&status=eq.published${comm}&order=starts_at.asc.nullslast`)) || [];

  const tool = (name: string, description: string, schema: z.ZodObject<any>, handler: (a: any) => Promise<any>, needs?: "member") => {
    if (needs === "member" && caller.role === "guest") return; // not even listed for guests
    server.registerTool(name, { description, inputSchema: schema, annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false } } as any,
      (async (args: any) => {
        try { return txt(await handler(args || {})); }
        catch (e: any) { return errTxt(e instanceof RpcError ? `DB error${e.code ? ` ${e.code}` : ""}: ${e.message}` : String(e?.message || e)); }
      }) as any);
  };

  tool("community_info", "The community this server answers for, and the caller's role (guest, member or admin). Read-only tier: answers come only from approved (published) data.",
    z.object({}), async () => ({
      community: env.COMMUNITY_NAME, role: caller.role, tier: "resident-read-only",
      note: "Only published places/events and open board posts are visible. Admin actions are not available on this endpoint.",
    }));
  tool("search_places", "Search approved (published) places and businesses by free text (Hebrew or English): name, category, address, notes. Returns up to `limit` best matches with hours, phone, website and a Google Maps link. Empty result means there is no approved record: say so, do not guess.",
    z.object({ query: z.string().max(200).optional(), category_group: z.string().max(60).optional(), limit: z.number().int().min(1).max(20).optional() }),
    async (a) => {
      const toks = tokens(a.query || "");
      let rows = (await places()).filter((p: any) => !a.category_group || p.category_group === a.category_group);
      if (toks.length) rows = rows.map((p: any) => ({ p, s: scoreText([p.name_he, p.name_en, p.category, p.category_group, p.address, p.note].join(" "), toks) }))
        .filter((x: any) => x.s > 0).sort((x: any, y: any) => y.s - x.s).map((x: any) => x.p);
      return { total: rows.length, places: rows.slice(0, a.limit || 8).map((p: any) => ({ ...p, links: { google_maps: p.maps_url || `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${p.name_he || ""} ${p.address || ""}`)}`, website: p.website || null } })) };
    });
  tool("get_place", "One approved place by id, with its public business calendar (opening hours / bookable slots) when the business has one.",
    z.object({ id: z.string().max(80) }), async (a) => {
      const rows = (await sbGet(env, caller.jwt, `places?select=${PCOLS}&status=eq.published&id=eq.${encodeURIComponent(a.id)}${comm}`)) || [];
      if (!rows.length || !visible(rows[0])) return { found: false };
      const cal = await rpc(env, caller.jwt || env.SUPABASE_ANON_KEY, "place_public_calendar", { p_place_id: a.id }).catch(() => null);
      return { found: true, place: rows[0], calendar: cal };
    });
  tool("list_events", "Approved (published) community events, upcoming first. Optional free-text query (title, venue, organizer) and `days_ahead` window.",
    z.object({ query: z.string().max(200).optional(), days_ahead: z.number().int().min(1).max(365).optional(), limit: z.number().int().min(1).max(30).optional() }),
    async (a) => {
      const now = Date.now(), until = now + (a.days_ahead || 60) * 864e5, toks = tokens(a.query || "");
      let rows = (await events()).filter((e: any) => {
        const t = e.starts_at ? Date.parse(e.starts_at) : e.start_date ? Date.parse(e.start_date + "T23:59:00+02:00") : NaN;
        return isNaN(t) || (t >= now - 6 * 3600e3 && t <= until);
      });
      if (toks.length) rows = rows.filter((e: any) => scoreText([e.title, e.venue_name, e.organizer, e.description, e.when_text].join(" "), toks) > 0);
      return { total: rows.length, events: rows.slice(0, a.limit || 10) };
    });
  tool("list_open_posts", "Open, approved community board posts (rides, giveaways, help requests, recommendations, courses/workshops). Author ids are not returned.",
    z.object({ type: z.enum(["ride", "giveaway", "help", "recommend", "course"]).optional(), query: z.string().max(200).optional(), limit: z.number().int().min(1).max(30).optional() }),
    async (a) => {
      const typeQ = a.type ? `&type=eq.${a.type}` : "";
      let rows = (await sbGet(env, caller.jwt, `posts?select=id,type,title,body,expires_at,created_at&status=eq.open${typeQ}${comm}&order=created_at.desc&limit=100`)) || [];
      const now = Date.now(), toks = tokens(a.query || "");
      rows = rows.filter((p: any) => !p.expires_at || Date.parse(p.expires_at) > now);
      if (toks.length) rows = rows.filter((p: any) => scoreText(`${p.title || ""} ${p.body || ""}`, toks) > 0);
      return { total: rows.length, posts: rows.slice(0, a.limit || 10) };
    });
  tool("business_availability", "Public calendar of an approved business place: opening hours, events and bookable slots (if the business enabled its calendar).",
    z.object({ place_id: z.string().max(80) }), (a) => rpc(env, caller.jwt || env.SUPABASE_ANON_KEY, "place_public_calendar", { p_place_id: a.place_id }));
  tool("course_slots", "Slots of an open course/workshop/tour post with capacity and remaining seats.",
    z.object({ post_id: z.string().max(80) }), (a) => rpc(env, caller.jwt || env.SUPABASE_ANON_KEY, "list_post_slots", { p_post: a.post_id }), "member");
  tool("my_bookings", "The signed-in user's own course/workshop bookings (requires the user's own session).",
    z.object({}), () => rpc(env, caller.jwt as string, "list_my_bookings"), "member");
  return server;
}
