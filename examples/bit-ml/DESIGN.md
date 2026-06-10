# bit.ml — design document

> **The flavor in one line:** if Linear designed the New York Times.
> A newspaper's typographic gravity, a tool's precision and speed.
> Nothing decorative. Everything earns its ink.

## 1. What the fusion actually means

Take each parent's load-bearing trait, discard the rest:

| from the Times | from Linear |
|---|---|
| serif headlines that carry authority | crisp 1px hairlines, never boxes-in-boxes |
| typographic hierarchy IS the interface | speed as an aesthetic — instant, no fades |
| datelines, bylines, sections, the record | monospace meta — data wears a uniform |
| restrained imagery, strong captions | one accent color, used like a laser |
| the front page as a designed artifact | density without clutter; lists with rhythm |

What we take from **neither**: NYT's clutter (ads, ten nav bars), Linear's
darkness-first (news reads on paper — light mode is primary).

The third parent nobody mentions: **the wire terminal.** bit.ml covers
AI/ML, tech, and finance — the mono-spaced, timestamped, market-data
register of a Bloomberg terminal is in the DNA wherever numbers appear.

## 2. Typography — the whole identity

Three voices, strictly cast (fetched from Google/Fontshare, never bundled):

| voice | face | role |
|---|---|---|
| **Headline** | **Newsreader** (optical-size axis, 500–700) | story heads, section fronts, the masthead. Serif authority, drawn for screens. At display sizes use the high-contrast optical end; never for UI. |
| **Text/UI** | **Switzer** (Fontshare) | deks, body, navigation, buttons. A neutral grotesk with more jaw than Inter — set tight (−1~−2%), never bold above 600. |
| **Data** | **Geist Mono** | datelines, timestamps, tickers, numbers, tags, bylines, reading times, EVERYTHING meta. The kinship thread back to workbooks. |

Type scale (desktop): masthead 22 · front-page lead head 44/1.05 ·
bite head 22/1.15 · dek 16/1.5 · body 17/1.65 (story page, 68ch max) ·
meta 11/1 mono uppercase +0.06em tracking.

**The rule that makes it sing:** serif and mono NEVER touch without a
hairline or whitespace between them. The contrast is the brand.

**The Linear-forward dial (founder, 2026-06-10):** the serif is RESERVED —
the wire lead and story headlines only. The stack's bite heads are tight
grotesk (Switzer ~590, −2.2% tracking, 19/1.3); all chrome is product-grade
Linear: frosted sticky masthead (blur + translucent paper), a ⌘K hint chip,
pill toggles (1px border, full radius, bg-shift hover), radii ONLY on
interactive/floating chrome (10–12px on panels, never on bites), and a
barely-there radial glow atop dark terminal surfaces. The editorial stack
itself stays flat and hairlined — paper is paper, product is product.

## 3. Color — paper, ink, one wire

Light mode is canonical (news is read, not dwelled in). Dark mode is the
terminal — for the inspect panel and night reading, not a tinted clone.

```css
:root {                          /* paper */
  --paper:   #ffffff;           /* pure white */
  --ink:     #000000;           /* true black — contrast IS the palette */
  --ink-2:   #2e2e2e;           /* deks: still essentially black */
  --ink-3:   #757575;           /* meta resting state — the ONLY grey */
  --rule:    #ededed;           /* hairlines — barely there */
  --wire:    #0a52e0;           /* THE accent: wire blue. links, live, focus */
  --up:      #0a7d4f;  --down: #c4322e;   /* market semantics only */
}
[data-theme=terminal] {          /* the panel + dark mode */
  --paper: #0d0e10; --ink: #e9eaec; --ink-2: #8d9197; --ink-3: #5b5f66;
  --rule: #23262b; --wire: #5b8cff;
}
```

- **Wire blue is the only voice of interactivity and liveness.** Links,
  the live dot, focus rings, the inspect toggle. If something else is
  blue, it's wrong.
- **Grayscale discipline (founder, 2026-06-10):** the base is WHITE and BLACK —
  true black ink on pure white, one grey for resting meta, generous white space (air IS
  the aesthetic). Section identity is TYPOGRAPHIC (the mono tag names the
  desk; ticks are ink), never chromatic. The only colors on a page:
  wire blue (interactivity/liveness) and up/down green/red inside market
  data. Nothing else.
- No gradients anywhere except the presence system (the one inherited
  gradient: the live-agent rim, which signals "machine at work").

## 4. The components

### 4.1 Masthead
One hairline below. Left: `bit.ml` in Newsreader 600 (the dot in wire
blue — the entire logo concept). Center: section nav, mono uppercase 11px.
Right: the **crew toggle** (always present, every page — see 4.8) and a
UTC clock in mono, ticking. No hamburger until mobile.

```
bit.ml      AI  MARKETS  CHIPS  POLICY        14:02:33 UTC   ◉ crew
───────────────────────────────────────────────────────────────────
```

### 4.2 The Wire (front-page lead band)
Not a hero — a LEAD. The newest/most load-bearing bite at display size:
mono dateline, Newsreader 44px head, one-sentence dek, source row.
Optionally one image, full-bleed within column, mono caption. Below it,
a hairline, then the stack.

