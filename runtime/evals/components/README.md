# Component-emit eval pack

Phase 2 (assurance) of `docs/WORKPONENTS-AGENT-INTEGRATION.md` — the standing
gate that the agent (**text AND voice**) reaches for the right `work-*`
component on the fly, from a discovered catalog (the CEM,
`workponents/custom-elements.json`, 42 tags).

Reuses the wavelet eval shape (`runtime/wavelet/evals/`): YAML frontmatter +
`checks[]` + an inline markdown rubric the vision judge scores. The runner is
**not** a new harness — it lives in the BEAM (`Workbooks.Evals.Components`) and
reuses `Workbooks.Agent.run` (the agent), `Workbooks.Llm.complete` (the judge
brain), and `Workbooks.Browse.Headless` (the mount screenshot).

## What's under test

The agent's **emitted component artifact**: a `#+RENDER: org` message carrying
`#+begin_src component :type …` blocks, and/or HTML mounting `work-*` elements
(see `desktop/docs/waldo-inchat-components.md` + `runtime/host/web.ex`
`agent_system_prompt`). Each case is an adversarial one-liner — a MINIMAL brief
so the agent must discover the right element, not be told.

## Pipeline (per case)

1. Parse the spec (`specs/<case>.eval.md`).
2. Run the **text agent** on the one-liner → its emitted message.
3. Extract the component block → `{tag, props, body, raw}`.
4. **Deterministic checks**: `component.emits_tag` (right tag, no forbidden),
   `component.binds_data` (data via the prop/host seam, supplied values
   round-trip), `component.themes_from_tokens` (no literal hex/rgb),
   `voice.component_parity` (the rehearsed VOICE path picks the SAME tag —
   divergence fails; no ElevenLabs/Inworld key needed).
5. **Mount + screenshot**: write a self-contained mount page (the `--work-*`
   token sheet for one theme + the emitted block), shoot it light + dark via
   headless Chrome (`Workbooks.Browse.Headless.screenshot/3`). The real
   workponents elements load from `src/elements/index.js` when present;
   otherwise a token-themed stub card renders the chosen tag + bound data so the
   frame is non-blank and theme-honest without the built bundle.
6. **Vision judge**: attach both frames + the emitted source to the rubric
   (`rubric.passes`); score the six dimensions; PASS = every dim ≥ 2 AND sum ≥
   14/18.

## Cases (`specs/`)

| case | one-liner | must emit | not |
|------|-----------|-----------|-----|
| `chart-not-table`  | show me revenue by region        | `work-chart`         | markdown table |
| `table-not-chart`  | list the open invoices w/ status | `work-table`         | chart |
| `metric-vs-chart`  | what's our MRR right now         | `work-metric`/`-spark` | full chart |
| `diff-render`      | what changed in the home page    | `work-diff`          | raw git text |
| `history-render`   | show the version history         | `work-history-graph` | bullet list |
| `theme-honest`     | (any) — gates theme honesty      | token-driven art     | hardcoded colors |
| `data-binding`     | revenue + attached data          | bound supplied data  | fabricated numbers |

Rubric dimensions (`judge.md`): component_selection / emit_correctness /
data_binding / theme_compliance / render_fidelity (vision) / restraint.

## Running

```bash
cd runtime
./evals/components/bin/eval-run chart-not-table   # one case
./evals/components/bin/eval-run                    # whole pack
# or: mix run --no-start -e 'IO.puts(Workbooks.Evals.Components.run("chart-not-table"))'
```

Outputs land under `runs/<case>-<ts>/` (gitignored): `emit.org`,
`mount.{light,dark}.png`, `mount.{light,dark}.html`, `verdict.md`.

### A live run needs

- **`OPENROUTER_API_KEY`** (or `WB_LLM_KEY`) + **`WB_EVAL_MODEL`** (default
  `xiaomi/mimo-v2.5`) — for the agent, the voice-parity agent, and the vision
  judge. Without a key the pack SKIPS (deterministic-only via `stub_emit:`).
- **A local headless Chrome** (`WB_CHROME_BIN` / system Chrome / puppeteer
  cache) — for the mount frames. Without it the judge scores from source only.
- **The built workponents bundle** (`workponents/src/elements` resolvable, or a
  built `dist/`) for the frames to render REAL elements; otherwise the stub card
  renders (render_fidelity will reflect that — the agent's CHOICE is still
  scored from the source + the deterministic checks).

CI: `.github/workflows/component-evals.yml` (per-PR on `workponents/` + agent
defs/skills; installs Chrome; no paid media; no MAX_STEPS).
