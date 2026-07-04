/**
 * Fish voice transport (wb-q29ga) — the full-duplex voice loop with the REAL
 * agent brain, succeeding both the Gemini Live black box and the never-shipped
 * Inworld WS transport.
 *
 * Placement: RENDERER-DIRECT for everything that needs Web APIs (mic, on-device
 * STT, playback); the nexus sidecar for the brain (the normal chat runtime — the
 * same agent/tools as typed chat) and for TTS (`POST /api/voice/tts`, a neutral
 * runtime primitive over Nexus.FishAudio). No provider key ever reaches this
 * renderer — the FISH_API_KEY stays host-side, unlike the legacy Gemini path
 * that revealed its key into the WS URL.
 *
 * The loop per turn:
 *   Moonshine commits an utterance → chatSession.send() runs the real agent →
 *   the final reply is sentence-chunked → each sentence hits /api/voice/tts
 *   (format=pcm @24kHz, prefetched one ahead) → PcmPlayer schedules gaplessly.
 *
 * Barge-in: Moonshine's interim callback fires the moment the user talks over
 * the agent — we flush playback, abort in-flight TTS fetches, and drop the
 * rest of the utterance queue (generation counter).
 *
 * Degradation: no mic/STT → text-driven session (injectUtterance still speaks
 * replies); TTS 503 (no FISH_API_KEY on the nexus) → caption-only, latched for
 * the session so we don't re-probe per sentence.
 */
import { moonshineStt } from "$lib/stt/moonshine.svelte";
import { sidecar } from "$lib/bridge/sidecar.svelte";
import { PcmPlayer, playConnectChime } from "./pcm";

export interface FishCallbacks {
  /** A finalized user utterance (Moonshine committed). */
  onUserTranscript?: (text: string) => void;
  /** Agent reply caption fragment — concatenate for the full line. */
  onAgentTranscript?: (text: string) => void;
  /** Agent finished speaking a turn. */
  onTurnComplete?: () => void;
  /** The code lane produced code — shown in the editor, never spoken. */
  onCode?: (task: string, code: string) => void;
  onError?: (message: string) => void;
  onClose?: () => void;
}

type State = "idle" | "connecting" | "live" | "closing" | "error";

const OUTPUT_RATE = 24_000;
/** Sentences shorter than this merge into the next chunk — tiny TTS calls
 *  waste round trips and sound choppy. */
const MIN_CHUNK_CHARS = 24;

class FishLiveSession {
  state = $state<State>("idle");
  error = $state<string | null>(null);
  /** True while the agent is speaking (or a turn's audio is still queued). */
  speaking = $state(false);
  /** When muted, committed utterances aren't sent — the mic stays open (so
   *  barge-in still works) but the user's words don't reach the agent. */
  muted = $state(false);
  outputLevel = $state(0);
  /** Last turn's utterance→first-audio latency, ms — the TTFA gate metric
   *  (wb-q29ga.5 reads this; also logged as [voice.ttfa]). */
  lastTtfaMs = $state<number | null>(null);

  active = $derived(this.state === "live");
  busy = $derived(this.state === "connecting" || this.state === "closing");
  present = $derived(this.state !== "idle");

  #player: PcmPlayer | null = null;
  #cb: FishCallbacks = {};
  #raf = 0;
  /** Bumped on barge-in/teardown; speech tasks from older generations stop. */
  #gen = 0;
  #abort: AbortController | null = null;
  /** Latched false after the first 503 — the nexus has no speech provider. */
  #ttsAvailable = true;
  /** Text-driven session (no mic/STT) — replies still speak when TTS is up. */
  #preview = false;

  async start(callbacks: FishCallbacks = {}): Promise<void> {
    if (this.state !== "idle" && this.state !== "error") return;

    this.#cb = callbacks;
    this.state = "connecting";
    this.error = null;
    this.#preview = false;
    this.#ttsAvailable = true;

    if (!sidecar.status.url) {
      this.#fail("Agent server isn't running.");
      return;
    }

    this.#player = new PcmPlayer(OUTPUT_RATE);

    try {
      // Bound STT startup: getUserMedia can hang indefinitely where there's no
      // mic and no permission prompt to resolve. If it doesn't come up
      // promptly, fall back to the text-driven session — the panel still runs
      // real agent turns (and still speaks them).
      await Promise.race([
        this.#startStt(),
        new Promise((_, rej) => setTimeout(() => rej(new Error("stt-timeout")), 2500)),
      ]);
    } catch {
      this.#preview = true;
    }

    this.state = "live";
    this.#exposeInjectHook();
    playConnectChime();
    this.#startLevelLoop();
  }

