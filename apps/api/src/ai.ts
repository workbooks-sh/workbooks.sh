// Cerebras client — direct HTTP, OpenAI-compatible Chat Completions shape.
// Default model: zai-glm-4.7 (Zhipu GLM-4.7 hosted on Cerebras silicon).
//
// We don't proxy through Cloudflare AI Gateway in v1 — going direct keeps
// latency low (the whole point of choosing Cerebras). If we want caching /
// analytics / fallback routing later, fronting with CF AI Gateway is a one-
// line change to the URL.

const CEREBRAS_URL = "https://api.cerebras.ai/v1/chat/completions";

export const MODELS = {
  /** Default: fast + capable enough for slide curation, tool calls, voice notes. */
  default: "zai-glm-4.7",
  /** Same alias, named explicitly. */
  glm47: "zai-glm-4.7",
} as const;

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  tool_call_id?: string;
  tool_calls?: Array<{
    id: string;
    type: "function";
    function: { name: string; arguments: string };
  }>;
}

export interface ChatOptions {
  model?: string;
  messages: ChatMessage[];
  /** If true, response_format = json_object — caller must instruct JSON in the prompt. */
  json?: boolean;
  temperature?: number;
  max_tokens?: number;
  top_p?: number;
  /** OpenAI-style tools, passed through. Set to enable function-calling. */
  tools?: unknown[];
  tool_choice?: "auto" | "none" | { type: "function"; function: { name: string } };
}

export interface ChatResult {
  content: string;
  tool_calls: Array<{
    id: string;
    name: string;
    arguments: unknown;
  }>;
  usage: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
  model: string;
  raw: unknown;
}

export class AiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly body?: unknown,
  ) {
    super(message);
    this.name = "AiError";
  }
}

/**
 * Single non-streaming chat completion. Use for slide curation, brief gen,
 * tool-call planning. Streaming variant can be added when we need it for a
 * UI surface (none today; the Workbook Presentation gets the final structured
 * output in one shot).
 */
export async function chat(
  apiKey: string,
  opts: ChatOptions,
): Promise<ChatResult> {
  if (!apiKey) throw new AiError("CEREBRAS_API_KEY is not configured", 503);

  // GLM-4.7 is a reasoning model: its CoT consumes max_tokens before the
  // final answer. If a caller asks for 400 max_tokens and reasoning eats all
  // 400, content comes back "". Floor to 8000 so reasoning has room AND
  // answer has room. Caller can still set a higher max_tokens explicitly.
  const REASONING_FLOOR = 8000;
  const body: Record<string, unknown> = {
    model: opts.model ?? MODELS.default,
    messages: opts.messages,
    stream: false,
    temperature: opts.temperature ?? 0.7,
    max_tokens: Math.max(opts.max_tokens ?? REASONING_FLOOR, REASONING_FLOOR),
    top_p: opts.top_p ?? 0.95,
    // Tell Cerebras / GLM to keep reasoning short — we want most tokens for
    // the actual answer, not the internal monologue.
    reasoning_effort: "low",
  };
  if (opts.json) body.response_format = { type: "json_object" };
  if (opts.tools) body.tools = opts.tools;
  if (opts.tool_choice) body.tool_choice = opts.tool_choice;

  const r = await fetch(CEREBRAS_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(body),
  });

  if (!r.ok) {
    const text = await r.text().catch(() => "");
    let parsed: unknown = text;
    try { parsed = JSON.parse(text); } catch { /* keep text */ }
    throw new AiError(`Cerebras ${r.status}: ${text.slice(0, 200)}`, r.status, parsed);
  }

  const data = (await r.json()) as {
    model?: string;
    choices?: Array<{
      message?: {
        content?: string | null;
        reasoning_content?: string | null;
        tool_calls?: Array<{
          id: string;
          function: { name: string; arguments: string };
        }>;
      };
    }>;
    usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
  };

  const msg = data.choices?.[0]?.message;
  // Reasoning models sometimes put the final answer in `reasoning_content`
  // when `content` is empty (depends on provider). Use whichever is present.
  if (msg && (!msg.content || msg.content.length === 0) && msg.reasoning_content) {
    msg.content = msg.reasoning_content;
  }
  const toolCalls = (msg?.tool_calls ?? []).map((t) => ({
    id: t.id,
    name: t.function.name,
    arguments: safeJsonParse(t.function.arguments),
  }));

  return {
    content: msg?.content ?? "",
    tool_calls: toolCalls,
    usage: {
      prompt_tokens: data.usage?.prompt_tokens ?? 0,
      completion_tokens: data.usage?.completion_tokens ?? 0,
      total_tokens: data.usage?.total_tokens ?? 0,
    },
    model: data.model ?? opts.model ?? MODELS.default,
    raw: data,
  };
}

/** Convenience: ask for a strict JSON object back. Caller must instruct shape in prompt. */
export async function chatJson<T = unknown>(
  apiKey: string,
  opts: Omit<ChatOptions, "json">,
): Promise<{ value: T; usage: ChatResult["usage"]; model: string }> {
  const r = await chat(apiKey, { ...opts, json: true });
  let parsed: T;
  try {
    parsed = JSON.parse(r.content) as T;
  } catch (e) {
    throw new AiError(
      `Cerebras returned invalid JSON: ${r.content.slice(0, 200)}`,
      502,
      r.raw,
    );
  }
  return { value: parsed, usage: r.usage, model: r.model };
}

function safeJsonParse(s: string): unknown {
  try { return JSON.parse(s); } catch { return s; }
}
