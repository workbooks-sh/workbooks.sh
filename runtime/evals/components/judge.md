# component-emit eval rubric

The shared rubric for `runtime/evals/components/`. Each spec carries its own
adversarial `rubric:` block (the one the vision judge actually scores); this
file is the canon those blocks instantiate — the six dimensions, the scoring
band, and the PASS threshold. Mirrors `runtime/wavelet/evals/judge.md`.

The artifact under test is the agent's **emitted component block** — a
`#+RENDER: org` message carrying `#+begin_src component :type …` blocks, and/or
HTML mounting `work-*` elements (catalog = the CEM `workponents/custom-elements.json`,
42 tags). The harness mounts that block headless, screenshots it light + dark,
and attaches the two frames to the judge.

Score each dimension 0-3:

- **0** — not attempted / wrong shape
- **1** — partial / trying but wrong
- **2** — works, a reviewer would note issues
- **3** — clean, indistinguishable from a careful human

## Dimensions

### 1. component_selection (0-3)
Did the agent reach for the RIGHT `work-*` element for the question?
- numeric series → `work-chart`; records → `work-table`; scalar KPI →
  `work-metric`/`work-spark`; "what changed" → `work-diff`; "version history"
  → `work-history-graph`.
- 0-1: a markdown table where a chart was wanted, prose numbers, raw git text,
  a bullet list, or the wrong element.

### 2. emit_correctness (0-3)
Is the emitted block well-formed against the contract?
- A parseable `#+begin_src component :type <t> …` block (or a `work-*` element)
  with the structural attributes the type needs (chart: x/y; table: columns;
  metric: value/label; diff: before/after; history: ordered revisions).
- 0-1: malformed block, missing structure, or `{@html}` of model output.

### 3. data_binding (0-3)
Is the data bound through the prop/host seam — not fabricated in prose?
- 2-3: rows/csv/query/data carried in the block; when the prompt supplies data,
  THAT data round-trips (no invented numbers).
- 0-1: numbers fabricated in prose, values dropped, or nothing bound.

### 4. theme_compliance (0-3)
Does the rendered artifact derive color from `--work-*` tokens?
Delegates to the `component.themes_from_tokens` check (static literal-color
scan) + the vision evidence that the light and dark frames DIFFER.
- 2-3: no literal hex/rgb/hsl in the artifact; light + dark frames differ.
- 0-1: literal colors in the artifact, OR light == dark (ignores tokens).

### 5. render_fidelity (0-3)  — vision
Open the two attached frames. Does the mounted component look like what the
question asked for, in both themes?
- 2-3: readable, recognizable as the right element, legible in light AND dark.
- 0-1: blank / broken / unrecognizable / illegible in one theme.

### 6. restraint (0-3)
Did the agent emit the MINIMUM that answers the question?
- 2-3: one well-chosen component, concise prose around it.
- 0-1: over-built (several components, walls of prose, decorative noise) or
  under-built (prose when a component was the answer).

## Threshold

PASS overall ONLY IF **every dimension >= 2 AND sum >= 14 / 18**. A
spec may additionally pin a dimension (e.g. theme-honest pins
theme_compliance >= 2, data-binding pins data_binding >= 2).

The rubric is a diagnostic, not a leaderboard — the low dimension names the
next thing to fix in the agent prompt, the catalog injection, or the element.

## Voice parity

`voice.component_parity` runs the SAME prompt through the rehearsed VOICE path
(one-sentence spoken reply + a component-artifact emit, no ElevenLabs/Inworld
key needed) and asserts the voice agent's chosen `work-*` tag MATCHES the text
agent's choice. Divergence = fail: text and voice are the same brain reaching
for the same catalog, so they must converge on the same element.

## Where to look

```bash
# run one case end-to-end (agent + mount + judge)
runtime/evals/components/bin/eval-run chart-not-table

# the emitted block + the two mount frames land under
runtime/evals/components/runs/<case>-<ts>/{emit.org,mount.light.png,mount.dark.png,verdict.md}
```
