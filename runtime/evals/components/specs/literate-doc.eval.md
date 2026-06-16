---
name: components/literate-doc
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "Write a short Q3 summary with the revenue trend."
    checks:
      - kind: component.emits_tag
        # The layering from the composition model: org-as-CONTENT wrapped in a
        # narrative island (work-doc / work-org), WITH an embedded live viz
        # (work-chart / work-spark) for the trend. extract_component matches the
        # OUTERMOST element first, so the primary tag is the narrative container;
        # the embedded viz + prose are scored by the rubric over the full emit.
        any_of: [work-doc, work-org]
        forbid: [markdown-table]
      - kind: component.binds_data
        # the embedded trend viz must carry a numeric series, not prose numbers.
        expect: numeric_series
      - kind: component.themes_from_tokens
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — literate-doc

          Adversarial: the brief wants BOTH prose ("a short Q3 summary") AND a
          data viz ("the revenue trend"). This is the layering the composition
          model is built on — narrative org as CONTENT inside a `<work-doc>` /
          `<work-org>` island, WITH an embedded `<work-chart>` / `<work-spark>`
          for the trend. Two wrong answers to catch: (1) prose only, no real
          component for the trend (just words / a markdown table); (2) a bare
          chart with no narrative — ignoring the "short summary" half.

          The correct artifact LAYERS both: a doc/org container holding readable
          prose AND a real embedded trend component, all theme-honest. Score
          each dimension 0-3. Two frames attached (light + dark).

          ## 1. component_selection  ← the point of this case
          - 2-3: a narrative island (`work-doc` / `work-org`) that EMBEDS a real
            trend component (`work-chart` / `work-spark`). Both layers present.
          - 0-1: prose only (no component), a markdown table, OR a bare chart
            with no narrative.

          ## 2. emit_correctness
          - 2-3: well-formed — the doc/org carries prose, the embedded viz is a
            parseable `work-chart`/`work-spark` with a sensible time axis.
          - 0-1: malformed island, or `{@html}` of model output.

          ## 3. data_binding
          - 2-3: the embedded trend viz carries a numeric series (rows/csv/data)
            for Q3 — bound through the prop seam, not fabricated in prose.
          - 0-1: numbers only in prose, or no series at all.

          ## 4. theme_compliance
          - 2-3: no hardcoded colors; light + dark frames clearly differ (both
            the prose surface and the viz read --work-* tokens).
          - 0-1: literal hex/rgb, OR light and dark look identical.

          ## 5. render_fidelity (vision)
          - 2-3: the frames show readable prose AND a recognizable trend line/
            spark together as one document.
          - 0-1: blank / broken / only one of the two layers visible.

          ## 6. restraint
          - 2-3: ONE short summary + ONE embedded trend viz — concise, not a
            report. The "short" in the brief is honored.
          - 0-1: a wall of prose, multiple charts, or padding.

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
          component_selection MUST be >= 2 — both the narrative layer AND a real
          embedded viz are required; one without the other is a miss.
---

# components/literate-doc

Adversarial layering probe: **"write a short Q3 summary with the revenue
trend."** The correct reach is the composition model's core layering —
org-as-CONTENT inside a `<work-doc>` / `<work-org>` narrative island WITH an
embedded `<work-chart>` / `<work-spark>` for the trend (components-outer,
org-inner). The tempting wrong answers: prose only (no real component) or a bare
chart that ignores the "short summary" half.

**Harness note:** `extract_component` matches the OUTERMOST element first, so the
primary tag is the narrative container (`work-doc`/`work-org`); the embedded viz
and the prose are judged by the vision rubric over the full emit + both frames.
