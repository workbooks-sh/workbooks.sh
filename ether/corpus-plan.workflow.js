export const meta = {
  name: 'ether-corpus-plan',
  description: 'Research + audit five fronts, then synthesize & adversarially harden a formalized Ether training-corpus plan',
  phases: [
    { title: 'Research', detail: 'five parallel deep-dives: Granite canon, FT best-practices, workponents audit, agentic surface, system-fixes', model: 'opus' },
    { title: 'Synthesize', detail: 'fuse findings into one formalized plan draft', model: 'opus' },
    { title: 'Harden', detail: 'adversarial review of the draft, then final revision', model: 'opus' },
  ],
}

// Shared context every agent gets, so they build ON our prior work instead of re-deriving it.
const PRIOR = `
PRIOR CONTEXT (read these, build on them, do NOT re-derive):
- ether/ETHER-PLAN.md — the inked plan (architecture, model=Granite-4.1, pipeline: distill+wb-build-gate corpus -> QLoRA-SFT -> length-penalized preference-opt -> serve Q5; RL=NO; §8 vision deferred).
- ether/TRAINING-STRATEGY.md, ether/INFERENCE-VIA-TRAINING.md — the training/inference research.
- ether/COMPOSER-INSPIRED.md, ether/FINETUNE-RESEARCH.md, ether/MODEL-SELECTION.md — model + token-efficiency findings.
- ether/VISION-PATH-B-RESEARCH.md — vision deferred to Phase-3.
KEY DECIDED FACTS: model = IBM Granite-4.1 dense (Apache-2.0), CPU-served Q5 GGUF on llama.cpp, bare-metal. Teachers = Claude Code CLI (subscription, trajectory distillation) + MiniMax-M3 (bulk). LFM/Liquid OUT (license). Token-efficiency is both top inference lever AND a quality lever. Corpus must be web-component-only (org-mode deprecating).

NEW DEVELOPMENT (the trigger for this workflow): the workponents web-component system just got etched out. It is NO LONGER a flat work-* pile. It is now:
- A 3-element SPINE: <work-src> (compute, lang=rust|c|zig|js|py|sql compiled by the Dock to WASM), <work-ref> (EVERY edge — dependency, binding, AND type via rel=toolkit|skill|agent), <work-flow> (the runnable DAG the runtime schedules).
- 49 elements regrouped into ~18 prefixed visual toolkits, each owning its own <prefix-*> (work-table -> grid-table, work-chart -> chart-view, etc.). "What something is" is an EDGE (work-ref rel=), not an element.
- A MACHINE-READABLE catalog: workponents/custom-elements.json (CEM, 52 elements/20 domains), workponents/registry/*.json (one per element: attributes, events, cssVars, tokens, deps, ACTUAL SOURCE — shadcn-style copy-in), workponents/theme-contract.json (the --work-* token namespace + variant enums + theme ids; "design-lint AND agents read THIS, not the elements").
- A LINT seam: workponents/src/validate/{design-lint.js,rules.js}.
- A WRITTEN SKILL: workponents/skills/theming.md ("style only from --work-* tokens, never raw hex; variants from declared enums; lint before done").
`;

const FRAMING = `
THE CENTRAL QUESTIONS this workflow must answer (the user's own words):
1. The catalog is machine-readable AND MOVING. Do we memorize terms into the weights, or teach catalog-grounded composition + keep the catalog in-context? If the latter, HOW do we teach the model to learn NEW verbs/toolkits it has never seen (zero-shot from a contract slice)?
2. The agent's job is NOT just composing code. It is full-service: composition + BUNDLING + CLI calls + bash commands + discovery + "communicating about assisting and finding out information." The corpus must cover the whole agentic loop, not just emit-a-component.
3. Some of that signal only exists in LOGS we create over time (real agent trajectories). How does a logs-as-corpus flywheel work and how do we bootstrap it before logs exist?
4. What should we FIX in the workponents framework / workbook substrate to better align it around agentic work + memory (agent affordances, discovery, machine-readable gaps)?
`;

