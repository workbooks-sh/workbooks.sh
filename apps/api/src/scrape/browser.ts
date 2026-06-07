// Shared Cloudflare Browser Rendering tier.
//
// This is the real bot-bypass rung in the escalation chain: a realistic UA
// driving a headless Chromium via the CF `BROWSER` binding (@cloudflare/
// puppeteer). It returns post-render HTML and (optionally) a screenshot.
//
// CONTRACT: renderPage MUST fail soft — on ANY error (binding missing, launch
// failure, navigation timeout, import problem) it returns `{ ok: false, error }`
// and NEVER throws. Callers rely on this to escalate to the next tier
// (Firecrawl, context.dev, mshots). It is the single place the browser binding
// is touched, replacing the fictional `https://browser-rendering.cf/v1/content`
// host that used to be POSTed from homepage-scrape.ts / multipage-text.ts.

import type { Bindings } from "../env.js";
import { BROWSER_UA } from "./headers.js";

// Minimal structural shapes for the @cloudflare/puppeteer handles we use.
// We avoid importing the package's named types directly because its
// `exports`/`types` packaging does not surface `Browser`/`Page` cleanly under
// `moduleResolution: bundler`. These cover exactly the methods we call; the
// real objects satisfy them at runtime.
interface PuppeteerResponse {
  status(): number;
}
interface PuppeteerElement {
  screenshot(opts?: { type?: "png" | "jpeg" }): Promise<Uint8Array>;
}
interface PuppeteerPage {
  setUserAgent(ua: string): Promise<void>;
  setViewport(vp: { width: number; height: number }): Promise<void>;
  setDefaultNavigationTimeout(ms: number): void;
  goto(url: string, opts?: { waitUntil?: string; timeout?: number }): Promise<PuppeteerResponse | null>;
  content(): Promise<string>;
  screenshot(opts?: { type?: "png" | "jpeg"; fullPage?: boolean }): Promise<Uint8Array>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  evaluate<R>(fn: (...a: any[]) => R, ...args: unknown[]): Promise<R>;
  $(selector: string): Promise<PuppeteerElement | null>;
}
interface PuppeteerBrowser {
  newPage(): Promise<PuppeteerPage>;
  close(): Promise<void>;
}
interface PuppeteerLike {
  launch(endpoint: unknown, options?: unknown): Promise<PuppeteerBrowser>;
}

const DEFAULT_NAV_TIMEOUT_MS = 20_000;
const HTML_CAP = 1_000_000;

export interface RenderPageResult {
  ok: boolean;
  /** Post-render HTML (page.content()). Present on success when not screenshot-only. */
  html?: string;
  /** PNG bytes when opts.screenshot was requested and capture succeeded. */
  screenshot?: ArrayBuffer;
  /** HTTP status of the main navigation response, when known. */
  status?: number;
  /** Reason the tier could not produce a result (callers escalate on this). */
  error?: string;
}

export interface RenderPageOptions {
  /** Also capture a PNG screenshot of the page. */
  screenshot?: boolean;
  /** Full-page screenshot (default false = viewport only). */
  fullPage?: boolean;
  /** Extra settle time after networkidle before reading content / screenshot. */
  waitMs?: number;
}

/**
 * Render a URL through the Cloudflare Browser Rendering binding.
 *
 * Fails SOFT: returns `{ ok: false, error }` on any failure so the caller can
 * fall back to Firecrawl / context.dev / mshots. Never throws.
 *
 * @param env  Worker bindings (needs `env.BROWSER`).
 * @param url  Absolute URL to render.
 * @param opts screenshot / fullPage / waitMs.
 */
