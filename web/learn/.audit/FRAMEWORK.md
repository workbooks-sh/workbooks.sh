# Learning Center — Rebuild Framework

**From an engine tour to a get-things-done-with-your-agent path.**

This document is the argument and the full proposed curriculum. The companion structured object is the implementation spec.

---

## 1. The one-line reframe

> **The current Learning Center teaches what Workbooks is *made of*. The new one teaches what *you* can do with it — by talking to an agent that builds real software for you, safely.**

The audit's verdict is unambiguous and all five research briefs converge on the same diagnosis: the prose is true and well-written, but it is wearing the wrong skeleton. It is sequenced by the **builder's dependency graph** (file → format → kernel → isolation → signatures), not the **learner's motivation graph**. The audience's actual job — directing an AI agent — is taught nowhere, and their collaborator (the agent) doesn't appear until lesson 10 of 21.

We keep nearly every word of prose. We rebuild the spine.

---

## 2. Why the current order fails (the evidence)

Every brief independently named the same failure and the same fix:

- **Andragogy (adult-learning-design):** Adults are *problem-centered, not subject-centered*. They refuse to learn until they know *why it matters to them*. The engine-tour order is a Curse-of-Knowledge artifact — the founder explaining the system the way *he* built it.
- **Onboarding / time-to-value (devtool-onboarding, internal-skills):** Elite tools hit the "aha" in under 5 minutes; ~62% of users churn before reaching it. A 21-lesson conceptual tour with the first felt win at lesson ~10 is the textbook anti-pattern: deferred value, no early doing, blank-canvas paralysis.
- **AI-collaboration maturity ladder (teaching-ai-collaboration):** There is a Level 1→2→3 climb (Answers → Daily partner → Autonomous agent) and **people who skip Level 2 fail at Level 3.** Today's LMS drops learners straight into Level-3 engine concepts (sandboxes, persistent agents) without ever teaching the Level-2 habits — context-building, iteration, review — that make autonomy reliable.
- **Analog teardown:** No analog (No Code MBA, Codédex, Learn Prompting Agents, Sidecar) opens on a file format or an engine. Every one opens on the *outcome*, introduces the *collaborator* before its sub-mechanics, front-loads a *guided first build*, and teaches *delegation as a named skill*. We do none of these.

**The single biggest miss, named by all five briefs:** zero worked examples and zero "how to work with your agent" lessons. The curriculum is 100% conceptual architecture.

---

## 3. The three faults we are fixing (from the audit)

