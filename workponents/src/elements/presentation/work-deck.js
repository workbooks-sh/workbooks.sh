// <work-deck> — THE presentation reinvention: a deck IS a wavelet timeline, and the
// slides ARE its discrete keyframe bands. Because of that single idea the domain
// shares the wavelet render-core with `video` and "export to video" is free — the
// deck just folds its <work-slide> children into a <gm-doc> timeline (one
// <gm-scene> per band, each band's `hold` = its duration) and hands it to the
// SAME path <work-video> uses (in-guest encode when the Host has `wavelet`,
// degrading to a portable self-contained .html otherwise). The deck never
// reimplements rendering or encoding.
//
// Composition-as-source: the ordered set of slotted <work-slide> children IS the
// deck. The deck owns the playhead (which band is live) and nothing else — slides
// keep their own content in the light DOM, so a live workponent on a slide (a
// <work-chart>, a <work-video>) is a first-class citizen, not a screenshot.
//
// Live navigation:
//   ← / PageUp / k        previous slide
//   → / Space / PageDown / j   next slide
//   Home / End            first / last
//   f                     toggle fullscreen
//   p                     toggle presenter notes (slides may carry [slot=notes])
//   Esc                   exit fullscreen
// Click the left/right thirds of the stage to go back/forward.
//
// Attributes:
//   index        current slide (0-based, reflected) — set it to jump.
//   hold         default per-band duration for video export (e.g. "4s").
//   transition   default enter transition applied to slides that don't set one.
//   aspect       stage aspect ratio (e.g. "16:9" | "4:3" | "1:1"). default 16:9.
//   resolution   export pixel size (e.g. "1920x1080"). default 1920x1080.
//   variant      framed | bare   (visual shell)
//   controls     show the bottom chrome (progress + prev/next + counter + export)
//   loop         wrap End→Home / Home→End on navigation
//
// Properties / methods:
//   .index .count .current        playhead state
//   .next() .prev() .go(i) .first() .last()
//   .toComposition()              the <gm-doc> timeline markup (deck → wavelet)
//   .export(format|{format})      "video"/"mp4"/"webm" → wavelet encode (Host) or
//                                 portable .html · "pptx" → a .pptx Blob (PptxGenJS).
//                                 slides→video is the differentiator no Office tool has.
//   .import(arrayBuffer|src)      a .pptx → importPptx → render its slides as
//                                 <work-slide> children (composition-as-source).
//
// Events (all bubbling):
//   work-slide-change { index, total, slide }   on every band change
//   work-export-start { format }                 export began
//   work-export      { format, … }               export finished (video path detail)
//   work-export-error { error }                  export failed
//   work-deck-export { format, ok }              export terminal (video + pptx) — the
//                                                format-agnostic signal the directive asks for
//   work-deck-import { ok, slides?, error? }     a .pptx import completed

import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

const VARIANTS = defineVariants({
  variant: { options: ["framed", "bare"], default: "framed" },
});

// Default location of the shipped wavelet runtime (mirrors <work-video>). Used only
// to inline the runtime into a portable export when no Host encode is available.
const DEFAULT_RUNTIME =
  (typeof window !== "undefined" && window.__WB_WAVELET_RUNTIME__) ||
  "/wavelet/wavelet-runtime.js";

