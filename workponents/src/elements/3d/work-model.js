// <model-view> — the themed wrapper over Google's <model-viewer>.
//
// 3D's analogue of <video-player>: the floor VIEWER for glTF/GLB/STL. model-viewer
// (Apache-2.0) is itself a custom element built on three.js; we do NOT reimplement
// any of it. We wrap it in a token-themed shell — frame chrome, our own loading /
// error / placeholder states, and model-viewer's OWN CSS custom properties driven
// from --work-* tokens — all shadow-scoped, exactly like the video wrapper.
//
// LAZY LOAD (mirrors plot-tier / wavelet runtime-src): model-viewer is imported
// from a CDN ESM at first connect — nothing is bundled, no dep installed. The
// single-flight loader is overridable via `window.__WB_MODELVIEWER__` (tests /
// offline hosts inject their own, OR set it falsy to force the floor). If the
// import fails (network-blocked — the gate-c wasm/floor proof) OR no `src` is set,
// we render a THEMED PLACEHOLDER CARD with the model name + a typed glyph (never a
// blank box).
//
// THEMING (gate-a, token-leak): model-viewer paints its progress bar / poster /
// AR button / interaction prompt from its OWN `--poster-color`, `--progress-bar-*`,
// `--mv-*` custom properties. We set every one of those from --work-* tokens so
// the viewer chrome re-themes light/dark/signal. The model's own materials keep
// their authored pixels (preview ≡ render of the asset) — we theme the CHROME, not
// the geometry, mirroring the video stage.
//
// SCOPE (gate-b): the <model-viewer> element + its shadow live INSIDE this
// element's shadow root; its styles never land in document.head.
//
// Usage:
//   <model-view src="astronaut.glb" camera-controls auto-rotate></model-view>
//   <model-view src="model.glb" ar poster="poster.webp"></model-view>
//   el.addEventListener("work-model-load", …); // / "work-model-error"
//
// Generation (text/image → 3D) is HOST-BROKERED — see `generate()` below: the seam
// routes to Meshy / Tripo through `this.host` (a `/3d/generate` Dock verb). We
// document the seam and degrade gracefully; no live key is wired here.

import { WbElement, html, css, define } from "../../core/element.js";
import { defineVariants, variantAttrs } from "../../core/variants.js";

// Default CDN for model-viewer's ESM bundle. Override per-element with
// `viewer-src`, or globally / for tests via window.__WB_MODELVIEWER__. Set
// __WB_MODELVIEWER__ to a falsy non-undefined value (e.g. null via a flag) to
// force the floor placeholder without a network hit.
const DEFAULT_VIEWER_SRC = "https://esm.sh/@google/model-viewer@4.0.0";

// One in-flight import shared across every <model-view> on the page. Resolves once
// <model-viewer> is registered. Rejects (→ floor placeholder) when the chunk can't
// load. An explicit window.__WB_MODELVIEWER__ override short-circuits the import:
//   • a truthy value → treat as "already provided" (e.g. a host that pre-bundled it),
//   • `false`/`null` (the key EXISTS but is falsy) → force the floor (no import).
let _viewerLoad = null;
function loadModelViewer(rawSrc) {
  // explicit override present?
  if (typeof window !== "undefined" && "__WB_MODELVIEWER__" in window) {
    const ov = window.__WB_MODELVIEWER__;
    if (!ov) return Promise.reject(new Error("model-viewer disabled (__WB_MODELVIEWER__ falsy)"));
    return Promise.resolve(true);
  }
  // already registered by the host?
  if (typeof customElements !== "undefined" && customElements.get("model-viewer")) {
    return Promise.resolve(true);
  }
  let src = rawSrc;
  try {
    if (typeof document !== "undefined") src = new URL(rawSrc, document.baseURI).href;
  } catch { /* keep rawSrc */ }
  if (!_viewerLoad) {
    _viewerLoad = import(/* @vite-ignore */ src).then(
      () => true,
      (e) => { _viewerLoad = null; throw e; }, // allow a later retry
    );
  }
  return _viewerLoad;
}

const VARIANTS = defineVariants({
  // visual weight of the viewer frame (matches video-player's transport vocabulary)
  variant: { options: ["solid", "soft", "bare"], default: "solid" },
  size: { options: ["sm", "md", "lg"], default: "md" },
  // accent the chrome (progress bar, AR button) paints with
  tone: { options: ["brand", "neutral"], default: "brand" },
});

export class WorkModel extends WbElement {
  static variants = VARIANTS;
  static props = [
    ...variantAttrs(VARIANTS),
    "src",        // glTF / GLB / STL URL
    "poster",     // still shown until the model loads
    "alt",        // accessible description
    "ar",         // present → enable WebXR / Scene Viewer / Quick Look
    "auto-rotate",
    "camera-controls",
    "name",       // label for the floor placeholder
    "viewer-src", // override the model-viewer ESM URL
  ];

