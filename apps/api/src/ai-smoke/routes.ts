// Smoke route for the Cerebras integration. NOT a real product surface —
// just `GET /v1/_smoke/ai?q=<question>` returns the model's short reply so we
// can verify the worker → Cerebras path works after deploy.
//
// Bearer-gated (uses the same requireBearer middleware as the rest of /v1).

import { Hono } from "hono";
import { chat, MODELS, AiError } from "../ai.js";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";

const app = new Hono<{ Bindings: Bindings }>();

app.use("*", requireBearer);

app.get("/", async (c) => {
  const q = c.req.query("q") ?? "In one sentence: what is a brand book?";
  const t0 = Date.now();
  try {
    const r = await chat(c.env.CEREBRAS_API_KEY ?? "", {
      model: MODELS.default,
      messages: [
        { role: "system", content: "You are concise. Reply in one sentence." },
        { role: "user", content: q },
      ],
      max_tokens: 400,
    });
    return c.json({
      ok: true,
      model: r.model,
      reply: r.content,
      usage: r.usage,
      latency_ms: Date.now() - t0,
    });
  } catch (err) {
    if (err instanceof AiError) {
      return c.json(
        { ok: false, error: err.message, status: err.status, body: err.body },
        err.status === 503 ? 503 : 502,
      );
    }
    throw err;
  }
});

export default app;
