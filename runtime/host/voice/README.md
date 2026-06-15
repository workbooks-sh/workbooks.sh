# Voice agent (wb-091n)

Our own full-duplex voice loop for the desktop coding agent — no LiveKit, no
ElevenLabs-Agents black box. STT is on-device; the brain and TTS are
host-brokered so credentials never leave the nexus.

```
desktop                          nexus (this dir)
─────────                        ─────────────────────────────────────────
mic → Moonshine STT ──transcript──▶ Stream (WS /api/voice/:id)
                                       └▶ Session: Llm.complete (brain, OpenRouter)
                                            └▶ sentence-chunk ▶ Inworld TTS ──PCM──┐
PcmPlayer ◀──────────────── binary PCM frames + {speaking_start/reply_text/end} ◀─┘
   ▲
   └ barge-in: Moonshine interim → flush playback + {barge_in} → kills server TTS
```

## Pieces

- `inworld.ex` — streaming TTS broker. POSTs `voice:stream`, parses NDJSON
  `audioContent` → emits raw LINEAR16 PCM chunks. `INWORLD_API_KEY` (HTTP Basic,
  a base64 `client:secret`) is read host-side via `Workbooks.Secrets`. Cancellable.
- `session.ex` — one turn: streams the brain, flushes each complete sentence to a
  `spawn_link`ed TTS worker (so audio starts before the reply finishes), strips
  markdown from spoken text. Barge-in = kill the driving task; the linked worker
  and in-flight Inworld stream die with it.
- `stream.ex` — the `WebSock` handler. Up: `{"type":"transcript"|"barge_in"}`.
  Down: binary PCM @ 24kHz + JSON `speaking_start`/`reply_text`/`speaking_end`.

Client: `desktop/src/lib/live/inworld.svelte.ts` + `pcm.ts`.

## Config

- `INWORLD_API_KEY` (required) — Inworld TTS. Model `inworld-tts-1.5-max`,
  $35 / 1M chars on-demand (≈ $0.035/min of speech), per-character, voice-agnostic.
  Warm first-audio ~0.6s.
- `WB_VOICE_BRAIN_MODEL` (optional) — fast LLM for spoken replies; falls back to
  the default `Workbooks.Llm` model. The voice brain favors TTFT over smarts; the
  code lane stays on `mercury-2`.

## Status

Server loop verified end-to-end (brain → streamed PCM). Open: UI mount
(`wb-091n.5`), `write_code` → mercury-2 → editor canvas (`wb-091n.6`), in-app mic
E2E. Fly GPUs are EOL (Jul 2026) but this loop needs none — TTS is a token API.