  static styles = css`
    :host { display: block; color: var(--work-fg); font-family: var(--work-font); }

    .frame {
      position: relative;
      display: flex; flex-direction: column;
      background: var(--work-surface);
      border: 1.5px solid var(--work-border);
      border-radius: var(--work-radius-lg);
      overflow: hidden;
      box-shadow: var(--work-shadow);
      aspect-ratio: 4 / 3;
    }
    :host([variant="soft"]) .frame { background: var(--work-surface-soft); box-shadow: var(--work-shadow-sm); }
    :host([variant="bare"]) .frame { background: transparent; border-color: transparent; box-shadow: none; border-radius: var(--work-radius); }
    :host([size="sm"]) .frame { aspect-ratio: 1 / 1; }
    :host([size="lg"]) .frame { aspect-ratio: 16 / 9; }

    /* the embedded <model-viewer>: fills the frame; its chrome is driven from
       --work-* tokens. The stage backdrop is a soft surface so light/dark/signal
       all read (the geometry itself keeps its authored materials). */
    model-viewer {
      flex: 1 1 auto; min-height: 0; width: 100%; height: 100%;
      display: block;
      background:
        radial-gradient(120% 120% at 30% 18%,
          var(--work-surface-soft) 0%, var(--work-surface) 72%);
      /* model-viewer's own theming hooks — all from tokens, zero literal leak */
      --poster-color: var(--work-surface);
      --progress-bar-color: var(--_a);
      --progress-bar-height: 3px;
      --progress-mask: transparent;
      --mv-interaction-prompt-text-color: var(--work-fg-muted);
      --interaction-prompt-color: var(--work-fg-muted);
      --_a: var(--work-brand);
    }
    :host([tone="neutral"]) model-viewer { --_a: var(--work-fg); }

    /* AR button, themed from tokens */
    model-viewer .ar-btn {
      position: absolute; right: var(--work-space-3); bottom: var(--work-space-3);
      appearance: none; cursor: pointer;
      height: 32px; padding: 0 var(--work-space-3);
      display: inline-flex; align-items: center; gap: var(--work-space-2);
      border: 1.5px solid var(--work-border-strong);
      border-radius: var(--work-radius-pill);
      background: var(--work-surface); color: var(--_a);
      font: 600 var(--work-text-sm) / 1 var(--work-font);
    }
    model-viewer .ar-btn:hover { background: var(--work-brand-soft); border-color: var(--_a); }

    /* loading + error chrome (token only) */
    .status {
      position: absolute; inset: 0;
      display: grid; place-items: center; padding: var(--work-space-4);
      text-align: center;
      color: var(--work-fg-muted); font-size: var(--work-text-sm);
      font-family: var(--work-font-mono);
    }
    .status.err { color: var(--work-err); white-space: pre-wrap; }

    /* the FLOOR placeholder — shown when there is no model-viewer (blocked /
       disabled) or no src. A clean themed card with a typed glyph + the name,
       never a blank box. */
    .floor {
      position: absolute; inset: 0;
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      gap: var(--work-space-3); padding: var(--work-space-5);
      text-align: center;
      background:
        radial-gradient(120% 120% at 30% 18%,
          var(--work-surface-soft) 0%, var(--work-surface) 72%);
    }
    .floor .glyph {
      font-size: var(--work-glyph-lg);
      line-height: 1;
      color: var(--_a, var(--work-brand));
      filter: drop-shadow(0 2px 10px var(--work-brand-soft));
    }
    :host([tone="neutral"]) .floor { --_a: var(--work-fg); }
    .floor .name {
      font: 600 var(--work-text) / 1.2 var(--work-font);
      color: var(--work-fg);
      word-break: break-word;
    }
    .floor .hint {
      font: 400 var(--work-text-sm) / 1.4 var(--work-font);
      color: var(--work-fg-subtle);
      max-width: 36ch;
    }
  `;

  constructor() {
    super();
    this._mvReady = false;   // model-viewer registered (import resolved)
    this._mvFailed = false;  // import failed / disabled → floor
    this._loading = false;   // a model is currently loading
    this._error = null;      // load error message
  }

  connectedCallback() {
    super.connectedCallback();
    this._ensureViewer();
    this._resolveSource();
  }

  /** Resolve a child <model-source> (composition-as-source) into `src`. A
   *  direct `src` attr always wins; otherwise a source child's compile() result
   *  drives the viewer (a `src` form sets it directly; a stubbed `code` form
   *  surfaces a clear status instead of a wrong model). */
  async _resolveSource() {
    if (this.attr("src")) return; // explicit src wins
    const srcEl = this.querySelector("model-source");
    if (!srcEl?.compile) return;
    try {
      const out = await srcEl.compile();
      if (out?.url) this.setAttribute("src", out.url);
      else if (out?.pending) { this._error = out.note; this.requestUpdate(); }
    } catch (e) { this._onError({ detail: { type: String(e?.message || e) } }); }
  }

