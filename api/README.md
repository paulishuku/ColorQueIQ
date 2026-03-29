# ColorHueIQ AI puzzle API

Deploy **this `api` folder** as the [Vercel](https://vercel.com) project root (see steps below). The iOS app posts to:

`POST {AIApiBaseURL}/api/v1/ai-puzzle`

The handler file must live at `api/v1/ai-puzzle.js` so Vercel exposes `/api/v1/ai-puzzle`.

## Deploy on Vercel (step-by-step)

1. **New or existing project?** Prefer a **new** Vercel project named e.g. `colorhueiq-api` so this API is isolated from unrelated sites. You *can* add this to an existing project only if you set **Root Directory** to this folder and it does not conflict with that project’s framework (e.g. don’t mix with Next.js `api` routes unless you know what you’re doing).

2. **Push the repo** to GitHub/GitLab/Bitbucket (if it isn’t already).

3. In [vercel.com](https://vercel.com) → **Add New… → Project** → **Import** your repo.

4. **Root Directory:** click **Edit** and set it to the folder that contains this `README` (the `api` package in your repo, e.g. `HueGame/api` — path depends on your repo layout). Vercel’s root for the deployment must be the directory that contains `api/v1/ai-puzzle.js` and `package.json`.

5. **Environment variables** (Project → Settings → Environment Variables), for **Production** (and Preview if you want):
   - `OPENAI_API_KEY` = your secret key from OpenAI (starts with `sk-…`).
   - Optional: `OPENAI_MODEL` = e.g. `gpt-4o-mini` or another model id that supports structured JSON output.

6. **Deploy.** When it finishes, copy the project URL, e.g. `https://colorhueiq-api.vercel.app`.

7. **iPhone app:** In Xcode, set **Info** custom key `AIApiBaseURL` to that URL **without** a trailing slash (same value you’d open in a browser minus any path).

8. **Smoke test** (Terminal):
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

Set the `AIApiBaseURL` key in your app Info tab (custom iOS target property) to your deployment origin, e.g. `https://your-project.vercel.app`, **no trailing slash**.

For local testing: `UserDefaults` key `ai_api_base_override` = `http://localhost:3000` and run `node server-local.mjs` from this directory.
