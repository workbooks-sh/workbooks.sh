---
name: components/history-render
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "show the version history of this doc"
    checks:
      - kind: component.emits_tag
        any_of: [work-history-graph]
        forbid: [work-table]
      - kind: component.themes_from_tokens
      - kind: voice.component_parity
        prompt: "show the version history of this doc"
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — history-render

          Adversarial: "version history" is a revision graph. The correct reach
          is `work-history-graph` (nodes newest-first, human/agent attribution),
          NOT a bullet list and NOT a table.

          Score each dimension 0-3. Two frames attached (light + dark).

          ## 1. component_selection
          - 2-3: emitted a `work-history-graph` block.
          - 0-1: a bullet list of versions, a table, or prose.

          ## 2. emit_correctness
          - 2-3: well-formed history (ordered revisions w/ author + title).
          - 0-1: malformed or unordered.

          ## 3. data_binding
          - 2-3: revision nodes bound through the prop/host seam.
          - 0-1: fabricated history in prose.

          ## 4. theme_compliance
          - 2-3: token-driven; light + dark differ.
          - 0-1: hardcoded colors, or identical light/dark.

          ## 5. render_fidelity (vision)
          - 2-3: frames show an ordered graph/timeline of revisions.
          - 0-1: blank / plain list.

          ## 6. restraint
          - 2-3: one history graph, concise framing.
          - 0-1: over-built.

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
---

# components/history-render

Adversarial: **"show the version history of this doc"** → `work-history-graph`,
not a bullet list. Newest-first nodes with human/agent attribution.