  attributeChangedCallback(name, oldV, newV) {
    super.attributeChangedCallback(name, oldV, newV);
    if (!this.isConnected) return;
    if (name === "viewer-src" && oldV !== newV) {
      this._mvReady = this._mvFailed = false;
      this._ensureViewer();
    }
    if (name === "src" && oldV !== newV) {
      this._error = null;
      this._loading = !!newV && this._mvReady;
    }
  }

  /** Lazy-load model-viewer; on success render the real viewer, on failure the floor. */
  async _ensureViewer() {
    const viewerSrc = this.attr("viewer-src", DEFAULT_VIEWER_SRC);
    try {
      await loadModelViewer(viewerSrc);
      this._mvReady = true;
      this._mvFailed = false;
      this._loading = !!this.attr("src");
    } catch {
      this._mvReady = false;
      this._mvFailed = true; // → floor placeholder (graceful degrade)
    }
    this.requestUpdate();
  }

  // ---- model-viewer event bridge → themed `work-model-*` events ----------

  _onLoad() {
    this._loading = false;
    this._error = null;
    this.requestUpdate();
    this.dispatchEvent(new CustomEvent("work-model-load", {
      bubbles: true, composed: true, detail: { src: this.attr("src") },
    }));
  }

  _onError(e) {
    this._loading = false;
    this._error = e?.detail?.type || "failed to load model";
    this.requestUpdate();
    this.dispatchEvent(new CustomEvent("work-model-error", {
      bubbles: true, composed: true, detail: { src: this.attr("src"), error: this._error },
    }));
  }

  // ---- generation seam (text/image → 3D) — HOST-BROKERED -----------------

  /**
   * Generate a model from a text prompt (or an image) via the Host broker — the
   * runtime proxies Meshy / Tripo (so the key stays host-side; never in the
   * artifact). On success the returned GLB url is set as `src`. Degrades cleanly
   * when no 3D capability is granted.
   *
   *   await el.generate({ prompt: "a low-poly fox" });
   *   await el.generate({ image: blobUrl });
   */
  async generate({ prompt, image, provider } = {}) {
    if (!this.host?.available?.("3d")) {
      this.dispatchEvent(new CustomEvent("work-model-error", {
        bubbles: true, composed: true,
        detail: { error: "3D generation needs a host broker (Meshy/Tripo) — not available" },
      }));
      return null;
    }
    this._loading = true; this._error = null; this.requestUpdate();
    try {
      const out = await this.host.request("/3d/generate", { body: { prompt, image, provider } });
      if (out?.url) this.setAttribute("src", out.url);
      return out;
    } catch (e) {
      this._onError({ detail: { type: String(e?.message || e) } });
      return null;
    }
  }

  // ---- render -------------------------------------------------------------

  render() {
    const src = this.attr("src");
    const a = this.constructor; void a;

    // FLOOR: no viewer engine (blocked / disabled), or nothing to show.
    if (this._mvFailed || (!this._mvReady && !src) || (this._mvReady && !src)) {
      return html`<div class="frame">${this._floor(src)}</div>`;
    }
    // still importing the engine
    if (!this._mvReady) {
      return html`<div class="frame"><div class="status">Loading 3D viewer…</div></div>`;
    }

    const poster = this.attr("poster");
    const alt = this.attr("alt") || this.attr("name") || "3D model";
    const ar = this.boolAttr("ar");
    const autoRotate = this.boolAttr("auto-rotate");
    const cameraControls = this.boolAttr("camera-controls");

    // The real <model-viewer>, themed via tokens (see static styles). We forward
    // the boolean/feature attrs and bridge its load/error to work-model-* events.
    return html`<div class="frame">
      <model-viewer
        src=${src}
        alt=${alt}
        ?ar=${ar}
        ?auto-rotate=${autoRotate}
        ?camera-controls=${cameraControls}
        poster=${poster || ""}
        exposure="1"
        shadow-intensity="0.9"
        @load=${() => this._onLoad()}
        @error=${(e) => this._onError(e)}
      >
        ${ar ? html`<button slot="ar-button" class="ar-btn">View in AR</button>` : ""}
      </model-viewer>
      ${this._error ? html`<div class="status err">3D: ${this._error}</div>` : ""}
    </div>`;
  }

  /** Themed placeholder card — typed glyph + the model name. Never blank. */
  _floor(src) {
    const name = this.attr("name") ||
      (src ? src.split("/").pop() : "3D model");
    const hint = this._mvFailed
      ? "3D viewer unavailable — showing the model reference."
      : src
        ? "Preparing the 3D viewer…"
        : "No model. Set the src attribute to a glTF / GLB / STL URL.";
    return html`<div class="floor">
      <div class="glyph" aria-hidden="true">◈</div>
      <div class="name">${name}</div>
      <div class="hint">${hint}</div>
    </div>`;
  }
}

define("model-view", WorkModel);
