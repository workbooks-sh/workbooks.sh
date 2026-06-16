// <work-video> — the themed wrapper over the SHIPPED wavelet player.
//
// Wavelet's reinvention: COMPOSITION-AS-SOURCE video. The composition (a
// <gm-doc> tree of <gm-timeline>/<gm-track>/<gm-clip>/<gm-scene>/… data
// elements, or plain HTML+CSS @keyframes) IS the source the player renders —
// preview ≡ render — and export is an IN-GUEST encode brokered through the
// Dock. This element does NOT reimplement any of that. It wraps the wavelet
// runtime (`desktop/static/wavelet/wavelet-runtime.js`, the `gm-doc`/`gm-data`
// custom elements) in a token-themed shell with a variant transport, and
// exposes play / pause / seek / export over the runtime's own API.
//
// The wavelet runtime auto-registers `gm-doc` on import (idempotent, like our
// define()). We import it lazily from `runtime-src` (default: the shipped
// path) so a host that already loaded it pays nothing, and a workbook that
// never plays video never fetches it.
//
// Source resolution (composition-as-source first):
//   • `composition` attr / a slotted <gm-doc> / inner gm-* markup — inlined
//     directly; the player IS the renderer (no fetch, no iframe). Preferred.
//   • `src="…html"` (or a <work-video-source>) — fetched, then inlined the same
//     way, so preview still equals render.
//
// Theming: chrome is suppressed on the embedded gm-doc (`data-embedded`); we
// paint our own controls from --wb-* tokens only. The composition stage keeps
// its native pixels (preview ≡ render); we letterbox-scale the box, never the
// content — mirroring the desktop WaveletPlayer.
//
// Usage:
//   <work-video controls poster="…">
//     <gm-doc fps="30" resolution="1280x720" duration="2.0s"> … </gm-doc>
//   </work-video>
//   <work-video src="reel.html" controls autoplay></work-video>
//   el.play(); el.pause(); await el.export();

import { WbElement, html, css, define } from "../../core/element.js";
import { ref, createRef } from "lit/directives/ref.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

// Default location of the shipped wavelet runtime. Override per-element with
// `runtime-src`, or globally via window.__WB_WAVELET_RUNTIME__.
const DEFAULT_RUNTIME =
  (typeof window !== "undefined" && window.__WB_WAVELET_RUNTIME__) ||
  "/wavelet/wavelet-runtime.js";

// One in-flight import per URL, shared across every <work-video> on the page.
const _runtimeLoads = new Map();
function loadWaveletRuntime(rawSrc) {
  if (typeof customElements !== "undefined" && customElements.get("gm-doc")) {
    return Promise.resolve(true); // already registered by the host
  }
  // Resolve a relative runtime-src against the DOCUMENT base, not this module —
  // authors point it at a page-relative path (e.g. ./wavelet/… or /wavelet/…).
  let src = rawSrc;
  try {
    if (typeof document !== "undefined") src = new URL(rawSrc, document.baseURI).href;
  } catch { /* keep rawSrc */ }
  if (!_runtimeLoads.has(src)) {
    _runtimeLoads.set(
      src,
      import(/* @vite-ignore */ src).then(
        () => true,
        (e) => {
          _runtimeLoads.delete(src);
          throw e;
        },
      ),
    );
  }
  return _runtimeLoads.get(src);
}

const VARIANTS = defineVariants({
  // visual weight of the player frame
  variant: { options: ["solid", "soft", "bare"], default: "solid" },
  // transport density
  size: { options: ["sm", "md", "lg"], default: "md" },
  // accent the controls paint with
  tone: { options: ["brand", "neutral"], default: "brand" },
  // how the composition fills its box
  fit: { options: ["contain", "cover"], default: "contain" },
});

