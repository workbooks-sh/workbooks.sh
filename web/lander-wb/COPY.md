# workbooks.sh — copy document (v1, for alignment)

The page is one argument: **software should be owned, not rented — and now you can
build your own.** Every section advances it. Two voices throughout: the HUMAN claim
(serif, editorial) and the MACHINE receipt (mono, a real command output — never
fabricated; every receipt below is from verified runs).

Audience: builders — problem-aware (tired of subscription sprawl, cloud bills,
no-code ceilings), comfortable with AI, not necessarily engineers.
Conversion: **download the desktop app.** Tone: confident, plainspoken, a little
contrarian. No hype, no fake numbers, no "seamless."

---

## 0 · NAV
- Links: `build · own · docs` + theme toggle + **Download free** (ink button)
- The nav never sells. It's furniture.

## 1 · HERO — the thesis
**Purpose:** make the claim in five words, then make it concrete in two sentences.

- **H1:** Build apps you actually own.
- **Lede:** A free desktop app that turns plain-language requests into real,
  working software — built on your computer, kept on your computer, yours for good.
- **Receipt:** `$ wb deploy local` → `engine up · port 4000 · runs on your machine`
- **CTA:** [Download free] · [See how it works →]
- **Micro:** free & open source · no account · bring your own AI key

*Alternatives considered:* "Own your software again." (weaker claim) ·
"Stop renting your software." (negative lead — better used in §2). Keep the locked H1.

## 2 · THE PROBLEM — name the enemy
**Purpose:** tension. The contrarian voice needs a villain: the rented-software era.
Short, declarative, no product mention yet. NEW section — the old page jumped
straight to possibilities and the argument had no spine.

- **H2:** Software stopped being yours.
- **Body:** Everything became a subscription. Your tools live on someone else's
  servers, your data pays the rent, and an app you rely on can vanish behind a
  pricing email. You don't own your software anymore — you borrow it, monthly.
- **Receipt:** none. Receipts prove *our* claims; this section is about the world.

## 3 · THE TURN — what Workbooks is
**Purpose:** the reveal, mechanism-first. One tight paragraph; the demo proves it.

- **H2:** Describe it. Watch it get built.
- **Body:** Type what you want in plain words. Workbooks writes the code, runs it,
  and hands you the working thing — then you change it the same way. The demo
  here is real: mark an invoice paid.
- **Receipt:** `› build "track my freelance invoices"` → `ready ✓`
- **Component:** the live invoice demo (interactive proof, not a screenshot).

## 4 · WHAT YOU BUILD — possibility
**Purpose:** let three concrete archetypes do the imagining for them.

- **H2:** If you can describe it, you can build it.
- **Body:** The internal tool, the client portal, the little tracker nobody will
  build for you — made in an afternoon, not a sprint. No stack to set up, no
  hosting to babysit.
- **Cells:**
  - **01 · Tools for your team** — Dashboards and admin panels that share one
    source of truth. Everyone opens the same thing; everyone sees the same numbers.
  - **02 · Apps for your clients** — A private workspace per client. Send it like
    a document; it works like an app.
  - **03 · Things just for you** — The app you've always half-wished existed.
    Build it tonight. It still opens in ten years.
- **Receipt:** `› 24 toolkits loaded · ffmpeg, git, palette…`

## 5 · ONE FILE — the differentiator
**Purpose:** the thing nobody else can say. Slow down here; this is the moat.

- **H2:** The whole app is one file.
- **Body:** Interface, data, logic — even its own source — in one portable file.
  Email it to a client. Drop it in a backup. Open it on any machine. There's no
  server to keep alive, so there's nothing that can be taken away.
- **Receipt:** `$ wb bundle .` → `workbook.wbundle · source travels inside`

## 6 · OWNERSHIP — your rules
**Purpose:** the trust block. Three flat facts, no adjectives.

- **H2:** Your apps. Your computer. Your rules.
- **Body:** Workbooks runs where you do. Your data never leaves unless you send
  it. And because everything is open source, the only person who can shut you
  down is you.
- **Rows:**
  - **Runs on your machine** — Private by default. Works offline.
  - **No surprise bills** — One desktop app replaces a stack of subscriptions.
  - **Yours to keep** — Open source, Apache-2.0. It still works in a year.
- **Receipt:** `$ wb verify app.html` → `"valid": true · signed, yours`

## 7 · FAIR QUESTIONS — objections
**Purpose:** answer the four hesitations honestly. NEW section. Header is in-voice.

- **H2:** Fair questions.
- **Q: Do I need to know how to code?** — No. Plain language in, working software
  out. If you do code, everything stays editable — real source, not a black box.
- **Q: Is it actually free?** — The desktop app is free and open source, forever.
  You bring your own AI key and pay your AI provider directly; we never mark it up.
- **Q: Where does my data live?** — In your files, on your disk. Workbooks doesn't
  have a server for your data to end up on.
- **Q: What if Workbooks disappears?** — Your apps keep working. They're files on
  your computer, the runtime is open source, and every workbook carries its own
  source code inside it.
- **Receipt:** `$ wb unbundle app.wbundle` → `source/ · yours to rebuild`

## 8 · CLOSE — the ask
**Purpose:** close the loop with the thesis verb. Short.

- **H2:** Own your software.
- **Body:** Free for Mac, Windows, and Linux. Bring an AI key, build whatever you
  want, and keep every bit of it.
- **CTA:** [Download free] · [Browse the docs →]
- **Terminal:** `curl -fsSL workbooks.sh/cli.sh | sh`

## 9 · TICKER (between hero and §2)
`build it yourself · own it · runs local · private by default · no subscriptions ·
no cloud bill · one file, whole app · open source`

## 10 · FOOTER
brand · `made as a workbook` (mono, true) · download / docs / github

## META
- **Title:** Workbooks — build apps you actually own
- **Description:** A free desktop app that turns plain language into real,
  working software — built on your computer, kept on your computer, yours for good.

---

### The rules this copy obeys
1. Two voices: claim (serif) + receipt (mono, real output) — never a claim without
   proof nearby, never a fabricated receipt.
2. The enemy is *renting*, never a named competitor.
3. Words used: own, yours, your computer, real software, one file, keep it.
   Words banned: no-code, framework, seamless, supercharge, enterprise-grade.
4. Pre-launch: zero invented users, metrics, or testimonials.
