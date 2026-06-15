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
  /** The code lane produced code (write_code → mercury-2). Shown in the editor,
   *  never spoken. */
  onCode?: (task: string, code: string) => void;
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
  /** When muted, committed utterances aren't sent — the mic stays open (so
   *  barge-in still works) but the user's words don't reach the agent. */
  muted = $state(false);
  outputLevel = $state(0);

  active = $derived(this.state === "live");
  busy = $derived(this.state === "connecting" || this.state === "closing");
  present = $derived(this.state !== "idle");

  #ws: WebSocket | null = null;
  #player: PcmPlayer | null = null;
  #cb: InworldCallbacks = {};
  #raf = 0;
  /** Preview/text-driven mode: the Inworld TTS WS transport (audio + on-device
   *  STT) isn't reachable — no mic, or the runtime doesn't serve /api/voice
   *  — so the session stays live and drives REAL agent turns through the
   *  text-chat runtime path instead. Only the spoken-audio transport is
   *  unavailable; the agent's turn is real inference over the connected
   *  runtime. Spoken input is injected via `injectUtterance`. */
  #preview = false;

  async start(callbacks: InworldCallbacks = {}): Promise<void> {
    if (this.state !== "idle" && this.state !== "error") return;

    this.#cb = callbacks;
    this.state = "connecting";
    this.error = null;
    this.#preview = false;

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

      // The audio transport needs the Inworld TTS WS + on-device mic. When
      // either is unavailable (browser preview with no mic, a runtime that
      // doesn't serve /api/voice), fall back to a live text-driven session
      // rather than erroring out — the panel still opens and runs real
      // agent turns. Bounded so a healthy WS that's merely slow still wins.
      const fallbackTimer = setTimeout(() => {
        if (this.state === "connecting") this.#enterPreview();
      }, 2500);

      ws.addEventListener("open", async () => {
        clearTimeout(fallbackTimer);
        if (token) ws.send(JSON.stringify({ auth: token }));
        try {
          // Bound STT startup: getUserMedia can hang indefinitely where there's
          // no mic and no permission prompt to resolve (headless capture). If it
          // doesn't come up promptly, fall back to the text-driven session.
          await Promise.race([
            this.#startStt(),
            new Promise((_, rej) => setTimeout(() => rej(new Error("stt-timeout")), 2500)),
          ]);
        } catch {
          // No mic / STT unavailable — keep the session live in preview
          // mode so the panel works; only the spoken-input path is gone.
          this.#enterPreview();
          return;
        }
        if (this.#preview) return;
        this.state = "live";
        this.#exposeInjectHook();
        playConnectChime();
        this.#startLevelLoop();
      });

      ws.addEventListener("message", (e) =>
        this.#onMessage(e.data as ArrayBuffer | string),
      );
      ws.addEventListener("error", () => {
        clearTimeout(fallbackTimer);
        if (this.state === "connecting") this.#enterPreview();
        else if (this.state === "live" && !this.#preview) this.#fail("Voice socket error");
      });
      ws.addEventListener("close", () => {
        if (this.#preview) return;
        if (this.state === "live" || this.state === "connecting") {
          clearTimeout(fallbackTimer);
          if (this.state === "connecting") this.#enterPreview();
          else this.#fail("Voice socket closed");
        }
      });
    } catch {
      // WebSocket couldn't even be constructed — go straight to preview.
      this.#enterPreview();
    }
  }

  /** Drop into the live text-driven session. Tears down any half-open audio
   *  transport but keeps the session present + live so the panel renders the
   *  listening strip and `injectUtterance` can drive a real agent turn. */
  #enterPreview(): void {
    if (this.#preview) return;
    this.#preview = true;
    try {
      this.#ws?.close();
    } catch {}
    this.#ws = null;
    this.#player?.close();
    this.#player = null;
    this.error = null;
    this.state = "live";
    this.#exposeInjectHook();
  }

  /** Expose a host-driver injection hook on the window. Lets a trusted host
   *  driver (the demo recorder) feed a "spoken" prompt that runs a REAL agent
   *  turn through this session — the same path a finalized STT utterance
   *  takes. Cleared on teardown. */
  #exposeInjectHook(): void {
    if (typeof window === "undefined") return;
    (window as unknown as { __wbVoiceInject?: (t: string) => Promise<void> }).__wbVoiceInject =
      (t: string) => this.injectUtterance(t);
  }

  /** Inject a "spoken" user utterance and drive a REAL agent turn through the
   *  connected runtime (text-chat path → real inference + tool calls). Used
   *  by the preview/text-driven session where the Inworld audio transport
   *  isn't available; the agent's turn itself is fully real. Echoes the user
   *  line, runs the turn, then surfaces the agent's final reply as a caption. */
  async injectUtterance(text: string): Promise<void> {
    const t = text.trim();
    if (!t || this.state !== "live") return;
    if (this.muted) return;
    this.#cb.onUserTranscript?.(t);
    const { chatSession } = await import("$lib/chat/session.svelte");
    this.speaking = true;
    try {
      // POSTs the run and returns once the session id is assigned; the agent's
      // telemetry then streams into chatSession.blocks asynchronously.
      await chatSession.send(t, { agentSlug: "waldo" });
      // Wait for the run to reach a terminal state so we caption the final
      // reply, not an empty in-flight block. Bounded so a stuck run can't hang
      // the session.
      const finalText = await this.#awaitReply(chatSession, 45_000);
      if (finalText) this.#cb.onAgentTranscript?.(finalText);
    } catch (err) {
      this.#cb.onError?.(err instanceof Error ? err.message : String(err));
    } finally {
      this.speaking = false;
      this.#cb.onTurnComplete?.();
    }
  }

  /** Poll the shared chat session until the agent run completes (or times out),
   *  then return the final assistant message text. */
  async #awaitReply(
    chatSession: { session: { status?: string } | null; blocks: Array<{ kind: string; pending?: boolean; text?: string }> },
    timeoutMs: number,
  ): Promise<string | null> {
    const deadline = Date.now() + timeoutMs;
    const terminal = new Set(["completed", "failed", "cancelled"]);
    while (Date.now() < deadline) {
      const status = chatSession.session?.status;
      if (status && terminal.has(status)) break;
      await new Promise((r) => setTimeout(r, 200));
    }
    const reply = [...chatSession.blocks]
      .reverse()
      .find((b) => b.kind === "message" && !b.pending && b.text);
    return reply?.text ?? null;
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
        // Finalized utterance → respond (unless muted).
        if (this.muted) return;
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
    let msg: { type?: string; text?: string; task?: string; code?: string };
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
      case "code":
        this.#cb.onCode?.(msg.task ?? "", msg.code ?? "");
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
    this.muted = false;
    await moonshineStt.stop().catch(() => {});
    try {
      this.#ws?.close();
    } catch {}
    this.#ws = null;
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

export const inworldLive = new InworldLiveSession();