export async function renderPage(
  env: Bindings,
  url: string,
  opts: RenderPageOptions = {},
): Promise<RenderPageResult> {
  const browserBinding = env?.BROWSER as Fetcher | undefined;
  if (!browserBinding) {
    return { ok: false, error: "browser_binding_missing" };
  }

  let puppeteer: PuppeteerLike;
  try {
    const mod = (await import("@cloudflare/puppeteer")) as unknown as {
      default: PuppeteerLike;
    };
    puppeteer = mod.default;
  } catch (e) {
    // Dep not bundled / import failed — graceful stub so callers escalate.
    return { ok: false, error: `browser_unavailable:${errMsg(e)}` };
  }

  let browser: PuppeteerBrowser | undefined;
  try {
    browser = await puppeteer.launch(browserBinding);
    const page = await browser.newPage();
    await page.setUserAgent(BROWSER_UA);
    await page.setViewport({ width: 1280, height: 800 });
    page.setDefaultNavigationTimeout(
      opts.waitMs ? DEFAULT_NAV_TIMEOUT_MS + opts.waitMs : DEFAULT_NAV_TIMEOUT_MS,
    );

    let status: number | undefined;
    try {
      const resp = await page.goto(url, { waitUntil: "networkidle0" });
      status = resp?.status();
    } catch {
      // networkidle0 can time out on sites that long-poll; fall back to a
      // looser wait so we still capture what rendered.
      try {
        const resp = await page.goto(url, { waitUntil: "domcontentloaded" });
        status = resp?.status();
      } catch (e2) {
        await safeClose(browser);
        return { ok: false, status, error: `nav_failed:${errMsg(e2)}` };
      }
    }

    if (opts.waitMs && opts.waitMs > 0) {
      // Best-effort settle after load.
      await delay(Math.min(opts.waitMs, 5_000));
    }

    const out: RenderPageResult = { ok: true, status };

    if (opts.screenshot) {
      try {
        const shot = await page.screenshot({
          type: "png",
          fullPage: opts.fullPage ?? false,
        });
        out.screenshot = toArrayBuffer(shot);
      } catch (e) {
        // Screenshot is optional — record the failure but still return html.
        out.error = `screenshot_failed:${errMsg(e)}`;
      }
    }

    try {
      const content = await page.content();
      out.html = content.length > HTML_CAP ? content.slice(0, HTML_CAP) : content;
    } catch (e) {
      // No HTML and no screenshot ⇒ this tier produced nothing usable.
      if (!out.screenshot) {
        await safeClose(browser);
        return { ok: false, status, error: `content_failed:${errMsg(e)}` };
      }
    }

    await safeClose(browser);
    return out;
  } catch (e) {
    await safeClose(browser);
    return { ok: false, error: `browser_error:${errMsg(e)}` };
  }
}

// ── Per-slide deck rendering ────────────────────────────────────────────────
//
// The brand-book presentation (book/presentation-shell.ts) is a vanilla-JS
// deck: each slide is a `<section>` inside `#stage`, and exactly one carries
// the `.active` class (opacity 1) at a time. The shell reads `data.curated.
// slide_order` to build `order` and toggles `.active` on the Nth `<section>`.
//
// renderDeckSlides drives that deck slide-by-slide WITHOUT depending on a
// global JS slide API: it loads the deck once, then for each section index it
// runs page.evaluate to mirror the shell's render() — toggle `.active` on the
// target section and clear it on the rest — waits for the opacity transition,
// and screenshots the `#stage` element (the 16:9 stage, not the dark surround).
//
// Fails SOFT like renderPage: on ANY failure it returns `{ ok:false, error }`
// and never throws. Partial success is allowed — `slides` carries whatever was
// captured even when some slides failed (their `error` is recorded).

const SLIDE_SETTLE_MS = 350; // opacity transition is 220ms; pad for fonts/img
const DEFAULT_MAX_SLIDES = 60;

/**
 * One deterministically-measured render defect on a slide. Measured in the
 * browser via getBoundingClientRect / scrollWidth / naturalWidth at render time
 * (page.evaluate) — NO LLM. These are MECHANICAL faults (overflow, clipping,
 * empty content, broken images), conservative to avoid false-positives on
 * intentional design. Subjective design quality is NOT measured here (that is
 * the optional TIER-2 vision pass).
 */
export interface SlideDefect {
  /**
   * Defect class:
   *   "overflow-x"   — content scrolls horizontally past the slide frame
   *   "overflow-y"   — content scrolls vertically past the slide frame
   *   "empty"        — visible text is below the near-empty threshold
   *   "clipped"      — a visible element's box sits outside the slide viewport
   *   "broken-image" — an <img> with naturalWidth === 0 (failed to load)
   */
  type: "overflow-x" | "overflow-y" | "empty" | "clipped" | "broken-image";
  /** Human-readable specifics (measured px / selector / counts). */
  detail: string;
}

export interface DeckSlideShot {
  /** 0-based slide index within the deck's slide_order. */
  index: number;
  /** Slide key from data.curated.slide_order (e.g. "cover", "palette"). */
  key: string;
  /** PNG bytes of the stage for this slide. */
  png: ArrayBuffer;
  /**
   * Deterministic mechanical defects measured at render time (empty array when
   * the slide is clean). NO LLM — see SlideDefect.
   */
  defects: SlideDefect[];
}

