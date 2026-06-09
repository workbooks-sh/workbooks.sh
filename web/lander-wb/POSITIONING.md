# workbooks.sh — positioning ideation (v1)

Supersedes COPY.md (which assumed the problem instead of finding it). This doc does
the upstream work: what problem is REAL, for whom, and which framing earns a
download. Nothing here reuses prior copy.

---

## 1 · Why the old copy failed (diagnosis)

"Build apps you actually own" led with a **worldview** (ownership philosophy).
Psych audit of that choice:

- **BJ Fogg (B = M·A·P):** ability was maxed (free, no account) but *motivation*
  was abstract — "ownership" is a future, diffuse good. Nothing urgent.
- **Hyperbolic discounting:** the payoff ("still works in ten years") is the
  opposite of an immediate reward. People discount it to ~zero.
- **Availability heuristic:** nobody woke up today vividly angry about not
  *owning* software. The pain has no recent, concrete episode attached.
- **Curse of knowledge:** WE feel the ownership thesis because we built the
  architecture. A visitor hasn't earned that feeling yet.

Conclusion: ownership is a real **differentiator** but a weak **hook**. It's the
why-us, not the come-in.

## 2 · The job to be done (first principles)

The person we can actually convert in 2026 already believes AI can write software
(no education needed — confirmation bias works FOR us). Their felt experience:

> "I've generated a dozen apps this year — in v0, Lovable, Bolt, ChatGPT, Claude.
> Demos everywhere. I'm USING approximately none of them."

The job: **"Turn what AI builds for me into something I actually use and keep."**
Not "build an app" — building is solved and commoditized. The unsolved half is
*having* the result: somewhere it lives, runs, persists, stays private, and stays
mine. That's exactly the half our architecture answers (one file, local runtime,
source inside, open source).

The drill/hole test: they don't want a builder (drill #9). They want the shelf
where the holes… live. Bad metaphor; real point: **everyone sells the building.
Nobody sells the keeping.**

## 3 · Candidate framings, scored

| Framing | Acute? | Vivid episode? | Rides existing belief? | Differentiated? | Risk |
|---|---|---|---|---|---|
| **A. The keeping problem** — AI apps die after the demo; here they live | ★★★ felt this month | ★★★ "20 dead demos" | ★★★ | ★★★ structural (file+local) | names the builder category |
| **B. An app is a file again** — permanence, the PDF moment | ★ philosophical | ★ | ★★ (files nostalgia) | ★★★ unique language | abstract as a lead |
| **C. Fire your subscriptions** — ownership/anti-rent | ★★ diffuse | ★ no single moment | ★★ | ★ every local-first app says it | generic, preachy |
| **D. Internal-tools backlog** | ★★ for ops folks | ★★ | ★★★ | ★ Retool-crowded; our multi-user story is young | overclaims today |
| **E. Agent-native home** | ★★ power users only | ★★ | ★ | ★★★ real moat | niche; docs/HN story, not the lander |

**Read:** A is the hook (loss aversion on already-sunk effort — losses felt 2×;
the episode is days old, not hypothetical). B is the brand layer that makes A
*ours* (the mechanism: it's a file). C demotes to a value-prop row. D becomes a
use-case card, not a promise. E goes to README/docs where it converts the right
crowd.

## 4 · The recommended position

> **For builders who keep generating apps that go nowhere, Workbooks is the
> desktop app where AI-built software becomes a real, lasting thing — because
> every app is one file that runs on your machine and belongs to you.**

Messaging hierarchy:
1. **Hook (A):** generating was never the hard part — keeping is. We're where
   what you build *lives*.
2. **Mechanism (B):** it can promise that because an app here is a **file** —
   interface, data, its own source, in one portable artifact. Files persist.
   Files are yours. (This is the claim no competitor can copy without becoming us.)
3. **Stakes (C, demoted):** no hosting to rent, no subscription, private by
   default, open source — the consequences of the mechanism, listed flat.

Psych mechanics intentionally engaged: loss aversion (sunk demos), endowment +
IKEA via the live demo ("this one's yours — change it"), zero-price effect
(free, BYO key, stated early), Pratfall trust ("what if we disappear? you lose
nothing — it's a file + open source"), contrast effect (builders' "now what?"
vs our "it's already running on your machine").

## 5 · Hero sketches (new language only)

**Direction A1 — the question that hurts**
- Eyebrow: `for everyone who's generated 20 apps and kept none`
- H1: **Where did all your AI apps go?**
- Lede: Demos in dead tabs. Repos you never deployed. Workbooks is the desktop
  app where the things you build actually live — each one a single file that
  runs on your machine and stays yours.
- Receipt: `$ open invoices.wbundle · running · last opened: today`

**Direction A2 — the blunt thesis**
- H1: **Keep what you build.**
- Lede: AI can write you an app in a minute. Workbooks is where it becomes real —
  one file, running on your computer, yours to open in ten years.
- Receipt: `$ wb bundle . → invoices.wbundle · source inside`

**Direction B1 — the artifact**
- H1: **An app is a file again.**
- Lede: Remember when software was a thing you *had*? Workbooks builds working
  apps with AI and saves each one as a single file — interface, data, and source,
  together, on your disk.
- Receipt: `$ ls ~/Workbooks → invoices.wbundle · 1 file · whole app`

**Direction A2×B1 blend (my pick)**
- H1: **Keep what you build.**
- Sub: Workbooks turns AI sessions into software you *have*: every app is one
  file — interface, data, source — running on your machine, owned by no one else.

## 6 · Objection map (orders the page's back half)

| Objection (in their words) | Answer (with receipt) |
|---|---|
| "Another AI app builder?" | Builders end at the demo. We start there: the output is a possession, not a preview. `wb bundle → one file` |
| "Do I need to code?" | No — describe and refine in plain words. If you code, it's real, editable source. `wb unbundle → source/` |
| "Is it actually free?" | App is free + open source forever. You bring your own AI key, pay your provider directly. No markup, no meter. |
| "Where's my data?" | On your disk, in your files. There is no server of ours for it to be on. |
| "What if you disappear?" | Then nothing happens. Your apps are files; the runtime is Apache-2.0; every workbook carries its own source. |

## 7 · What we deliberately do NOT claim (honesty gates)

- No "deploy to the world / share with millions" — publishing exists, but the
  lander's promise stays: *runs and lives on your machine.*
- No real-time team collaboration promises (architecture is young there) — team
  language stays at "share it like a document."
- No metrics, users, or testimonials (pre-launch).
- Builder competitors never named; the category is gestured at ("demos," "dead
  tabs"), not attacked by name.

---

### Decision needed
1. Framing: **A-hook + B-mechanism** as recommended? Or lead B (braver brand,
   slower motivation)?
2. Hero: A1 (question), A2 (imperative), B1 (artifact), or the A2×B1 blend?
3. Keep "Where did all your AI apps go?" anywhere even if not the H1? (It's the
   single most loss-averse line in the doc — strong as §2 opener.)

Copy gets written ONLY after these three calls. Then design-from-scratch around
the locked copy.
