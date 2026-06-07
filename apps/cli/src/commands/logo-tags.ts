// Logo tagging — enrich each resolved logo candidate with usage-relevant
// attributes so the agent can pick the right asset per context (a transparent
// wordmark for a header, a square symbol for a favicon, a mono mark for a dark
// bg, …). Two paths, by the candidate's own format:
//   - raster (png/jpg/webp/unknown): Groq vision (llama-4-scout). We fetch the
//     bytes ourselves and send base64 — this dodges the 403 Groq's own media
//     fetcher hits on hosts like Wikimedia, and works where remote-URL doesn't.
//   - svg: parsed structurally from the source (exact transparency + palette +
//     mono/colour; <text>/<image> presence; viewBox aspect). Vision can't
//     render SVG XML, and the source gives ground truth anyway.

export interface LogoTags {
  /** wordmark (text), symbol (mark only), combination (both), or icon (square mark). */
  kind: "wordmark" | "symbol" | "combination" | "icon" | "unknown";
  /** transparent | light | dark | colored — the asset's backdrop. */
  background: "transparent" | "light" | "dark" | "colored" | "unknown";
  transparent: boolean;
  monochrome: boolean;
  has_wordmark: boolean;
  has_symbol: boolean;
  /** Up to ~6 dominant hex colours (SVG: exact from source; raster: vision estimate). */
  palette?: string[];
  /** How the tags were derived. */
  via: "groq-vision" | "svg-source";
}

// Wikimedia (and others) 429 a generic UA; their policy requires a descriptive
// agent with a contact URL. Verified: this UA gets 200 where "brandnana-logo/1.0"
// got 429 from a datacenter IP. Shared across every logo fetch.
export const LOGO_USER_AGENT = "brandnana-logo-resolver/1.0 (+https://brandnana.net)";

const GROQ_VISION_MODEL = "meta-llama/llama-4-scout-17b-16e-instruct";
const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";

// ── SVG: structural tagging from source (no network beyond the fetch) ─────────

const HEX_RE = /#[0-9a-fA-F]{3,8}\b/g;
const NAMED_COLOR_RE = /(?:fill|stroke)\s*[:=]\s*["']?(rgb\([^)]+\)|[a-z]{3,20})["']?/gi;

export function deriveSvgTags(svgText: string): LogoTags {
  const lower = svgText.toLowerCase();

  // Palette: hex colours present in the source, minus pure black/white which
  // carry no brand signal on their own.
  const hexes = Array.from(new Set((svgText.match(HEX_RE) ?? []).map((h) => h.toLowerCase())));
  const chromatic = hexes.filter((h) => !/^#(0{3,8}|f{3,8})$/.test(h));
  const palette = (chromatic.length ? chromatic : hexes).slice(0, 6);

  // Colour count for mono detection — hexes + named/rgb fills, excluding none.
  const named = Array.from(lower.matchAll(NAMED_COLOR_RE))
    .map((m) => m[1])
    .filter((c): c is string => !!c && c !== "none" && c !== "currentcolor" && c !== "transparent");
  const distinct = new Set<string>([...hexes, ...named]);
  const monochrome = distinct.size <= 1;

  // Transparent unless a full-canvas background rect/path fills the viewBox.
  const hasBgRect = /<rect[^>]*\b(width|height)\s*=\s*["']?(100%|\d{3,})/.test(lower) &&
    /<rect[^>]*fill\s*=\s*["']?(?!none|transparent)/.test(lower);
  const transparent = !hasBgRect;

  // Wordmark signal: real <text> nodes, or a wide aspect from the viewBox.
  const hasText = /<text[\s>]/.test(lower);
  const vb = svgText.match(/viewbox\s*=\s*["']([\d.\s,-]+)["']/i)?.[1]?.trim().split(/[\s,]+/);
  const aspect = vb && vb.length === 4 ? Number(vb[2]) / Number(vb[3]) : undefined;
  const wide = aspect != null && aspect >= 2.2;
  const has_wordmark = hasText || wide;
  const has_symbol = !wide; // a wide pure-wordmark rarely carries a separate mark

  const kind: LogoTags["kind"] = has_wordmark && has_symbol
    ? "combination"
    : has_wordmark
      ? "wordmark"
      : aspect != null && aspect >= 0.85 && aspect <= 1.18
        ? "icon"
        : "symbol";

  return {
    kind,
    background: transparent ? "transparent" : "unknown",
    transparent,
    monochrome,
    has_wordmark,
    has_symbol,
    ...(palette.length ? { palette } : {}),
    via: "svg-source",
  };
}

// ── Raster: Groq vision tagging (base64) ─────────────────────────────────────

const VISION_PROMPT =
  "You are tagging a brand LOGO image. Reply with ONLY a compact JSON object, no prose:\n" +
  '{"kind":"wordmark|symbol|combination|icon","background":"transparent|light|dark|colored",' +
  '"transparent":true|false,"monochrome":true|false,"has_wordmark":true|false,' +
  '"has_symbol":true|false,"palette":["#hex",...]}\n' +
  "kind: wordmark=text only, symbol=mark only, combination=both, icon=small square mark. " +
  "transparent=checkerboard/no background. monochrome=single colour. " +
  "palette=up to 4 dominant hex colours.";

function parseJsonLoose<T>(text: string): T | null {
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return null;
  try { return JSON.parse(m[0]) as T; } catch { return null; }
}

export async function tagRasterWithGroqVision(
  url: string,
  apiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<LogoTags | null> {
  // Fetch the bytes ourselves (UA set) so hosts that block Groq's fetcher still
  // tag, and so this works regardless of remote-URL support.
  let dataUrl: string;
  try {
    const imgRes = await fetchImpl(url, { headers: { "User-Agent": LOGO_USER_AGENT } });
    if (!imgRes.ok) return null;
    const mime = imgRes.headers.get("content-type") || "image/png";
    const buf = Buffer.from(await imgRes.arrayBuffer());
    if (buf.length === 0 || buf.length > 4_000_000) return null; // empty or too big
    dataUrl = `data:${mime};base64,${buf.toString("base64")}`;
  } catch {
    return null;
  }

  try {
    const res = await fetchImpl(GROQ_ENDPOINT, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: GROQ_VISION_MODEL,
        temperature: 0,
        max_tokens: 250,
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: VISION_PROMPT },
              { type: "image_url", image_url: { url: dataUrl } },
            ],
          },
        ],
      }),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const content = data.choices?.[0]?.message?.content ?? "";
    const parsed = parseJsonLoose<Partial<LogoTags>>(content);
    if (!parsed) return null;
    return {
      kind: parsed.kind ?? "unknown",
      background: parsed.background ?? "unknown",
      transparent: !!parsed.transparent,
      monochrome: !!parsed.monochrome,
      has_wordmark: !!parsed.has_wordmark,
      has_symbol: !!parsed.has_symbol,
      ...(Array.isArray(parsed.palette) && parsed.palette.length ? { palette: parsed.palette.slice(0, 6) } : {}),
      via: "groq-vision",
    };
  } catch {
    return null;
  }
}