export class WorkVideo extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "src",
    "composition",
    "poster",
    "controls",
    "autoplay",
    "loop",
    "runtime-src",
  ];

  static styles = css`
    :host { display: block; color: var(--wb-fg); font-family: var(--wb-font); }

    .frame {
      position: relative;
      display: flex; flex-direction: column;
      background: var(--wb-surface);
      border: 1.5px solid var(--wb-border);
      border-radius: var(--wb-radius-lg);
      overflow: hidden;
      box-shadow: var(--wb-shadow);
    }
    :host([variant="soft"]) .frame { background: var(--wb-surface-soft); box-shadow: var(--wb-shadow-sm); }
    :host([variant="bare"]) .frame { background: transparent; border-color: transparent; box-shadow: none; border-radius: var(--wb-radius); }

    /* stage: native composition pixels, letterbox-scaled to fit. Checkerboard
       behind transparent compositions, like the desktop player. */
    .stage-wrap {
      position: relative;
      flex: 1 1 auto; min-height: 0;
      display: flex; align-items: center; justify-content: center;
      aspect-ratio: var(--_aspect, 16 / 9);
      background:
        repeating-conic-gradient(
          color-mix(in srgb, var(--wb-fg) 5%, transparent) 0% 25%,
          transparent 0% 50%) 50% / 22px 22px,
        var(--wb-bg);
      overflow: hidden;
    }
    .stage {
      flex: 0 0 auto;
      transform-origin: center center;
      background: #000;
    }
    :host([fit="cover"]) .stage-wrap { /* cover lets the scaler overflow-crop */ }

    /* the embedded composition: chrome suppressed; we own the transport */
    .stage ::slotted(gm-doc), .stage gm-doc { display: block; }

    .poster {
      position: absolute; inset: 0;
      width: 100%; height: 100%; object-fit: cover;
      cursor: pointer;
    }
    .bigplay {
      position: absolute; inset: 0; margin: auto;
      width: 64px; height: 64px;
      display: grid; place-items: center;
      border: none; border-radius: var(--wb-radius-pill);
      background: color-mix(in srgb, var(--wb-brand) 88%, transparent);
      color: var(--wb-on-brand);
      font-size: 24px; cursor: pointer;
      box-shadow: var(--wb-shadow);
      transition: transform var(--wb-dur) var(--wb-ease);
    }
    .bigplay:hover { transform: scale(1.06); }

    .status {
      position: absolute; inset: 0;
      display: grid; place-items: center; padding: var(--wb-space-4);
      text-align: center;
      color: var(--wb-fg-muted); font-size: var(--wb-text-sm);
      font-family: var(--wb-font-mono);
    }
    .status.err { color: var(--wb-err); white-space: pre-wrap; }

    /* transport — tokens only */
    .transport {
      flex: 0 0 auto;
      display: flex; align-items: center; gap: var(--wb-space-2);
      padding: var(--wb-space-2) var(--wb-space-3);
      border-top: 1.5px solid var(--wb-border);
      background: var(--wb-surface);
      --_a: var(--wb-brand); --_ink: var(--wb-on-brand);
    }
    :host([tone="neutral"]) .transport { --_a: var(--wb-fg); --_ink: var(--wb-surface); }
    :host([variant="soft"]) .transport { background: var(--wb-surface-soft); }
    :host([variant="bare"]) .transport { background: transparent; border-top-color: var(--wb-border); }

    .transport button {
      appearance: none; cursor: pointer;
      height: 30px; min-width: 30px; padding: 0 var(--wb-space-2);
      display: inline-flex; align-items: center; justify-content: center;
      border: 1.5px solid var(--wb-border-strong);
      border-radius: var(--wb-radius-sm);
      background: var(--wb-surface); color: var(--wb-fg);
      font-family: var(--wb-font); font-size: var(--wb-text-sm); font-weight: 600;
      line-height: 1;
      transition: border-color var(--wb-dur) var(--wb-ease), background var(--wb-dur) var(--wb-ease);
    }
    .transport button:hover:not(:disabled) { border-color: var(--_a); background: var(--wb-brand-soft); }
    .transport button:focus-visible { outline: none; box-shadow: 0 0 0 3px var(--wb-ring); }
    .transport button:disabled { opacity: 0.45; cursor: default; }
    .play { color: var(--_a); font-weight: 700; }

    :host([size="sm"]) .transport { padding: var(--wb-space-1) var(--wb-space-2); }
    :host([size="sm"]) .transport button { height: 26px; min-width: 26px; }
    :host([size="lg"]) .transport { padding: var(--wb-space-3) var(--wb-space-4); }
    :host([size="lg"]) .transport button { height: 34px; min-width: 34px; font-size: var(--wb-text); }

    .scrub {
      flex: 1 1 auto; min-width: 40px;
      accent-color: var(--_a); cursor: pointer;
    }
    .time, .frames {
      font-family: var(--wb-font-mono); font-size: var(--wb-text-sm);
      color: var(--wb-fg-muted); white-space: nowrap;
    }
    .export { margin-left: auto; }
    .export.busy { opacity: 0.6; pointer-events: none; }
  `;

  // ---- lifecycle ----------------------------------------------------------

  constructor() {
    super();
    this._doc = null; // the embedded <gm-doc>
    this._ready = false;
    this._playing = false;
    this._raf = 0;
    this._status = null; // {kind:'load'|'error', msg}
    this._exporting = false;
    // refs to the live transport widgets (set by Lit after each render)
    this._stageRef = createRef();
    this._scrubRef = createRef();
    this._timeRef = createRef();
    this._framesRef = createRef();
    this._playRef = createRef();
  }

  connectedCallback() {
    super.connectedCallback();
    this._boot();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    cancelAnimationFrame(this._raf);
    this._raf = 0;
    try { this._doc?.pause?.(); } catch {}
  }

  // Only re-boot on source/runtime changes; cosmetic attrs just re-render. Lit
  // already re-renders on any reactive-property change; here we additionally
  // re-boot when the SOURCE changes.
  attributeChangedCallback(name, oldV, newV) {
    super.attributeChangedCallback(name, oldV, newV);
    if (!this.isConnected) return;
    if (["src", "composition", "runtime-src"].includes(name) && oldV !== newV) {
      this._boot();
    }
  }

  // After every Lit render: re-attach the cached gm-doc into the (new) stage
  // node and re-sync transport. update() rewrites the shadow tree, so the doc
  // must be re-homed — but the gm-doc element itself is preserved (never torn
  // down), so the player keeps running across theme/variant changes.
  updated() {
    if (this._doc) {
      const stage = this._stageRef.value;
      if (stage && this._doc.parentNode !== stage) stage.appendChild(this._doc);
      this._scaleStage();
      this._syncTransport();
    }
  }

  // ---- source resolution (composition-as-source) --------------------------

  /** Inline composition markup from, in order: `composition` attr, a slotted/
   *  child <gm-doc> or gm-* markup, else null (meaning: fetch `src`). */
  _inlineSource() {
    const attr = this.attr("composition");
    if (attr && attr.trim()) return attr;
    // A <work-video-source composition="…"> child (declarative form).
    const srcEl = this.querySelector("work-video-source[composition]");
    if (srcEl) {
      const c = srcEl.getAttribute("composition");
      if (c && c.trim()) return c;
    }
    // A slotted/child <gm-doc> authored directly inside <work-video>; move it
    // into the shadow stage.
    const child = this.querySelector("gm-doc");
    if (child) return child.outerHTML;
    return null;
  }

  /** The src to fetch when no inline composition is present. */
  _srcUrl() {
    const direct = this.attr("src");
    if (direct) return direct;
    const srcEl = this.querySelector("work-video-source[src]");
    return srcEl ? srcEl.getAttribute("src") : null;
  }

  async _boot() {
    cancelAnimationFrame(this._raf);
    this._ready = false;
    this._playing = false;
    this._doc = null;
    this._status = { kind: "load", msg: "Loading composition…" };
    this.requestUpdate();

    let markup = this._inlineSource();
    try {
      if (!markup) {
        const url = this._srcUrl();
        if (!url) {
          // Nothing to play — themed placeholder (clean, on-brand).
          this._status = null;
          this.requestUpdate();
          return;
        }
        const res = await fetch(url);
        if (!res.ok) throw new Error(`fetch ${res.status} ${url}`);
        markup = await res.text();
      }

      const runtimeSrc = this.attr("runtime-src", DEFAULT_RUNTIME);
      const needsRuntime = /<gm-doc[\s>]/i.test(markup) || /^\s*<gm-/i.test(markup);
      if (needsRuntime) await loadWaveletRuntime(runtimeSrc);

      this._status = null;
      await this._mount(markup);
    } catch (e) {
      this._status = { kind: "error", msg: `wavelet: ${e?.message || e}` };
      this.requestUpdate();
    }
  }

  /** Place the composition into the shadow stage and wire transport to the
   *  gm-doc API. The composition is the renderer; we never re-render frames. */
  async _mount(markup) {
    // Ensure the .stage node exists before we mount into it.
    this.requestUpdate();
    await this.updateComplete;
    const stage = this._stageRef.value;
    if (!stage) return;

    // If the markup is a full <gm-doc …>…</gm-doc>, instantiate it directly.
    // If it's bare gm-* fragments, wrap in a gm-doc carrying our attrs.
    let frag = markup.trim();
    if (!/^<gm-doc[\s>]/i.test(frag)) {
      frag = `<gm-doc data-embedded>${frag}</gm-doc>`;
    }
    stage.innerHTML = frag;
    const doc = stage.querySelector("gm-doc");
    if (!doc) {
      this._status = { kind: "error", msg: "no <gm-doc> in composition" };
      this.requestUpdate();
      return;
    }
    // Suppress wavelet's own chrome — we paint the themed transport.
    doc.setAttribute("data-embedded", "");
    this._doc = doc;

    // gm-doc resolves its timeline in connectedCallback (already run on
    // innerHTML insert). Read metadata for the aspect + transport.
    queueMicrotask(() => {
      this._ready = true;
      this._applyAspect();
      this._scaleStage();
      this.requestUpdate();
      if (this.boolAttr("autoplay")) this.play();
    });
  }

  _applyAspect() {
    const w = this._doc?.resolved?.resolution?.width;
    const h = this._doc?.resolved?.resolution?.height;
    if (w && h) {
      this.style.setProperty("--_aspect", `${w} / ${h}`);
    }
  }

  /** Letterbox-scale the native-pixel stage to fit its box (preview ≡ render —
   *  scale the box, not the content). Mirrors WaveletPlayer.recomputeScale. */
  _scaleStage() {
    const stage = this._stageRef.value;
    const wrap = stage?.parentElement;
    const w = this._doc?.resolved?.resolution?.width;
    const h = this._doc?.resolved?.resolution?.height;
    if (!wrap || !stage || !w || !h) return;
    stage.style.width = `${w}px`;
    stage.style.height = `${h}px`;
    const aw = wrap.clientWidth, ah = wrap.clientHeight;
    if (!aw || !ah) return;
    const cover = this.attr("fit") === "cover";
    const s = cover ? Math.max(aw / w, ah / h) : Math.min(aw / w, ah / h, 1);
    stage.style.transform = `scale(${s})`;
  }

  // ---- public transport API (delegates to the wavelet runtime) ------------

  play() {
    if (!this._doc) return;
    this._doc.play();
    this._playing = true;
    this._tickLoop();
    this.requestUpdate();
    this.dispatchEvent(new CustomEvent("work-play", { bubbles: true }));
  }

  pause() {
    if (!this._doc) return;
    this._doc.pause();
    this._playing = false;
    cancelAnimationFrame(this._raf);
    this.requestUpdate();
    this.dispatchEvent(new CustomEvent("work-pause", { bubbles: true }));
  }

  toggle() {
    if (this._playing) this.pause();
    else this.play();
  }

  /** Seek to a frame (render-equal precision — wavelet seeks the clock). */
  seek(frame) {
    if (!this._doc) return;
    const total = this._doc.totalFrames || 1;
    const f = Math.max(0, Math.min(total - 1, Math.round(frame)));
    this._doc.seekFrame(f);
    this._syncTransport();
  }

  get currentFrame() { return this._doc?.currentFrame ?? 0; }
  get totalFrames() { return this._doc?.totalFrames ?? 0; }
  get fps() { return this._doc?.fps ?? 30; }
  get playing() { return this._playing; }

  /** Export — IN-GUEST encode via the Dock when a runtime is reachable;
   *  otherwise download the portable, self-contained composition .html (the
   *  SAME source the renderer consumes — preview ≡ render ≡ the file). Both
   *  honor wavelet's model: the artifact is its own source. */
  async export({ format = "mp4" } = {}) {
    if (this._exporting) return;
    const markup = this._currentMarkup();
    if (!markup) return;
    this._exporting = true;
    this.requestUpdate();
    this.dispatchEvent(new CustomEvent("work-export-start", { bubbles: true }));
    try {
      if (this.host.available("wavelet")) {
        // In-guest encode brokered through the Dock (render_seq.wasm + the
        // wasm encoder). The host returns a URL / handle to the rendered file.
        const out = await this.host.request("/wavelet/encode", {
          body: { composition: markup, format, fps: this.fps },
        });
        this.dispatchEvent(
          new CustomEvent("work-export", { bubbles: true, detail: { ...out, format } }),
        );
        return out;
      }
      // Degrade: portable HTML download (self-contained composition).
      const file = await this._downloadPortable(markup);
      this.dispatchEvent(
        new CustomEvent("work-export", { bubbles: true, detail: { file, format: "html" } }),
      );
      return { file, format: "html" };
    } catch (e) {
      this.dispatchEvent(
        new CustomEvent("work-export-error", { bubbles: true, detail: { error: String(e) } }),
      );
      throw e;
    } finally {
      this._exporting = false;
      this.requestUpdate();
    }
  }

  /** The live composition markup (what plays === what exports). */
  _currentMarkup() {
    if (this._doc) {
      // Re-serialize the gm-doc tree without our embed flag.
      const clone = this._doc.cloneNode(true);
      clone.removeAttribute("data-embedded");
      return clone.outerHTML;
    }
    return this._inlineSource();
  }

  /** Inline the wavelet runtime so the downloaded .html plays standalone. */
  async _downloadPortable(markup) {
    const runtimeSrc = this.attr("runtime-src", DEFAULT_RUNTIME);
    let runtime = "";
    try {
      const res = await fetch(runtimeSrc);
      if (res.ok) runtime = await res.text();
    } catch { /* fall through — markup is still valid with an external runtime */ }
    const doc =
      `<!doctype html><html><head><meta charset="utf-8">` +
      (runtime ? `<script type="module">${runtime}<\/script>` : "") +
      `</head><body style="margin:0;background:#000">${markup}</body></html>`;
    const blob = new Blob([doc], { type: "text/html" });
    const url = URL.createObjectURL(blob);
    const name = (this.attr("src") || "composition").split("/").pop().replace(/\.html?$/i, "") + ".html";
    const a = document.createElement("a");
    a.href = url; a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    return name;
  }

  // ---- transport tick -----------------------------------------------------

  _tickLoop() {
    cancelAnimationFrame(this._raf);
    const step = () => {
      if (!this._playing) return;
      // wavelet ended? (currentFrame stuck at end)
      if (this._doc && this._doc.currentFrame >= this._doc.totalFrames - 1) {
        if (this.boolAttr("loop")) {
          this._doc.seekFrame(0);
          this._doc.play();
        } else {
          this._playing = false;
          this._syncTransport();
          this.dispatchEvent(new CustomEvent("work-ended", { bubbles: true }));
          return;
        }
      }
      this._syncTransport();
      this._raf = requestAnimationFrame(step);
    };
    this._raf = requestAnimationFrame(step);
  }

  /** Update only the transport widgets without re-mounting the composition. */
  _syncTransport() {
    if (!this._doc) return;
    const scrub = this._scrubRef.value;
    const time = this._timeRef.value;
    const frames = this._framesRef.value;
    const play = this._playRef.value;
    const cur = this._doc.currentFrame, total = this._doc.totalFrames, fps = this._doc.fps;
    if (scrub) { scrub.max = String(Math.max(0, total - 1)); scrub.value = String(cur); }
    if (time) time.textContent = `${fmt(cur, fps)} / ${fmt(total, fps)}`;
    if (frames) frames.textContent = `f ${cur}/${Math.max(0, total - 1)} · ${fps}fps`;
    if (play) play.textContent = this._playing ? "❚❚" : "▶";
  }

  // ---- render -------------------------------------------------------------

  render() {
    const controls = this.boolAttr("controls");
    const poster = this.attr("poster");
    const showPoster = poster && !this._playing && !this._doc;
    const status = this._status;

    const overlay = showPoster
      ? html`<img class="poster" src=${poster} alt="" @click=${() => this.toggle()} /><button class="bigplay" aria-label="Play" @click=${() => this.toggle()}>▶</button>`
      : status
        ? html`<div class="status ${status.kind === "error" ? "err" : ""}">${status.msg}</div>`
        : !this._doc && !showPoster
          ? html`<div class="status">No composition. Set <code>composition</code>, <code>src</code>, or slot a &lt;gm-doc&gt;.</div>`
          : "";

    const stage = html`<div class="stage-wrap"><div class="stage" ${ref(this._stageRef)}></div>${overlay}</div>`;

    const transport = controls
      ? html`<div class="transport">
           <button class="play" aria-label="Play/Pause" @click=${() => this.toggle()} ${ref(this._playRef)}>${this._playing ? "❚❚" : "▶"}</button>
           <button class="step-back" aria-label="Previous frame" title="Previous frame" @click=${() => this.seek(this.currentFrame - 1)}>⟨</button>
           <button class="step-fwd" aria-label="Next frame" title="Next frame" @click=${() => this.seek(this.currentFrame + 1)}>⟩</button>
           <input class="scrub" type="range" min="0" max="0" step="1" value="0" aria-label="Scrub timeline" @input=${(e) => this.seek(Number(e.target.value))} ${ref(this._scrubRef)} />
           <span class="time" ${ref(this._timeRef)}>0:00 / 0:00</span>
           <span class="frames" ${ref(this._framesRef)}>f 0/0</span>
           <button class="export ${this._exporting ? "busy" : ""}" title="Export (in-guest encode, or portable .html)" @click=${() => { void this.export(); }}>${this._exporting ? "…" : "Export ↓"}</button>
         </div>`
      : "";

    return html`<div class="frame">${stage}${transport}</div>`;
  }
}

function fmt(frame, fps) {
  const s = Math.max(0, frame) / (fps || 30);
  const m = Math.floor(s / 60);
  const sec = Math.floor(s % 60);
  return `${m}:${String(sec).padStart(2, "0")}`;
}

define("work-video", WorkVideo);
