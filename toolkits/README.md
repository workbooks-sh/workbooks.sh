# toolkits — the catalog

A toolkit is a capability an agent (or a developer) can pull in: commands plus
org **skills** (progressive-disclosure docs), authored to one standard. Each
folder has a `manifest.org` (the front door — `:toolkit:` node, skill index)
and a `skills/` tree; asset/engine toolkits also ship `dist/`, a `specimen`,
and a `test`. The format and depth bar live in **[AUTHORING.org](AUTHORING.org)**
(runtime contract: `../runtime/docs/TOOLKITS-V3.org`).

Two audiences, one format: a markdown twin under `skills/workbooks-system/`
(repo root) addresses OS-capable harnesses; these org toolkits address an agent
running **inside** the WASM runtime (one shell, WASM-only, host-brokered caps).

---

## Authoring & content

| toolkit | what it is | status |
|---|---|---|
| **[orgitorial](orgitorial/)** | org-mode blogging/CMS — a zero-dep org→HTML renderer + editorial CSS library + interactive blocks (`:app` mini-apps, mermaid, `:width` breakouts). Plain HTML, no framework. | experimental |
| **[presentation](presentation/)** | ask for a presentation, get reveal.js — slide nav, per-slide URLs. Capability is "presentation"; impl swappable. | stable |
| **[video](video/)** + **[wavelet](wavelet/)** | author a motion-graphics scene → rendered clip (HyperFrames over the wavelet CLI). | beta / experimental |
| **[ctk](ctk/)** | a human-in-the-loop canvas — render any component with org-tangled controls; iterate states without building a UI. | experimental |

## Visual assets (SVG marks)

| toolkit | what it is | status |
|---|---|---|
| **[open-avatars](open-avatars/)** | one DiceBear-like API, many art styles — `avatar(pack, seed)` routes by pack type (assembled / gallery / procedural). Same seed → byte-identical avatar forever. Ships open-peeps, transhumans, pixabots, boring, jdenticon, minidenticons, pixitar. | experimental |
| **[glyphs](glyphs/)** | the unified SVG-mark resolver — `glyph('brand:google' \| 'icon:html5' \| 'avatar:open-peeps/wren' \| 'social:gh/user')`. Curated-local first, CDN fallback (svgl / simple-icons / lobehub / unavatar). Delegates avatars to open-avatars. | experimental |
| **[icons](icons/)** | the universal icon library as a CLI — `icons search/for-file/for-folder/get/grammar` over the one value grammar (`mi:<def>` material · `lobe:<slug>` brand · emoji · `data:` · initials) the desktop's `Icon.svelte` renders. What an agent writes renders unchanged. | experimental |

## System knowledge & meta

| toolkit | what it is | status |
|---|---|---|
| **[workbooks-system](workbooks-system/)** | what a workbook/runtime/toolkit/workflow is, the WASM-only rules, authoring + publishing from the agent's seat, and the product facts to get right when writing about Workbooks. | experimental |
| **[toolkit-forge](toolkit-forge/)** | forge a new toolkit from a target (npm / GitHub / a need) — research → study the real surface → author skills + manifest to the AUTHORING standard. | experimental |

## Capabilities — a CLI/crate as a WASM command

| toolkit | what it is | status |
|---|---|---|
| **[git](git/)** | distributed VC — recovery/rebase/undo recipes liftable verbatim. | stable |
| **[ffmpeg](ffmpeg/)** | image + audio + video at parity — resize/crop/convert/overlay; transcode/trim/concat. | stable |
| **[wraith](wraith/)** | Rust + TS/JS codebase analyzer — dead code, unused deps, cycles, complexity. | stable |
| **[palette](palette/)** | the WASM build/runtime palette — language runtimes & compilers as pinned sandboxed commands. | experimental |
| **[mono](mono/)** | RGBA → grayscale — the first deployed kernel-shape toolkit (bytes→bytes hot loop). | experimental |

## Ship a forged workbook (the user's own account)

| toolkit | target | status |
|---|---|---|
| **[wrangler](wrangler/)** / **[cloudflare](cloudflare/)** | Cloudflare Pages / D1 + Workers AI | experimental |
| **[railway](railway/)** | Railway static site | experimental |
| **[byod](byod/)** | a real multi-tenant app (live DB + auth, no engine) | experimental |
| **[tauri](tauri/)** / **[capacitor](capacitor/)** | native desktop / native iOS (TestFlight) | experimental |
| **[fly](fly/)** | fly deploy | — |

## Federation & external services

| toolkit | what it is | status |
|---|---|---|
| **[linear](linear/)** / **[asana](asana/)** | mirror a project into org `:task:` nodes; query + (gated) write-back. | experimental |
| **[publish](publish/)** | AT Protocol publishing + Workbooks Network identity — bind Bluesky, publish signed workbooks. | stable |
| **[brandnana](brandnana/)** | ad + brand intelligence — identity, ads, catalog, design tokens, brand-book composition. | experimental |
| **[3w](3w/)** | local-first deep-research browser — keyless search, clean reads, crawl into a context repository. | experimental |

---

## Conventions (what every toolkit shares)

- **`manifest.org`** — header block (`#+TITLE/#+TOOLKIT/#+VERSION/#+KIND/#+STATUS/#+TAGLINE/#+FLOW`), a `:toolkit:`-tagged front-door node with a `:PROPERTIES:` drawer, and a skill-index table.
- **`skills/*.org`** — one concern per file, terse + imperative, *why* explained; opens with "When to use this". Loaded by need, not all at once (progressive disclosure).
- **asset/engine toolkits** also ship `dist/<name>.{js,css}` (zero-dep, tri-modal: browser / Node / QuickJS-wasm), a self-contained `specimen.html` proof page, and a `test/`.
- **honesty** — `LICENSES.md` where third-party assets are bundled; skills name their gaps; nothing native-exec reachable from an in-runtime agent.

**Composition is the point.** bit.ml (an example app) uses *orgitorial* to render stories, *open-avatars*/*glyphs* for its crew faces and inline brand marks — three toolkits, one site. Add a capability by adding a toolkit, not by forking an app.
