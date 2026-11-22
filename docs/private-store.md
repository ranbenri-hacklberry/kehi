# Private store (community-owned machine)

Rule: **private records live on a machine the community owns; only public content (approved places, events, posts) lives in Supabase / Cloudflare.**

`store/kehi-store.mjs` is a small Node service (no npm deps, built-in `node:sqlite`, Node 22.5+):

- Listens on `127.0.0.1:8798` only; exposed through one Tailscale Funnel path: `tailscale funnel --bg --set-path /kehi-store http://127.0.0.1:8798`.
- Every request is signed (ECDSA P-256 / SHA-256 over `ts\nnonce\nsha256(body)`, headers `x-kehi-ts`, `x-kehi-nonce`, `x-kehi-sig`, `x-kehi-caller`), ±60 s, nonce replay cache. Same scheme as `relay/`.
- Public keys only, in `~/.kehi-store/keys/<caller>.pem`: `app.pem` (the app worker's `KEHI_RELAY_JWK`), `mcp.pem` (the admin MCP's `KEHI_STORE_JWK`). Private keys exist only as Cloudflare worker secrets, generated inside Cloudflare.
- Per-caller allowed ops (`ACL` in the file). The callers check admin rights themselves (app worker: the admin's own Supabase session via `admin_whoami`; MCP: OAuth + `admin_whoami`) before signing admin ops.
- Data: `~/.kehi-store/kehi.db` (dir 700, files 600), WAL. Daily local backup with `VACUUM INTO` to `~/.kehi-store/backups/`, 14 kept. Chat reports are deleted after 30 days. Text is scrubbed again on the store side (keys, tokens, passwords, entry codes, ID numbers).
- Logs op, status and timing only (`store.log`), never record text.
- LaunchAgent: `store/il.kehi.store.plist` (replace `__HOME__`).

Workers:

- App worker (`deploy/qa-handler.js`): if `__STORE_URL__` is set at build time, `/api/qa-log` and `/api/qa-flag` write only to the store, and `/api/admin/store` serves the admin page. If the store is offline the call returns `503 private_store_offline` with a clear Hebrew message; nothing is written anywhere else. If `__STORE_URL__` is not set, the Supabase RPC backend is used.
- Admin MCP (`mcp/`): `add_feedback`, `list_feedback`, `update_feedback_status`. With `PRIVATE_STORE_URL` + secret `KEHI_STORE_JWK` they use the store; without them, the Supabase RPCs from `migrations/026_admin_feedback.sql`. The MCP audit log records only lengths of feedback text, never the text.
- Admin page: set `private_store_admin_path: "/api/admin/store"` in `community.config.json` to read reports / feedback through the worker.

Moving a community: install the store, add keys, set the Funnel path, deploy the app and MCP with the store URL, copy existing rows into the store, then run `migrations/027_private_store_move.sql`.
