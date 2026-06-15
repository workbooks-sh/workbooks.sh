/**
 * Inworld voice transport — our own full-duplex voice loop, replacing the
 * Gemini Live black box (wb-091n).
 *
 * Placement: RENDERER-DIRECT for the parts that need Web APIs (mic, STT,
 * playback), CONTROL-PLANE for the brain + TTS. STT is on-device Moonshine
 * (see `$lib/stt/moonshine.svelte`), so unlike the Gemini path we never stream
 * mic audio over the wire — only the finalized transcript text goes up. The
 * nexus runs the brain and brokers Inworld TTS (the INWORLD_API_KEY stays
 * host-side); spoken audio streams back as binary PCM frames.
 *
 * Barge-in: Moonshine's interim-transcript callback fires the moment the user
 * starts talking. If the agent is mid-utterance we flush local playback and
 * send `{type:"barge_in"}`, which kills the server's TTS pipeline.
 *
 * Wire (see Workbooks.Voice.Stream):
 *   up:   {"type":"transcript","text":...} | {"type":"barge_in"} | {"auth":...}
 *   down: binary PCM @ 24kHz | {"type":"speaking_start"|"reply_text"|"speaking_end"}
 */
import { moonshineStt } from "$lib/stt/moonshine.svelte";
import { sidecar } from "$lib/bridge/sidecar.svelte";
import { PcmPlayer, playConnectChime } from "./pcm";

export interface InworldCallbacks {
  /** A finalized user utterance (Moonshine committed). */
  onUserTranscript?: (text: string) => void;
  /** Agent reply caption fragment — concatenate for the full line. */
  onAgentTranscript?: (text: string) => void;
  /** Agent finished speaking a turn. */
  onTurnComplete?: () => void;
  onError?: (message: string) => void;
  onClose?: () => void;
}

type State = "idle" | "connecting" | "live" | "closing" | "error";

const OUTPUT_RATE = 24_000;
const SESSION_ID = "desktop";

class InworldLiveSession {
  state = $state<State>("idle");
  error = $state<string | null>(null);
  /** True while the agent is speaking (between speaking_start/end). */
  speaking = $state(false);
  outputLevel = $state(0);

  active = $derived(this.state === "live");
  busy = $derived(this.state === "connecting" || this.state === "closing");
  present = $derived(this.state !== "idle");

  #ws: WebSocket | null = null;
  #player: PcmPlayer | null = null;
  #cb: InworldCallbacks = {};
  #raf = 0;

  async start(callbacks: InworldCallbacks = {}): Promise<void> {
    if (this.state !== "idle" && this.state !== "error") return;

    this.#cb = callbacks;
    this.state = "connecting";
    this.error = null;

    const base = sidecar.status.url;
    if (!base) {
      this.#fail("Agent server isn't running.");
      return;
    }
    const token = sidecar.status.token;
    const wsUrl =
      base.replace(/^http/, "ws") + "/api/voice/" + encodeURIComponent(SESSION_ID);

    try {
      const ws = new WebSocket(wsUrl);
      ws.binaryType = "arraybuffer";
      this.#ws = ws;
      this.#player = new PcmPlayer(OUTPUT_RATE);

      ws.addEventListener("open", async () => {
        if (token) ws.send(JSON.stringify({ auth: token }));
        try {
          await this.#startStt();
        } catch (err) {
          this.#fail(err instanceof Error ? err.message : "Microphone unavailable");
          return;
        }
        this.state = "live";
        playConnectChime();
        this.#startLevelLoop();
      });

      ws.addEventListener("message", (e) =>
        this.#onMessage(e.data as ArrayBuffer | string),
      );
      ws.addEventListener("error", () => this.#fail("Voice socket error"));
      ws.addEventListener("close", () => {
        if (this.state === "live" || this.state === "connecting") {
          this.#fail("Voice socket closed");
        }
      });
    } catch (err) {
      this.#fail(err instanceof Error ? err.message : "Voice session failed");
    }
  }

  async end(): Promise<void> {
    if (this.state === "idle") return;
    this.state = "closing";
    await this.#teardown();
    this.state = "idle";
    this.#cb.onClose?.();
  }

  async #startStt(): Promise<void> {
    await moonshineStt.start(
      (text) => {
        // Finalized utterance → respond.
        this.#cb.onUserTranscript?.(text);
        this.#send({ type: "transcript", text });
      },
      () => {
        // Interim words while the agent is talking = barge-in.
        if (this.speaking) this.#bargeIn();
      },
    );
  }

  #bargeIn(): void {
    this.speaking = false;
    this.#player?.flush();
    this.#send({ type: "barge_in" });
  }

  #onMessage(data: ArrayBuffer | string): void {
    if (data instanceof ArrayBuffer) {
      this.#player?.push(data);
      return;
    }
    let msg: { type?: string; text?: string };
    try {
      msg = JSON.parse(data);
    } catch {
      return;
    }
    switch (msg.type) {
      case "speaking_start":
        this.speaking = true;
        break;
      case "reply_text":
        if (msg.text) this.#cb.onAgentTranscript?.(msg.text);
        break;
      case "speaking_end":
        this.speaking = false;
        this.#cb.onTurnComplete?.();
        break;
    }
  }

  #send(obj: Record<string, unknown>): void {
    if (this.#ws?.readyState === WebSocket.OPEN) {
      this.#ws.send(JSON.stringify(obj));
    }
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
    if (this.#raf) cancelAnimationFrame(this.#raf);
    this.#raf = 0;
    this.outputLevel = 0;
    this.speaking = false;
    await moonshineStt.stop().catch(() => {});
    try {
      this.#ws?.close();
    } catch {}
    this.#ws = null;
    this.#player?.close();
    this.#player = null;
  }

  #fail(message: string): void {
    this.error = message;
    this.#cb.onError?.(message);
    void this.#teardown().finally(() => {
      this.state = "error";
    });
  }
}

export const inworldLive = new InworldLiveSession();
