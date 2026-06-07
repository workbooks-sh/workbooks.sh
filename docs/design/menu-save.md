# Menu & Save System (DESIGN, 2026-06-05)

**Status: buildable design, post-recon. Grounds on `sim/` primitives + `docs/02-technical.md` §5 + `docs/research/localfirst.md` §3. Rulings at next review.**

The save's identity **is** the brand the player made (DECISIONS 2026-06-05, "menu+save"). A slot is a brand: its logo and name are the slot's face; loading a slot resumes that brand's engagement. This doc designs the persistence layer (what is written, where, how atomically, how versioned), the menu/slot-list UI, the New Game flow into the Brand/Product creators, and the autosave hooks into the turn machine.

This system **does not** invent state. Everything persisted already exists as a pure-Lua structure in `sim/` (`game.lua` is the canonical run holder; `namegen.lua` is the brand seed; `ledger.lua` owns the codex). Menu-save serializes those structures and owns the menu shell around them.

---

## 0. The architecture seam (where save code lives)

Per the architecture rule (`docs/02-technical.md` §2), `sim/` is framework-free and knows nothing about Defold. Save work splits across that line:

| Layer | File | Responsibility | Pure? |
|---|---|---|---|
| **Serializer** | `sim/serialize.lua` (NEW) | `Serialize.snapshot(g) -> plain table` and `Serialize.restore(tbl, pack) -> g`. Strips metatables/functions, derives the slot header, round-trips PRNG state. Golden-tested headless. | ✅ pure Lua |
| **Save envelope** | `sim/saveformat.lua` (NEW) | envelope build/verify (magic, `save_version`, `content_format`, checksum), the ordered `migrations` table, schema validation of a loaded payload. | ✅ pure Lua |
| **I/O wrapper** | `game/save.lua` (NEW, Defold shell) | atomic `sys.save`/`sys.load`, `.bak` rotation, `pcall` + fallback, lifecycle-event hooks, settings file. The ONLY place that touches the filesystem. | Defold |
| **Menu screens** | `game/menu/*` (Defold/Druid/Monarch) | Title, Slot List, New Game wizard, confirm dialogs. Renders headers; calls Brand Creator's logo compositor. | Defold |

The serializer and envelope are pure so they run in CI (the save golden test, §7) and so the engine fallback (LÖVE) re-skins only `game/save.lua`. The Defold I/O wrapper is ~150 lines; everything load-bearing (round-trip fidelity, migrations) is testable without an engine.

---

## 1. Three files, three domains, three cadences

Straight from `localfirst.md` §3.1 / `docs/02-technical.md` §5 — corruption blast radius differs per domain, so they never co-mingle.

| File | Domain | Contents | Written when |
|---|---|---|---|
| `settings.dat` | Global | audio · haptics (+intensity) · reduce-motion · CRT toggle · locale · frame-rate policy | on change |
| `profile.dat` (+`.bak`) | Account | **codex** (`Ledger.new_codex`) · meta-unlocks (hireable pool, brand-kit atoms) · lifetime stats · `next_run_id` counter · **slot index** (header cache) | run boundaries + key unlocks |
| `run.<slot>.dat` (+`.bak`) | Run (per slot) | full snapshot of one brand's engagement (the `game.lua` `g` object) + embedded header | day-end · week-close · focus-loss |

**One run file per slot** (`run.0.dat`, `run.1.dat`, …) so a corrupt run never touches a sibling slot or the account. The codex lives in `profile.dat`, **not** in any run file: it is account-scoped (claims canonize across 2 *distinct* runs — `Ledger.codex_status`), exactly the cross-run persistence the recon flagged as separate from per-run saves.

`save_version` is per-file and **independent of `content_format`** (`docs/02-technical.md` §5). A loaded file is migrated by `save_version` then its content ids are reconciled by `content_format`/alias table.

---

## 2. The save envelope (every file)

```lua
{
  magic         = "ADDM",      -- reject foreign files fast
  save_version  = 1,           -- bumped on breaking shape change; drives migrations
  content_format = 1,          -- matches sim/content.lua pack version; drives id aliasing
  checksum      = 0xDEADBEEF,  -- FNV-1a over a CANONICAL (ordered) dump of payload
  payload       = { ... },     -- domain body (§3)
}
```

