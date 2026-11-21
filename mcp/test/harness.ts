// Local-only harness: runs the MCP endpoint with fake props (no network auth) to check tools/list.
// Never deployed (separate entry point).
import { mcpApi } from "../src/index";
export default {
  fetch(req: Request, env: any, ctx: any) {
    (ctx as any).props = { uid: "00000000-0000-0000-0000-000000000000", email: "test@example.invalid", sbAccess: "fake", sbRefresh: "fake", sbExp: Math.floor(Date.now() / 1000) + 3600 };
    return mcpApi(req, env, ctx);
  },
};