export interface RenderDeckSlidesResult {
  ok: boolean;
  /** Successfully captured slides (may be a subset on partial failure). */
  slides: DeckSlideShot[];
  /** Total slides the deck declared (before the cap). */
  total?: number;
  /** True when the deck had more slides than the cap and we stopped early. */
  truncated?: boolean;
  /** HTTP status of the deck navigation, when known. */
  status?: number;
  /** Reason rendering produced nothing usable (fail-loud for the caller). */
  error?: string;
}

export interface RenderDeckSlidesOptions {
  /** Cap on slides captured (default 60). Extra slides are dropped + logged. */
  maxSlides?: number;
  /** Settle time (ms) after activating a slide, before screenshot. */
  settleMs?: number;
  /** Stage viewport. Defaults to a 16:9 1280x720 frame so the stage fills it. */
  viewport?: { width: number; height: number };
}

/**
 * Render each slide of a served brand-book deck to its own PNG.
 *
 * @param env  Worker bindings (needs `env.BROWSER`).
 * @param url  Absolute URL of the served deck (.../books/<slug>.html).
 * @param opts maxSlides / settleMs / viewport.
 *
 * Never throws — returns `{ ok:false, error }` on hard failure.
 */
export async function renderDeckSlides(
  env: Bindings,
  url: string,
  opts: RenderDeckSlidesOptions = {},
): Promise<RenderDeckSlidesResult> {
  const browserBinding = env?.BROWSER as Fetcher | undefined;
  if (!browserBinding) {
    return { ok: false, slides: [], error: "browser_binding_missing" };
  }

  let puppeteer: PuppeteerLike;
  try {
    const mod = (await import("@cloudflare/puppeteer")) as unknown as {
      default: PuppeteerLike;
    };
    puppeteer = mod.default;
  } catch (e) {
    return { ok: false, slides: [], error: `browser_unavailable:${errMsg(e)}` };
  }

  const maxSlides = clampInt(opts.maxSlides ?? DEFAULT_MAX_SLIDES, 1, 200);
  const settleMs = clampInt(opts.settleMs ?? SLIDE_SETTLE_MS, 0, 5_000);
  const vp = opts.viewport ?? { width: 1280, height: 720 };

  let browser: PuppeteerBrowser | undefined;
  try {
    browser = await puppeteer.launch(browserBinding);
    const page = await browser.newPage();
    await page.setUserAgent(BROWSER_UA);
    await page.setViewport(vp);
    page.setDefaultNavigationTimeout(DEFAULT_NAV_TIMEOUT_MS);

    let status: number | undefined;
    try {
      const resp = await page.goto(url, { waitUntil: "networkidle0" });
      status = resp?.status();
    } catch {
      try {
        const resp = await page.goto(url, { waitUntil: "domcontentloaded" });
        status = resp?.status();
      } catch (e2) {
        await safeClose(browser);
        return { ok: false, slides: [], status, error: `nav_failed:${errMsg(e2)}` };
      }
    }

    // Let the shell build the deck (innerHTML, fonts) before we inspect it.
    await delay(Math.min(settleMs + 250, 2_000));

    // Read the slide keys the shell rendered. We DON'T trust book-data alone:
    // the shell filters slide_order to keys with a builder, so the authoritative
    // count is the live `#stage section` set.
    let keys: string[];
    try {
      // Runs in the BROWSER context — `doc` is the page's document. We avoid
      // referencing DOM globals by name (the Workers tsconfig has no DOM lib)
      // by reaching through globalThis with a loose type.
      keys = await page.evaluate(() => {
        const doc = (globalThis as { document?: any }).document;
        const stage = doc?.getElementById("stage");
        if (!stage) return [] as string[];
        const sections = Array.from(stage.querySelectorAll("section")) as any[];
        return sections.map((s: any, i: number) => s.getAttribute("data-slide") || `slide-${i}`);
      });
    } catch (e) {
      await safeClose(browser);
      return { ok: false, slides: [], status, error: `slide_probe_failed:${errMsg(e)}` };
    }

    const total = keys.length;
    if (total === 0) {
      await safeClose(browser);
      return { ok: false, slides: [], status, error: "no_slides_found" };
    }

    const truncated = total > maxSlides;
    const capped = truncated ? keys.slice(0, maxSlides) : keys;
    if (truncated) {
      console.warn(
        `[renderDeckSlides] deck ${url} has ${total} slides; capping at ${maxSlides}`,
      );
    }

    const slides: DeckSlideShot[] = [];
    const errors: string[] = [];

    for (let i = 0; i < capped.length; i++) {
      try {
        // Mirror the shell's render(): make the Nth section active, hide the
        // rest. Disabling the opacity transition makes the frame deterministic.
        // Runs in the BROWSER context — DOM reached via globalThis (no DOM lib).
        await page.evaluate((idx: number) => {
          const doc = (globalThis as { document?: any }).document;
          const stage = doc?.getElementById("stage");
          if (!stage) return;
          const sections = Array.from(stage.querySelectorAll("section")) as any[];
          for (let j = 0; j < sections.length; j++) {
            const sec = sections[j];
            const on = j === idx;
            sec.classList.toggle("active", on);
            // Force the active slide fully opaque + interactive immediately so
            // the screenshot doesn't catch a mid-transition frame.
            sec.style.transition = "none";
            sec.style.opacity = on ? "1" : "0";
            sec.style.pointerEvents = on ? "auto" : "none";
          }
        }, i);

        if (settleMs > 0) await delay(settleMs);

        // Measure DETERMINISTIC defects on the now-active slide, in the BROWSER
        // context (page.evaluate already runs per slide, so this is nearly free).
        // Conservative thresholds avoid false-positives on intentional design.
        // DOM reached via globalThis (no DOM lib in the Workers tsconfig).
        const defects = await measureSlideDefects(page, i);

        // Screenshot the ACTIVE slide section (each .slide is a 1280×720 card),
        // NOT the whole #stage. book-deck.css (deck-v2) STACKS sections vertically,
        // so #stage is the full-height composite of ALL slides — screenshotting it
        // yields one giant 1280×N image that breaks per-slide vision review
        // (wb-ax6f). Clipping to the active section gives ONE slide; it also works
        // for old absolute-overlay decks (the active section fills the 16:9 card).
        // Fall back to #stage, then the viewport.
        const slideEl = (await page.$("#stage section.active")) ?? (await page.$("#stage"));
        const shot = slideEl
          ? await slideEl.screenshot({ type: "png" })
          : await page.screenshot({ type: "png", fullPage: false });

        slides.push({ index: i, key: capped[i] ?? `slide-${i}`, png: toArrayBuffer(shot), defects });
      } catch (e) {
        errors.push(`${i}:${errMsg(e)}`);
      }
    }

    await safeClose(browser);

    if (slides.length === 0) {
      return {
        ok: false,
        slides: [],
        status,
        total,
        truncated,
        error: errors.length ? `all_slides_failed:${errors.join(",")}` : "no_slides_captured",
      };
    }

    return {
      ok: true,
      slides,
      total,
      truncated,
      status,
      error: errors.length ? `partial:${errors.join(",")}` : undefined,
    };
  } catch (e) {
    await safeClose(browser);
    return { ok: false, slides: [], error: `browser_error:${errMsg(e)}` };
  }
}