phase('Research');
const research = await parallel([
  () => agent(`${PRIOR}\n${FRAMING}\n
YOUR FRONT: GRANITE-4.1 FINE-TUNING CANON. Produce a rigorous, citation-backed briefing (web + the ether/ docs).
Cover, concretely and current to June 2026:
- Granite-4.1 dense exact lineup (3B/8B params, context, license), tokenizer + the EXACT chat template + the tool-calling / function-calling format Granite expects (this matters: our llm.ex had to recover Qwen's XML tool dialect — what is Granite's?).
- The canonical QLoRA recipe for Granite-4.1: which modules to target, rank/alpha, 4-bit, learning rate, epochs for a NARROW domain; what IBM officially publishes (granite recipes, IBM "Granite Snack Cookbook", etc.).
- Tooling that actually supports Granite-4.1 fine-tune today: Unsloth, LLaMA-Factory, TRL, Axolotl — which, with what caveats. Re-quantize-to-GGUF path post-merge (Q5_K_M).
- Preference-optimization (ORPO/SimPO/DPO) support for Granite + length-penalty mechanics.
- Any Granite-specific gotchas for serving fine-tuned Q5 on llama.cpp.
Return a tight markdown briefing (~150-250 lines) ending with 5 "load-bearing facts the plan must respect."`,
    { label: 'research:granite', phase: 'Research', model: 'opus' }),

  () => agent(`${PRIOR}\n${FRAMING}\n
YOUR FRONT: FINE-TUNING BEST PRACTICES for a small model on a bespoke, EVOLVING web-component DSL + agentic tool-use. This is the intellectual core. Web-research + reason rigorously.
Answer:
- MEMORIZE-vs-COMPOSE: when should domain knowledge live in weights vs in-context (RAG/contract-in-prompt)? Evidence on fine-tuning teaching SKILLS/FORMAT vs FACTS; catastrophic forgetting; the cost of baking a moving catalog into weights.
- TEACHING NEW VERBS/TOOLKITS the model never saw: how do you train a model to correctly use an element/CLI/tool it only learns about at inference from a machine-readable contract slice? (in-context-learning robustness, "tool documentation as context", schema-grounded generation, contract-following SFT where the relevant contract is INCLUDED in the training prompt so the model learns to READ-then-USE rather than recall). This is the key mechanism — go deep.
- TOKEN-EFFICIENCY training (length-penalized pref-opt, trajectory distillation on tight edit traces) — quantify the documented wins.
- TRAJECTORY / LOG distillation: how teams turn real agent run-logs into SFT data (rejection sampling on execution feedback, on-policy distillation). How to bootstrap BEFORE you have logs.
- Data scale + mix for a narrow agentic-coding fine-tune (LIMA, replay ratios, diversity).
Return ~200-300 lines ending with "the 6 design rules our corpus must follow" + an explicit recommendation on memorize-vs-compose.`,
    { label: 'research:finetune-bp', phase: 'Research', model: 'opus' }),

  () => agent(`${PRIOR}\n${FRAMING}\n
YOUR FRONT: FULL WORKPONENTS AUDIT. Read the actual system deeply (do NOT trust summaries):
- workponents/README.md, catalog.html, manifest.html, roadmap.html, audit-foundation.html.
- workponents/theme-contract.json (every token + variant enum), custom-elements.json (CEM), registry/index.json + registry/README.md + 4-5 representative registry/*.json (grid-table, chart-view, chat-thread, work-flow, form-view).
- workponents/src/core/* (element.js base, variants.js, host.js), src/elements/* (the spine: work/work-src.js, work/work-ref.js, flow/work-flow.js, plus 3-4 toolkit elements), src/validate/* (the lint), src/theme/*.
- workponents/skills/theming.md, workponents/tools/* (catalog.js, build.js, the gate).
- Find + read the canonical vision doc (Glob for WORKPONENTS.md / WORKPONENTS-AGENT-INTEGRATION.md anywhere in the repo).
Produce a COMPLETE map: the spine semantics (work-src/ref/flow) precisely; how the 18 toolkits + their <prefix-*> tags are organized; the exact authoring contract an agent must obey (token-only styling, reflected-variant enums, data-binding via from=/query, capability via host/Dock); BUNDLING (how a folder of workbooks weaves to one wbundle-html — find the bundler); and what is machine-readable vs tribal-knowledge. Flag the EXACT facts a fine-tuned model must get right and the failure modes (off-enum variant, raw hex, inventing a tag, wrong prefix after regroup).
Return ~250-350 lines: "the authoring contract" + "the toolkit inventory" + "bundling" + "what's machine-readable vs not".`,
    { label: 'research:workponents', phase: 'Research', model: 'opus' }),

  () => agent(`${PRIOR}\n${FRAMING}\n
YOUR FRONT: THE AGENTIC SURFACE BEYOND COMPOSITION. The agent's job is full-service: CLI calls, bash, discovery, bundling, and "communicating about assisting / finding out information" — not just emitting components. Read the actual code:
- runtime/host/agent.ex (the agent loop — tools, how it calls shell, how it finishes), runtime/host/llm.ex (tool-call handling), runtime/host/cli.ex + runtime/host/cli/* (the work CLI verbs).
- runtime/host/evals/components.ex + runtime/bench/agent_evals.exs (what we currently eval).
- skills/* (the toolkit/skill surface), and how toolkit discovery works (memory says: agents have ONE tool = bash; "toolkits" = CLIs on PATH + skill files + progressive-disclosure subcommands; NEVER a ToolRegistry).
Map: the FULL set of things the agent DOES (compose, run 'work' verbs, bash, discover toolkits/skills, bundle/publish, inspect/answer/assist). What a real agentic TRAJECTORY looks like end-to-end (discover -> compose -> wb build -> fix -> bundle). Identify which behaviors are TEACHABLE from synthetic data vs only from REAL LOGS over time (e.g. assisting/communication, error-recovery, discovery dead-ends). Define the logs-as-corpus flywheel: what to capture from real runs, how to gate it, how it feeds the next fine-tune. How to bootstrap before logs exist (Claude-CLI trajectory distillation).
Return ~250-350 lines: "what the agent actually does" + "trajectory shape" + "synthetic-able vs logs-only" + "the logs flywheel + bootstrap".`,
    { label: 'research:agentic', phase: 'Research', model: 'opus' }),

  () => agent(`${PRIOR}\n${FRAMING}\n
YOUR FRONT: SYSTEM-FIX RECOMMENDATIONS — what to change in workponents + the workbook substrate to better align it around AGENTIC WORK and MEMORY. Read workponents/ (registry, theme-contract, CEM, skills, validate, tools), runtime/host/agent.ex, and any agent-integration doc (Glob for it). Think like a model that must use this system from a contract.
Surface concrete, actionable suggestions in these buckets:
- DISCOVERY: can an agent reliably enumerate "what elements/verbs/toolkits exist and how do I use this one" from machine-readable sources alone? Gaps? (e.g. is every element's usage example in the registry? is there a single index the agent reads first? are CLI verbs self-describing?)
- CONTRACT COMPLETENESS: is theme-contract.json + CEM + registry enough to compose correctly zero-shot, or is there tribal knowledge only in prose/heads? What's missing to make catalog-grounded composition reliable (the mechanism that lets us NOT memorize)?
- LINT/GATE as a TEACHER: can design-lint give structured, machine-readable feedback an agent (and our rejection-sampler) can consume? What rules are missing?
- MEMORY alignment: how should the framework expose state/memory so an agent's "finding out information / assisting" is first-class (vs reconstructed each turn)? Tie to the project's context-tree/memory direction.
- AGENT AFFORDANCES: small framework changes that would make the corpus smaller and the model more reliable (canonical examples per element, a machine-readable "verbs" manifest, deterministic discovery entrypoint).
Be specific and file-level where you can. Rank by leverage. Return ~200-300 lines: a ranked list of system fixes, each with WHY-it-helps-the-agent + rough effort.`,
    { label: 'research:system-fixes', phase: 'Research', model: 'opus' }),
]);

