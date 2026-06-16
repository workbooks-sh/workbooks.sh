---
name: components/sql-bound-table
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "Show our top 10 customers by revenue from the customers table."
    checks:
      - kind: component.emits_tag
        # A list of records FROM A TABLE → work-table, bound to a query/rows seam
        # against `customers`. Adversarial: "by revenue" tempts a chart, but the
        # ask is a ranked RECORD LIST ("top 10 customers"), not a categorical
        # series for plotting — fabricating a chart is the failure mode.
        any_of: [work-table, work-record-list]
        forbid: [work-chart, work-spark, markdown-table]
      - kind: component.binds_data
        # the table must pull from the data tier — a query against the
        # customers table (or rows) — not numbers fabricated in prose.
        expect: numeric_series
      - kind: component.themes_from_tokens
      - kind: voice.component_parity
        prompt: "Show our top 10 customers by revenue from the customers table."
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — sql-bound-table

          Adversarial: the brief names a SOURCE TABLE ("from the customers
          table") and asks for a RANKED RECORD LIST ("top 10 customers by
          revenue"). The only correct reach is a `work-table` bound to a
          query/rows seam against `customers`. Two wrong answers to catch:
          (1) reaching for a CHART because "by revenue" sounds plottable — but a
          top-N ranked list of named records is tabular, not a categorical
          series; (2) fabricating the ten customers in prose instead of binding
          a query/rows seam to the data tier.

          Score each dimension 0-3. Two frames attached (light + dark).

          ## 1. component_selection
          - 2-3: a `work-table` (or `work-record-list`) for the ranked records.
          - 0-1: a `work-chart`, a markdown table, or prose.

          ## 2. emit_correctness
          - 2-3: well-formed table — columns for customer + revenue (+ rank),
            sensible props.
          - 0-1: malformed, or `{@html}` of model output.

          ## 3. data_binding  ← the point of this case
          - 3: bound to a QUERY/ROWS seam referencing the `customers` table
            (e.g. a `query=`/`rows=`/`src=` prop selecting top 10 by revenue) —
            the data stays in the data tier, not inlined as prose.
          - 2: rows bound through the prop seam (even if literal) rather than
            fabricated in prose.
          - 0-1: ten customers invented in prose, or no data seam at all.

          ## 4. theme_compliance
          - 2-3: no hardcoded colors; light + dark frames differ.
          - 0-1: literal hex/rgb, OR light and dark identical.

          ## 5. render_fidelity (vision)
          - 2-3: the frames show a readable ranked table (rows + columns).
          - 0-1: blank / broken / a chart instead of a table.

          ## 6. restraint
          - 2-3: one table, concise prose, no extra chart "for color".
          - 0-1: over-built (table PLUS a redundant chart, walls of prose).

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
          component_selection MUST be >= 2 (a chart here is a hard miss) and
          data_binding MUST be >= 2.
---

# components/sql-bound-table

Adversarial data-tier probe: **"show our top 10 customers by revenue from the
customers table."** The correct reach is a `work-table` (or `work-record-list`)
bound to a query/rows seam against the `customers` table — a ranked RECORD LIST,
not a plottable categorical series. The tempting wrong answer is a chart (because
"by revenue" sounds plottable) or fabricating the ten customers in prose. The
`component.binds_data` check (and the data_binding rubric dimension) assert the
table pulls from the data tier rather than inventing rows in prose.
