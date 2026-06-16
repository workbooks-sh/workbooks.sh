# workponents · the 5-gate validation harness

ONE Playwright headless-Chromium process, sequential per element. No powered
engine ships behind a `work-*` element until all five gates pass. This is the
non-contended replacement for ad-hoc agent screenshotting (it drives its OWN
browser — never the shared chrome-devtools MCP).

```
npm run gate              # all 42 elements → .gate/<element>.json verdicts
npm run gate work-diff    # a subset
npm run gate:all          # --strict: exit 1 if ANY element verdict is pass:false (CI)
npm run gate:baseline     # (re)write the visual baselines (.gate/baseline/*.png)
npm run test:gitviz       # git-viz correctness (work-diff golden+property, history-graph DOM)
```

## Verdict shape — `.gate/<element>.json`

```json
{
  "element": "work-diff",
  "domain": "git",
  "gates": { "tokens": false, "scope": true, "wasm": true, "functional": true, "visual": true },
  "pass": false,
  "leaks": [ { "gate": "tokens", "rule": "off-token-color", "path": "…", "message": "…" } ],
  "notes": [ "tokens: paints (L=485 D=485), flip=true", "pure-floor — static scan only", … ]
}
```
`.gate/summary.json` aggregates pass/fail counts, total leaks, page errors, and
barrel-load errors.

## The five gates

| gate | what it proves | how |
| --- | --- | --- |
| **tokens** | styles only from `--work-*` | static design-lint (reuses `tools/design-lint.mjs`'s `src/validate/design-lint.js`) **+** a runtime computed-style sweep across light/dark/signal **+** a theme-flip-delta (an element that paints identically light-vs-dark ignores the tokens → fail; pure-layout/slot elements with no paint are exempt) |
| **scope** | shadow DOM isolates it | mount under a hostile host-page stylesheet (`button{}`, `div{}`, `table{}`, `.frame{}`, …) and assert shadow-descendant paint is unchanged; assert no unscoped `<style>` was injected into `document.head`. (Inherited `color`/`font` cascade through the shadow boundary by spec, so the host node itself and a `*!important` color override are deliberately not weaponized.) |
| **wasm** | no native dep, floor-loadable | static import-graph scan (no `node:*` built-in, no load-time CDN import) + for powered seams, the floor must still render with the engine chunk network-blocked (Playwright `route.abort`) |
| **functional** | engine output == floor output | the parity framework (oracle = floor). No-op until P3 registers an engine — see below |
| **visual** | render matches the baseline | element × {light,dark,signal} × key variants → PNG; perceptual diff (sharp, ≤6% pixels) vs the committed `.gate/baseline/` |

## Plugging a powered engine into the parity gate at P3

When P3 swaps a powered engine behind a `work-*` element:

1. Register the **load seam** in `gates.js → POWERED_SEAMS`:
   ```js
   "work-map": { enginePattern: /maplibre/i, floorMustRender: ".frame" }
   ```
   The `wasm` gate then route-aborts `enginePattern` and asserts `floorMustRender`
   still appears (the floor degrades gracefully with the engine offline).

2. Register the **parity fixture** in `gates.js → PARITY_FIXTURES`:
   ```js
   "work-chart": {
     oracle:    (page) => page.evaluate(() => /* canonical model off the FLOOR render */),
     candidate: (page) => page.evaluate(() => /* SAME model off the powered render */),
     compare:   (a, b) => ({ equal: deepEqual(a, b), notes: "" }),
   }
   ```
   The model is the *logical* output — series/rows/domain/labels — NOT pixels
   (pixels are the visual gate). The floor is the oracle: same data in, same data
   out, regardless of which engine drew it.

Until a fixture is registered, `functional` is a documented structural pass
("no powered engine — floor is the only impl").

## Disk / Playwright setup (worktree-safe)

- `workponents/node_modules` is a **symlink** to the shared `desktop/node_modules`
  (one tree across all worktrees — never `bun install` per worktree). `playwright`
  + `sharp` + `lit` live in that shared tree.
- The Chromium binary lives in `~/.cache/ms-playwright` (shared across worktrees;
  installed once via `npx playwright install chromium`).
- The harness runs **offline**: `tools/gate/server.js` serves the workponents tree
  and maps every `lit` / `lit/directives/*` import onto one self-contained bundle
  (`tools/gate/vendor/lit-all.js`, a single shared lit-html instance). No CDN.
- CI (`.github/workflows/workponents-gate.yml`) has no shared tree, so it installs
  the deps and regenerates the lit bundle (esbuild) per run.
