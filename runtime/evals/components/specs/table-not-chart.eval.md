---
name: components/table-not-chart
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "list the open invoices with their status"
    checks:
      - kind: component.emits_tag
        any_of: [work-table]
        forbid: [work-chart]
      - kind: component.binds_data
        expect: rows
      - kind: component.themes_from_tokens
      - kind: voice.component_parity
        prompt: "list the open invoices with their status"
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — table-not-chart

          Adversarial inverse of chart-not-table: heterogeneous RECORDS with a
          status field ("open invoices with status") are tabular, NOT a chart.
          The correct reach is `work-table`.

          Score each dimension 0-3. Two frames attached (light + dark).

          ## 1. component_selection
          - 2-3: emitted a `work-table` block (multiple columns incl. status).
          - 0-1: drew a chart, or dumped prose.

          ## 2. emit_correctness
          - 2-3: well-formed table with named columns and rows.
          - 0-1: malformed, single-column, or no columns.

          ## 3. data_binding
          - 2-3: rows carried in the block / bound via the data seam.
          - 0-1: fabricated invoice rows in prose, or empty.

          ## 4. theme_compliance
          - 2-3: token-driven; light + dark frames differ.
          - 0-1: hardcoded colors, or identical light/dark.

          ## 5. render_fidelity (vision)
          - 2-3: frames show a readable table with a header row + status column.
          - 0-1: blank / broken.

          ## 6. restraint
          - 2-3: one table, concise framing.
          - 0-1: over-built.

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
---

# components/table-not-chart

Adversarial: **"list the open invoices with their status"** → records with a
status field are tabular. The agent must reach for `work-table`, not a chart.
