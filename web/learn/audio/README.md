# learn audio — the narrated-episode pipeline

One fully-produced episode per learn page (NYT-Daily register): v3 narration
with audio tags + a dynamic cue score composed per lesson. ~6–11 min each.

## Pipeline

```
scripts/<slug>.json       narration scripts (per-section segments + outro)
   │  XI_API_KEY=… node generate.mjs [slug]     ← ElevenLabs v3 + timestamps
raw/ align/               per-segment takes + character alignments
   │  XI_API_KEY=… node cues.mjs [slug]         ← Music API, composition plans
cues/<slug>-{intro,turn1,turn2,turn3,outro}.mp3
   │  node compose.mjs [slug]                   ← ffmpeg score + mixdown
episodes/<slug>.mp3 + manifest.json             ← what the player serves
```

The player (`../audio.js`) reads `manifest.json`: episode list (jump across
lessons), chapter seek within an episode, desktop hero dock + mobile
bottom-bar → full-screen sheet.

## Writing for audio — THE RULES (learned the hard way)

1. **Rewrite lists for the ear.** Page prose does `Files — a workspace…
   Processes — real programs… Memory — …` and the eye copes. Spoken, it
   reads as a flat run-on. Enumerate explicitly: *"First, files… Second,
   processes… Third, memory… and fourth — time."* Same for any
   hyphen/bullet construction: give it spoken connective tissue
   ("and finally", "on top of that", "last one"). Never read a table —
   pick the two cells that matter and say a sentence about them.

2. **Proven audio tags ONLY.** v3 accepts free-form tags but unreliable
   ones get spoken aloud or ignored. The set that works:
   `[curious] [excited] [chuckles] [laughs] [sighs] [exhales] [whispers]
   [sarcastic] [mischievously] [clears throat]`.
   Do NOT invent mood tags (`[warm]`, `[thoughtful]`, `[serious]` were all
   read as words at least once). Mood comes from the prose itself.

3. **NO double quotes in narration text.** v3 treats a quote-led sentence
   as stage direction and silently skips it — fourteen segments lost their
   opening rhetorical questions this way ("Isn't this just a zip file?"
   was never spoken). Write the words without quote marks; delivery tags
   and sentence shape carry the "voicing a question" feel.

4. **Pauses are ellipses.** `…` is a real beat in v3. Use it for thought
   rhythm; use `—` for mid-sentence pivots. No SSML.

5. **Tags need earning.** ~10–15 per episode, each at a moment the text
   actually supports ([chuckles] after a genuinely wry line). A tag against
   the grain of the sentence does nothing.

6. **Voice + settings** (generate.mjs): voice `q0IMILNRPxOgtBTS4taI`,
   `eleven_v3`, stability `0.0` (creative — maximum tag response).
   A future switch to another voice is one constant + a regen pass.

## Music — tunes, not atmospheres

Cue prompts say *1970s library music, warm electric piano, melodic, gentle
rhythm*, and the negatives kill the failure mode: *ambient drone, eerie,
suspense, cinematic pads*. "Cinematic/ambient/intimate synth" vocabulary
produces creepy washes — don't reintroduce it.

Score shape per episode (compose.mjs):
- **intro** cue sized to the intro narration (composition-plan sections are
  exact): title melody alone ~3s → quiet undercurrent under the whole
  opening section → the theme returns to button it off in the first pause →
  silence; dry reading begins.
- **turn1/2/3** at a few chosen sections (TURNS map) — distinct cues
  (piano motif / plucked strings + flute / main-theme reprise), riser
  starting under the previous section's closing words.
- **outro** builds under the final lines and resolves after the voice ends.
- Light sidechain (`ratio 3.5`) keeps tails polite; the dynamics live in
  the cues themselves, not the ducking.

## Regenerating

Per-asset idempotence: delete the file you want remade and rerun that stage
(`rm raw/agents--*.mp3 && node generate.mjs agents`). The API key is never
committed — pass `XI_API_KEY` in the environment.
