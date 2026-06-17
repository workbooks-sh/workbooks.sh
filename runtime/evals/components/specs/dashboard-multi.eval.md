---
name: components/dashboard-multi
agent: waldo
timeoutMs: 600000
turns:
  - prompt: |
      Build me a sales overview: total revenue as a KPI, revenue by region
      as a chart, and the top deals as a table.
    checks:
      - kind: component.emits_tag
        # HARNESS LIMITATION: emits_tag + extract_component only inspect the
        # FIRST/PRIMARY component in the emit (a single {tag, props, body}). A
        # genuine multi-component layout can't be asserted tag-by-tag by the
        # deterministic check, so we assert the PRIMARY element is a legitimate
        # dashboard component (metric/chart/table — NOT prose or a markdown
        # table). The rubric (reading the whole emit + both frames) scores
        # whether all three coherent components are present and well-composed.
        any_of: [work-metric, work-chart, work-table, work-spark]
        forbid: [markdown-table]
      - kind: component.binds_data
        # whichever component leads, it must carry a numeric series / values,
        # not fabricate the dashboard in prose.
        expect: numeric_series
      - kind: component.themes_from_tokens
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — dashboard-multi

          Adversarial: an IMPERATIVE multi-part brief ("a KPI, a chart, and a
          table"). The tempting WRONG answer is a single markdown table dumping
          all three, or a wall of prose. The correct reach is a COHERENT
          MULTI-COMPONENT layout: a `work-metric` (total revenue KPI), a
          `work-chart` (revenue by region), and a `work-table` (top deals) — each
          the right element for its data shape, composed together, none of them
          decorative filler.

          The rubric (not the deterministic check) is the authority on the
          multi-component requirement — it reads the FULL emitted message plus
          both rendered frames. Score each dimension 0-3.

          ## 1. component_selection
          - 2-3: all three intended elements present and correctly typed —
            metric→KPI, chart→by-region series, table→top deals.
          - 0-1: collapsed into one markdown table, prose, or only one component.

          ## 2. emit_correctness
          - 2-3: every element is well-formed (parseable `work-*` HTML),
            with sensible props for its shape.
          - 0-1: any malformed block, or `{@html}` of model output.

          ## 3. data_binding
          - 2-3: each component carries its own data via the prop/host seam
            (the KPI a scalar+delta, the chart a series, the table rows).
          - 0-1: numbers fabricated in prose, or data dropped.

          ## 4. theme_compliance
          - 2-3: no hardcoded colors anywhere; light + dark frames clearly
            differ (every artifact reads --work-* tokens).
          - 0-1: literal hex/rgb, OR light and dark look identical.

          ## 5. render_fidelity (vision)
          - 2-3: the frames show a readable, laid-out overview — a KPI tile, a
            chart, and a table reading as one cohesive surface.
          - 0-1: blank / broken / a single undifferentiated blob.

          ## 6. composition_restraint
          - 2-3: EXACTLY the three asked-for components, sensibly ordered
            (headline KPI first), minimal connective prose. Coherent, not
            over-built.
          - 0-1: extra decorative components, duplicated views of the same data,
            or walls of prose around them.

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
          composition_restraint AND component_selection MUST each be >= 2 —
          this case is specifically about composing several components coherently.
---

# components/dashboard-multi

Adversarial imperative brief: **"a KPI, a chart, and a table" sales overview**.
A coherent MULTI-component layout is required — `work-metric` + `work-chart` +
`work-table`, each the right element for its data shape. The tempting wrong
answer is a single markdown table or a prose dump.

**Harness note:** `component.emits_tag` / `extract_component` only inspect the
PRIMARY (first) component, so the deterministic check asserts the primary
element is a real dashboard component (not prose / not a markdown table). The
multi-component coherence + restraint judgement lives in the vision rubric,
which reads the whole emit and both mounted frames.
