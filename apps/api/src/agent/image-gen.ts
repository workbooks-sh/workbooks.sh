// Image generation via OpenRouter. Default model: google/gemini-3.1-flash-image-preview
// (~$0.04/image, accepts reference image + text prompt, returns PNG data URL).
//
// Used by the concept-deck composer to materialize static ads, landing-page
// hero images, carousel frames, product concept renders, etc — all grounded
// in the brand's actual visual identity by passing the homepage screenshot
// as a reference image.

import { imagePart } from "../llm/image-input.js";

const ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const DEFAULT_MODEL = "google/gemini-3.1-flash-image-preview";
const REFERER = "https://brandnana.net";
const X_TITLE = "brandnana";

export interface GeneratedImage {
  /** data:image/png;base64,... URL. Caller usually uploads to R2 for serving. */
  data_url: string;
  /** Raw PNG bytes (parsed from data_url for convenience). */
  bytes: Uint8Array;
  mime: string;
  model: string;
  latency_ms: number;
  cost_usd: number;
  /** Any text the model returned alongside the image. */
  caption?: string;
}

export interface GenerateImageOpts {
  prompt: string;
  /** Reference image — homepage screenshot, brand book mark, etc. URL or data URL. */
  referenceImageUrl?: string;
  /** "1:1" | "16:9" | "9:16" | "4:5" | "3:4" — hint embedded in the prompt. */
  aspectRatio?: string;
  /** Override the default model (e.g. "google/gemini-3-pro-image-preview" for higher quality). */
  model?: string;
}

interface ORResponse {
  choices?: Array<{
    message?: {
      content?: string;
      images?: Array<{ type?: string; image_url?: string | { url?: string } }>;
    };
  }>;
  usage?: { cost?: number; image_tokens?: number; total_tokens?: number };
  model?: string;
}

export async function generateImage(
  openrouterApiKey: string,
  opts: GenerateImageOpts,
): Promise<GeneratedImage> {
  if (!openrouterApiKey) throw new Error("OPENROUTER_API_KEY is not configured");

  const t0 = Date.now();
  const model = opts.model ?? DEFAULT_MODEL;

  // Build messages. If reference image, multimodal content; else plain text.
  const aspectHint = opts.aspectRatio ? `\n\nAspect ratio: ${opts.aspectRatio}.` : "";
  const promptWithHint = opts.prompt + aspectHint;

  const content: any = opts.referenceImageUrl
    ? [
        { type: "text", text: promptWithHint },
        // Inline the reference image as a data URI so OpenRouter never fetches a
        // (possibly private/temp-hosted) URL — same fix as the vision paths (wb-r8z1).
        await imagePart(opts.referenceImageUrl),
      ]
    : promptWithHint;

  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: {
      authorization: `Bearer ${openrouterApiKey}`,
      "content-type": "application/json",
      "http-referer": REFERER,
      "x-title": X_TITLE,
    },
    body: JSON.stringify({
      model,
      messages: [{ role: "user", content }],
      modalities: ["image", "text"],
    }),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`OpenRouter ${res.status}: ${text.slice(0, 200)}`);
  }
  const data = (await res.json()) as ORResponse;
  const msg = data.choices?.[0]?.message;
  const imgEntry = msg?.images?.[0];
  if (!imgEntry) {
    throw new Error(`no image in response: ${msg?.content?.slice(0, 120) ?? "<empty>"}`);
  }

  const url = typeof imgEntry.image_url === "string"
    ? imgEntry.image_url
    : imgEntry.image_url?.url;
  if (!url || !url.startsWith("data:")) {
    throw new Error(`unexpected image_url shape: ${typeof imgEntry.image_url}`);
  }
  const m = url.match(/^data:([^;]+);base64,(.+)$/);
  if (!m) throw new Error("malformed data URL");
  const mime = m[1]!;
  const b64 = m[2]!;
  const bytes = base64ToBytes(b64);

  return {
    data_url: url,
    bytes,
    mime,
    model: data.model ?? model,
    latency_ms: Date.now() - t0,
    cost_usd: data.usage?.cost ?? 0,
    caption: msg?.content?.trim() || undefined,
  };
}

/** Generate N images in parallel from N independent prompts. */
export async function generateImageBatch(
  openrouterApiKey: string,
  prompts: GenerateImageOpts[],
): Promise<Array<GeneratedImage | { error: string; prompt: string }>> {
  const results = await Promise.allSettled(
    prompts.map((p) => generateImage(openrouterApiKey, p)),
  );
  return results.map((r, i) =>
    r.status === "fulfilled" ? r.value : { error: (r.reason as Error).message, prompt: prompts[i]!.prompt },
  );
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** Upload a generated image to R2 and return its public URL.
 *
 * `key` MUST start with "concept-images/" to land in the correct R2 path.
 * The public URL strips that prefix because the serving route is mounted at
 * /concept-images/* — without the strip we'd get a double-prefixed 404. */
export async function uploadImageToR2(
  bucket: R2Bucket,
  key: string,
  img: GeneratedImage,
): Promise<string> {
  await bucket.put(key, img.bytes, {
    httpMetadata: { contentType: img.mime },
    customMetadata: {
      generated_at: String(Date.now()),
      model: img.model,
      cost_usd: String(img.cost_usd),
      bytes: String(img.bytes.length),
    },
  });
  const publicPath = key.replace(/^concept-images\//, "");
  return `https://api.brandnana.net/concept-images/${publicPath}`;
}