1. **Frame inversion.** "Foundations = the file" contradicts the founder's own thesis — *"this is an ecosystem… the main component to STAND ON is the runtime."* The file is the core **unit**, not the **foundation**. → The new Unit on the ecosystem makes the *whole thing* the foundation; the file is introduced as the thing you end up holding.
2. **Runtime + isolation demoted and misplaced.** ~40% of the thesis is the isolation / sandbox / threat-model argument, scattered into sub-bullets and placed *after* toolkits (a backwards dependency). → Runtime + isolation becomes its own unit, placed **before** toolkits, and framed as a *motivation* ("why it's safe to hand your agent power"), not a mechanism tour.
3. **Missing climax + missing audience skill.** The autopoet / living-system (the thesis's emotional peak) is one stray doc-link; "how to work with your agent" is taught nowhere. → A four-lesson "Work with your agent" unit moves to the front; the self-improving system becomes the explicit Level-3 capstone.

---

## 4. The design principles (what every unit must obey)

1. **Why before how.** Every unit opens with a learner-stake dek (1–2 sentences). Need-to-know on every entry point.
2. **First win fast.** A felt "I directed an agent and it built something real" by the end of Unit 1 — not lesson 10.
3. **Problem-centered, not content-centered.** Sequence around what the learner wants to *do* (delegate, review, ship, trust), not how the system is constructed.
4. **The collaborator appears first.** The agent is the learner's hands. It shows up in Unit 1, structured as the Level 1→2→3 climb.
5. **Show, don't tell.** Worked artifacts — a real prompt, the agent's real reply, the real result — over analogies. Editable starter-prompt cards ("Build me a `[tool]` that `[does X]` from `[my data]`") beat blank-canvas prose.
6. **Concept first, mechanics optional.** Keep the conceptual strength, but re-anchor each concept lesson as *"so you can tell if the agent did it right."* Push deep mechanics (Org syntax, work, kernel, seam) to optional/reference back-half — expertise-reversal effect: deep mechanics help experts, hurt novices.
7. **Honest arc with payoff.** End the core path on the aspirational self-improving system (brand-canon framed: "software built in workbooks," never "sites that run themselves"), then optional internals.

---

## 5. The new spine — 7 units, learner-ordered

```
UNIT 1  Build by talking to your agent          (WHY + first win + the L1→2→3 climb)   ← agent appears here
UNIT 2  The whole thing                         (ecosystem map; the file as the unit)
UNIT 3  The engine & the sandbox                (runtime as the thing you stand on; isolation as headline)  ← BEFORE toolkits
UNIT 4  Giving it abilities                      (toolkits — now correctly after the engine that runs them)
UNIT 5  Agents that work on their own            (persistent agents, review, the ledger)
UNIT 6  Plans that run & the system that improves itself   (automation → autopoet CLIMAX)
UNIT 7  Trust, sharing & the disk                (copyable artifact stays safe + useful when handed out)
UNIT 8  Under the hood (optional)                (one ending, gated "for the curious")
```

**Order rationale, unit by unit:**

- **Unit 1 is the activation unit** and the spine of the whole rebuild. It answers "why does this matter to me," then immediately puts the learner in the director's seat. Structured as the maturity ladder: *tell it what you want* (L1→2) → *the loop: prompt, look, redirect* (L2) → *reading what it did* (L2→3) → *your first workbook, end to end* (the worked narrative every analog front-loads, which we have zero of). This is the felt first win.
- **Unit 2 fixes the frame inversion.** Now that the learner has *done* something, the ecosystem map lands as "here's what you were just standing on." The file is introduced as the core *unit you end up holding*, not the foundation. Folds `the-one-file` + `carries-its-story` + the language idea.
- **Unit 3 fixes the backwards dependency and surfaces 40% of the thesis.** "Your agent runs in a safe sandbox you can trust" is a *motivation* (why you can hand it power), so it belongs before toolkits, framed as a benefit ("your secrets never touch the OS"), not a micro-VM mechanism tour. This is also the most *shareable* asset (counterintuitive, founder-original) and answers the audience's first objection: "is this safe for my company's data?"
- **Unit 4 (toolkits) now sits after the engine that runs them.** Maturity-hedged (toolkits = least-mature prong). `work` demoted to a reference card — the *agent* runs work, not this user.
- **Unit 5** keeps the agent-depth lessons, re-anchored as "how the agent works when you're not watching, and how you keep it honest" — review like an untrusted colleague.
- **Unit 6 is the climax.** Automation → the self-improving system. The autopoet moves OUT of `plans-that-run` (where it's a credibility risk — Phase-1-only + collides with "never pitch self-running") and becomes the honest Level-3 summit, framed per brand canon.
- **Unit 7** merges the two thin single-lesson units (disk, browser) into trust/sharing — all the same idea: a copyable artifact that stays safe and useful when handed out.
- **Unit 8** is the one optional ending. The two redundant "it's all the same idea" endings (`the-browser` + `under-the-hood`) dissolve into a single capstone, gated for the curious.

---

## 6. The truth fixes folded in (audit P0)

These over-claims are corrected as we reframe, not deferred:

- `the-one-file` three false claims (no-server, history-in-file, one-HTML→bundle) — corrected in Unit 2; the file is the *unit* inside an ecosystem that *does* stand on a runtime.
- `did-it-do-well` grounded in the real `work toolkit eval` surface; cost/speed figure softened — Unit 1 (review) and Unit 5.
- `going-live` public-history 401 claim fixed — Unit 3.
- `plans-that-run` two-way kanban + self-running schedule softened; **autopoet doc-link cut** and relocated to the Unit 6 climax — the highest-risk over-claim.
- `safe-powers` lowest-rung "no secrets" corrected — Unit 3.
- Per-lesson maturity marker (ships-today vs north-star) and a path progress bar — honesty + motivation in one move.

---

## 7. What's new vs. reused

- **New lessons (5):** the four "work with your agent" lessons (tell-it / the-loop / reading-it / first-build-end-to-end) + the standalone isolation/threat-model lesson. These are the audience's actual job and the most-cited gap.
- **Reframed (heavy reuse of true prose):** `the-one-file`, `the-one-language`, `coming-alive`, `safe-powers`, `going-live`, `giving-it-abilities`, `the-one-command`, `plans-that-run`, `the-browser`. Same words, new frame and new home.
- **Kept:** `carries-its-story`, `code-in-the-document`, `what-an-agent-is` (moved up), `agents-that-persist`, `did-it-do-well`, `compiled-plans`, `proving-origin`, `who-sees-what`, `secrets-in-the-open`, the disk lessons, `under-the-hood`.
- **Cut (structural, zero topic loss):** the standalone "Foundations = file" unit framing, the standalone disk unit, the standalone browser unit, the autopoet-beside-shipped-primitives doc-link, and one of the two duplicate endings. Every topic survives; only the wrong skeleton is removed.

**Net:** keep the prose, re-skin the spine to *why → agent → guided build → trust → grows-into*, add the three-to-five missing "work with your agent" lessons. That is the gap between us and every analog.
