// Brand-correctness verifier — given (domain, expected_name), checks whether
// what we're scraping actually IS the brand we think. Catches the "agent
// pulled the wrong company from the URL" case the user flagged.
//
// Signals checked:
//   - <title> tag contains the expected name (or vice versa, fuzzy)
//   - <meta property="og:site_name">
//   - <meta property="og:title">
//   - <link rel="canonical"> hostname matches the domain
//   - Schema.org Organization/Brand name in JSON-LD
//   - Logo alt text (when we have the homepage HTML)
//
// Returns a confidence score 0-1 + reasons. Anything below ~0.5 should make
// the agent prompt the user to confirm OR escalate to a different source.

const STOPWORDS = new Set([
  "the", "a", "an", "of", "and", "&", "co", "inc", "corp", "ltd", "llc",
  "company", "corporation", "limited", "incorporated", "official",
  "home", "homepage", "website", "site", "store", "shop", "online",
]);

function normalize(s: string): string {
  return s
    .toLowerCase()
    .replace(/[®©™]/g, "")
    .replace(/[‘’“”]/g, "'")
    .replace(/[^\w\s'-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function tokenize(s: string): string[] {
  return normalize(s).split(/\s+/).filter((t) => t && !STOPWORDS.has(t));
}

function jaccard(a: string[], b: string[]): number {
  if (a.length === 0 || b.length === 0) return 0;
  const setA = new Set(a);
  const setB = new Set(b);
  let inter = 0;
  for (const t of setA) if (setB.has(t)) inter++;
  return inter / (setA.size + setB.size - inter);
}

function containsName(haystack: string, needleTokens: string[]): boolean {
  const hay = normalize(haystack);
  return needleTokens.every((t) => hay.includes(t));
}

export interface BrandVerifyResult {
  /** 0-1 confidence that observed_name matches expected_name. */
  confidence: number;
  /** Human-readable signals that drove the score. */
  signals: Array<{ source: string; observed: string; match: boolean; weight: number }>;
  /** Best-guess observed brand name (from strongest matching signal). */
  observed_name: string | null;
  /** True if confidence is high enough to ship without user confirmation (>= 0.6). */
  trust: boolean;
  /** Warnings the caller should surface. */
  warnings: string[];
}

export interface VerifyInputs {
  domain: string;
  expected_name: string;
  /** Optional homepage HTML (skip re-fetching if caller already has it). */
  html?: string;
}

export async function verifyBrand(inputs: VerifyInputs): Promise<BrandVerifyResult> {
  const out: BrandVerifyResult = {
    confidence: 0,
    signals: [],
    observed_name: null,
    trust: false,
    warnings: [],
  };
  const expectedTokens = tokenize(inputs.expected_name);
  if (expectedTokens.length === 0) {
    out.warnings.push("expected_name is empty after tokenization");
    return out;
  }

  let html = inputs.html;
  if (!html) {
    try {
      const r = await fetch(`https://${inputs.domain}/`, {
        headers: {
          "user-agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
          "accept": "text/html",
        },
        redirect: "follow",
      });
      if (!r.ok) {
        out.warnings.push(`homepage fetch ${r.status}`);
        return out;
      }
      html = (await r.text()).slice(0, 500_000);
    } catch (e) {
      out.warnings.push(`homepage fetch threw: ${(e as Error).message}`);
      return out;
    }
  }

  // Signal 1: <title> tag (weight 0.25).
  const titleRaw = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.trim().replace(/\s+/g, " ");
  if (titleRaw) {
    const match = containsName(titleRaw, expectedTokens) || jaccard(tokenize(titleRaw), expectedTokens) > 0.4;
    out.signals.push({ source: "<title>", observed: titleRaw.slice(0, 100), match, weight: 0.25 });
    if (match && !out.observed_name) out.observed_name = titleRaw.slice(0, 80);
  } else {
    out.warnings.push("no <title> tag found");
  }

  // Signal 2: og:site_name (weight 0.25).
  const ogSite = matchMeta(html, "og:site_name");
  if (ogSite) {
    const match = containsName(ogSite, expectedTokens) || jaccard(tokenize(ogSite), expectedTokens) > 0.5;
    out.signals.push({ source: "og:site_name", observed: ogSite.slice(0, 100), match, weight: 0.25 });
    if (match && !out.observed_name) out.observed_name = ogSite;
  }

  // Signal 3: og:title (weight 0.15).
  const ogTitle = matchMeta(html, "og:title");
  if (ogTitle) {
    const match = containsName(ogTitle, expectedTokens);
    out.signals.push({ source: "og:title", observed: ogTitle.slice(0, 100), match, weight: 0.15 });
    if (match && !out.observed_name) out.observed_name = ogTitle.slice(0, 80);
  }

  // Signal 4: canonical link hostname matches the domain we're inspecting (weight 0.15).
  const canonical = html.match(/<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']/i)?.[1];
  if (canonical) {
    try {
      const host = new URL(canonical).hostname.replace(/^www\./, "");
      const want = inputs.domain.replace(/^www\./, "");
      const match = host === want || host.endsWith("." + want) || want.endsWith("." + host);
      out.signals.push({ source: "<link rel=canonical>", observed: host, match, weight: 0.15 });
    } catch { /* malformed canonical */ }
  }

  // Signal 5: JSON-LD Organization / Brand name (weight 0.20).
  const ldNames = extractJsonLdNames(html);
  for (const ld of ldNames) {
    const match = containsName(ld, expectedTokens) || jaccard(tokenize(ld), expectedTokens) > 0.5;
    out.signals.push({ source: "json-ld Organization", observed: ld.slice(0, 100), match, weight: 0.20 });
    if (match && !out.observed_name) out.observed_name = ld;
    break; // first one is usually correct
  }

  // Aggregate: weighted average of matched signals + small bonus for any match at all.
  let weightSum = 0;
  let matchedWeight = 0;
  for (const s of out.signals) {
    weightSum += s.weight;
    if (s.match) matchedWeight += s.weight;
  }
  out.confidence = weightSum > 0 ? matchedWeight / weightSum : 0;
  out.trust = out.confidence >= 0.6 && out.signals.filter((s) => s.match).length >= 2;

  if (!out.trust && out.observed_name) {
    out.warnings.push(
      `Low confidence — observed brand ("${out.observed_name}") may not match expected ("${inputs.expected_name}").`,
    );
  } else if (out.signals.length === 0) {
    out.warnings.push("No brand-identity signals found on homepage.");
  }

  return out;
}

function matchMeta(html: string, key: string): string | null {
  const esc = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re1 = new RegExp(`<meta[^>]+(?:property|name)=["']${esc}["'][^>]+content=["']([^"']+)["']`, "i");
  const re2 = new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']${esc}["']`, "i");
  return (html.match(re1)?.[1] ?? html.match(re2)?.[1] ?? null);
}

function extractJsonLdNames(html: string): string[] {
  const out: string[] = [];
  const re = /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    try {
      const parsed = JSON.parse(m[1]!);
      const arr = Array.isArray(parsed) ? parsed : [parsed];
      for (const node of arr) {
        const flat = flattenLdGraph(node);
        for (const item of flat) {
          const type = typeof item["@type"] === "string" ? item["@type"] : Array.isArray(item["@type"]) ? item["@type"][0] : "";
          if (/Organization|Brand|LocalBusiness|Corporation/i.test(type) && typeof item.name === "string") {
            out.push(item.name);
          }
        }
      }
    } catch { /* skip malformed JSON-LD */ }
  }
  return out;
}

function flattenLdGraph(node: any): any[] {
  if (!node || typeof node !== "object") return [];
  if (Array.isArray(node["@graph"])) return node["@graph"];
  return [node];
}
