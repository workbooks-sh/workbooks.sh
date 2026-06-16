# Workponents → Agent Integration — The Directive

*The end-state architecture + sequenced plan for making the agent (voice and text) visibly
compose correct, on-brand, living UI from workponents. Synthesized from 5 grounded research
streams (chat-render, theming, file-formats, validation/evals, toolkit-graph), 2026-06-15.*

---

## North Star

> The agent — voice and text — composes **living, correct, on-brand UI** from a **discovered
> component catalog**, rendered **efficiently inline in the chat thread**, **self-editing real
> documents** (org/docx/pptx/3D) through the WASM lane, all governed by **one theming construct**,
> and **proven by evals** that it actually reaches for the right component. The desktop chat is the
> proving ground; we dogfood our own components there.

## The thesis: this is *wiring + de-dup + discovery + validation*, not building

The floor exists — **42 `work-*` Lit elements across 15 domains**, all verified rendering/theming.
Every research stream converged on the same finding: **almost nothing here is net-new construction.**
The capabilities already exist as seams (the OQL kernel, the WASI compiler pallet, wavelet, the
SQLite VFS, the Dock cap model, the wavelet eval harness, even a theme registry in the desktop Rust
layer). What's missing is the *system* that connects them. The genuinely new inventions are small:
**a pptx→org emitter, a 3D domain, a 5-gate validation harness, and ~30–40 lines to make the toolkit
dependency graph real.**

---

## HAVE / DON'T-HAVE

### HAVE
- 42 themed `work-*` Lit elements (floor tier), one `WbElement` base, token-only theming through shadow DOM.
- The seams: SQLite VFS (`vfs-query`), wavelet render-core + `wb_encode.wasm`, OQL kernel (`oql.wasm`), RCP/BEAM, the WASM **compiler lane + WASI pallet** (pandoc already in it), the Dock cap model.
- A real chat surface with **real inference** (`/api/agent/run`), and the `#+RENDER: org` + `#+begin_src component` contract **already taught to the agent and parsed by the desktop**.
- A **theme registry already in the desktop Rust layer** (`store.rs` — `Theme{id,name,light/dark tokens}`, CRUD, persisted).
- A **mature eval harness** (`runtime/wavelet/evals/` — spec + checks + vision-judge rubric).
- Runtime **toolkit→toolkit composition** (the `commands` Dock cap → `run-command`, Policy-gated).

### DON'T-HAVE (the gaps, by stream)
1. **Chat:** the desktop renders **duplicate Svelte twins** (`ChatComponent.svelte`, `messageRender.ts`, `markdown.ts`) of the `work-*` elements — already drifted (`wb-chat-action`→nobody vs `work-intent`). Desktop imports **zero** workponents. The `work-intent` event loop is **open** (agent never sees a button press). Voice is a **visual-less universe** (own `VoiceBubble` model, only `write_code`→editor).
2. **Catalog/discovery:** the agent's component catalog is a **hardcoded 5-type string** in `web.ex:1881`, not discovered. "Any agent can register components" doesn't exist in code.
3. **Theming:** **three disconnected namespaces** (`--wb-*` SDK presets / `--color-*` app registry / per-brand ad-hoc), guaranteed to drift; **no design-lint**; **no agent theme-awareness** (agents invent palettes per artifact).
4. **Toolkit graph:** workponents' `#+KIND: web-components` is a **self-invented string the runtime doesn't parse** — with no `#+EXEC`, it's a **discovery-only asset bundle, not a wired toolkit**. The **declared dependency DAG does not exist** (`#+REQUIRES` is unparsed prose naming native CLIs); `resolve` is flat.
5. **Validation:** **zero test tooling** on workponents; powered engines not integrated; no gate proving an engine is themed/scoped/WASM-correct; no eval proving the agent *uses* components; git-viz correctness unproven.
6. **Self-editing formats:** no docx/pptx/3D ↔ workponents path.

---

## The unified architecture

