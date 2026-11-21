# Kehi relay (Studio)

Signed relay between the app worker and the local Ollama on the Studio. Ollama stays on 127.0.0.1.

- `kehi-relay.mjs` listens on `127.0.0.1:8797`, exposed via a Tailscale Funnel path (`/kehi-relay`).
- Auth: the worker signs `ts\nnonce\nsha256(body)` with an ECDSA P-256 key. The private key exists only as a Cloudflare worker secret (`KEHI_RELAY_JWK`); the Studio keeps only the public key in `~/.kehi-relay/worker_pub.pem`. 60s clock window, nonce replay cache.
- Not a general proxy: fixed model (`gemma4:12b-it-qat`), fixed QA prompt and JSON schema, `num_ctx` 4096 (matches the shared runner so it is not reloaded), `num_predict` 512, 45s model timeout, 2 in flight + 4 queued, 24KB body cap, question ≤ 400 chars, ≤ 8 context records.
- Runs as a user LaunchAgent (`~/Library/LaunchAgents/il.kehi.relay.plist`). Logs status/timings only to `~/.kehi-relay/relay.log`.
- The app falls back to the plain MCP answer cards when the relay is offline, slow or busy.
- `worker-ask-handler.js` is the app worker's `POST /api/ask` (origin lock, Workers rate-limit binding `ASK_RL` plus a per-isolate cap, 20KB body cap, 50s timeout). The app shows the plain record cards first and replaces them with the model's answer when it arrives; on any relay error the cards stay.