// ── Deterministic per-slide defect measurement ──────────────────────────────
//
// Runs ENTIRELY in the browser context (page.evaluate) against the active slide
// section. Returns mechanical faults only; conservative thresholds keep it from
// firing on intentional design (e.g. a few px of sub-pixel overflow, a splash
// slide that is intentionally text-light, a single decorative element bleeding
// to the edge). NO LLM. See SlideDefect for the defect classes.
async function measureSlideDefects(
  page: PuppeteerPage,
  idx: number,
): Promise<SlideDefect[]> {
  try {
    return await page.evaluate((i: number) => {
      const doc = (globalThis as { document?: any }).document;
      const stage = doc?.getElementById("stage");
      if (!stage) return [] as SlideDefect[];
      const sections = Array.from(stage.querySelectorAll("section")) as any[];
      const sec = sections[i];
      if (!sec) return [] as SlideDefect[];

      const out: SlideDefect[] = [];
      const frame = sec.getBoundingClientRect();
      // Tolerances (px). Generous enough that sub-pixel rounding and a hair of
      // decorative bleed do NOT register as defects.
      const OVERFLOW_TOL = 8;
      const CLIP_TOL = 12;
      const MIN_TEXT = 12; // visible chars below this ⇒ near-empty content slide

      // 1. Horizontal overflow — content wider than its frame can show.
      const sw = sec.scrollWidth || 0;
      const cw = sec.clientWidth || 0;
      if (sw > cw + OVERFLOW_TOL) {
        out.push({ type: "overflow-x", detail: `scrollWidth ${sw} > clientWidth ${cw}` });
      }

      // 2. Vertical overflow — content taller than the slide frame.
      const sh = sec.scrollHeight || 0;
      const ch = sec.clientHeight || 0;
      if (sh > ch + OVERFLOW_TOL) {
        out.push({ type: "overflow-y", detail: `scrollHeight ${sh} > clientHeight ${ch}` });
      }

      // 3. Empty / near-empty slide — visible text below the threshold. We only
      // flag when there is ALSO no <img> in the slide, so an intentional
      // image-only / full-bleed slide is not falsely flagged as empty.
      const text = (sec.innerText || sec.textContent || "").replace(/\s+/g, " ").trim();
      const imgs = Array.from(sec.querySelectorAll("img")) as any[];
      if (text.length < MIN_TEXT && imgs.length === 0) {
        out.push({ type: "empty", detail: `visible text ${text.length} chars, no images` });
      }

      // 4. Broken images — failed loads (naturalWidth 0). Skip imgs the layout
      // hid (display:none / 0-size) so lazy/placeholder imgs don't false-fire.
      let broken = 0;
      let brokenSrc = "";
      for (const img of imgs) {
        const r = img.getBoundingClientRect();
        const shown = r.width > 1 && r.height > 1;
        if (shown && img.complete && (img.naturalWidth || 0) === 0) {
          broken++;
          if (!brokenSrc) brokenSrc = String(img.currentSrc || img.src || "").slice(0, 120);
        }
      }
      if (broken > 0) {
        out.push({ type: "broken-image", detail: `${broken} broken img (naturalWidth 0), e.g. ${brokenSrc}` });
      }

      // 5. Clipped / off-canvas elements — a VISIBLE descendant whose box sits
      // substantially outside the slide frame. Conservative: only direct-ish
      // content elements with real size, and only when clearly past the edge.
      let clipped = 0;
      let clipSel = "";
      const candidates = Array.from(sec.querySelectorAll("*")) as any[];
      for (const el of candidates) {
        const style = (globalThis as { getComputedStyle?: any }).getComputedStyle?.(el);
        if (style && (style.visibility === "hidden" || style.display === "none")) continue;
        if (style && parseFloat(style.opacity || "1") === 0) continue;
        const r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) continue;
        const offLeft = frame.left - r.right;
        const offRight = r.left - frame.right;
        const offTop = frame.top - r.bottom;
        const offBottom = r.top - frame.bottom;
        const maxOff = Math.max(offLeft, offRight, offTop, offBottom);
        if (maxOff > CLIP_TOL) {
          clipped++;
          if (!clipSel) {
            const tag = String(el.tagName || "?").toLowerCase();
            const cls = String(el.className || "").split(/\s+/).filter(Boolean).slice(0, 2).join(".");
            clipSel = cls ? `${tag}.${cls}` : tag;
          }
        }
      }
      if (clipped > 0) {
        out.push({ type: "clipped", detail: `${clipped} element(s) off-frame, e.g. ${clipSel}` });
      }

      return out;
    }, idx);
  } catch (e) {
    // Measurement is best-effort — never let it sink the render. No defects on
    // probe failure (the screenshot path is what callers truly depend on).
    console.warn(`[renderDeckSlides] defect probe failed for slide ${idx}: ${errMsg(e)}`);
    return [];
  }
}

function clampInt(n: number, lo: number, hi: number): number {
  if (!Number.isFinite(n)) return lo;
  return Math.max(lo, Math.min(hi, Math.trunc(n)));
}

// ── helpers ──────────────────────────────────────────────────────────────────

function errMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

async function safeClose(browser: PuppeteerBrowser | undefined): Promise<void> {
  if (!browser) return;
  try {
    await browser.close();
  } catch {
    /* ignore */
  }
}

function toArrayBuffer(u8: Uint8Array): ArrayBuffer {
  // Copy into a standalone ArrayBuffer (the view may be over a larger buffer).
  const copy = new Uint8Array(u8.byteLength);
  copy.set(u8);
  return copy.buffer;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
