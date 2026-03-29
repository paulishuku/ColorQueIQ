# ColorHueIQ AI puzzle API

Import the **Git repository root** (the folder that contains both `api/` and `HueGame/`). The iOS app posts to:

`POST {AIApiBaseURL}/api/v1/ai-puzzle`

The handler must be at **`api/v1/ai-puzzle.js`** from that root (next to `vercel.json`). Opening `https://YOUR_APP.vercel.app` in a browser may show **404** — that’s normal; only the `/api/v1/ai-puzzle` route exists.

## Deploy on Vercel (step-by-step)

1. **Push the repo** to GitHub (if it isn’t already).

2. In [vercel.com](https://vercel.com) → **Add New… → Project** → **Import** your repo.

3. **Root Directory:** leave **empty** (repository root) — the same level as `vercel.json`, `api/v1/ai-puzzle.js`, and `HueGame/`. Do **not** set root to only the `api` subfolder unless you know how to nest routes.

4. **Environment variables** (Project → Settings → Environment Variables), for **Production** (and Preview if you want):
   - `OPENAI_API_KEY` = your secret key from OpenAI (starts with `sk-…`).
   - Optional: `OPENAI_MODEL` = e.g. `gpt-4o-mini` or another model id that supports structured JSON output.

5. **Deploy**, then tap **Redeploy** if you added env vars after the first deploy (otherwise OpenAI key won’t be available).

6. **iPhone app:** Edit `HueGame/Info.plist` → `AIApiBaseURL` to your `https://….vercel.app` URL (no trailing slash). Or use Build Settings; `HueGame/Info.plist` is merged with the generated plist and is the reliable source.

7. **Smoke test** (Terminal):
   ```bash
   curl -sS -X POST "https://YOUR_PROJECT.vercel.app/api/v1/ai-puzzle" \
     -H "Content-Type: application/json" \
     -H "X-Device-Id: test-device-123" \
     -d '{"prompt":"simple heart shape","tier":"free"}'
   ```
   You should get JSON with a `puzzle` object. If you see `OPENAI_API_KEY missing`, the env var isn’t set for that deployment.

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | Yes | OpenAI API key |
| `OPENAI_MODEL` | No | Defaults to `gpt-4o-mini`. Set to your preferred small model id. |

## Headers

- `X-Device-Id`: stable UUID from the app (used for UTC-day quotas).
- `Content-Type: application/json`

## Body

```json
{ "prompt": "text max 200 chars", "tier": "free" | "pro" }
```

## Quotas

- `free`: 1 successful generation per UTC day per device id.
- `pro`: 10 per UTC day per device id.

Quota is enforced in memory and resets when the serverless instance cold-starts. For production, persist counts in [Vercel KV](https://vercel.com/docs/storage/vercel-kv) or [Upstash Redis](https://upstash.com/).

## iOS configuration

Set **`AIApiBaseURL`** in **`HueGame/Info.plist`** (merged into the app with `GENERATE_INFOPLIST_FILE`). No trailing slash.

For local testing: `UserDefaults` key `ai_api_base_override` = `http://127.0.0.1:3000` and run `node server-local.mjs` from the `api` directory.
