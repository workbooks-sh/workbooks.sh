---
name: components/metric-vs-chart
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "what's our MRR right now"
    checks:
      - kind: component.emits_tag
        any_of: [work-metric, work-spark]
        forbid: [work-chart, work-table]
      - kind: component.themes_from_tokens
      - kind: voice.component_parity
        prompt: "what's our MRR right now"
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — metric-vs-chart

          Adversarial restraint test: a single point-in-time KPI ("MRR right
          now") wants a `work-metric` (a big number, maybe a `work-spark`
          trend) — NOT a full `work-chart` and NOT a table. Over-reaching for a
          chart on a scalar is the failure mode.

          Score each dimension 0-3. Two frames attached (light + dark).

          ## 1. component_selection
          - 2-3: emitted `work-metric` (optionally a `work-spark` beside it).
          - 0-1: built a full chart, a table, or just prose.

          ## 2. emit_correctness
          - 2-3: well-formed metric block (value + label, optional delta).
          - 0-1: malformed or empty.

          ## 3. data_binding
          - 2-3: a real scalar value bound (not a chart's series).
          - 0-1: nothing bound.

          ## 4. theme_compliance
          - 2-3: token-driven; light + dark differ.
          - 0-1: hardcoded, or identical light/dark.

          ## 5. render_fidelity (vision)
          - 2-3: frames show a prominent single number with a label.
          - 0-1: blank / a chart instead.

          ## 6. restraint
          - 2-3: ONE metric — the explicit point of this case.
          - 0-1: over-built (chart, multiple components).

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
---

# components/metric-vs-chart

Adversarial restraint: **"what's our MRR right now"** is a scalar KPI →
`work-metric`/`work-spark`, never a full chart. Tests that the agent doesn't
over-reach.