### 1. The toolkit graph (the substrate everything sits on)
- **workponents is a *library/capability* toolkit** — it provides rendering primitives, not agent actions; it's the **stdlib of the UI layer**: foundational, depended-upon, ambient. The desktop app and the Waldo agent are **top-of-DAG subscribers**.
- **Reshape workponents** from the no-op `#+KIND: web-components` into: a **static-asset core** (tokens + base elements that just drop into HTML — no EXEC needed, shipped as `dist/`) + **per-domain `#+EXEC: component` toolkits** (the compute elements like `work-table` over the VFS, with `#+CAPS: vfs`). workponents becomes a **multi-node sub-graph**, not one node.
- **Wire the dependency graph (~30–40 lines, one chokepoint):** promote `#+REQUIRES` to a typed, toolkit-aware edge (parsed in `toolkits.ex:504 parse_descriptor`); compute a **transitive closure at subscription time** (`resolve/2:71` + `injection_text/2:141`), dedup, flatten to the prompt index. Cycle-detect (it's a DAG). Keep native-CLI requires as a separate non-graph pre-flight class (don't break the 10 existing manifests).
- **Caps stay grant-gated.** A dependency edge changes *discovery/closure*, never *enforcement* — a dep can't silently widen powers; composition (`commands` cap) runs the callee in **its own isolated instance under its own profile** (host-brokered flat forest, no wasm-in-wasm). Third-party dep edges ride the existing `#+SIGNATURE`/`#+AUTHOR_DID` gate.
- **"Author your own workponents" = publish a signed `#+EXEC: component` toolkit others `REQUIRES`.**

### 2. The agent ↔ component render contract (text + voice)
- **Collapse to ONE implementation — the `work-*` elements. Delete the Svelte twins.** The duplicate parsers/components fold into the toolkit's `ai/markdown.js` + `work-message`/`work-gen-block`.
- **Keep the `#+RENDER: org` + `#+begin_src component :type …` syntax** — already taught, streaming-stable (marker on line 1), sandboxed (structured props, never `{@html}` of model output), and it IS the conversation-as-source model. Change the *renderer*, not the syntax.
- **Rebuild the chat surface from the elements:** the chat panel becomes `<work-thread>` fed the conversation-as-source string (`* user`/`* assistant` headings — `parseTranscript` already understands it); composer → `<work-composer>`; turns → `work-message` → component blocks → `work-gen-block`. The desktop becomes a **thin host**: map `session:<id>` telemetry → conversation-as-source → `work-thread`; listen for `work-intent`. **Efficiency:** per-element identity means a streamed `llm_delta` patches one `work-message`, not a full-thread re-walk.
- **Discovered catalog:** replace the hardcoded `web.ex:1881` string with the **`component` index from component-KIND toolkits** (`injection_text` emits the `:type` tags + prop schema, sourced from the **CEM `custom-elements.json`**). An agent's `:TOOLKITS:` declares which component toolkits it gets → that's the registration.
- **Close the loop:** standardize on `work-intent` (bubbles+composed); `work-thread` forwards it to the session → POST back as a follow-up turn → the agent re-enters the loop on a button/share press.
- **Voice parity:** give the voice session the **same emit channel** onto the shared `session:<id>` topic (a `write_code`-sibling that emits a component block / `component_artifact`). Fold `VoiceBubble` into the `ChatBlock`/`work-message` model. Spoken reply stays one sentence; the visual lands in the thread as a `work-gen-block`. Voice becomes just another turn source feeding `work-thread`.