  /** Expose a host-driver injection hook on the window (demo recorder) — feeds
   *  a "spoken" prompt through the same path a finalized utterance takes. */
  #exposeInjectHook(): void {
    if (typeof window === "undefined") return;
    (window as unknown as { __wbVoiceInject?: (t: string) => Promise<void> }).__wbVoiceInject =
      (t: string) => this.injectUtterance(t);
  }

  /** Inject a "spoken" user utterance and drive a REAL agent turn (text-chat
   *  runtime path → real inference + tool calls), then speak the reply. */
  async injectUtterance(text: string): Promise<void> {
    const t = text.trim();
    if (!t || this.state !== "live" || this.muted) return;
    await this.#runTurn(t);
  }

  async end(): Promise<void> {
    if (this.state === "idle") return;
    this.state = "closing";
    await this.#teardown();
    this.state = "idle";
    this.#cb.onClose?.();
  }

  toggleMute(): void {
    this.muted = !this.muted;
  }

  async #startStt(): Promise<void> {
    await moonshineStt.start(
      (text) => {
        // Finalized utterance → run a turn (unless muted).
        if (this.muted || this.state !== "live") return;
        void this.#runTurn(text);
      },
      () => {
        // Interim words while the agent is talking = barge-in.
        if (this.speaking) this.#bargeIn();
      },
    );
  }

  /** One full turn: caption the utterance, run the real agent, speak the reply. */
  async #runTurn(text: string): Promise<void> {
    const gen = this.#gen;
    const startedAt = performance.now();
    this.#cb.onUserTranscript?.(text);
    this.speaking = true;

    try {
      const { chatSession } = await import("$lib/chat/session.svelte");
      await chatSession.send(text, { agentSlug: "waldo" });
      const reply = await this.#awaitReply(chatSession, 45_000);
      if (gen !== this.#gen || this.state !== "live") return;

      if (reply) {
        this.#cb.onAgentTranscript?.(reply);
        await this.#speak(reply, gen, startedAt);
      }
    } catch (err) {
      if (gen === this.#gen) {
        this.#cb.onError?.(err instanceof Error ? err.message : String(err));
      }
    } finally {
      if (gen === this.#gen) {
        this.speaking = false;
        this.#cb.onTurnComplete?.();
      }
    }
  }

  /** Poll the shared chat session until the agent run completes (or times out),
   *  then return the final assistant message text. */
  async #awaitReply(
    chatSession: {
      session: { status?: string } | null;
      blocks: Array<{ kind: string; pending?: boolean; text?: string }>;
    },
    timeoutMs: number,
  ): Promise<string | null> {
    const deadline = Date.now() + timeoutMs;
    const terminal = new Set(["completed", "failed", "cancelled"]);
    while (Date.now() < deadline) {
      const status = chatSession.session?.status;
      if (status && terminal.has(status)) break;
      if (this.state !== "live") return null;
      await new Promise((r) => setTimeout(r, 200));
    }
    const reply = [...chatSession.blocks]
      .reverse()
      .find((b) => b.kind === "message" && !b.pending && b.text);
    return reply?.text ?? null;
  }

  /** Sentence-chunk the reply and stream it through /api/voice/tts. Sentences
   *  play strictly in order (each streams fully into the player before the
   *  next starts draining), with the NEXT request opened one ahead so its
   *  synthesis overlaps the current playback. Barge-in (gen bump) aborts. */
  async #speak(reply: string, gen: number, startedAt: number): Promise<void> {
    if (!this.#ttsAvailable || !this.#player) return;
    const chunks = sentenceChunks(reply);
    if (chunks.length === 0) return;

    this.#abort = new AbortController();
    const signal = this.#abort.signal;
    let firstAudio = true;

    const onAudio = () => {
      if (firstAudio) {
        firstAudio = false;
        this.lastTtfaMs = Math.round(performance.now() - startedAt);
        console.info("[voice.ttfa]", this.lastTtfaMs, "ms");
      }
    };

    // One request of lookahead: OPEN i+1's request (the server starts
    // synthesizing on arrival) while i's bytes stream into the player — but
    // only DRAIN one body at a time, or the two streams would interleave
    // into the shared playback queue.
    let next = this.#openTts(chunks[0], signal);
    for (let i = 0; i < chunks.length; i++) {
      const current = next;
      next = i + 1 < chunks.length ? this.#openTts(chunks[i + 1], signal) : null!;
      const res = await current;
      if (gen !== this.#gen || this.state !== "live") return;
      if (res === null) return; // TTS unavailable — captions carry the turn.
      const ok = await this.#drainTts(res, gen, onAudio);
      if (gen !== this.#gen || this.state !== "live" || !ok) return;
    }

    // Hold `speaking` until the scheduled audio actually drains (or barge-in).
    while (gen === this.#gen && this.state === "live" && this.#player?.playing) {
      await new Promise((r) => setTimeout(r, 100));
    }
  }

  /** Open one sentence's TTS request. The server begins synthesizing (and
   *  buffering into the socket) as soon as the request lands — the body is
   *  drained later, in playback order. null when TTS is unavailable. */
  async #openTts(text: string, signal: AbortSignal): Promise<Response | null> {
    const base = sidecar.status.url;
    if (!base || !this.#ttsAvailable) return null;

    try {
      const headers: Record<string, string> = { "content-type": "application/json" };
      const token = sidecar.status.token;
      if (token) headers["authorization"] = `Bearer ${token}`;

      const res = await fetch(`${base}/api/voice/tts`, {
        method: "POST",
        headers,
        signal,
        body: JSON.stringify({ text, format: "pcm", sample_rate: OUTPUT_RATE }),
      });

      if (res.status === 503) {
        // No speech provider on this nexus — latch caption-only for the session.
        this.#ttsAvailable = false;
        return null;
      }
      if (!res.ok || !res.body) return null;
      return res;
    } catch {
      return null; // Aborted (barge-in) or transport error — never breaks the turn.
    }
  }

  /** Drain one opened response into the player AS BYTES ARRIVE (chunked proxy
   *  → first audio at Fish's TTFB, not after the whole clip). Chunk boundaries
   *  aren't frame-aligned — a carry buffer keeps int16 alignment. */
  async #drainTts(res: Response, gen: number, onAudio: () => void): Promise<boolean> {
    try {
      const reader = res.body!.getReader();
      let carry = new Uint8Array(0);
      let pushedAny = false;

      for (;;) {
        const { done, value } = await reader.read();
        if (gen !== this.#gen) {
          void reader.cancel().catch(() => {});
          return false;
        }
        if (done) break;
        if (!value || value.byteLength === 0) continue;

        // Re-align to whole int16 frames across arbitrary chunk boundaries.
        const buf = new Uint8Array(carry.byteLength + value.byteLength);
        buf.set(carry, 0);
        buf.set(value, carry.byteLength);
        const usable = buf.byteLength - (buf.byteLength % 2);
        carry = buf.slice(usable);

        if (usable > 0) {
          onAudio();
          pushedAny = true;
          this.#player?.push(buf.slice(0, usable).buffer as ArrayBuffer);
        }
      }

      return pushedAny;
    } catch {
      return false; // Aborted (barge-in) or transport error — never breaks the turn.
    }
  }

  #bargeIn(): void {
    this.#gen++;
    this.speaking = false;
    this.#abort?.abort();
    this.#abort = null;
    this.#player?.flush();
  }

  #startLevelLoop(): void {
    if (this.#raf) return;
    const tick = () => {
      if (this.state !== "live") {
        this.#raf = 0;
        this.outputLevel = 0;
        return;
      }
      this.outputLevel = this.#player?.level() ?? 0;
      this.#raf = requestAnimationFrame(tick);
    };
    this.#raf = requestAnimationFrame(tick);
  }

  async #teardown(): Promise<void> {
    this.#gen++;
    if (this.#raf) cancelAnimationFrame(this.#raf);
    this.#raf = 0;
    this.outputLevel = 0;
    this.speaking = false;
    this.muted = false;
    this.#abort?.abort();
    this.#abort = null;
    await moonshineStt.stop().catch(() => {});
    this.#player?.close();
    this.#player = null;
    this.#preview = false;
    if (typeof window !== "undefined") {
      delete (window as unknown as { __wbVoiceInject?: unknown }).__wbVoiceInject;
    }
  }

  #fail(message: string): void {
    this.error = message;
    this.#cb.onError?.(message);
    void this.#teardown().finally(() => {
      this.state = "error";
    });
  }
}

/** Split a reply into speakable chunks: sentence boundaries, with runts merged
 *  forward so we never pay a TTS round trip for "OK." */
export function sentenceChunks(text: string): string[] {
  const plain = text
    // Speech-hostile markdown: fences become a spoken aside, inline md is stripped.
    .replace(/```[\s\S]*?```/g, " I've put the code in the editor. ")
    .replace(/[*_`#>|]/g, " ")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
  if (!plain) return [];

  const parts = plain.split(/(?<=[.!?])\s+/);
  const chunks: string[] = [];
  let acc = "";
  for (const part of parts) {
    acc = acc ? `${acc} ${part}` : part;
    if (acc.length >= MIN_CHUNK_CHARS) {
      chunks.push(acc);
      acc = "";
    }
  }
  if (acc) chunks.push(acc);
  return chunks;
}

export const fishLive = new FishLiveSession();
