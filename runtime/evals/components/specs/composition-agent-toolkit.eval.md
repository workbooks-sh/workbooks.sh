---
name: components/composition-agent-toolkit
agent: waldo
timeoutMs: 600000
turns:
  - prompt: "Set up an agent named Scout that uses a web-browser toolkit and a CRM toolkit."
    checks:
      - kind: component.emits_tag
        # The correct reach is the DECLARATIVE composition islands, not a live UI
        # widget. A `<work-agent>` island carries the agent def; its toolkit
        # dependencies are expressed as nested `<work-toolkit>` islands (or
        # `<work-toolkit src=…>`), exactly the #+REQUIRES DAG the host resolves
        # transitively (see docs/WORKBOOK-COMPOSITION-MODEL.md §"Composition =
        # DOM nesting"). The adversarial wrong answer is reaching for a data/UI
        # component (chart/table/metric) — there is no data here, only structure.
        any_of: [work-agent]
        forbid: [work-chart, work-table, work-metric, work-spark, markdown-table]
      - kind: component.themes_from_tokens
      - kind: rubric.passes
        target: assistant_text
        minScore: 0.66
        attachments:
          # config islands render NOTHING (inert) — frames are best-effort and
          # may be empty/stub. render_fidelity is scored LOW-WEIGHT here; the
          # source structure of the islands is the primary evidence.
          light_png: ctx:mountLightPng
          dark_png: ctx:mountDarkPng
        rubric: |
          # component-emit rubric — composition-agent-toolkit

          Adversarial: this brief is about STRUCTURE, not data. "Set up an agent
          that uses two toolkits" must be expressed through the declarative
          composition islands — a `<work-agent>` containing/referencing two
          `<work-toolkit>` islands. The tempting WRONG answer is to reach for a
          live data/UI component (a chart, a table, a metric) because the eval
          normally rewards those — but there is no numeric series here, only a
          configuration graph. Reaching for a viz component is a hard fail.

          The composition islands are inert (they render nothing), so the
          EMITTED SOURCE is the primary evidence. Frames are best-effort.

          Score each dimension 0-3.

          ## 1. component_selection  ← the point of this case
          - 2-3: a `<work-agent>` island for Scout, with the two toolkits
            expressed as `<work-toolkit>` islands — nested inside the agent
            and/or referenced via `src=` (web-browser toolkit + CRM toolkit).
          - 0-1: reached for a chart/table/metric, answered in pure prose, or
            emitted only a bare agent with no toolkit islands.

          ## 2. emit_correctness
          - 2-3: well-formed islands — `<work-agent>` carries a name/id "Scout"
            (and ideally a system-prompt child), each `<work-toolkit>` names or
            src-references the right toolkit. Parseable as the #+REQUIRES DAG.
          - 0-1: malformed elements, or the toolkits are mentioned only in prose
            rather than as islands.

          ## 3. composition_correctness  ← the point of this case
          - 3: BOTH toolkits are real composition islands (nested or src=), so
            the agent→toolkit dependency edges exist in the DOM, not in prose.
          - 2: both toolkits present as islands but flatly (siblings, no clear
            edge to the agent).
          - 0-1: toolkits described in prose, only one toolkit, or none.

          ## 4. theme_compliance
          - 2-3: no hardcoded colors in the emitted markup.
          - 0-1: literal hex/rgb in the islands.

          ## 5. render_fidelity (low weight — inert islands)
          - 2-3: frames are non-broken (a stub card or nothing is fine — these
            islands legitimately render nothing).
          - 0-1: only fail if the emit itself is structurally broken.

          ## 6. restraint
          - 2-3: exactly one agent + two toolkit islands, minimal prose; no
            invented extra components.
          - 0-1: over-built with unrelated widgets or walls of prose.

          ## Threshold
          PASS only if every dimension >= 2 AND sum >= 14 / 18.
          component_selection AND composition_correctness MUST each be >= 2 —
          this case probes the composition model, not rendering.
---

# components/composition-agent-toolkit

Adversarial composition probe: **"set up an agent named Scout that uses a
web-browser toolkit and a CRM toolkit."** The correct reach is the DECLARATIVE
composition islands from the composition model — a `<work-agent>` island
containing/referencing two `<work-toolkit>` islands (the `#+REQUIRES` DAG as DOM
nesting), NOT a chart/table/metric. There is no data here, only structure.

This case specifically probes the **composition model** (docs/WORKBOOK-
COMPOSITION-MODEL.md): structure = components, expressed as typed config
islands. `work-agent` / `work-toolkit` are inert islands (they render nothing),
so the emitted SOURCE — not a frame — is the primary evidence; `render_fidelity`
is low-weight. No `binds_data` / `voice.component_parity` check: there is no
numeric series and no visual-answer parity to assert.
