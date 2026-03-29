/**
 * Vercel serverless: POST /api/v1/ai-puzzle
 * Deploy: set Vercel "Root Directory" to repository root (or the folder that contains this `api` folder).
 * Path on disk must be api/v1/ai-puzzle.js so the live URL is /api/v1/ai-puzzle
 *
 * Env: OPENAI_API_KEY (required), OPENAI_MODEL (optional, default gpt-4o-mini)
 */

function utcDayKey() {
  return new Date().toISOString().slice(0, 10);
}

function getQuotaMap() {
  const g = globalThis;
  if (!g.__colorhueiqQuota) g.__colorhueiqQuota = new Map();
  return g.__colorhueiqQuota;
}

function validatePuzzleSpec(obj) {
  const indices = obj.filledCellIndices;
  if (!Array.isArray(indices)) return "filledCellIndices must be an array";
  if (indices.length < 12 || indices.length > 48) return "Need 12–48 cells";
  const set = new Set();
  for (const i of indices) {
    if (!Number.isInteger(i) || i < 0 || i > 63) return "Invalid cell index";
    if (set.has(i)) return "Duplicate cell index";
    set.add(i);
  }
  const hb = obj.hueBase;
  const ho = obj.hueOffset;
  if (typeof hb !== "number" || hb < 0 || hb > 1) return "hueBase must be 0–1";
  if (typeof ho !== "number" || ho < 0.15 || ho > 0.85) return "hueOffset must be 0.15–0.85";
  let lr = obj.lockRatio;
  if (lr === undefined || lr === null) lr = 0.6;
  if (typeof lr !== "number" || lr < 0.45 || lr > 0.75) return "lockRatio must be 0.45–0.75";
  return null;
}

const jsonSchema = {
  name: "puzzle_spec",
  strict: true,
  schema: {
    type: "object",
    additionalProperties: false,
    required: ["filledCellIndices", "hueBase", "hueOffset"],
    properties: {
      filledCellIndices: {
        type: "array",
        items: { type: "integer", minimum: 0, maximum: 63 },
        minItems: 12,
        maxItems: 48,
      },
      hueBase: { type: "number", minimum: 0, maximum: 1 },
      hueOffset: { type: "number", minimum: 0.15, maximum: 0.85 },
      lockRatio: { type: "number", minimum: 0.45, maximum: 0.75 },
    },
  },
};

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "method_not_allowed" });
    return;
  }

  const deviceId = (req.headers["x-device-id"] || "").toString().trim().slice(0, 128);
  if (!deviceId) {
    res.status(400).json({ error: "missing_device", message: "Send X-Device-Id header" });
    return;
  }

  let body = req.body;
  if (typeof body === "string") {
    try {
      body = JSON.parse(body);
    } catch {
      res.status(400).json({ error: "invalid_json" });
      return;
    }
  }

  const tier = body.tier === "pro" ? "pro" : "free";
  const limit = tier === "pro" ? 10 : 1;
  const promptRaw = (body.prompt || "").toString().trim().slice(0, 200);

  if (!promptRaw) {
    res.status(400).json({ error: "empty_prompt" });
    return;
  }

  const day = utcDayKey();
  const qKey = `${deviceId}|${day}|${tier}`;
  const map = getQuotaMap();
  const used = map.get(qKey) || 0;
  if (used >= limit) {
    res.status(429).json({
      error: "quota_exceeded",
      message: tier === "pro" ? "Daily AI limit (10) reached." : "Daily AI limit (1) reached.",
    });
    return;
  }

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    res.status(500).json({ error: "server_misconfigured", message: "OPENAI_API_KEY missing" });
    return;
  }

  const model = process.env.OPENAI_MODEL || "gpt-4o-mini";

  const system = `You output ONLY valid JSON for an 8x8 grid puzzle (indices 0-63 row-major, top-left=0).
The user describes a silhouette. Choose filled cells that form a recognizable shape. Use 12-48 cells.
hueBase and hueOffset are 0-1 on the color wheel; hueOffset is separation between corners (0.15-0.85).
Optional lockRatio 0.45-0.75 = fraction of shape cells that are locked hints.
No text outside JSON.`;

  const openaiRes = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: system },
        { role: "user", content: promptRaw },
      ],
      response_format: {
        type: "json_schema",
        json_schema: jsonSchema,
      },
    }),
  });

  const raw = await openaiRes.text();
  if (!openaiRes.ok) {
    res.status(502).json({
      error: "openai_error",
      message: raw.slice(0, 500),
    });
    return;
  }

  let completion;
  try {
    completion = JSON.parse(raw);
  } catch {
    res.status(502).json({ error: "openai_bad_response" });
    return;
  }

  const text = completion.choices?.[0]?.message?.content;
  if (!text) {
    res.status(502).json({ error: "no_content" });
    return;
  }

  let spec;
  try {
    spec = JSON.parse(text);
  } catch {
    res.status(502).json({ error: "model_not_json" });
    return;
  }

  const err = validatePuzzleSpec(spec);
  if (err) {
    res.status(502).json({ error: "invalid_spec", message: err });
    return;
  }

  map.set(qKey, used + 1);
  const remaining = Math.max(0, limit - used - 1);

  res.status(200).json({
    puzzle: {
      filledCellIndices: spec.filledCellIndices,
      hueBase: spec.hueBase,
      hueOffset: spec.hueOffset,
      lockRatio: spec.lockRatio ?? 0.6,
    },
    remainingQuota: remaining,
    tier,
  });
}
