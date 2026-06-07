// OpenRouter LLM client.
//
// Goes through Cloudflare AI Gateway (cf-aig-authorization) when the
// gateway token is configured, otherwise calls OpenRouter directly.
// Default model is Meta's Llama 3.2 3B — cheap, fast, enough for
// product-card extraction.
//
// Models we use:
//   meta-llama/llama-3.2-3b-instruct  ($0.06/M in, $0.06/M out)  default
//   meta-llama/llama-3.3-70b-instruct ($0.59/M in, $0.79/M out)  higher quality fallback

import type { Bindings } from "../env.js";

const DIRECT = "https://openrouter.ai/api/v1";

export type ChatMessage =
  | { role: "system"; content: string }
  | { role: "user"; content: string }
  | { role: "assistant"; content: string };

export interface ChatOptions {
  messages: ChatMessage[];
  model?: string;
  max_tokens?: number;
  temperature?: number;
  /** Force JSON output (OpenRouter passes through to providers that support it). */
  response_format?: { type: "json_object" };
  tenant: string;
}

export interface ChatResult {
  content: string;
  model: string;
  usage?: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
  /**
   * Upstream-reported USD cost for this call, when OpenRouter surfaces
   * it in `usage.cost`. When absent, callers should compute the cost
   * locally from `usage` × the rate table in pricing.ts.
   */
  upstream_cost_usd?: number;
}

function gatewayUrl(env: Bindings): string | null {
  if (!env.CF_AI_GATEWAY_TOKEN) return null;
  const acct =
    (env as unknown as { CF_ACCOUNT_ID?: string }).CF_ACCOUNT_ID ??
    "6d4b74aeb10f455fbf88141901e7595d";
  const gw = (env as unknown as { AI_GATEWAY_ID?: string }).AI_GATEWAY_ID ?? "brandnana";
  return `https://gateway.ai.cloudflare.com/v1/${acct}/${gw}/openrouter`;
}

export async function chat(env: Bindings, opts: ChatOptions): Promise<ChatResult> {
  if (!env.OPENROUTER_API_KEY) {
    throw new Error("OPENROUTER_API_KEY not configured on the worker");
  }
  const base = gatewayUrl(env) ?? DIRECT;
  const model = opts.model ?? "meta-llama/llama-3.2-3b-instruct";

  const headers: Record<string, string> = {
    authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
    "content-type": "application/json",
    "http-referer": "https://github.com/shinyobjectz/brandnana",
    "x-title": "brandnana",
  };
  if (env.CF_AI_GATEWAY_TOKEN) {
    headers["cf-aig-authorization"] = `Bearer ${env.CF_AI_GATEWAY_TOKEN}`;
    headers["cf-aig-metadata"] = JSON.stringify({ provider: "openrouter", tenant: opts.tenant });
  }

  const body: Record<string, unknown> = {
    model,
    messages: opts.messages,
    max_tokens: opts.max_tokens ?? 512,
    temperature: opts.temperature ?? 0.2,
  };
  if (opts.response_format) body.response_format = opts.response_format;

  const res = await fetch(`${base}/chat/completions`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`OpenRouter ${res.status}: ${await res.text()}`);
  }
  const data = (await res.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
    model?: string;
    usage?: {
      prompt_tokens: number;
      completion_tokens: number;
      total_tokens: number;
      /** OpenRouter exposes the underlying-provider USD cost here. */
      cost?: number;
    };
    error?: { message?: string };
  };
  if (data.error) {
    throw new Error(`OpenRouter: ${data.error.message ?? JSON.stringify(data.error)}`);
  }
  const content = data.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    throw new Error("OpenRouter: response had no content");
  }
  const usage = data.usage
    ? {
        prompt_tokens: data.usage.prompt_tokens,
        completion_tokens: data.usage.completion_tokens,
        total_tokens: data.usage.total_tokens,
      }
    : undefined;
  return {
    content,
    model: data.model ?? model,
    usage,
    upstream_cost_usd:
      typeof data.usage?.cost === "number" && Number.isFinite(data.usage.cost)
        ? data.usage.cost
        : undefined,
  };
}
