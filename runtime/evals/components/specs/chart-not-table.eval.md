---
name: components/chart-not-table
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "show me revenue by region"
    checks:
      - kind: component.emits_tag
        any_of: [work-chart]
        forbid: [work-table, markdown-table]
      - kind: component.binds_data
        # numeric series must be present (rows/csv/query), not prose fabrication
        expect: numeric_series
      - kind: component.themes_from_tokens
        # rendered artifact draws from --work-* — no hardcoded hex / rgb literals
      - kind: voice.component_parity
        prompt: "show me revenue by region"
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          # the agent's emitted component block is mounted headless and shot
          # in BOTH themes; the frames are the primary evidence for render_fidelity.
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — chart-not-table

          Adversarial: the brief is a numeric series over a categorical
          dimension ("revenue by region"). The ONLY correct reach is a CHART,
          not a markdown table and not raw numbers in prose.

          Score each dimension 0-3. Two frames are attached — the emitted
          component mounted light + dark. They are the primary evidence for
          `render_fidelity` and `theme_compliance`.

          ## 1. component_selection
          - 2-3: emitted a `work-chart` (bar/line/area) block via the
            `#+begin_src component :type …` contract or a `work-chart` element.
          - 0-1: answered with a markdown table, a bullet list, or prose numbers.

          ## 2. emit_correctness
          - 2-3: the block is well-formed — a parseable `:type chart` (or
            `work-chart`) with x = region, y = revenue, sensible variant.
          - 0-1: malformed block, missing axes, or `{@html}` of model output.

          ## 3. data_binding
          - 2-3: numeric series carried in the block (rows/csv/query/data prop),
            bound through the prop/host seam.
          - 0-1: fabricated numbers in prose, or no data at all.

          ## 4. theme_compliance
          - 2-3: no hardcoded colors; light + dark frames clearly differ
            (the artifact reads --work-* tokens).
          - 0-1: literal hex/rgb in the artifact, OR light and dark look
            identical (ignores tokens).

          ## 5. render_fidelity (vision)
          - 2-3: the attached frames show a readable chart with axes and marks.
          - 0-1: blank / broken / unrecognizable.

          ## 6. restraint
          - 2-3: one chart, no decorative extras, concise prose around it.
          - 0-1: over-built (multiple components, walls of prose).

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
---

# components/chart-not-table

Adversarial one-liner: **"show me revenue by region"**. A numeric series over a
categorical dimension — the agent must reach for `work-chart`, NOT a markdown
table. Minimal brief by design: the agent discovers the right element from the
catalog (the CEM, 42 tags). The emitted component block is mounted headless and
screenshotted light + dark; frames feed the vision judge. Voice parity asserts
the rehearsed voice path picks the same element.
