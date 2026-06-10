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
interactive/floating chrome (10–12px on panels, never on bites), and the
soft `--shadow` lift on floating Notion surfaces (the Notion dial, §3). The
editorial stack itself stays flat and hairlined — paper is paper, product
is product.

## 3. Color — ONE theme: paper, ink, one wire

**One theme (founder, 2026-06-10).** Light only — white paper, black ink.
The Notion-style editorial pivot: fun but modern, clean white and black,
lots of whitespace. The [data-theme=terminal] page theme and its toggle were
**deleted** — there is no dark mode, no night reading, no terminal skin
anywhere. Surfaces that used to be terminal-skinned (the Receipt, the
CrewPanel) are reinterpreted as light Notion surfaces.

```css
:root {                          /* paper — the only theme */
  --paper:   #ffffff;           /* pure white */
  --ink:     #000000;           /* true black — contrast IS the palette */
  --ink-2:   #2e2e2e;           /* deks: still essentially black */
  --ink-3:   #757575;           /* meta resting state — the ONLY grey */
  --rule:    #ededed;           /* hairlines — barely there */
  --wash:    #f5f5f5;           /* Notion hover wash on interactive rows */
  --surface: #fafafa;           /* lightest gray a card may carry (#fafafa max) */
  --wire:    #0a52e0;           /* THE accent: wire blue. links, live, focus */
  --up:      #0a7d4f;  --down: #c4322e;   /* market semantics only */
  /* the ONE Notion lift — soft shadow now sanctioned on floating surfaces */
  --shadow:  0 1px 3px rgba(0,0,0,.06), 0 8px 24px -12px rgba(0,0,0,.12);

  /* section badge accent colors — ONLY for the badge pill, nowhere else */
  --sec-ai:      #0a52e0;   /* wire blue */
  --sec-markets: #0a7d4f;   /* up-green */
  --sec-chips:   #b8860b;   /* amber */
  --sec-policy:  #7a4988;   /* plum */
}
```

- **Section colors return ONLY as badge accents (founder note, 2026-06-10).**
  The page stays monochrome. The section badge pill (§4.3) is the sole carrier
  of section color: tinted wash bg (color ~10% via `color-mix`), colored icon +
  tag text. No tinted cards, no colored bands, no chromatic section headers.