export class WorkDeck extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "index", "aspect", "controls", "loop", "hold", "transition", "resolution"];

  static properties = {
    ...WbElement.properties,
    // internal reactive state that drives the Lit template
    _count: { state: true },
    _exporting: { state: true },
  };

  static styles = css`
    :host {
      display: block;
      color: var(--work-fg);
      font-family: var(--work-font);
      --work-deck-enter: .42s;
    }

    .shell {
      display: flex; flex-direction: column;
      background: var(--work-surface);
      border: 1.5px solid var(--work-border);
      border-radius: var(--work-radius-lg);
      overflow: hidden;
      box-shadow: var(--work-shadow);
    }
    :host([variant="bare"]) .shell { background: transparent; border-color: transparent; box-shadow: none; border-radius: 0; }
    :host(:fullscreen) .shell, :host(.is-fs) .shell { height: 100vh; border: none; border-radius: 0; }

    /* the stage holds exactly one absolutely-positioned <work-slide> at a time */
    .stage {
      position: relative;
      aspect-ratio: var(--_aspect, 16 / 9);
      background: var(--work-bg);
      overflow: hidden;
    }
    :host(.is-fs) .stage { flex: 1 1 auto; aspect-ratio: auto; }

    /* the slotted slides live here; only [active] paints (slide owns that) */
    ::slotted(work-slide) { position: absolute; inset: 0; }

    /* edge click zones for click-to-advance */
    .zone { position: absolute; top: 0; bottom: 0; width: 22%; z-index: 4; cursor: pointer; }
    .zone.prev { left: 0; }
    .zone.next { right: 0; cursor: pointer; }
    .zone:hover { background: linear-gradient(to var(--_dir, right),
      color-mix(in srgb, var(--work-fg) 6%, transparent), transparent); }
    .zone.prev { --_dir: left; }

    /* presenter notes overlay */
    .notes {
      position: absolute; left: 0; right: 0; bottom: 0; z-index: 6;
      max-height: 38%; overflow: auto;
      padding: var(--work-space-3) var(--work-space-4);
      background: color-mix(in srgb, var(--work-surface) 86%, transparent);
      backdrop-filter: blur(8px);
      border-top: 1.5px solid var(--work-border);
      color: var(--work-fg-muted); font-size: var(--work-text-sm); line-height: 1.5;
      display: none;
    }
    :host(.show-notes) .notes { display: block; }
    .notes b { color: var(--work-fg); font-weight: 600; }

    /* progress hairline */
    .progress { position: relative; height: 3px; background: var(--work-surface-soft); z-index: 5; }
    .progress > i { position: absolute; inset: 0 auto 0 0; background: var(--work-brand);
      width: var(--_pct, 0%); transition: width var(--work-dur) var(--work-ease); }

    /* bottom chrome — tokens only */
    .chrome {
      display: flex; align-items: center; gap: var(--work-space-2);
      padding: var(--work-space-2) var(--work-space-3);
      border-top: 1.5px solid var(--work-border);
      background: var(--work-surface);
    }
    :host([variant="bare"]) .chrome { background: transparent; }
    .chrome button {
      appearance: none; cursor: pointer;
      height: 30px; min-width: 30px; padding: 0 var(--work-space-2);
      display: inline-flex; align-items: center; justify-content: center; gap: var(--work-space-1);
      border: 1.5px solid var(--work-border-strong);
      border-radius: var(--work-radius-sm);
      background: var(--work-surface); color: var(--work-fg);
      font-family: var(--work-font); font-size: var(--work-text-sm); font-weight: 600; line-height: 1;
      transition: border-color var(--work-dur) var(--work-ease), background var(--work-dur) var(--work-ease);
    }
    .chrome button:hover:not(:disabled) { border-color: var(--work-brand); background: var(--work-brand-soft); }
    .chrome button:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--work-ring); }
    .chrome button:disabled { opacity: .45; cursor: default; }
    .counter { font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg-muted); white-space: nowrap; }

    /* dot rail — one dot per band, the wavelet "keyframe markers" */
    .dots { display: flex; gap: var(--work-space-6px); flex: 1 1 auto; align-items: center; justify-content: center; flex-wrap: wrap; }
    .dot { width: 8px; height: 8px; border-radius: var(--work-radius-pill);
      background: var(--work-border-strong); border: none; padding: 0; cursor: pointer;
      transition: background var(--work-dur) var(--work-ease), transform var(--work-dur) var(--work-ease); }
    .dot:hover { transform: scale(1.25); }
    .dot[aria-current="true"] { background: var(--work-brand); width: 20px; }
    .spacer { flex: 1 1 auto; }
    .export { margin-left: auto; }
    .export.busy { opacity: .6; pointer-events: none; }

    .empty { position: absolute; inset: 0; display: grid; place-items: center;
      color: var(--work-fg-muted); font-family: var(--work-font-mono); font-size: var(--work-text-sm); }
  `;

  constructor() {
    super();
    this._slides = [];
    this._index = 0;
    this._count = 0;
    this._exporting = false;
    this._onKey = this._onKey.bind(this);
    this._onFsChange = () => this._syncFs();
  }

  connectedCallback() {
    super.connectedCallback();
    this._collect();
    // re-collect if slides are added/removed/reordered (composition-as-source)
    this._mo = new MutationObserver(() => this._collect());
    this._mo.observe(this, { childList: true });
    this.tabIndex = this.tabIndex < 0 ? 0 : this.tabIndex; // focusable for keys
    this.addEventListener("keydown", this._onKey);
    document.addEventListener("fullscreenchange", this._onFsChange);
    this._applyAspect();
    this._index = clampIndex(this._intAttr("index", 0), this._slides.length);
    this._reflectSlides(false);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._mo?.disconnect();
    this.removeEventListener("keydown", this._onKey);
    document.removeEventListener("fullscreenchange", this._onFsChange);
  }

  // Lit-reactive: when `index`/`aspect` change as attributes, react.
  updated(changed) {
    if (changed.has("index")) {
      const i = clampIndex(this._intAttr("index", 0), this._slides.length);
      if (i !== this._index) { this._index = i; this._reflectSlides(true); }
    }
    if (changed.has("aspect")) this._applyAspect();
  }

  // ---- slides + playhead --------------------------------------------------

  _collect() {
    const prev = this._slides.length;
    this._slides = Array.from(this.querySelectorAll(":scope > work-slide"));
    // honor a per-deck default transition on slides that didn't declare one
    const tDefault = this.attr("transition");
    if (tDefault) for (const s of this._slides) {
      if (!s.hasAttribute("transition")) s.setAttribute("transition", tDefault);
    }
    this._index = clampIndex(this._index, this._slides.length);
    this._count = this._slides.length;       // drives the Lit template (dots/chrome)
    this._reflectSlides(prev !== this._slides.length ? false : false);
    this.requestUpdate();
  }

  get count() { return this._slides.length; }
  get index() { return this._index; }
  set index(i) { this.go(i); }
  get current() { return this._slides[this._index] || null; }

  go(i) {
    const n = this._slides.length;
    if (!n) return;
    let next = i;
    if (this.boolAttr("loop")) next = ((i % n) + n) % n;
    else next = Math.max(0, Math.min(n - 1, i));
    if (next === this._index) return;
    this._index = next;
    this._reflectSlides(true);
  }
  next() { this.go(this._index + 1); }
  prev() { this.go(this._index - 1); }
  first() { this.go(0); }
  last() { this.go(this._slides.length - 1); }

  /** Reflect playhead onto slides + request a Lit re-render; emit on move. */
  _reflectSlides(emit) {
    this.setAttribute("index", String(this._index));
    this._slides.forEach((s, i) => {
      s.toggleAttribute("active", i === this._index);
      s.toggleAttribute("prev", i === this._index - 1);
      s.toggleAttribute("next", i === this._index + 1);
    });
    this.requestUpdate();
    if (emit) {
      this.dispatchEvent(new CustomEvent("work-slide-change", {
        bubbles: true,
        detail: { index: this._index, total: this._slides.length, slide: this.current },
      }));
    }
  }

  // ---- keyboard + click + fullscreen --------------------------------------

  _onKey(e) {
    if (e.defaultPrevented) return;
    switch (e.key) {
      case "ArrowRight": case "PageDown": case " ": case "j": this.next(); break;
      case "ArrowLeft":  case "PageUp":   case "k": this.prev(); break;
      case "Home": this.first(); break;
      case "End":  this.last();  break;
      case "f": this.toggleFullscreen(); break;
      case "p": this.classList.toggle("show-notes"); this.requestUpdate(); break;
      case "Escape": if (document.fullscreenElement) document.exitFullscreen(); return;
      default: return;
    }
    e.preventDefault();
  }

  toggleFullscreen() {
    if (document.fullscreenElement) document.exitFullscreen();
    else this.requestFullscreen?.().catch(() => {});
  }
  _syncFs() { this.classList.toggle("is-fs", document.fullscreenElement === this); }

  // ---- deck → wavelet timeline (the shared-engine payoff) ------------------

  /** Fold the slides into a <gm-doc> timeline: one <gm-scene> keyframe band per
   *  slide, sequenced by each band's `hold`. The captured HTML is the slide's
   *  rendered content + its enter animation, so preview ≡ the exported video. */
  toComposition({ fps = 30 } = {}) {
    const res = parseRes(this.attr("resolution", "1920x1080"));
    const aspect = this.attr("aspect", "16:9");
    const holdDefault = this.attr("hold", "4s");
    let t = 0; // seconds cursor
    const scenes = this._slides.map((slide, i) => {
      const dur = slide.hold || holdDefault;
      const secs = durToSeconds(dur, fps) || 4;
      const start = `${round3(t)}s`;
      t += secs;
      const html = captureSlide(slide, res, i);
      return `      <gm-scene id="slide-${i}" start="${start}" duration="${round3(secs)}s">
        <template>${html}</template>
      </gm-scene>`;
    }).join("\n");
    return `<gm-doc fps="${fps}" resolution="${res.w}x${res.h}" aspect="${aspect}">
  <gm-timeline id="deck" duration="${round3(t)}s">
    <gm-track id="slides" z="0">
${scenes}
    </gm-track>
  </gm-timeline>
</gm-doc>`;
  }

  /** Export the deck. Routes by format:
   *   "video" | "mp4" | "webm"  → the wavelet path (the slides→video differentiator):
   *       in-guest encode via the Dock when the Host has `wavelet`, else a portable,
   *       self-contained .html (the deck AS the wavelet composition the render-core
   *       consumes). This is the existing free win — no Office tool does it.
   *   "pptx"                    → a real .pptx Blob (PptxGenJS, floor-JS, lazy CDN).
   *  Accepts a format string or an options object. Emits `work-deck-export {format, ok}`
   *  for both lanes; the video lane also emits the richer work-export(-start/-error). */
  async export(opts = {}) {
    const o = typeof opts === "string" ? { format: opts } : opts;
    const format = o.format || "mp4";
    if (this._exporting || !this._slides.length) return;
    if (format === "pptx") return this._exportPptx();
    return this._exportVideo({ format, fps: o.fps || 30 });
  }

  /** The wavelet video lane (the original export() — slides folded into a timeline). */
  async _exportVideo({ format = "mp4", fps = 30 } = {}) {
    this._exporting = true;
    this.dispatchEvent(new CustomEvent("work-export-start", { bubbles: true, detail: { format } }));
    const composition = this.toComposition({ fps });
    try {
      let out;
      if (this.host.available("wavelet")) {
        out = await this.host.request("/wavelet/encode", { body: { composition, format, fps } });
        this.dispatchEvent(new CustomEvent("work-export", { bubbles: true, detail: { ...out, format } }));
      } else {
        const file = await this._downloadPortable(composition);
        out = { file, format: "html" };
        this.dispatchEvent(new CustomEvent("work-export", { bubbles: true, detail: out }));
      }
      this.dispatchEvent(new CustomEvent("work-deck-export", { bubbles: true, composed: true, detail: { format, ok: true } }));
      return out;
    } catch (e) {
      this.dispatchEvent(new CustomEvent("work-export-error", { bubbles: true, detail: { error: String(e) } }));
      this.dispatchEvent(new CustomEvent("work-deck-export", { bubbles: true, composed: true, detail: { format, ok: false, error: String(e.message || e) } }));
      throw e;
    } finally {
      this._exporting = false;
    }
  }

  /** The pptx lane — map the deck's <work-slide> bands → a .pptx Blob. */
  async _exportPptx() {
    this._exporting = true;
    this.dispatchEvent(new CustomEvent("work-export-start", { bubbles: true, detail: { format: "pptx" } }));
    try {
      const { exportPptx } = await import("./pptx-io.js");
      const blob = await exportPptx(this);
      this.dispatchEvent(new CustomEvent("work-deck-export", { bubbles: true, composed: true, detail: { format: "pptx", ok: true } }));
      return blob;
    } catch (e) {
      this.dispatchEvent(new CustomEvent("work-deck-export", { bubbles: true, composed: true, detail: { format: "pptx", ok: false, error: String(e.message || e) } }));
      this.dispatchEvent(new CustomEvent("work-export-error", { bubbles: true, detail: { error: String(e) } }));
      return null;
    } finally {
      this._exporting = false;
    }
  }

  /** Import a .pptx → render its slides as <work-slide> children (composition-as-
   *  source). Accepts an ArrayBuffer/Uint8Array, or a URL string to fetch. Replaces
   *  the deck's current slides with the parsed ones. Emits `work-deck-import`. */
  async import(input) {
    try {
      let buf = input;
      if (typeof input === "string") {
        const res = await fetch(input);
        if (!res.ok) throw new Error(`${res.status} ${input}`);
        buf = await res.arrayBuffer();
      }
      const { importPptx } = await import("./pptx-io.js");
      const source = await importPptx(buf);
      // the emitted source is a full <work-deck>…</work-deck>; adopt only its slides
      // (this deck stays the host, keeping its own controls/aspect/theme).
      const tpl = document.createElement("template");
      tpl.innerHTML = source.replace(/^<!--[\s\S]*?-->\s*/, "");
      const imported = tpl.content.querySelector("work-deck");
      const slides = imported ? Array.from(imported.querySelectorAll(":scope > work-slide")) : [];
      // swap children
      for (const s of Array.from(this.querySelectorAll(":scope > work-slide"))) s.remove();
      for (const s of slides) this.appendChild(document.importNode(s, true));
      this._index = 0;
      this._collect();
      this._reflectSlides(false);
      this.dispatchEvent(new CustomEvent("work-deck-import", { bubbles: true, composed: true, detail: { ok: true, slides: slides.length } }));
      return slides.length;
    } catch (e) {
      this.dispatchEvent(new CustomEvent("work-deck-import", { bubbles: true, composed: true, detail: { ok: false, error: String(e.message || e) } }));
      return 0;
    }
  }

  /** Inline the wavelet runtime so the downloaded deck.html plays standalone. */
  async _downloadPortable(composition) {
    const runtimeSrc = (typeof window !== "undefined" && window.__WB_WAVELET_RUNTIME__) || DEFAULT_RUNTIME;
    let runtime = "";
    try {
      const res = await fetch(new URL(runtimeSrc, document.baseURI).href);
      if (res.ok) runtime = await res.text();
    } catch { /* external runtime still works */ }
    const doc =
      `<!doctype html><html><head><meta charset="utf-8">` +
      (runtime ? `<script type="module">${runtime}<\/script>` : "") +
      `</head><body style="margin:0;background:#000">${composition}</body></html>`;
    const blob = new Blob([doc], { type: "text/html" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = "deck.html";
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    return "deck.html";
  }

  // ---- render -------------------------------------------------------------

  _applyAspect() {
    const a = this.attr("aspect", "16:9");
    const m = String(a).match(/^(\d+(?:\.\d+)?)[:x/](\d+(?:\.\d+)?)$/);
    this.style.setProperty("--_aspect", m ? `${m[1]} / ${m[2]}` : "16 / 9");
  }
  _intAttr(name, d) { const v = parseInt(this.attr(name, ""), 10); return Number.isFinite(v) ? v : d; }

  _notesHtml() {
    const slide = this.current;
    const note = slide ? slide.querySelector('[slot="notes"]') : null;
    const head = `Notes · ${this._index + 1}/${this._slides.length}`;
    return note
      ? html`<b>${head}</b><br>${unsafeNotes(note.innerHTML)}`
      : html`<b>${head}</b><br><span style="opacity:.6">no notes for this slide</span>`;
  }

  render() {
    const controls = this.boolAttr("controls");
    const n = this._count;
    const i = this._index;
    const loop = this.boolAttr("loop");
    const pct = n > 1 ? `${(i / (n - 1)) * 100}%` : (n ? "100%" : "0%");
    const counter = n ? `${i + 1} / ${n}` : "0 / 0";
    const dots = Array.from({ length: n }, (_, k) => html`
      <button class="dot" part="dot" data-i=${k}
        aria-label=${`Go to slide ${k + 1}`}
        aria-current=${String(k === i)}
        @click=${() => this.go(k)}></button>`);

    return html`
      <div class="shell">
        <div class="stage" part="stage">
          <slot></slot>
          ${n ? html`
            <div class="zone prev" aria-hidden="true" @click=${() => this.prev()}></div>
            <div class="zone next" aria-hidden="true" @click=${() => this.next()}></div>
          ` : html`<div class="empty">No &lt;work-slide&gt; children.</div>`}
          <div class="notes" part="notes">${this._notesHtml()}</div>
        </div>
        <div class="progress" part="progress"><i style=${`--_pct:${pct}`}></i></div>
        ${controls ? html`
          <div class="chrome" part="chrome">
            <button class="btn-prev" aria-label="Previous slide"
              ?disabled=${!loop && i <= 0} @click=${() => this.prev()}>‹</button>
            <span class="counter">${counter}</span>
            <div class="dots" part="dots">${dots}</div>
            <button class="btn-next" aria-label="Next slide"
              ?disabled=${!loop && i >= n - 1} @click=${() => this.next()}>›</button>
            <button class="btn-fs" aria-label="Fullscreen" title="Fullscreen (f)"
              @click=${() => this.toggleFullscreen()}>⤢</button>
            <button class=${"export" + (this._exporting ? " busy" : "")}
              title="Export to video (in-guest encode, or portable .html)"
              @click=${() => { void this.export(); }}>${this._exporting ? "…" : "Export ↓"}</button>
          </div>` : ""}
      </div>`;
  }
}

// ---- helpers --------------------------------------------------------------

function clampIndex(i, n) { return n ? Math.max(0, Math.min(n - 1, i || 0)) : 0; }
function round3(n) { return Math.round(n * 1000) / 1000; }
function parseRes(s) {
  const m = String(s).match(/^(\d+)x(\d+)$/);
  return m ? { w: Number(m[1]), h: Number(m[2]) } : { w: 1920, h: 1080 };
}
function durToSeconds(raw, fps) {
  const v = String(raw).trim();
  if (v.endsWith("f")) { const f = parseInt(v.slice(0, -1), 10); return Number.isFinite(f) ? f / fps : 0; }
  if (v.endsWith("s")) { const s = parseFloat(v.slice(0, -1)); return Number.isFinite(s) ? s : 0; }
  const n = parseFloat(v); return Number.isFinite(n) ? n : 0;
}

// Presenter notes are AUTHOR-supplied light-DOM markup we want to render as-is in
// the overlay. Lazily import Lit's unsafeHTML so the no-build module graph stays
// flat; until it resolves we fall back to the escaped text.
let _unsafeHTML = null;
import("lit/directives/unsafe-html.js").then((m) => { _unsafeHTML = m.unsafeHTML; });
function unsafeNotes(htmlStr) {
  return _unsafeHTML ? _unsafeHTML(htmlStr) : htmlStr;
}

// Capture a slide's rendered band as a self-contained scene for the wavelet
// timeline. We snapshot the LIGHT-DOM content (the author's source — preview ≡
// render) and wrap it in the deck's themed band layout, so the exported video is
// what the deck shows. Live workponents on a slide serialize to their current
// markup; an in-guest render-core re-mounts them frame-accurately.
function captureSlide(slide, res, i) {
  const band = slide.getAttribute("band") || "content";
  const align = slide.getAttribute("align") || "center";
  // Pull the slotted content (skip presenter notes — they don't render on video).
  const parts = Array.from(slide.children)
    .filter((c) => c.getAttribute("slot") !== "notes")
    .map((c) => c.outerHTML)
    .join("\n");
  // Resolve the live theme tokens onto the scene root so the video matches the
  // on-screen theme (the scene renders in a bare <gm-doc>, outside our cascade).
  const cs = getComputedStyle(slide);
  const tok = (name, fb) => (cs.getPropertyValue(name) || fb).trim();
  const bg = tok("--work-bg", "#0a0d13");
  const fg = tok("--work-fg", "#e9edf4");
  const font = tok("--work-font", "system-ui, sans-serif");
  const justify = align === "start" ? "center" : align === "end" ? "flex-end" : "center";
  const items = align === "start" ? "flex-start" : align === "end" ? "flex-end" : "center";
  const text = align === "center" ? "center" : align === "end" ? "right" : "left";
  return `<style>
    .deck-band-${i} { position:absolute; inset:0; display:flex; flex-direction:column;
      gap:16px; padding:clamp(28px,6vw,80px); box-sizing:border-box;
      background:${bg}; color:${fg}; font-family:${font};
      align-items:${items}; justify-content:${justify}; text-align:${text};
      animation: db${i} .5s cubic-bezier(.2,.7,.2,1) both; }
    .deck-band-${i} h1 { font-size:clamp(40px,7vw,88px); margin:0; line-height:1.04; letter-spacing:-.02em; }
    .deck-band-${i} h2 { font-size:clamp(26px,4.5vw,48px); margin:0; line-height:1.1; }
    .deck-band-${i} p  { margin:0; line-height:1.5; opacity:.78; max-width:64ch; }
    .deck-band-${i} > * { max-width:min(100%,1100px); }
    @keyframes db${i} { from { opacity:0; transform:translateY(24px); } to { opacity:1; transform:none; } }
  </style>
  <div class="deck-band-${i}" data-band="${band}">${parts}</div>`;
}

define("work-deck", WorkDeck);
