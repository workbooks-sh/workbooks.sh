// Unified LLM client. One surface, two providers — OpenRouter (default,
// routes to DeepSeek v4 Pro or any other catalog model) and Cerebras
// (kept for speed-critical paths since GLM-4.7 is sub-second).
//
// Why DeepSeek default: 1M context, very cheap, no reasoning tax (unlike
// GLM-4.7 which eats max_tokens on CoT before answering), and Pro is
// strong for structured-output planning.

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const CEREBRAS_URL = "https://api.cerebras.ai/v1/chat/completions";

/** Canonical model slugs. Use these instead of literal strings so a switch
 *  is one constant change. */
export const MODELS = {
  /** DeepSeek v4 Flash via OpenRouter — primary planner. Sub-2s on OpenRouter,
   *  clean JSON, 1M context. Pro is too slow for CF Worker 30s wall-clock. */
  planner: "deepseek/deepseek-v4-flash",
  /** DeepSeek v4 Pro — reserved for high-stakes single-shot composition where
   *  we have time for reasoning (e.g. brand book narrative). Not used in
   *  interactive HTTP paths. */
  thinker: "deepseek/deepseek-v4-pro",
  /** Cerebras GLM-4.7 — kept for ultra-fast (sub-second) classification. */
  fast: "zai-glm-4.7",
  /** Vision — read images (slide review, ad/creative analysis, palette). Uses
   *  minimax-m3, the AGENT'S OWN natively-multimodal model (text+image+video in,
   *  1M ctx) — we do NOT need a separate image-generation model just to LOOK at
   *  an image, and this keeps one model across the agent + its vision calls. */
  vision: "minimax/minimax-m3",
} as const;

export type Provider = "openrouter" | "cerebras";

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: any; // string OR multimodal content array
}

export interface ChatOptions {
  /** Model slug. Picks provider from the slug shape (anything with "/" is
   *  OpenRouter; bare slugs are Cerebras). Override via `provider`. */
  model?: string;
  provider?: Provider;
  messages: ChatMessage[];
  json?: boolean;
  temperature?: number;
  max_tokens?: number;
  top_p?: number;
  /** Reasoning models only (Cerebras GLM). Ignored elsewhere. */
  reasoning_effort?: "low" | "medium" | "high";
}

export interface ChatResult {
  content: string;
  model: string;
  provider: Provider;
  usage: { prompt_tokens: number; completion_tokens: number; total_tokens: number; cost_usd?: number };
  latency_ms: number;
  raw: unknown;
}

export class LlmError extends Error {
  constructor(message: string, public readonly status: number, public readonly body?: unknown) {
    super(message);
    this.name = "LlmError";
  }
}

interface Keys {
  openrouter?: string;
  cerebras?: string;
}

function pickProvider(model: string, override?: Provider): Provider {
  if (override) return override;
  return model.includes("/") ? "openrouter" : "cerebras";
}

export async function chat(keys: Keys, opts: ChatOptions): Promise<ChatResult> {
  const model = opts.model ?? MODELS.planner;
  const provider = pickProvider(model, opts.provider);
  const t0 = Date.now();

  if (provider === "openrouter") {
    if (!keys.openrouter) throw new LlmError("OPENROUTER_API_KEY is not configured", 503);
    return openrouterChat(keys.openrouter, model, opts, t0);
  } else {
    if (!keys.cerebras) throw new LlmError("CEREBRAS_API_KEY is not configured", 503);
    return cerebrasChat(keys.cerebras, model, opts, t0);
  }
}

async function openrouterChat(
  apiKey: string,
  model: string,
  opts: ChatOptions,
  t0: number,
): Promise<ChatResult> {
  const body: Record<string, unknown> = {
    model,
    messages: opts.messages,
    stream: false,
    temperature: opts.temperature ?? 0.7,
    max_tokens: opts.max_tokens ?? 4000,
    top_p: opts.top_p ?? 0.95,
  };
  if (opts.json) body.response_format = { type: "json_object" };

  const r = await fetch(OPENROUTER_URL, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
      "http-referer": "https://brandnana.net",
      "x-title": "brandnana",
    },
    body: JSON.stringify(body),
  });

  if (!r.ok) {
    const text = await r.text().catch(() => "");
    throw new LlmError(`OpenRouter ${r.status}: ${text.slice(0, 200)}`, r.status, text);
  }
  const data = (await r.json()) as any;
  const msg = data.choices?.[0]?.message ?? {};
  // Fall back to reasoning_content when content is empty (some routing).
  const content: string = msg.content || msg.reasoning_content || "";
  return {
    content,
    model: data.model ?? model,
    provider: "openrouter",
    usage: {
      prompt_tokens: data.usage?.prompt_tokens ?? 0,
      completion_tokens: data.usage?.completion_tokens ?? 0,
      total_tokens: data.usage?.total_tokens ?? 0,
      cost_usd: data.usage?.cost,
    },
    latency_ms: Date.now() - t0,
    raw: data,
  };
}

async function cerebrasChat(
  apiKey: string,
  model: string,
  opts: ChatOptions,
  t0: number,
): Promise<ChatResult> {
  // GLM-4.7 is a reasoning model — floor max_tokens so reasoning doesn't eat
  // the budget before any answer is produced.
  const body: Record<string, unknown> = {
    model,
    messages: opts.messages,
    stream: false,
    temperature: opts.temperature ?? 0.7,
    max_tokens: Math.max(opts.max_tokens ?? 8000, 8000),
    top_p: opts.top_p ?? 0.95,
    reasoning_effort: opts.reasoning_effort ?? "low",
  };
  if (opts.json) body.response_format = { type: "json_object" };

  const r = await fetch(CEREBRAS_URL, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!r.ok) {
    const text = await r.text().catch(() => "");
    throw new LlmError(`Cerebras ${r.status}: ${text.slice(0, 200)}`, r.status, text);
  }
  const data = (await r.json()) as any;
  const msg = data.choices?.[0]?.message ?? {};
  if ((!msg.content || msg.content.length === 0) && msg.reasoning_content) {
    msg.content = msg.reasoning_content;
  }
  return {
    content: msg.content ?? "",
    model: data.model ?? model,
    provider: "cerebras",
    usage: {
      prompt_tokens: data.usage?.prompt_tokens ?? 0,
      completion_tokens: data.usage?.completion_tokens ?? 0,
      total_tokens: data.usage?.total_tokens ?? 0,
    },
    latency_ms: Date.now() - t0,
    raw: data,
  };
}

/** Strict-JSON convenience that parses + validates the model spat JSON. */
export async function chatJson<T = unknown>(keys: Keys, opts: ChatOptions): Promise<{ value: T; usage: ChatResult["usage"]; model: string; latency_ms: number }> {
  const r = await chat(keys, { ...opts, json: true });
  const cleaned = r.content.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "").trim();
  let parsed: T;
  try {
    parsed = JSON.parse(cleaned) as T;
  } catch {
    throw new LlmError(`Model did not return valid JSON: ${r.content.slice(0, 200)}`, 502, r.content);
  }
  return { value: parsed, usage: r.usage, model: r.model, latency_ms: r.latency_ms };
}