**Checksum canonicalization is mandatory, not optional.** Lua `pairs()` order is unspecified (`localfirst.md` §4.3); a naive hash of the table would differ run-to-run and falsely flag good saves as corrupt. Reuse the ordered-fold approach already proven in `sim/golden.lua` / `Wave.state_hash` (sort keys, concat in order, FNV-1a via the helper in `sim/rng.lua`). The serializer emits arrays-of-pairs for any map it hashes so the dump order is stable.

**Load sequence** (`game/save.lua`):
1. `pcall(sys.load, path)` — Defold raises on corrupt files since 1.10.3; catch it.
2. verify `magic` + recompute checksum; mismatch → try `path..".bak"`; both bad → mark slot `CORRUPT` (do **not** delete; keep the header readable so the player sees their brand, not an empty slot).
3. if `save_version < CURRENT`: copy file to `run.<slot>.dat.pre-v<N>`, then apply `migrations[N]`, `migrations[N+1]`, … (ordered, pure functions on the payload). `docs/02-technical.md` §5.
4. reconcile content ids through the alias/retired table (`content_format`), then schema-validate the payload (same discipline as `sim/content.lua`'s loader).
5. hand payload to `Serialize.restore`.

**Atomic write** is free on Defold: `sys.save` writes `*.defoldtmp_*` then renames (verified in engine source, `localfirst.md` §3.2). Caveats respected: ≤512 KB output, ≤65 536 rows per table — our state is KB-scale; §6 keeps it bounded. `.bak` rotation rule: rotate `run.<slot>.dat → .bak` **only after** the new write verifies (load-back checksum), so a bad write can never clobber the last good `.bak`.

---

## 3. Payload shapes

### 3.1 Run payload (`run.<slot>.dat`) — snapshot of `game.lua`'s `g`

**Decision: the run-save is a full structural snapshot of `g`, not journal-replay.** Rationale: `game.lua` holds ALL run state — `bank`, `collection`, `desk`, `ledger`, `combo_book`, `wear`, `stats`, and the embedded wave `run` — and the economic/meta mutations (pack buys, hires, V2 mints, wear exposure, note minting) happen in `Game.play_wave`'s bookkeeping, which is **not** in the wave journal. Snapshotting is robust to that; journal-replay would require lifting every meta-command into one account-level journal first (deferred, §8). This matches `localfirst.md` §3.1's primary recommendation ("snapshot, don't journal" for production; journal as a dev facility).

```lua
payload = {
  header = { ... },          -- §3.3, duplicated here as source-of-truth
  run_id = 7,                -- stable, allocated from profile.next_run_id (codex needs it)
  seed   = 0x...,            -- g.seed
  pack_id = "core",          -- reference, NOT the pack itself (rebuilt from bundle on load)

  -- brand identity + logo recipe (the save's face; §3.3 mirrors this into header)
  brand = {
    name = "Hearth & Hew", pattern = "amp", vertical = "cookware",
    traits = { "heritage", "rustic", "earnest" }, palette_id = 4,
    logo = { container_id = 3, glyph_id = "whisk", color_ids = {12, 4}, font_id = 2, layout_id = 5 },
  },

  -- product roster (NEW schema; Product Creator owns the full shape, §3.4)
  products = { roster = { {...} }, unlocked_offer_ids = { "off_bundle" }, tech_tier = 1 },

  -- economy / collection (sim/economy.lua)
  bank = { cents = 64500 },
  collection = { owned = {"hook_pain","vis_ugc",...}, ip = 3, tempo_tags = 1 },
  minted_cards = { ["off_bundle:v2"] = { id=..., rarity=..., aspects={...}, foil=true } },

  -- run-scoped knowledge & state
  ledger = { notes = {...}, by_key = {...} },     -- Ledger.new_run_ledger shape
  combo_book = { uses = {...} },                  -- Composer.new_combo_book shape
  desk = { slots = 2, hires = {...} },            -- Team.new_desk shape
  wear = { lane_cold = { hook_pain = {...} } },   -- Fatigue wear per (lane,card)
  stats = { calibrated_ads=4, launched_ads=11, ... },

  -- the wave machine (sim/wave.lua run); FLIGHT fields present only mid-week
  wave = {
    state="FLIGHT", pips=3, client_i=1, wave_in_client=2, global_wave=2,
    ap=3, tick=72, plan_ticks=360, ticks_per_day=72,
    builds={...}, pins={...}, clean_test_count=1, last_result={...},
    ads={...}, ad_imps={...}, prev_cum={...}, pace={...},
    rng_states={ [1]={x,y,z,w}, [2]={x,y,z,w} },   -- per-ad funnel PRNG, see below
    journal={...},                                  -- kept for bug-report/replay, not load-bearing
  },
}
```

**PRNG serialization is small and bounded — the key insight.** Because the codebase derives every substream on demand from `(seed, name)` (`Rng.substream` in `economy.lua`, `director.lua`, `resonance.lua`, etc.), those streams carry **no persistent state between uses** — they are reconstructed identically from the saved `seed`. The **only** live PRNG state that must be serialized is `run.rngs[i]` (the per-ad funnel streams created in `Wave.add_ad`), and only while a flight is in progress. `Serialize.snapshot` calls `rng:state()` on each (returns `{x,y,z,w}`); `restore` calls `Rng.restore(st)`. Outside FLIGHT (BRIEF/BUILD/NEWSSTAND between days), there is no live PRNG and `rng_states` is omitted.

**Save points are always day-aligned.** The turn-based loop only ever pauses at day boundaries (plan → End Day → ceremony → next morning). So a mid-week snapshot is always at `tick % ticks_per_day == 0` with `run.pending == {}`. We never serialize a sub-day partial tick. Focus-loss *during* the resolution ceremony is handled by saving **after** the ceremony's state mutation completes (§5), so resume just re-plays the already-saved result.

**What is NOT serialized (rebuilt on load from `pack_id`):** `g.pack`, `g.cards` (id→def map), `g.lanes` (`.rlane` is rebuilt lazily per client by `Game.current_lane`). `Serialize.restore(payload, pack)` re-runs the `Game.new` table-build over the bundled pack, then overlays the saved mutable state, then re-adds `minted_cards` into `g.cards` (V2 foils are generated, not baked — their full defs MUST persist, keyed by id, or `collection.owned` references dangle).

### 3.2 Account payload (`profile.dat`)

```lua
payload = {
  codex = { claims = { ["offer_strength:PRODUCT:CVR:1"] = { runs={3,7}, run_set={...} } },
  meta_unlocks = { hireable_pool = {...}, brand_kit_atoms = {...} },  -- broaden-only (pillar 3)
  lifetime_stats = { runs_started=9, runs_won=2, cards_seen=41, ... },
  next_run_id = 8,                                  -- monotonic; allocated at New Game
  slot_index = { [0]={header}, [1]={header}, [2]={header} },  -- header cache for fast menu
}
```

`next_run_id` lives here because **menu-save owns run_id allocation** — the codex's CANON rule (`Ledger.codex_status`: confirmed in 2 *distinct* runs) needs globally distinct run ids, and only the account scope can guarantee monotonic uniqueness across slots. Allocated once at New Game, stamped into the run payload, fed to `Ledger.codex_observe(codex, run_id, claim)` at autopsy.

### 3.3 The slot header (the menu's currency)

A small (~few hundred bytes) record, embedded in each run file **and** cached in `profile.slot_index`. The run file's copy is source-of-truth; the index is a render cache. On menu open, if a run file exists, trust its embedded header and refresh the cache (reconcile-on-mismatch).

```lua
header = {
  slot = 0,
  brand_name = "Hearth & Hew",
  logo = { container_id=3, glyph_id="whisk", color_ids={12,4}, font_id=2, layout_id=5 },
  vertical = "cookware",
  progress = { client_i=1, client_total=2, week=2, day=4, pips=3 },
  bank_cents = 64500,
  status = "ACTIVE",            -- ACTIVE | WON | FIRED | CORRUPT
  saved_at = 1749200000,        -- wall-clock, display only (never enters sim)
  save_version = 1,
}
```

The header is everything the slot list needs to draw a slot without deserializing the full run. The `logo` recipe is rendered by the Brand Creator's logo compositor (dependency, §6) — menu-save stores the recipe (all integer/string atom ids, deterministic) and never owns pixels.

### 3.4 Product roster (NEW schema — minimal here, owned by Product Creator)

A product is not yet a sim entity (recon). Menu-save persists the roster as opaque, id-stable data; the Product Creator doc defines the full shape and the sim wiring (AOV/CVR/which offers exist). Minimal v1 contract menu-save relies on:

```lua
product = { id="cookware_skillet_1", category="cookware", subcategory="skillet",
            name="Copper Skillet No. 3", aov_cents=4500, tech_tier=0,
            offer_ids={"off_bundle"}, fbx_id="skillet_a", label_decal_ref="brand.logo" }
```

`roster[1]` is seeded from `Namegen.identity().starting_product` at New Game; tech-tree unlocks append (the array grows, never rewrites — id-stable). Persisting an array of these is all menu-save needs; it treats the inner fields as data.

---

## 4. Menu / screen flow

Landscape, built from `design/design-language.html` components only (DECISIONS design-language v0.1; chunky rounded, FB-blue #3b5998, Baloo 2 + Nunito). No new component invented.

```
TITLE
 ├─ CONTINUE        → loads most-recent ACTIVE slot straight to The Desk
 ├─ PLAY / LOAD     → SLOT LIST
 ├─ CODEX           → reads profile.dat codex (drawer)
 └─ SETTINGS        → settings.dat editor
```

### 4.1 Slot list

Up to **3 slots** (v1). Each slot is a chunky brand card:

```
┌───────────────────────────────┐   ┌───────────────────────────────┐
│  [LOGO]  Hearth & Hew          │   │             ＋                 │
│          Cookware · Week 2     │   │       New Brand                │
│          ●●● $645   3 days ago │   │                                │
│        [ CONTINUE ]  [ ⋯ ]     │   │   [ Start a new engagement ]   │
└───────────────────────────────┘   └───────────────────────────────┘
```

- **[LOGO]** = Brand Creator compositor over `header.logo`. The slot's face — this is what "keyed to brand name + logo" means literally.
- progress line = `header.progress` (client X/Y · Week W · Day D), pips as `●`, bankroll from `header.bank_cents`, relative `saved_at`.
- `[⋯]` → Delete (confirm dialog; never one-tap — losing a brand "costs the player's life", `localfirst.md` §3.1). (Rename/duplicate deferred, §8.)
- Empty slot → `New Brand` tile → New Game wizard.
- `status="CORRUPT"` slot renders with a warning chip and a "Restore from backup / Discard" choice; the header still shows the brand so the loss is legible.
- `status="WON"`/`"FIRED"` slots show a stamp and offer "View Case Study" (read-only) — the slot is kept as a record (New Game+ deferred).

### 4.2 New Game flow → creators → first week

```
New Brand
  └─ allocate slot + run_id (profile.next_run_id++)        [menu-save]
  └─ draw a seed; Namegen.identity(rng, vertical) seeds defaults
  └─ BRAND CREATOR    (pick vertical → logo kit → wordmark/name)   [Brand Creator]
  └─ PRODUCT CREATOR  (pick category + starting product)           [Product Creator]
  └─ build the run:                                        [menu-save]
        g = Game.new(seed, pack)
        overlay brand identity (name/logo recipe) + products.roster[1]
        write run.<slot>.dat  +  profile slot_index[slot]   ← the brand now persists
  └─ CLIENT SIGNING → WEEK BRIEF → THE DESK (flows.md screens 2→3)
```

The moment the initial run file is written (right after the creators, before the first day), the brand is durable — a crash during Week 1 Day 1 resumes the created brand, never a blank. Brand/Product creators can ship as stubs and this flow still works (seed from `Namegen.identity` directly); menu-save is not blocked on them for the write path, only the slot-list **logo render** is (§9 risk).

---

## 5. Autosave hooks into the turn machine

The sim emits the events; the Defold turn controller catches them and calls `game/save.lua`. The sim never calls save (architecture rule).

| Trigger | Sim signal | Action |
|---|---|---|
| **Day end** | `Wave.advance`/`Wave.end_day` returns an event `{type="day_end", day=N}`, after `game.lua` applies that day's bookkeeping | `Save.write_run(slot, g)` — the structural per-day autosave (flows.md: "clean exit at EVERY day boundary; autosave is structural") |
| **Week close** | autopsy event `{type="autopsy", state=...}` → NEWSSTAND; `play_wave` has applied payout/wear/notes; `Ledger.codex_observe(codex, run_id, claim)` ran | `Save.write_run(slot, g)` **and** `Save.write_profile()` (flush codex + lifetime stats) |
| **Run end** | wave `state` ∈ {`RUN_WON`, `FIRED`} | final `write_run` (`header.status` set) + `write_profile`; slot becomes a record |
| **Focus loss / background / quit** | Defold `WINDOW_EVENT_FOCUS_LOST` / iconify | `Save.write_run(slot, g)` if a run is live (iOS gives no quit guarantee — `localfirst.md` §3.2) |
| **Settings change** | UI | `Save.write_settings()` |

**Ceremony ordering rule:** the day's autosave fires **after** the resolution ceremony's state mutation is committed to `g`, not after its animation. The ceremony (`flows.md` Night Resolution) is a non-interactive replay of an already-decided result, so focus-loss mid-animation just re-plays the saved result on resume — no partial-ceremony state ever persists. This is what keeps "save points are always day-aligned" (§3.1) true.

**Resume path:** Title → Continue → `Save.read_run(slot)` → `Serialize.restore(payload, pack)` → drop the player back on The Desk at the saved morning. No offline progress, no catch-up (DECISIONS: time freezes when the app closes; `localfirst.md` §5.2 ships option 1).

---

## 6. Asset & dependency needs (menu-save specific)

Light — the menu reuses the component library; the heavy visual dependency is owned by Brand Creator.

- **Logo compositor + atom tables** (Brand Creator deliverable) — REQUIRED to render slot faces. Until it exists, slots render a placeholder mark + name (§9).
- Slot-card frame, empty-slot tile, confirm-dialog modal, warning chip, pip/meter atoms, relative-time label — all **already in** `design/design-language.html`; assemble, don't invent (DECISIONS design-language ruling).
- A subtle "saved" micro-indicator (Phosphor Fill icon, runtime-tinted per the icon ruling) — one new atom, optional.
- No new fonts, no new audio.
- Pure-Lua deps: `sim/rng.lua` (FNV + `state`/`restore`), `sim/golden.lua` (ordered-hash pattern to reuse for the checksum). No new third-party libs.

---

## 7. Testing (the save golden test)

Mirror the determinism discipline already in `sim/golden.lua`. All pure, all headless in CI:

1. **Round-trip fidelity:** for a run advanced to assorted states (BUILD, mid-FLIGHT at a day boundary, NEWSSTAND, post-autopsy), assert `Wave.state_hash(restore(snapshot(g)).run) == Wave.state_hash(g.run)` **and** a new `Game.state_hash(g)` (ordered fold over bank/collection/ledger/combo_book/wear/desk/stats) matches. Snapshot→restore is identity.
2. **Continue-equivalence:** a run saved mid-week and resumed produces the **same** final `state_hash` as the same run never saved — proves PRNG/`rng_states` capture is complete. (This is the test that catches any future system that adds an un-serialized persistent substream — §9 risk.)
3. **Migration fixtures:** one checked-in fixture save per shipped `save_version`, loaded + migrated to current + schema-validated, every CI run (`docs/02-technical.md` §5; the only thing that makes update-day safe).
4. **Size budget assertion:** serialized run payload ≤ a CI ceiling (well under Defold's 512 KB / 65 536-row caps); guards against `wear`/`owned`/`minted_cards` growth.
5. **Checksum stability:** snapshot the same `g` twice → identical canonical dump + checksum (proves the ordered-fold defeats `pairs()` nondeterminism).

---

## 8. MVP scope (v1)

- 3 fixed slots; `settings.dat` + `profile.dat`(+`.bak`) + `run.<slot>.dat`(+`.bak`).
- Envelope with `magic` + `save_version` + `content_format` + canonical FNV checksum; `pcall`+`.bak` fallback; `CORRUPT` slot state (never auto-delete).
- `sim/serialize.lua` (snapshot/restore) + `sim/saveformat.lua` (envelope + `migrations` v0→v1 stub + schema validate), both golden-tested (§7).
- `game/save.lua` Defold I/O wrapper: atomic `sys.save`, verified-then-rotate `.bak`, lifecycle hooks.
- Autosave on day-end, week-close, run-end, focus-loss; settings on change.
- `next_run_id` allocation; codex persisted in `profile.dat`; `Ledger.codex_observe` wired at autopsy.
- New Game wizard → Brand Creator → Product Creator → write initial run → Week 1.
- Slot list: header render (logo via Brand Creator compositor when available, else placeholder), Continue, Delete-with-confirm, Continue-from-Title shortcut.
- Alias/retired-id table mechanism present (table may ship empty) so Live Update content removals don't brick saves later.

## 9. Explicitly deferred

- **Journal-replay production saves / shareable seeds / ghosts / daily challenges.** The wave journal stays a dev bug-report + golden-verification facility, not the save source-of-truth. Requires lifting all meta-commands (pack buys, hires, V2 mints, shop) into one account-level journal first.
- **Cloud sync / iCloud Documents / Android Auto Backup.** Kept *possible* by the single-versioned-document discipline (profile + per-slot run), built later — DECISIONS open question, due by beta (Phase 4).
- **New Game+ / Case Study archive browser** beyond a read-only stamp on finished slots.
- **Slot rename / duplicate / unlimited slots.**
- **Sub-day (mid-tick) snapshots** — unnecessary; the turn-based loop only pauses at day boundaries.
- **Bounded offline catch-up** — remains a one-function policy switch (`localfirst.md` §5.2 option 2), not built.
- **Migrations beyond the v0→v1 framework** — the harness + fixture discipline ship; real migrations arrive with the first breaking change.

## 10. Risks

- **Un-serialized persistent PRNG:** today only per-ad funnel streams carry live state. Any future system that holds a substream across ticks must add it to `rng_states` or resume desyncs — test #2 (continue-equivalence) is the tripwire.
- **Snapshot↔journal divergence:** choosing snapshot means the wave journal is *not* the save truth; keep the two test suites separate (golden journal-replay vs save round-trip) so they can't quietly drift, and document that pack-buys/hires/mints are captured only by snapshot.
- **Checksum nondeterminism via `pairs()`:** the checksum MUST fold over an ordered/canonicalized dump (reuse `golden.lua`); a naive hash would brand good saves corrupt. Highest-likelihood footgun.
- **Content id stability across Live Update:** removed/renamed card ids in a save dangle without the alias/retired table; ship the mechanism in v1 even empty (retrofitting into shipped saves is painful — `docs/02-technical.md` §5).
- **Defold `sys.save` limits (512 KB / 65 536 rows):** `wear` (lane×card nested) and `owned`/`minted_cards` are the growth vectors; CI size assertion (test #4) + compact array encodings keep headroom.
- **Header-cache consistency:** `profile.slot_index` can lag the run file (e.g. profile write fails after run write). Run-file embedded header is source-of-truth; reconcile on menu open.
- **iOS no-quit-guarantee:** must save on focus-loss; `.bak` rotates only after a verified-good write so a kill mid-write can't destroy the last good backup.
- **Brand Creator dependency:** the slot list can't render real logos until the compositor + atom tables exist. Build order: menu-save's write/load path is independent and can land first with a placeholder mark; the logo render lands when Brand Creator does.
- **5-day `flight_cfg` vs 7-day week:** `game.lua` currently configures `days=5` while the new loop is Mon–Sun (7). Autosave keys off `day_end` events regardless of count, so menu-save is insulated — but flagged as an external sim reconciliation the loop owner must settle.
```
