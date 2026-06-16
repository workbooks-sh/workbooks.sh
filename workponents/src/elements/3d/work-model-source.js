// <model-source> — the composition-as-source-for-3D descriptor for
// <model-view>. The 3D analogue of <video-source> / <source>: a typed slot
// of metadata the parent <model-view> reads to resolve what to render. Renders
// nothing itself.
//
//   <model-view><model-source src="model.glb"></model-source></model-view>
//
// THE COMPOSITION-AS-SOURCE MOMENT (text → geometry): the `code` form carries a
// scene SOURCE (an OpenSCAD-like / minimal CSG scene spec) that compiles to a GLB
// in-browser via **Manifold** wasm (manifold-3d, lazy CDN ESM) and feeds the
// resulting blob URL to the parent — exactly the way <video-source> inlines a
// wavelet composition. The source IS the model: edit the text, recompile, the
// viewer updates; the GLB never has to be shipped.
//
//   <model-view camera-controls>
//     <model-source code="cube(20); sphere(12);"></model-source>
//   </model-view>
//
// STATUS — STUBBED (directive: "if Manifold is heavy, scope the viewer solid first
// and STUB model-source with a clear note"). The descriptor contract + the
// parent wiring + the lazy single-flight Manifold loader (overridable via
// window.__WB_MANIFOLD__) are REAL and shipped. The scene-spec → Manifold-mesh
// COMPILER (`_compileScene`) is the only deferred piece: today it parses the spec
// and reports that the kernel binding is pending, surfacing a clear status on the
// parent rather than rendering a wrong model. Wiring a real Manifold build is a
// follow-up (tracked for merge); the seam below is where it lands — `compile()`
// already returns the {url} the parent consumes, so flipping the stub to live is
// a localized change with no parent churn.

import { WbElement, html, css, define } from "../../core/element.js";

const DEFAULT_MANIFOLD_SRC = "https://esm.sh/manifold-3d@3.0.0";

// Single-flight lazy import of the Manifold wasm module. Overridable via
// window.__WB_MANIFOLD__ (tests / offline hosts / a host that pre-bundled it).
let _manifoldLoad = null;
export function loadManifold(rawSrc = DEFAULT_MANIFOLD_SRC) {
  if (typeof window !== "undefined" && window.__WB_MANIFOLD__) {
    return Promise.resolve(window.__WB_MANIFOLD__);
  }
  let src = rawSrc;
  try {
    if (typeof document !== "undefined") src = new URL(rawSrc, document.baseURI).href;
  } catch { /* keep rawSrc */ }
  if (!_manifoldLoad) {
    _manifoldLoad = import(/* @vite-ignore */ src).then(
      (m) => m,
      (e) => { _manifoldLoad = null; throw e; },
    );
  }
  return _manifoldLoad;
}

export class WorkModelSource extends WbElement {
  static props = ["src", "code", "manifold-src", "type"];
  // metadata only — no visible rendering.
  static styles = css`:host { display: none; }`;

  /** The source descriptor the parent <model-view> reads. */
  get descriptor() {
    return {
      src: this.attr("src"),
      code: this.attr("code"),
      type: this.attr("type", this.attr("code") ? "scene/manifold" : "model/gltf-binary"),
    };
  }

  /**
   * Compile this source to something <model-view> can render.
   *  • `src` form  → returns { url } directly (a GLB/STL URL, no compile).
   *  • `code` form → compiles the scene spec to a GLB blob URL via Manifold.
   *
   * STUB: the `code` path loads the Manifold module + parses the spec, but the
   * spec→mesh kernel binding is pending — it resolves with { pending:true, note }
   * so the parent shows a clear status instead of a wrong model. The `src` path is
   * fully live.
   */
  async compile() {
    const code = this.attr("code");
    if (!code) return { url: this.attr("src") || null };

    let manifold = null;
    try { manifold = await loadManifold(this.attr("manifold-src", DEFAULT_MANIFOLD_SRC)); }
    catch (e) { return { pending: true, note: `Manifold unavailable: ${e?.message || e}` }; }

    const parsed = parseScene(code);
    // ── deferred kernel binding ────────────────────────────────────────────
    // Where the real build lands: turn `parsed` ops into Manifold primitives
    // (manifold.cube/sphere/...), boolean-compose, mesh → GLB via a GLTF
    // exporter, URL.createObjectURL(blob). Returns { url } with no parent churn.
    void manifold;
    return {
      pending: true,
      ops: parsed,
      note: `model-source: parsed ${parsed.length} op(s); Manifold spec→GLB compile is stubbed (kernel binding pending). Use src= for a ready model.`,
    };
  }

  attributeChangedCallback(name, oldV, newV) {
    super.attributeChangedCallback?.(name, oldV, newV);
    if (this.isConnected && oldV !== newV) {
      this.closest("model-view")?._resolveSource?.();
    }
  }

  render() { return html``; }
}

/** Minimal OpenSCAD-like scene parser: `cube(20); sphere(12);` → [{op,args}]. */
function parseScene(code) {
  const ops = [];
  for (const stmt of String(code).split(";")) {
    const m = /^\s*([a-z_]+)\s*\(([^)]*)\)\s*$/i.exec(stmt);
    if (!m) continue;
    const args = m[2].split(",").map((s) => s.trim()).filter(Boolean).map(Number);
    ops.push({ op: m[1].toLowerCase(), args });
  }
  return ops;
}

define("model-source", WorkModelSource);
