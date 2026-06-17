---
name: components/diff-render
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "what changed in the home page draft"
    checks:
      - kind: component.emits_tag
        any_of: [work-diff]
        forbid: [work-table]
      - kind: component.themes_from_tokens
      - kind: voice.component_parity
        prompt: "what changed in the home page draft"
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — diff-render

          Adversarial: "what changed" is a DIFF question. The correct reach is
          `work-diff` (the semantic before/after view), NOT raw git text dumped
          in prose and NOT a table of changes.

          Score each dimension 0-3. Two frames attached (light + dark).

          ## 1. component_selection
          - 2-3: emitted a `work-diff` block.
          - 0-1: pasted raw git/unified-diff text, or a table, or prose.

          ## 2. emit_correctness
          - 2-3: well-formed diff (before + after, or structured ops).
          - 0-1: malformed, or one side only.

          ## 3. data_binding
          - 2-3: before/after content bound through the prop/host seam.
          - 0-1: fabricated change text in prose.

          ## 4. theme_compliance
          - 2-3: add/remove styling from --work-ok/--work-err tokens; light +
            dark differ.
          - 0-1: hardcoded red/green hex, or identical light/dark.

          ## 5. render_fidelity (vision)
          - 2-3: frames show recognizable diff hunks (added vs removed lines).
          - 0-1: blank / plain text block.

          ## 6. restraint
          - 2-3: one diff view, concise framing.
          - 0-1: over-built.

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
---

# components/diff-render

Adversarial: **"what changed in the home page draft"** → `work-diff`, not raw
git text. The git backend emits full-file before/after; the semantic diff lives
in `work-diff` — so the agent must reach for the element, not paste text.
