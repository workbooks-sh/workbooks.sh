---
name: components/data-binding
agent: waldo
timeoutMs: 600000
turns:
  - prompt: |
      Show me revenue by region. Use this data exactly:
      region,revenue
      North,42000
      South,31500
      East,28800
      West,51200
    checks:
      - kind: component.emits_tag
        any_of: [work-chart]
        forbid: [work-table, markdown-table]
      - kind: component.binds_data
        expect: numeric_series
        # the four supplied values must round-trip into the block, NOT be
        # replaced by invented numbers.
        contains_values: ["42000", "31500", "28800", "51200"]
      - kind: component.themes_from_tokens
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — data-binding

          The prompt carries DATA. The artifact must bind THAT data through the
          prop/host seam (rows/csv/data) — fabricating different inline numbers
          is the failure mode this case catches.

          Score each dimension 0-3. Two frames attached (light + dark).

          ## 1. component_selection
          - 2-3: a `work-chart` for the supplied series.
          - 0-1: a table or prose.

          ## 2. emit_correctness
          - 2-3: well-formed chart with x = region, y = revenue.
          - 0-1: malformed.

          ## 3. data_binding  ← the point of this case
          - 3: ALL FOUR supplied values (42000/31500/28800/51200) present in
            the block, bound via rows/csv/data.
          - 2: most values present, bound through the seam.
          - 0-1: invented numbers, or values dropped.

          ## 4. theme_compliance
          - 2-3: token-driven; light + dark differ.
          - 0-1: hardcoded, or identical.

          ## 5. render_fidelity (vision)
          - 2-3: four bars/points roughly proportional to the data.
          - 0-1: blank / wrong shape.

          ## 6. restraint
          - 2-3: one chart.
          - 0-1: over-built.

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
          data_binding MUST be >= 2.
---

# components/data-binding

Revenue prompt WITH attached data. The agent must bind the supplied series via
the prop/host seam (rows/csv/data) — not fabricate inline numbers. The
`component.binds_data` check asserts all four supplied values round-trip into
the emitted block.
