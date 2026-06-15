// <wb-deck> — THE presentation reinvention: a deck IS a wavelet timeline, and the
// slides ARE its discrete keyframe bands. Because of that single idea the domain
// shares the wavelet render-core with `video` and "export to video" is free — the
// deck just folds its <wb-slide> children into a <gm-doc> timeline (one
// <gm-scene> per band, each band's `hold` = its duration) and hands it to the
// SAME path <wb-video> uses (in-guest encode when the Host has `wavelet`,
// degrading to a portable self-contained .html otherwise). The deck never
// reimplements rendering or encoding.
//
// Composition-as-source: the ordered set of slotted <wb-slide> children IS the
// deck. The deck owns the playhead (which band is live) and nothing else — slides
// keep their own content in the light DOM, so a live workponent on a slide (a
// <wb-chart>, a <wb-video>) is a first-class citizen, not a screenshot.
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
//   .export({format})             in-guest encode via Host, else portable .html
//
// Events (all bubbling):
//   wb-slide-change { index, total, slide }   on every band change
//   wb-export-start                            export began
//   wb-export      { format, … }               export finished
//   wb-export-error { error }                  export failed

import { WbElement, define } from "../../core/element.js";
import { defineVariants, variantAttrs, resolveVariant } from "../../core/variants.js";

const VARIANTS = defineVariants({
  variant: { options: ["framed", "bare"], default: "framed" },
});

// Default location of the shipped wavelet runtime (mirrors <wb-video>). Used only
// to inline the runtime into a portable export when no Host encode is available.
const DEFAULT_RUNTIME =
  (typeof window !== "undefined" && window.__WB_WAVELET_RUNTIME__) ||
  "/wavelet/wavelet-runtime.js";