### 3. Theming as a first-class construct
- **Keep `--wb-*` as the canonical contract** (do NOT rename to `--work-*` — high blast radius, zero gain; the deferred decision was correct). Solve cohesion by **derivation, not unification**: ship `workponents/src/theme/bridge.css` mapping `--wb-*: var(--color-*, <fallback>)` so the desktop's existing `--color-*` registry drives `work-*` elements with **zero desktop churn**. Canon: **`--wb-*` is the contract; `--color-*` is the host alias** (one direction).
- **Promote the existing Rust theme registry into a shared, serializable artifact** keyed on `wb-*` names (the 3 CSS presets become seeded built-ins generated *from* the registry). Add `workponents/src/theme/registry.js` (`registerTheme`/`applyTheme`/`listThemes`) — the browser/artifact-side runtime workponents is missing.
- **Per-workspace/brand themes:** each demo brand becomes a registry entry keyed by workspace id; extend the `workbook-spec` marker with `"theme": "<id>"` → artifacts `applyTheme(spec.theme)` on hydrate instead of hardcoding palettes.
- **Design-lint** (`workponents/src/validate/design-lint.js`, reuses the `{valid,errors:[{path,rule,message}]}` shape): off-token color (literal hex in `static styles`), off-system value (radius/space/font not from tokens), unknown token (typo guard), variant conformance (folds in `lintVariants`), **contrast/a11y** (WCAG per theme). Runs as a CLI gate + in-demo overlay.
- **Agent theme-awareness:** emit `workponents/theme-contract.json` (token names + roles + variant enums + active theme) — the single source the design-lint AND the agent read; add a **theming skill** ("generate UI only from `--wb-*`; never raw hex; pick variants from the declared enums; set the artifact's `workbook-spec.theme`; run design-lint before done").