const dossier = research.filter(Boolean).map((r, i) =>
  `\n\n===== RESEARCH FRONT ${i + 1} =====\n${r}`).join('');

phase('Synthesize');
const draft = await agent(`${PRIOR}\n${FRAMING}\n
You are the lead author. Below are five research fronts. FUSE them into ONE formalized plan: "Ether Training Corpus & Agentic-Alignment Plan."
${dossier}

The plan MUST contain these sections, decisive and concrete (not a survey):
1. THESIS — one paragraph: what we are training the model to BE (a catalog-grounded, contract-reading, full-service workbook agent), and the memorize-vs-compose verdict.
2. WHAT LIVES IN WEIGHTS VS IN-CONTEXT — the explicit split. The mechanism for teaching NEW verbs/toolkits zero-shot (contract-in-prompt SFT so the model learns READ-then-USE). This is the centerpiece.
3. CORPUS COMPOSITION — every task shape with rough %: catalog-grounded component composition, spine usage (work-src/ref/flow), bundling, CLI/bash/work-verb tool-use, discovery, assisting/communication. Which are synthetic-from-registry, which are teacher-distilled, which are logs-only.
4. DATA SOURCES & THE TEACHER SPLIT — registry-synthetic, Claude-CLI trajectories, MiniMax bulk, real logs. Concrete generation recipe per source.
5. THE GATE — the deterministic machine-lint (design-lint + CEM-tag-existence + theme-contract enums + wb build/render) as the rejection-sampler. What's deterministic vs judge-needed.
6. THE LOGS FLYWHEEL — capture, gate, recycle real agent runs into the next fine-tune; bootstrap before logs exist.
7. TRAINING PIPELINE — fold into the existing Phase 0->1->2 (SFT -> length-penalized pref-opt -> serve Q5), with Granite-4.1-specific recipe facts.
8. SYSTEM FIXES — the ranked workponents/substrate changes that shrink the corpus + raise reliability (and align around agentic memory). Mark which are prerequisites.
9. EVAL & SUCCESS BARS — how we know it worked (compliance lint pass-rate, tokens-per-task, wb-build pass, render fidelity).
10. SEQUENCING — what to do first given the catalog is "etched, not done."
11. OPEN QUESTIONS / RISKS.
Write the full markdown document (aim 400-650 lines). Be specific enough to execute from. Return ONLY the document.`,
  { label: 'synthesize:draft', phase: 'Synthesize', model: 'opus', effort: 'high' });