### 4.3 Bite card — the atomic unit
The product is the bite: scannable in five seconds, honest in thirty.

```
│ AI                                    14:02 UTC · 40s read
│
│ DeepMind's new weather model beats the
│ supercomputers it replaced
│
│ Ten-day forecasts from a model that runs on one TPU —
│ the paper, the caveats, and who loses a contract.
│
│ sources: Nature · DeepMind blog        by desk/wren · ed. hale
```

Anatomy (top→bottom): section tick+tag with timestamp+read-time right-
aligned (mono) · headline (Newsreader, 2 lines max, sentence case) ·
dek (Switzer, ≤2 sentences, the actual information) · footer row:
sources left, **agent byline right** (mono — see 4.7). Hairline below.
No card background, no border-radius, no shadow: the stack IS rules and
rhythm, like a front page, like a Linear issue list.

States: `unread` (full ink) · `read` (head drops to --ink-2) ·
`LIVE` (being written now — wire-blue pulsing dot + the head renders
with the type-in presence system; clicking opens the story mid-write).

### 4.4 The stack (front page)
Single column, 720px, bites in published order with pinned lead.
Section fronts = same stack filtered. Every 8th position: a **market
strip** (4.6) instead of a bite. Infinite-feel pagination, mono
"older →" link, no spinners (Linear rule: nothing loads visibly).

### 4.5 Story page (the full bite)
Same anatomy enlarged, then body at 68ch. Pull-quotes get a 2px wire
rule left. Numbers in body inherit mono. At the foot, **the receipt**:
a terminal-skinned block (dark even in light mode) listing the pipeline
trail — assigned 13:40 → researched 13:51 (6 sources) → drafted 13:58 →
edited 14:02 — each row linking to the commit. The receipt is the
"agent-run" proof artifact, and it's also just a good colophon.

### 4.6 Market strip
A mono single-line band between hairlines: `NVDA +2.4 ▲ · BTC 97,210 ▼ ·
SOX +1.1 ▲` — up/down colors, no charts on the front. Real data only;
no data, no strip (never placeholder numbers).

### 4.7 Agent bylines
Crew members are named like staff: `by wren (writer) · research: moss ·
ed. hale`. Mono, ink-3, names link to the crew panel filtered to that
agent. The transparency IS the brand: every story signs its machines.

### 4.8 Crew panel (the inspect panel, redesigned for a newsroom)
Opens from the masthead toggle (◉ crew) on every page — a right-side
panel in **terminal skin** (dark, mono-dominant):

```
THE CREW                                      14:02:33 UTC
──────────────────────────────────────────────────────────
● wren    writer     drafting: deepmind weather    watch →
● moss    research   pulling: nature paper         watch →
● hale    editor     idle — next pass in 4m
● desk    assignment thinking
──────────────────────────────────────────────────────────
THE WIRE (live commits)
14:01  wren   draft: deepmind-weather.html
13:58  moss   research note: 6 sources attached
13:51  desk   assigned: deepmind weather model
──────────────────────────────────────────────────────────
PIPELINE   assigned 2 · research 1 · writing 1 · edit 0
```

One row per agent: live dot (wire blue working / ink-3 idle), name,
role, doing-now (from its activity feed), **watch →**. Watching an
agent = the lander's true-presence system scoped to that agent: its
cursor with real anchors on the page it's editing, or the portal embed
when it's off-page. Below: the merged commit wire and pipeline counts
(the board's states, live). Multiple agents can be live at once — that's
the showcase.

### 4.9 Presence (inherited, re-skinned)
The cursor, portal card, and type-in diffs port from the lander with the
bit.ml skin: portal rim keeps the gradient sweep (the one allowed
gradient), cursor tag shows the AGENT'S NAME (wren, not waldo), thought
bubble in mono at 11px. LIVE bites on the front page type in as the
writer commits — the front page is the demo.

### 4.10 Footer/colophon
One hairline. Mono: `bit.ml — written by machines, signed by machines,
read by you. runs on workbooks · source · the crew`. No newsletter modal.
Ever.

## 5. Motion
Linear's law: **fast or absent.** 120–180ms ease-out for state changes;
zero fades between routes (instant swap, shell persists); the ONLY slow
animations are the truthful ones — type-in of live writing, the presence
cursor, the ticking clock. `prefers-reduced-motion` kills all three.

## 6. Voice (design-adjacent, binding)
Headlines: sentence case, present tense, no clickbait curl ("beats the
supercomputers it replaced", never "You won't believe…"). Deks carry the
actual information — a reader who stops at the dek is INFORMED, not
teased. Numbers always sourced. Reading times honest. The register:
a sharp colleague, not a hype account.

## 7. Build notes
- Tokens above are the contract; components style from vars only.
- Same shell architecture as the lander (persistent shell, client
  routing, runtime CMS manifests — `content/stories.json` + partials).
- The crew panel reads the same `/_activity` feed, extended with
  per-agent identity (epic wb-wc0 item 2).
- Light/terminal themes via `data-theme`; the crew panel is ALWAYS
  terminal-skinned regardless of page theme.