### 4. Validation & assurance (the "built-in systems" you asked for)
- **The powered-engine ship-gate** — `workponents/tools/gate/`, ONE **Playwright headless** harness (NOT per-agent chrome-devtools — that's the contention source that killed the sweep agents). Writes verdict JSON. Five gates, no engine ships behind a `work-*` element until all pass:
  - **(a) token-leak audit** — static CSS lint + runtime computed-style sweep across all 3 themes + a theme-flip-delta (an engine that looks identical light/dark ignores tokens → fail).
  - **(b) scope isolation** — mount under a hostile global stylesheet; assert unaffected; assert no `document.head` pollution (catches MapLibre/CodeMirror's default global injection → forces shadow-scoped).
  - **(c) WASM/floor loadability** — no native dep; lazy-load proof (floor renders with the engine chunk network-blocked); loads in the embedded-workbook offline context; MapLibre tiles via `this.host` broker, never a CDN.
  - **(d) functional parity vs the floor** — the floor is the oracle (same series/rows/domain; search recall ≥ floor; editor value round-trip).
  - **(e) one serialized visual baseline** — the single contended resource, sequential; replaces ad-hoc agent screenshotting. The demo pages double as the baseline corpus.
- **Git-viz correctness** (critical finding: the backend emits **full-file `{before,after}`, NOT a semantic diff** — the semantic org-block diff lives **entirely in `work-diff`**, so it's pure-frontend unit-testable):
  - `work-history-graph`: frozen backend fixtures (`history.ex` shape: `{id,when,author_type,author_name,title}`, newest-first) → assert node order, **human/agent attribution 1:1**, no drop/coalesce, linear-when-input-linear (don't draw fictional merges).
  - `work-diff`: golden `(before,after,expected_ops)` table + **property/conservation invariants** (every block accounted for; `diff(x,x)`=all-eq; applying ops reconstructs `after`) — catches silent corruption. One live backend-parity smoke.
- **Agent-use evals** — new pack `runtime/evals/components/`, reuses the wavelet spec/judge format. Adversarial one-liner cases (`"show me revenue by region"` → must emit `work-chart`, not a markdown table; `work-table` for records; `work-diff` for "what changed"; theme-honest; data-binding-not-fabricated). Judge rubric: component_selection / emit_correctness / data_binding / theme_compliance (delegates to Gate-a) / render_fidelity (vision) / restraint. **Voice parity** via the rehearsal harness (no key needed): same cases, assert text and voice reach the *same* component decision (`voice.component_parity`). **Standing CI gate**, cheap (no paid media), no `MAX_STEPS`.
- **Dogfooding loop:** mounting `work-*` in the desktop chat makes the product itself the canary; demos are the visual-baseline corpus; every observed failure converts into a new fixture (git-viz) or eval case (agent-use).

### 5. Self-editing real document formats
Rule: **floor-JS where a clean lib exists · WASM-lane (pallet) for heavy/source-as-text kernels · Host-broker only for creation · never native exec.**
- **docx (do first):** pandoc.wasm is **already in the pallet** (max-fidelity, invoke-over-Dock — GPL stays a tool, never linked); `mammoth.js`+`turndown` (read) / `docx` (write) are floor libs. Round-trips into the existing **`work-doc`** + OQL kernel. One new build: a `doc.export` Host verb. **No new domain.**
- **pptx:** write trivial (PptxGenJS); the **one genuinely novel piece** is a **pptx→org emitter** (no off-the-shelf exists — pandoc has no pptx reader) on `aiden0z/pptx-renderer`. Payoff: **slides→video for free** via wavelet (`work-deck` = keyframe timeline) — ship that wiring before the read emitter.
- **3D (new `work-3d` domain):** `<model-viewer>` (floor viewer, lazy-loaded like wavelet's `runtime-src`), three.js sibling (STL/OBJ + gizmo edit), **Manifold wasm as source-text→GLB** (the composition-as-source moment for 3D), Host-brokered Meshy/Tripo for generation. Defer USDZ-in-viewport.

---

## The sequenced roadmap

**Phase 0 — Foundation (unlocks everything).**
- Reshape workponents into static-asset core + per-domain `#+EXEC: component` toolkits.
- Wire the toolkit dependency graph (`REQUIRES` → typed edge + transitive closure; ~30–40 lines).
- Emit the **CEM `custom-elements.json`** — the machine-readable catalog the discovery, theme-contract, and evals all consume.

**Phase 1 — The spine + dogfood + theming.**
- Collapse the chat to `work-*` (delete the Svelte twins), discovered catalog (replace the hardcoded string), close the `work-intent` loop, rebuild the chat surface from `work-thread`/`work-composer`.
- Theming construct: `bridge.css`, promote the registry to shared data, `theme-contract.json`, the design-lint, the theming skill.

**Phase 2 — Assurance (make it provable).**
- The 5-gate Playwright harness + workponents CI.
- Git-viz fixtures + golden/property tests.
- The component-emit eval pack (text + voice rehearsal parity) + CI gate.

**Phase 3 — Powered engines (behind the now-existing gate).**
- Swap Observable Plot/uPlot (data-viz), MapLibre+PMTiles (maps), CodeMirror (code), MiniSearch (search), Standard Schema (forms) — each must pass the 5-gate before shipping.
- ElementInternals/Form-Associated Custom Elements for `forms`. Shoelace/Web Awesome for any generic primitives.

**Phase 4 — Self-editing formats.**
- 4a docx (`doc.export` + import adapter → `work-doc`). 4b pptx + slides→video via wavelet, then the pptx→org emitter. 4c the `work-3d` domain.

**Phase 5 — Distribution.**
- The shadcn-style copy-in themed registry (CEM already emitted in Phase 0 feeds it). VS Code `html.customData` for autocomplete.

---

## What's genuinely NEW to build (the short list)
1. The **toolkit dependency-graph** resolution (~30–40 lines).
2. The **5-gate validation harness** (Playwright) + the **component-emit eval pack**.
3. The **theming construct** runtime (registry.js, bridge.css, design-lint, theme-contract).
4. The **pptx→org emitter** and the **`work-3d` domain**.

Everything else is wiring, de-duplication, discovery, and config — over seams that already ship.

## Open decisions for the user
- **Token rename:** recommendation is to KEEP `--wb-*` (bridge `--color-*`); confirm or override.
- **Phase 0 vs Phase 1 first:** Phase 0 (toolkit graph) is the architectural unlock but invisible; Phase 1 (dogfood the chat) is the visible win. Can run in parallel; which leads?
- **Powered-engine priority order** within Phase 3 (data-viz/Plot likely first — highest visible payoff).
