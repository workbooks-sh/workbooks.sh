---
name: components/theme-honest
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "show me signups by week"
    checks:
      - kind: component.emits_tag
        any_of: [work-chart]
      - kind: component.themes_from_tokens
        # this case GATES on theme honesty: any literal hex/rgb/hsl in the
        # emitted artifact is a hard fail before the rubric runs.
        strict: true
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — theme-honest

          Theme-honesty is the SUBJECT here. The artifact must derive its color
          entirely from `--work-*` tokens; the proof is that the light and dark
          frames look materially different (a token-reading artifact re-themes,
          a hardcoded one does not). Any literal hex / rgb / hsl in the emitted
          block is dishonest theming.

          Score each dimension 0-3. Two frames attached (light + dark).

          ## 1. component_selection
          - 2-3: a `work-chart` (weekly signups = a series).
          - 0-1: wrong element or prose.

          ## 2. emit_correctness
          - 2-3: well-formed chart block.
          - 0-1: malformed.

          ## 3. data_binding
          - 2-3: weekly series bound.
          - 0-1: fabricated.

          ## 4. theme_compliance  ← the point of this case
          - 3: zero literal colors; light + dark frames clearly differ.
          - 2: token-driven but minor literal (e.g. one neutral).
          - 0-1: literal hex/rgb in the artifact, OR light == dark.

          ## 5. render_fidelity (vision)
          - 2-3: readable chart in both frames.
          - 0-1: blank / broken.

          ## 6. restraint
          - 2-3: one chart.
          - 0-1: over-built.

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
          theme_compliance MUST be >= 2.
---

# components/theme-honest

The rendered artifact themes from `--work-*` only — no hardcoded colors. Proof:
the light + dark frames must differ. The `component.themes_from_tokens` check is
`strict` here (literal hex/rgb = hard fail before the rubric).