export class WbDeck extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "index", "aspect", "controls", "loop", "hold", "transition", "resolution"];

  static styles = `
    :host {
      display: block;
      color: var(--wb-fg);
      font-family: var(--wb-font);
      --wb-deck-enter: .42s;
    }

    .shell {
      display: flex; flex-direction: column;
      background: var(--wb-surface);
      border: 1.5px solid var(--wb-border);
      border-radius: var(--wb-radius-lg);
      overflow: hidden;
      box-shadow: var(--wb-shadow);
    }
    :host([variant="bare"]) .shell { background: transparent; border-color: transparent; box-shadow: none; border-radius: 0; }
    :host(:fullscreen) .shell, :host(.is-fs) .shell { height: 100vh; border: none; border-radius: 0; }

    /* the stage holds exactly one absolutely-positioned <wb-slide> at a time */
    .stage {
      position: relative;
      aspect-ratio: var(--_aspect, 16 / 9);
      background: var(--wb-bg);
      overflow: hidden;
    }
    :host(.is-fs) .stage { flex: 1 1 auto; aspect-ratio: auto; }

    /* the slotted slides live here; only [active] paints (slide owns that) */
    ::slotted(wb-slide) { position: absolute; inset: 0; }

    /* edge click zones for click-to-advance */
    .zone { position: absolute; top: 0; bottom: 0; width: 22%; z-index: 4; cursor: pointer; }
    .zone.prev { left: 0; }
    .zone.next { right: 0; cursor: pointer; }
    .zone:hover { background: linear-gradient(to var(--_dir, right),
      color-mix(in srgb, var(--wb-fg) 6%, transparent), transparent); }
    .zone.prev { --_dir: left; }

    /* presenter notes overlay */
    .notes {
      position: absolute; left: 0; right: 0; bottom: 0; z-index: 6;
      max-height: 38%; overflow: auto;
      padding: var(--wb-space-3) var(--wb-space-4);
      background: color-mix(in srgb, var(--wb-surface) 86%, transparent);
      backdrop-filter: blur(8px);
      border-top: 1.5px solid var(--wb-border);
      color: var(--wb-fg-muted); font-size: var(--wb-text-sm); line-height: 1.5;
      display: none;
    }
    :host(.show-notes) .notes { display: block; }
    .notes b { color: var(--wb-fg); font-weight: 600; }

    /* progress hairline */
    .progress { position: relative; height: 3px; background: var(--wb-surface-soft); z-index: 5; }
    .progress > i { position: absolute; inset: 0 auto 0 0; background: var(--wb-brand);
      width: var(--_pct, 0%); transition: width var(--wb-dur) var(--wb-ease); }

    /* bottom chrome — tokens only */
    .chrome {
      display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3);
      border-top: 1.5px solid var(--wb-border);
      background: var(--wb-surface);
    }
    :host([variant="bare"]) .chrome { background: transparent; }
    .chrome button {
      appearance: none; cursor: pointer;
      height: 30px; min-width: 30px; padding: 0 var(--wb-space-2);
      display: inline-flex; align-items: center; justify-content: center; gap: var(--wb-space-1);
      border: 1.5px solid var(--wb-border-strong);
      border-radius: var(--wb-radius-sm);
      background: var(--wb-surface); color: var(--wb-fg);
      font-family: var(--wb-font); font-size: var(--wb-text-sm); font-weight: 600; line-height: 1;
      transition: border-color var(--wb-dur) var(--wb-ease), background var(--wb-dur) var(--wb-ease);
    }
    .chrome button:hover:not(:disabled) { border-color: var(--wb-brand); background: var(--wb-brand-soft); }
    .chrome button:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    .chrome button:disabled { opacity: .45; cursor: default; }
    .counter { font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); color: var(--wb-fg-muted); white-space: nowrap; }

    /* dot rail — one dot per band, the wavelet "keyframe markers" */
    .dots { display: flex; gap: 6px; flex: 1 1 auto; align-items: center; justify-content: center; flex-wrap: wrap; }
    .dot { width: 8px; height: 8px; border-radius: var(--wb-radius-pill);
      background: var(--wb-border-strong); border: none; padding: 0; cursor: pointer;
      transition: background var(--wb-dur) var(--wb-ease), transform var(--wb-dur) var(--wb-ease); }
    .dot:hover { transform: scale(1.25); }
    .dot[aria-current="true"] { background: var(--wb-brand); width: 20px; }
    .spacer { flex: 1 1 auto; }
    .export { margin-left: auto; }
    .export.busy { opacity: .6; pointer-events: none; }

    .empty { position: absolute; inset: 0; display: grid; place-items: center;
      color: var(--wb-fg-muted); font-family: var(--wb-font-mono); font-size: var(--wb-text-sm); }
  `;

  constructor() {
    super();
    this._slides = [];
    this._index = 0;
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
    this._sync(false);
  }

  disconnectedCallback() {
    this._mo?.disconnect();
    this.removeEventListener("keydown", this._onKey);
    document.removeEventListener("fullscreenchange", this._onFsChange);
  }

  attributeChangedCallback(name, oldV, newV) {
    super.attributeChangedCallback(name, oldV, newV);
    if (!this._connected) return;
    if (name === "index" && oldV !== newV) {
      const i = clampIndex(this._intAttr("index", 0), this._slides.length);
      if (i !== this._index) { this._index = i; this._sync(true); }
    } else if (name === "aspect") {
      this._applyAspect();
    }
  }

  // ---- slides + playhead --------------------------------------------------

  _collect() {
    const prev = this._slides;
    this._slides = Array.from(this.querySelectorAll(":scope > wb-slide"));
    // honor a per-deck default transition on slides that didn't declare one
    const tDefault = this.attr("transition");
    if (tDefault) for (const s of this._slides) {
      if (!s.hasAttribute("transition")) s.setAttribute("transition", tDefault);
    }
    this._index = clampIndex(this._index, this._slides.length);
    if (prev.length !== this._slides.length) this._sync(false);
    else this._paintControls();
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
    this._sync(true);
  }
  next() { this.go(this._index + 1); }
  prev() { this.go(this._index - 1); }
  first() { this.go(0); }
  last() { this.go(this._slides.length - 1); }

  /** Reflect playhead onto slides + chrome; emit wb-slide-change when moved. */
  _sync(emit) {
    this.setAttribute("index", String(this._index));
    this._slides.forEach((s, i) => {
      s.toggleAttribute("active", i === this._index);
      s.toggleAttribute("prev", i === this._index - 1);
      s.toggleAttribute("next", i === this._index + 1);
    });
    this.update();
    if (emit) {
      this.dispatchEvent(new CustomEvent("wb-slide-change", {
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
      case "p": this.classList.toggle("show-notes"); this._paintNotes(); break;
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

  /** Export the deck. In-guest wavelet encode via the Dock when the Host has the
   *  `wavelet` capability; otherwise a portable, self-contained .html (the deck
   *  as a wavelet composition — the SAME source the render-core consumes). */
  async export({ format = "mp4", fps = 30 } = {}) {
    if (this._exporting || !this._slides.length) return;
    this._exporting = true;
    this._paintControls();
    this.dispatchEvent(new CustomEvent("wb-export-start", { bubbles: true }));
    const composition = this.toComposition({ fps });
    try {
      if (this.host.available("wavelet")) {
        const out = await this.host.request("/wavelet/encode", {
          body: { composition, format, fps },
        });
        this.dispatchEvent(new CustomEvent("wb-export", { bubbles: true, detail: { ...out, format } }));
        return out;
      }
      const file = await this._downloadPortable(composition);
      this.dispatchEvent(new CustomEvent("wb-export", { bubbles: true, detail: { file, format: "html" } }));
      return { file, format: "html" };
    } catch (e) {
      this.dispatchEvent(new CustomEvent("wb-export-error", { bubbles: true, detail: { error: String(e) } }));
      throw e;
    } finally {
      this._exporting = false;
      this._paintControls();
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

  update() {
    if (!this.shadowRoot) return;
    this.shadowRoot.innerHTML = this.render();
    this._wire();
    this._paintControls();
    this._paintNotes();
  }

  _wire() {
    const sr = this.shadowRoot;
    sr.querySelector(".zone.prev")?.addEventListener("click", () => this.prev());
    sr.querySelector(".zone.next")?.addEventListener("click", () => this.next());
    sr.querySelector(".btn-prev")?.addEventListener("click", () => this.prev());
    sr.querySelector(".btn-next")?.addEventListener("click", () => this.next());
    sr.querySelector(".btn-fs")?.addEventListener("click", () => this.toggleFullscreen());
    sr.querySelector(".export")?.addEventListener("click", () => { void this.export(); });
    sr.querySelectorAll(".dot").forEach((d) =>
      d.addEventListener("click", () => this.go(Number(d.dataset.i))));
  }

  _paintControls() {
    const sr = this.shadowRoot; if (!sr) return;
    const n = this._slides.length, i = this._index;
    const fill = sr.querySelector(".progress > i");
    if (fill) fill.style.setProperty("--_pct", n > 1 ? `${(i / (n - 1)) * 100}%` : (n ? "100%" : "0%"));
    const counter = sr.querySelector(".counter");
    if (counter) counter.textContent = n ? `${i + 1} / ${n}` : "0 / 0";
    sr.querySelector(".btn-prev")?.toggleAttribute("disabled", !this.boolAttr("loop") && i <= 0);
    sr.querySelector(".btn-next")?.toggleAttribute("disabled", !this.boolAttr("loop") && i >= n - 1);
    sr.querySelectorAll(".dot").forEach((d) =>
      d.setAttribute("aria-current", String(Number(d.dataset.i) === i)));
    const ex = sr.querySelector(".export");
    if (ex) { ex.classList.toggle("busy", this._exporting); ex.textContent = this._exporting ? "…" : "Export ↓"; }
  }

  _paintNotes() {
    const sr = this.shadowRoot; if (!sr) return;
    const box = sr.querySelector(".notes"); if (!box) return;
    const slide = this.current;
    const note = slide ? slide.querySelector('[slot="notes"]') : null;
    box.innerHTML = note
      ? `<b>Notes · ${this._index + 1}/${this._slides.length}</b><br>${note.innerHTML}`
      : `<b>Notes · ${this._index + 1}/${this._slides.length}</b><br><span style="opacity:.6">no notes for this slide</span>`;
  }

  render() {
    const controls = this.boolAttr("controls");
    const n = this._slides.length;
    const dots = Array.from({ length: n }, (_, i) =>
      `<button class="dot" part="dot" data-i="${i}" aria-label="Go to slide ${i + 1}"></button>`).join("");
    const stage = `<div class="stage" part="stage">
      <slot></slot>
      ${n ? `<div class="zone prev" aria-hidden="true"></div><div class="zone next" aria-hidden="true"></div>` : `<div class="empty">No &lt;wb-slide&gt; children.</div>`}
      <div class="notes" part="notes"></div>
    </div>`;
    const progress = `<div class="progress" part="progress"><i></i></div>`;
    const chrome = controls ? `<div class="chrome" part="chrome">
      <button class="btn-prev" aria-label="Previous slide">‹</button>
      <span class="counter">0 / 0</span>
      <div class="dots" part="dots">${dots}</div>
      <button class="btn-next" aria-label="Next slide">›</button>
      <button class="btn-fs" aria-label="Fullscreen" title="Fullscreen (f)">⤢</button>
      <button class="export" title="Export to video (in-guest encode, or portable .html)">Export ↓</button>
    </div>` : "";
    return `<div class="shell">${stage}${progress}${chrome}</div>`;
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
  const bg = tok("--wb-bg", "#0a0d13");
  const fg = tok("--wb-fg", "#e9edf4");
  const font = tok("--wb-font", "system-ui, sans-serif");
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

define("wb-deck", WbDeck);