phase('Harden');
const critique = await agent(`You are a skeptical ML+systems reviewer. Adversarially review this Ether corpus plan. Find: unsupported claims, hand-waving (esp. the "teach new verbs zero-shot" mechanism — is it actually sound and specified, or aspirational?), wrong scale estimates, missing failure modes, places it conflates memorize/compose, gate gaps (will the lint actually catch the failures?), logs-flywheel chicken-and-egg, and anything that would make a real fine-tune fail. Also check it RESPECTS the Granite-4.1 facts and our prior decisions (Q5 serve, RL=no, vision deferred). Output a numbered punch-list, each item: SEVERITY (blocker/major/minor), the problem, and the concrete fix. Be harsh and specific. End with the 3 things most likely to sink this in practice.\n\nPLAN:\n${draft}`,
  { label: 'harden:critique', phase: 'Harden', model: 'opus', effort: 'high' });

const final = await agent(`You are the lead author finalizing the plan. Apply this review punch-list to the draft — fix every blocker and major, address minors where cheap, and note any you reject with one-line reasoning. Keep it decisive and executable. Return ONLY the final, revised full markdown document (this is the artifact we ship to ether/).\n\n--- REVIEW PUNCH-LIST ---\n${critique}\n\n--- DRAFT TO REVISE ---\n${draft}`,
  { label: 'harden:finalize', phase: 'Harden', model: 'opus', effort: 'high' });

return { final, critique, draftLen: draft.length };