- **The Notion dial (founder, 2026-06-10):** fun / clean / whitespace. Cards
  are white or gray-25 (`--surface` #fafafa max), NO strokes (surface law
  stands), and a soft **lift shadow is now sanctioned** on floating surfaces
  (panels, the receipt, chips) — ONE consistent `--shadow` token, never a
  freelanced shadow. Interactive rows take a `--wash` (#f5f5f5) hover.
  Generous padding; `--r` stays 12px. Mono is reserved for genuine meta
  (the meta system stands). The frosted sticky masthead + ⌘K + crew pill
  read Notion-compatible and stay.
- **Wire blue is the only voice of interactivity and liveness.** Links,
  the live badge, focus rings, the crew toggle. If something else is
  blue, it's wrong.
- **Grayscale discipline (founder, 2026-06-10):** the base is WHITE and BLACK —
  true black ink on pure white, one grey for resting meta, generous white space (air IS
  the aesthetic). The only colors on a page: wire blue (interactivity/liveness),
  up/down green/red inside market data, and section badge accents (§4.3). Nothing else.
- No gradients anywhere except the presence system (the one inherited
  gradient: the live-agent rim, which signals "machine at work").
- **Surface laws (founder, 2026-06-10):** backgrounds are #fff or the
  gray-25 `--surface` (#fafafa) — never a darker tinted gray, never #000.
  NO STROKES ON CARDS — a card separates by contrast + the soft `--shadow`
  lift (the Notion sanction); borders survive only on small product chrome
  (pills, keycaps). ONE radius scale: --r 12px for floating surfaces,
  --r-s 6px for chips — nothing freelances its roundness.

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
mono dateline with **section badge** (§4.3), Newsreader 44px head, one-sentence
dek, source row. Optionally one banner image (§4.5, note 3) below the dek,
full-column within the layout column, `border-radius: var(--r)`, no border.
Below, a hairline, then the stack.

**Whitespace dial (founder, 2026-06-10):** generous and rhythmic. Dateline
`margin-bottom: 20px`, dek `margin-top: 18px`, foot `margin-top: 24px`,
padding `8px 0 36px`.

### 4.3 Bite card — the atomic unit
The product is the bite: scannable in five seconds, honest in thirty.

```
│ [✦ AI]                                14:02 UTC · 40s read
│
│ DeepMind's new weather model beats the
│ supercomputers it replaced
│
│ Ten-day forecasts from a model that runs on one TPU —
│ the paper, the caveats, and who loses a contract.
│
│ sources: Nature · DeepMind blog        by desk/wren · ed. hale
```

**Section badge spec (founder note, 2026-06-10):**

| property | value |
|---|---|
| anatomy | `[icon 12px] [TAG text]` |
| font | Geist Mono, 9.5px, uppercase, letter-spacing 0.07em |
| background | `color-mix(in srgb, <section-color> 10%, transparent)` |
| text color | `<section-color>` (full saturation) |
| border-radius | `999px` |
| padding | `3px 8px` |
| icon | 12px inline SVG, `stroke="currentColor"`, 24-viewBox clean path |
| section colors | ai `#0a52e0` · markets `#0a7d4f` · chips `#b8860b` · policy `#7a4988` |
| icons | ai = sparkle/circuit · markets = trending line · chips = chip outline · policy = bank/columns |

The badge is the ONLY color on the page (besides wire blue for interactivity
and up/down in market data). Everything else: monochrome. No big tag pills,
no tinted card backgrounds, no colored section bands.

Anatomy (top→bottom): section badge + timestamp+read-time right-aligned (mono) ·
headline (Switzer tight grotesk, 2 lines max, sentence case) ·
dek (Switzer, ≤2 sentences, the actual information) · footer row:
sources left, **agent byline right** (mono — see 4.7). Hairline below.
Bite cards are Notion cards: white bg, `border-radius: var(--r)`, soft `--shadow`
lift, lift-on-hover. **No banner on Bite** — the stack stays fast.

**Whitespace dial (founder, 2026-06-10):** generous, rhythmic.
Card `padding: 26px 28px 22px`. Stack `gap: 20px`. Top margin `margin-bottom: 14px`.
Dek `margin: 10px 0 0`. Foot `margin-top: 18px`.

States: `unread` (full ink) · `read` (head drops to --ink-2) ·
`LIVE` (being written now — wire-blue pulsing dot + the head renders
with the type-in presence system; clicking opens the story mid-write).

### 4.4 The stack (front page)
Single column, 720px, bites in published order with pinned lead.
Section fronts = same stack filtered. Every 8th position: a **market
strip** (4.6) instead of a bite. Infinite-feel pagination, mono
"older →" link, no spinners (Linear rule: nothing loads visibly).

Section front header uses the **section badge** (§4.3, slightly larger
variant: 11px, padding 4px 10px) as the sole section identity — color
accent on a monochrome page.

### 4.5 Story page (the full bite)
Same anatomy enlarged, then body at 68ch. Pull-quotes get a 2px wire
rule left. Numbers in body inherit mono. At the foot, **the receipt**:
a **light Notion card** (`--surface` #fafafa, no stroke, the soft `--shadow`
lift) listing the pipeline trail — assigned 13:40 → researched 13:51 (6
sources) → drafted 13:58 → edited 14:02 — each row linking to the commit.
The receipt is the "agent-run" proof artifact, and it's also just a good
colophon.

**Banner images (founder note 3, 2026-06-10):** manifest rows may carry
`"banner": "content/images/<file>"` (+ optional `"bannerAlt"`). Rendered
on the story page as a full-column image above the org body:
`border-radius: var(--r)`, no border, `object-fit: cover`.
On WireLead: rendered below the dek, calm placement, same radius.
On Bite cards: **no banner** — the stack stays fast.
Missing/404 → renders nothing; `onerror` hides the element, no broken-image icon.

**Whitespace dial (founder, 2026-06-10):** story `padding-top: 36px`,
meta-top `margin-bottom: 22px`, dek `margin: 22px 0 0`,
byline-row `margin: 30px 0 0`, story-hr `margin-top: 28px`,
banner `margin-top: 32px`, org-mount `margin-top: 36px`,
receipt-wrap `margin-top: 52px`.

### 4.6 Market strip
A mono single-line band between hairlines: `NVDA +2.4 ▲ · BTC 97,210 ▼ ·
SOX +1.1 ▲` — up/down colors, no charts on the front. Real data only;
no data, no strip (never placeholder numbers).

### 4.7 Agent bylines
Crew members are named like staff: `by wren (writer) · research: moss ·
ed. hale`. Mono, ink-3, names link to the crew panel filtered to that
agent. The transparency IS the brand: every story signs its machines.
On **story pages** the byline MAY carry the writer's **avatar (sm)** inline
(the OpenPeeps face — see "the crew are characters") to humanize it; the
stack bites keep their bylines clean (no avatar in the stack).

### 4.8 Crew panel (grid · profile · commit console)
Opens from the masthead toggle (◉ crew) on every page — a slide-in right
panel, a **light Notion surface** (white card, soft `--shadow` lift, no
stroke). It is a **character roster**, not a terminal list nor an org chart
(the org-chart spec was retired, founder 2026-06-10). It also renders
**inline on /design** as the specimen. Three parts, top→bottom:

**The character GRID (home view).** A full-bleed responsive grid of character
cards (`grid-template-columns: repeat(auto-fill, minmax(150px, 1fr))`, generous
gap, lots of whitespace). Each card is a Notion-soft surface (`--surface`,
`--shadow`, no stroke, `--r`, lift-on-hover) and a **button**:

```
   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
   │  (face)  │  │  (face)  │  │  (face)  │  │  (face)  │
   │   desk   │  │   moss   │  │   wren   │  │   hale   │
   │ASSIGNMENT│  │ RESEARCH │  │  WRITER  │  │  EDITOR  │
   │● drafting│  │● pulling…│  │● drafting│  │   idle   │
   └──────────┘  └──────────┘  └──────────┘  └──────────┘
```

avatar (circle face, lg), name (sans 600), job type (mono uppercase ink-3:
desk=assignment · moss=research · wren=writer · hale=editor), and a tiny
**status badge** pill — live (wire dot + a `<verb>…` drawn from `doing`) or
"idle". Below the grid: **PIPELINE** counts as Notion stat chips. The whole
card → that member's PROFILE.

**The member PROFILE (click a card).** Replaces the grid with an "about the
author" view: a **larger avatar** with a face→bust→full **crop reveal** — a
small dot control (and click-the-avatar) steps `circle → bust → full`, showing
progressively more of the peep (the fun reveal); name, job type, a one-sentence
honest **bio** (`feed.js` `BIOS`, sourced from `agents/*.org`), and that
agent's **recent commits** (the `/_changes` history filtered to commits it
authored — `sha · message · relative time`). A **← crew** back-arrow returns to
the grid. A byline click deep-links straight into the member's profile.

**The commit CONSOLE (below, terminal-styled, resizable).** A monospace,
dense, scrollable feed of the **whole newsroom commit history** (`/_changes`:
`sha · author · message · time`), tag-colored by message type
(desk/research/write/edit/publish — colors from `lib/commits.js`, within the
B&W + wire palette: research=plum, write=wire, publish=up-green, desk/edit
near-ink). A subtle terminal tint (`--surface` ground, a `$ tail -f` header).
A **draggable horizontal divider** between the top (grid/profile) and the
console resizes it (drag up grows, down shrinks; ArrowUp/Down for a11y); the
height **persists in `localStorage`** (`bitml.crew.consoleH`, clamped 96–520px).

Multiple agents can be live at once — that's the showcase. Data: `/_activity`
(crew) + `/_changes` (commits), polled every ~3s while the panel is open; the
`feed.js` `crewFeed()` / `changesFeed()` specimens stand offline, and the
honest **"specimen data"** tag shows only while the stubs are in use.

### 4.8a The crew are characters (OpenPeeps, local pack)
The crew get **faces**. Avatars are **OpenPeeps** (CC0, Pablo Stanley) drawn by
the **local open-avatars engine** — vendored at `app/src/vendor/open-avatars.js`
+ `open-peeps.bundle.json` (source of truth: `toolkits/open-avatars/`). The
engine is a pure `avatar(bundle, seed, {crop})` → SVG **string** (rendered with
`{@html}`, first-party), deterministic per seed, so `desk`/`moss`/`wren`/`hale`
always render the same face. **No DiceBear, no network** — the pack ships inline,
so the workbook bundle is fully self-contained.

The pack is **monochrome by law** (black ink on white) — avatars are the ONE
place art lives, and they stay B&W. `crop` drives how much shows:
`circle` (round face-crop, default — small uses, the byline + grid cards),
`bust` (head + shoulders), `full` (the whole peep); bust/full power the profile
reveal. The round face sits on a `--wash` (#f5f5f5) circle backplate; bust/full
sit on the surface. Sizes sm 28 / md 44 / lg 64 / xl 132. The wire-blue live dot
is a **badge on the avatar's corner** when an agent is working. **Never used for
humans — only agents.**

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

### 4.11 Interactive story blocks (full-bleed)
The story page lets orgitorial breakout blocks escape the 68ch body column.

**Width contract (page side — implemented in `app.css` + `Story.svelte`):**

| `data-width` | behaviour |
|---|---|
| `wide` | `width: min(92vw, calc(68ch + 24rem))`, centered via `left:50%` + `translateX(-50%)` |
| `full` | `width: 100vw`, `margin-inline: calc(50% - 50vw)` — true full-bleed |

Containers must NOT clip: `overflow: visible` is set on both `.org-mount`
and `.org-mount .org-doc` in `app.css`.

**`Orgitorial.activate(mountEl)`:** after the story body renders into the
DOM, `Story.svelte` calls `window.Orgitorial.activate(mountEl)` if the
vendored orgitorial exposes it (guarded: `typeof window.Orgitorial?.activate === 'function'`).
This is a forward-compatible no-op until the new vendor build lands. The
guard lives in a `$effect` that re-runs whenever `pending` clears.

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
- The crew panel reads the same `/_activity` feed (crew identity + `avatarSeed`)
  plus `/_changes` (the commit history for the console + per-member commits),
  polled while the panel is open (epic wb-wc0 item 2).
- Avatars are the **local open-peeps pack** (vendored, B&W) — never DiceBear,
  never network; the pack inlines into the workbook so it stays self-contained.
- **One theme — light only.** No `data-theme`, no toggle, no terminal skin.
  Every surface (the receipt, the crew panel) is a light Notion surface.
- **Section colors: badge-only.** `--sec-*` vars exist in CSS for reference
  but section color logic lives in `sections.js` as literal hex (one home).
  Components read `sec.color` directly for `color-mix` tinting.
