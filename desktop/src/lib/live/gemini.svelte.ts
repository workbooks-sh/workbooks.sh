/**
 * Gemini Live transport — chat-voice domain (Phase B locked schema).
 *
 * Renderer-direct bidirectional audio session with Google's Gemini Live
 * (model: gemini-3.1-flash-live-preview). The renderer holds the WS
 * because Web Audio APIs live there. The session mixes three placement
 * tiers per the canonical schema map:
 *
 *   - NATIVE (offline): `connections_reveal_api_key` — the provider key
 *     is read host-side from the OS keychain via invoke(); the secret
 *     never crosses IPC except to seed the Gemini WS handshake here.
 *   - RUNTIME (control-plane, graceful-offline): the rendered system
 *     prompt (GET /api/agents/:slug/system_prompt) and live bash exec
 *     (POST /api/agents/:slug/exec) go through `engineRequest()` so an
 *     offline daemon surfaces as EngineApiError code "daemon_down"
 *     rather than a raw fetch failure. When the daemon is down we
 *     degrade — empty/default — and never throw to the chat UI.
 *   - RENDERER-DIRECT (local-store): the Gemini Live WS, mic capture,
 *     audio playback, level metering, and the connect chime are all
 *     client-side. No runtime hop.
 *
 * Mic access depends on the native `webview_enable_media` boot config
 * (re-added to the Rust shell); without it getUserMedia is undefined in
 * the WKWebview and #openMic throws a clear error.
 *
 * Out of scope (follow-ups):
 *   - Resumability after WS drop
 *   - Multi-agent concurrent live sessions (one at a time for v1)
 *   - Screen-share input
 */

import { invoke } from "@tauri-apps/api/core";
import { engineRequest, EngineApiError } from "$lib/engine-api/gen";

// ── Wire types (Gemini Live BidiGenerateContent) ──────────────────────
//
// Gemini Live serializes its proto in camelCase JSON. Snake_case is
// accepted on input by Google's relaxed proto-JSON parser, but outputs
// are always camelCase — keep the wire types camelCase end-to-end so
// reads and writes match.

interface GeminiSetupMessage {
  setup: {
    model: string;
    systemInstruction?: { parts: Array<{ text: string }> };
    tools?: Array<{
      functionDeclarations: Array<{
        name: string;
        description: string;
        parameters: Record<string, unknown>;
      }>;
    }>;
    generationConfig?: {
      responseModalities?: Array<"AUDIO" | "TEXT">;
      speechConfig?: {
        voiceConfig?: { prebuiltVoiceConfig?: { voiceName: string } };
      };
    };
    outputAudioTranscription?: Record<string, never>;
    inputAudioTranscription?: Record<string, never>;
    /** Gemini Live session resumption. Pass an empty object to enable
     *  the server-side handle stream; pass `{ handle }` on reconnect
     *  to pick up where the previous WS left off. */
    sessionResumption?: { handle?: string };
  };
}

interface GeminiRealtimeInputMessage {
  realtimeInput: {
    audio?: { mimeType: string; data: string };
    video?: { mimeType: string; data: string };
    text?: string;
    audioStreamEnd?: boolean;
  };
}

interface GeminiToolResponseMessage {
  toolResponse: {
    functionResponses: Array<{
      id: string;
      name: string;
      response: Record<string, unknown>;
    }>;
  };
}

interface GeminiServerMessage {
  setupComplete?: Record<string, never>;
  serverContent?: {
    modelTurn?: {
      parts: Array<{
        text?: string;
        inlineData?: { mimeType: string; data: string };
      }>;
    };
    inputTranscription?: { text: string };
    outputTranscription?: { text: string };
    turnComplete?: boolean;
    generationComplete?: boolean;
    interrupted?: boolean;
  };
  toolCall?: {
    functionCalls: Array<{
      id: string;
      name: string;
      args: Record<string, unknown>;
    }>;
  };
  toolCallCancellation?: { ids: string[] };
  sessionResumptionUpdate?: {
    newHandle?: string;
    resumable?: boolean;
    lastConsumedClientMessageIndex?: string;
  };
}

// ── Service API ───────────────────────────────────────────────────────

/** Function declaration shape the renderer can hand off to Gemini Live
 *  via the `extraTools` start() option. Used for "chip" tools the
 *  brainstorming skill surfaces (wb-5hc0.8) — the agent calls them,
 *  the renderer shows a tappable chip, the click commits an action.
 *  The wire-shape mirrors Gemini's `functionDeclarations` entries. */
export interface ExtraFunctionDecl {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

export interface LiveSessionCallbacks {
  /** User's spoken words transcribed by Gemini (input_audio_transcription).
   *  Streamed in fragments — concatenate to build the full utterance. */
  onUserTranscript?: (text: string) => void;
  /** Agent's spoken words (output_audio_transcription). Same streaming
   *  semantics as the user side. */
  onAgentTranscript?: (text: string) => void;
  /** A bash function_call started executing. */
  onToolCallStart?: (id: string, command: string) => void;
  /** A bash function_call returned. */
  onToolCallEnd?: (id: string, output: string) => void;
  /** A non-bash function_call landed — these are "chip" tools the
   *  renderer should surface as tappable UI rather than execute
   *  silently. Implementations should immediately decide whether to
   *  ack the call (it stays on screen for the user) by returning, and
   *  the user's click handler runs the local effect.
   *
   *  After invoking this callback, the transport auto-sends a
   *  `{shown: true}` function_response so the model can keep talking
   *  without waiting on the user's click. */
  onChip?: (id: string, name: string, args: Record<string, unknown>) => void;
  /** Gemini finished a turn — the agent stopped speaking. The host
   *  uses this to close out the current message block so the next
   *  transcript starts a fresh bubble. */
  onTurnComplete?: () => void;
  /** Terminal error — connection failed, key missing, etc. */
  onError?: (message: string) => void;
  /** Session closed (graceful or otherwise). */
  onClose?: () => void;
}

/** Options for `start()` beyond agent + workdir. */
export interface LiveSessionStartOptions {
  /** Skill slugs to attach. The engine appends each
   *  `agent/skills/<slug>.org` body to the system prompt. */
  skills?: string[];
  /** Extra function declarations exposed alongside `bash`. Tool calls
   *  for any of these names route to `LiveSessionCallbacks.onChip`
   *  rather than the bash exec path. */
  extraTools?: ExtraFunctionDecl[];
}

type State = "idle" | "connecting" | "live" | "paused" | "closing" | "error";

const MODEL = "gemini-3.1-flash-live-preview";
const WS_URL_BASE =
  "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
const INPUT_RATE = 16_000;
const OUTPUT_RATE = 24_000;

const BASH_FUNCTION = {
  name: "bash",
  description:
    "Run a shell command in the active workspace. Returns combined " +
    "stdout/stderr with a leading exit=<n> marker line. Use this for " +
    "running CLIs, inspecting filesystem, builds — anything that fits " +
    "a POSIX command line.",
  parameters: {
    type: "object",
    properties: {
      command: {
        type: "string",
        description: "The shell command to execute, run via `sh -c`.",
      },
    },
    required: ["command"],
  },
} as const;

class GeminiLiveSession {
  state = $state<State>("idle");
  error = $state<string | null>(null);
  muted = $state(false);
  agentSlug = $state<string | null>(null);

  /** Audio levels for reactive UI (AuroraGlow, etc.). Sampled at
   *  ~60fps via requestAnimationFrame off the AnalyserNodes attached
   *  to mic input + playback output. 0..1 RMS-shaped. */
  inputLevel = $state(0);
  outputLevel = $state(0);

  active = $derived(this.state === "live");
  busy = $derived(this.state === "connecting" || this.state === "closing");
  /** Visible whenever the session has any presence — live, paused,
   *  connecting, even error (so the bar can surface the failure). */
  present = $derived(this.state !== "idle");
  /** True when paused — `resume()` will reconnect with the saved
   *  session handle. */
  resumable = $derived(this.state === "paused");

  /** Last server-side handle for `sessionResumption`. Kept across
   *  `pause()` so `resume()` reconnects with full context. Cleared by
   *  the destructive `end()`. Not reactive — readers use `state`. */
  #sessionHandle: string | null = null;

  #ws: WebSocket | null = null;
  #callbacks: LiveSessionCallbacks = {};
  /** Cached for re-issuing setup on resume(). */
  #startOpts: LiveSessionStartOptions = {};
  /** Set true when WE initiate the close (pause/end). The WS close
   *  event fires asynchronously after `ws.close()` returns, by which
   *  time `state` may already have advanced past `"closing"` — the
   *  flag is the reliable signal that the close was intentional and
   *  should NOT be reported as an error. */
  #intentionallyClosing = false;

  #micStream: MediaStream | null = null;
  #micCtx: AudioContext | null = null;
  #micWorklet: AudioWorkletNode | null = null;
  #micAnalyser: AnalyserNode | null = null;
  #playCtx: AudioContext | null = null;
  #playGainNode: GainNode | null = null;
  #playAnalyser: AnalyserNode | null = null;
  #playQueueAt = 0;
  #rafHandle = 0;
  #analyserBuf: Uint8Array | null = null;

  async start(
    agentSlug: string,
    workdir: string | null,
    callbacks: LiveSessionCallbacks = {},
    opts: LiveSessionStartOptions = {},
  ): Promise<void> {
    // Allowed transitions into start: idle, error (retry), paused
    // (resume). Other states would clobber an in-flight session.
    if (
      this.state !== "idle" &&
      this.state !== "error" &&
      this.state !== "paused"
    ) {
      return;
    }

    this.#callbacks = callbacks;
    this.#startOpts = opts;
    this.agentSlug = agentSlug;
    this.state = "connecting";
    this.error = null;

    try {
      console.log("[gemini-live] step 1: fetching api key");
      const apiKey = await this.#fetchApiKey();
      console.log("[gemini-live] step 1 ok, key length:", apiKey.length);

      console.log("[gemini-live] step 2: fetching system prompt");
      const prompt = await this.#fetchSystemPrompt(agentSlug, workdir, opts.skills);
      console.log("[gemini-live] step 2 ok, prompt length:", prompt.length);

      console.log("[gemini-live] step 3: opening mic");
      await this.#openMic();
      console.log("[gemini-live] step 3 ok");

      console.log("[gemini-live] step 4: opening WS");
      const wsUrl = `${WS_URL_BASE}?key=${encodeURIComponent(apiKey)}`;
      console.log("[gemini-live] ws url:", wsUrl.replace(/key=[^&]+/, "key=…"));
      const ws = new WebSocket(wsUrl);
      this.#ws = ws;

      ws.addEventListener("open", () => {
        console.log(
          "[gemini-live] WS open — sending setup",
          this.#sessionHandle ? "(resuming)" : "(fresh)",
        );
        const declarations = [
          BASH_FUNCTION as ExtraFunctionDecl,
          ...(opts.extraTools ?? []),
        ];
        const setup: GeminiSetupMessage = {
          setup: {
            model: `models/${MODEL}`,
            systemInstruction: {
              parts: [{ text: prompt }],
            },
            tools: [{ functionDeclarations: declarations }],
            generationConfig: {
              responseModalities: ["AUDIO"],
              // Male prebuilt voice (Charon) so the resident agent doesn't
              // surprise users with a default/female voice. Gemini Live male
              // voices: Charon, Fenrir, Puck; female: Aoede, Kore.
              speechConfig: {
                voiceConfig: { prebuiltVoiceConfig: { voiceName: "Charon" } },
              },
            },
            inputAudioTranscription: {},
            outputAudioTranscription: {},
            // Enable session resumption — `{}` opts in to receiving
            // `sessionResumptionUpdate` events; `{ handle }` resumes
            // an earlier session.
            sessionResumption: this.#sessionHandle
              ? { handle: this.#sessionHandle }
              : {},
          },
        };
        ws.send(JSON.stringify(setup));
      });

      ws.addEventListener("message", (e) => {
        void this.#onMessage(e.data as string | ArrayBuffer | Blob);
      });

      ws.addEventListener("error", (e) => {
        console.error("[gemini-live] WS error event", e);
        this.#fail("Gemini Live WebSocket error");
      });

      ws.addEventListener("close", (e) => {
        console.log("[gemini-live] WS close", e.code, e.reason || "(no reason)");
        // Intentional closure path: pause()/end() set this flag before
        // calling ws.close(). The browser-synthesized close event
        // (with code 1000 — normal closure) is expected here; don't
        // route it to #fail.
        if (this.#intentionallyClosing) {
          this.#intentionallyClosing = false;
          return;
        }
        if (this.state === "closing" || this.state === "idle" || this.state === "paused") {
          return;
        }
        this.#fail(
          `Gemini Live closed (code ${e.code}${e.reason ? `: ${e.reason}` : ""})`,
        );
      });
    } catch (err) {
      console.error("[gemini-live] start failed:", err);
      this.#fail(err instanceof Error ? err.message : "Live session failed");
    }
  }

  /** Pause the session: close the transport but keep the resumption
   *  handle so `resume()` picks up the same conversation. Use this for
   *  user-initiated stops where they may want to continue later. */
  async pause(): Promise<void> {
    if (this.state !== "live") return;
    this.#intentionallyClosing = true;
    this.state = "closing";
    await this.#teardown();
    this.state = "paused";
  }

  /** Reconnect after a `pause()`. Uses the saved handle so the model
   *  resumes the previous turn graph. */
  async resume(): Promise<void> {
    if (this.state !== "paused") return;
    if (!this.agentSlug) return;
    await this.start(this.agentSlug, null, this.#callbacks, this.#startOpts);
  }

  /** Destructive close — kills the session and clears the handle so
   *  it cannot be resumed. */
  async end(): Promise<void> {
    if (this.state === "idle") return;
    this.#intentionallyClosing = true;
    this.state = "closing";
    this.#sessionHandle = null;
    this.agentSlug = null;
    await this.#teardown();
    this.state = "idle";
    this.#callbacks.onClose?.();
  }

  /** @deprecated Prefer `pause()` (keeps context) or `end()` (clears).
   *  Kept for source compatibility — routes to `pause()`. */
  async stop(): Promise<void> {
    return this.pause();
  }

  toggleMute(): void {
    this.muted = !this.muted;
  }

  /** Inject a text turn into the live session as if the user typed it.
   *  The model responds in audio the same way it would to a spoken
   *  utterance. Used by the palette to seed an active session with a
   *  prior text Q→A so the brainstorm picks up the thread instead of
   *  starting fresh. No-op if the session isn't live. */
  sendText(text: string): void {
    if (this.state !== "live" || !this.#ws) return;
    const msg: GeminiRealtimeInputMessage = {
      realtimeInput: { text },
    };
    this.#ws.send(JSON.stringify(msg));
  }

  /** Send an empty user turn so the agent knows it's its turn to
   *  speak. Used right after setupComplete to make the agent open
   *  the conversation per its system prompt's instructions instead
   *  of waiting for user audio. */
  #nudgeAgentToOpen(): void {
    if (!this.#ws) return;
    const msg = {
      clientContent: {
        turns: [{ role: "user", parts: [{ text: "(session started)" }] }],
        turnComplete: true,
      },
    };
    this.#ws.send(JSON.stringify(msg));
  }

  // ── Wire helpers ───────────────────────────────────────────────────

  async #fetchApiKey(): Promise<string> {
    try {
      return await invoke<string>("connections_reveal_api_key", {
        service: "gemini",
      });
    } catch (err) {
      throw new Error(
        "No Gemini API key configured. Add one in Settings → Integrations.",
      );
    }
  }

  /** RUNTIME cap: GET /api/agents/:slug/system_prompt via the
   *  control-plane transport. Graceful-offline — if the daemon is down
   *  we return an empty prompt so the live session still opens (the
   *  agent just lacks its rendered persona) rather than throwing to the
   *  chat UI. */
  async #fetchSystemPrompt(
    slug: string,
    workdir: string | null,
    skills?: string[],
  ): Promise<string> {
    const params = new URLSearchParams();
    if (workdir) params.set("workdir", workdir);
    if (skills && skills.length > 0) params.set("skills", skills.join(","));
    const qs = params.toString() ? `?${params.toString()}` : "";

    try {
      const body = await engineRequest<{ system_prompt: string }>(
        `/api/agents/${encodeURIComponent(slug)}/system_prompt`,
        { method: "GET", query: qs },
      );
      return body.system_prompt ?? "";
    } catch (err) {
      if (isDaemonDown(err)) {
        console.warn("[gemini-live] daemon down — empty system prompt");
        return "";
      }
      throw err;
    }
  }

  async #onMessage(raw: string | ArrayBuffer | Blob): Promise<void> {
    let text: string;
    if (typeof raw === "string") {
      text = raw;
    } else if (raw instanceof Blob) {
      text = await raw.text();
    } else {
      text = new TextDecoder().decode(raw);
    }

    let msg: GeminiServerMessage;
    try {
      msg = JSON.parse(text) as GeminiServerMessage;
    } catch {
      console.warn("[gemini-live] non-JSON server message:", text.slice(0, 200));
      return;
    }

    console.log("[gemini-live] ← server message keys:", Object.keys(msg));

    if (msg.setupComplete) {
      console.log("[gemini-live] setupComplete — going live");
      this.state = "live";
      // Soft connect chime + nudge the agent to open the
      // conversation. Without the nudge, Gemini Live waits silently
      // for the first user utterance — but the skills attached to
      // these sessions (brainstorming) instruct the agent to greet
      // first. The empty turn signals "your turn"; the agent's system
      // prompt handles what to say.
      playConnectChime();
      this.#nudgeAgentToOpen();
      return;
    }

    if (msg.serverContent) {
      const sc = msg.serverContent;
      if (sc.inputTranscription?.text) {
        this.#callbacks.onUserTranscript?.(sc.inputTranscription.text);
      }
      if (sc.outputTranscription?.text) {
        this.#callbacks.onAgentTranscript?.(sc.outputTranscription.text);
      }
      for (const part of sc.modelTurn?.parts ?? []) {
        if (part.inlineData?.mimeType.startsWith("audio/")) {
          this.#enqueueAudio(part.inlineData.data);
        }
      }
      if (sc.interrupted) {
        this.#flushPlayback();
      }
      if (sc.turnComplete) {
        this.#callbacks.onTurnComplete?.();
      }
    }

    if (msg.toolCall) {
      for (const call of msg.toolCall.functionCalls) {
        void this.#handleToolCall(call.id, call.name, call.args);
      }
    }

    if (msg.sessionResumptionUpdate?.newHandle) {
      // Save the latest resumption handle so `pause()` → `resume()`
      // continues the same conversation. Gemini issues a new handle
      // roughly every model turn.
      this.#sessionHandle = msg.sessionResumptionUpdate.newHandle;
    }
  }

  async #handleToolCall(
    id: string,
    name: string,
    args: Record<string, unknown>,
  ): Promise<void> {
    // Non-bash function_calls are "chip" tools (wb-5hc0.8). The
    // renderer surfaces them in the transcript and runs the local
    // effect on user click. We immediately ack the call with
    // `{shown: true}` so the model can keep talking — the click
    // outcome is a sideband UI signal, not a tool result.
    if (name !== "bash") {
      this.#callbacks.onChip?.(id, name, args);
      this.#sendToolResponse(id, name, { shown: true });
      return;
    }

    const command = typeof args.command === "string" ? args.command : "";
    this.#callbacks.onToolCallStart?.(id, command);

    // RUNTIME cap: POST /api/agents/:slug/exec via the control-plane
    // transport. Graceful-offline — a daemon-down exec returns a polite
    // tool_response so the model can keep talking instead of stalling on
    // a thrown error.
    try {
      const slug = this.agentSlug ?? "";
      const body = await engineRequest<{
        output?: string;
        error?: string;
        detail?: string;
      }>(`/api/agents/${encodeURIComponent(slug)}/exec`, {
        method: "POST",
        body: { command },
      });
      const output =
        body.output ?? `error: ${body.error ?? "unknown"} ${body.detail ?? ""}`;
      this.#callbacks.onToolCallEnd?.(id, output);
      this.#sendToolResponse(id, name, { output });
    } catch (err) {
      const offline = isDaemonDown(err);
      const msg = offline
        ? "agent server offline — command not run"
        : err instanceof Error
          ? err.message
          : "exec failed";
      this.#callbacks.onToolCallEnd?.(id, `error: ${msg}`);
      this.#sendToolResponse(id, name, { error: msg });
    }
  }

  #sendToolResponse(id: string, name: string, response: Record<string, unknown>): void {
    const msg: GeminiToolResponseMessage = {
      toolResponse: {
        functionResponses: [{ id, name, response }],
      },
    };
    this.#ws?.send(JSON.stringify(msg));
  }

  // ── Mic capture ────────────────────────────────────────────────────

  async #openMic(): Promise<void> {
    // The Tauri WKWebView is configured at app start to expose
    // navigator.mediaDevices (see src-tauri/src/media.rs). If it's
    // still undefined here, either the setup hook didn't run or
    // the platform doesn't support it — surface a clear error
    // instead of a raw "undefined is not an object" stack.
    if (!navigator.mediaDevices?.getUserMedia) {
      throw new Error(
        "Microphone API isn't available in this webview. Try restarting the " +
          "app; if it persists, file a bug.",
      );
    }
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });
    this.#micStream = stream;

    const ctx = new AudioContext({ sampleRate: INPUT_RATE });
    this.#micCtx = ctx;

    // AudioWorklet is the modern path; ScriptProcessorNode is deprecated
    // but kept here as the simplest single-file implementation. The
    // worklet upgrade is a follow-up — needs an external .js file path.
    await ctx.audioWorklet.addModule(makeMicWorkletUrl());
    const node = new AudioWorkletNode(ctx, "mic-pcm-worklet");
    this.#micWorklet = node;

    node.port.onmessage = (e) => {
      if (this.muted || this.state !== "live" || !this.#ws) return;
      const pcm = e.data as Int16Array;
      const msg: GeminiRealtimeInputMessage = {
        realtimeInput: {
          audio: {
            mimeType: `audio/pcm;rate=${INPUT_RATE}`,
            data: int16ToBase64(pcm),
          },
        },
      };
      this.#ws.send(JSON.stringify(msg));
    };

    const source = ctx.createMediaStreamSource(stream);
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 256;
    analyser.smoothingTimeConstant = 0.7;
    source.connect(analyser);
    source.connect(node);
    this.#micAnalyser = analyser;

    this.#startAnalyserLoop();
  }

  // ── Reactive audio levels ───────────────────────────────────────────

  /** Single rAF loop polling both analysers. Cheap (one Uint8Array
   *  read per frame, RMS in JS). Stops when state leaves "live". */
  #startAnalyserLoop(): void {
    if (this.#rafHandle) return;
    this.#analyserBuf = new Uint8Array(128);

    const tick = () => {
      if (this.state !== "live" && this.state !== "connecting") {
        this.#rafHandle = 0;
        this.inputLevel = 0;
        this.outputLevel = 0;
        return;
      }
      this.inputLevel = this.muted ? 0 : sampleLevel(this.#micAnalyser, this.#analyserBuf);
      this.outputLevel = sampleLevel(this.#playAnalyser, this.#analyserBuf);
      this.#rafHandle = requestAnimationFrame(tick);
    };
    this.#rafHandle = requestAnimationFrame(tick);
  }

  // ── Audio playback ─────────────────────────────────────────────────

  #enqueueAudio(base64: string): void {
    if (!this.#playCtx) {
      const ctx = new AudioContext({ sampleRate: OUTPUT_RATE });
      this.#playCtx = ctx;
      this.#playQueueAt = ctx.currentTime;
      // Tap an analyser off the playback path so the UI can react.
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 256;
      analyser.smoothingTimeConstant = 0.6;
      const gain = ctx.createGain();
      gain.connect(analyser);
      gain.connect(ctx.destination);
      this.#playGainNode = gain;
      this.#playAnalyser = analyser;
    }
    const ctx = this.#playCtx;
    const sink = this.#playGainNode ?? ctx.destination;

    const pcm = base64ToInt16(base64);
    const buf = ctx.createBuffer(1, pcm.length, OUTPUT_RATE);
    const channel = buf.getChannelData(0);
    for (let i = 0; i < pcm.length; i++) channel[i] = pcm[i] / 0x7fff;

    const node = ctx.createBufferSource();
    node.buffer = buf;
    node.connect(sink);
    const startAt = Math.max(this.#playQueueAt, ctx.currentTime);
    node.start(startAt);
    this.#playQueueAt = startAt + buf.duration;
  }

  #flushPlayback(): void {
    // Drop pending playback when Gemini signals interruption (e.g.
    // user barge-in). The simplest implementation closes + reopens
    // the playback context.
    void this.#playCtx?.close();
    this.#playCtx = null;
    this.#playGainNode = null;
    this.#playAnalyser = null;
    this.#playQueueAt = 0;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────

  async #teardown(): Promise<void> {
    try {
      this.#ws?.close();
    } catch {}
    this.#ws = null;

    if (this.#rafHandle) cancelAnimationFrame(this.#rafHandle);
    this.#rafHandle = 0;
    this.inputLevel = 0;
    this.outputLevel = 0;
    this.#analyserBuf = null;
    this.#micAnalyser = null;
    this.#playAnalyser = null;
    this.#playGainNode = null;

    this.#micWorklet?.disconnect();
    this.#micWorklet = null;
    await this.#micCtx?.close().catch(() => {});
    this.#micCtx = null;
    this.#micStream?.getTracks().forEach((t) => t.stop());
    this.#micStream = null;

    await this.#playCtx?.close().catch(() => {});
    this.#playCtx = null;
    this.#playQueueAt = 0;
  }

  #fail(message: string): void {
    this.error = message;
    this.#callbacks.onError?.(message);
    void this.#teardown().finally(() => {
      this.state = "error";
    });
  }
}

// ── Helpers ───────────────────────────────────────────────────────────

/** True when an error is the "daemon offline" signal from the engine
 *  transport. Locked schema renames this code `sidecar_down`→`daemon_down`;
 *  match both so this bridge is correct before and after gen.ts flips. */
function isDaemonDown(err: unknown): boolean {
  return (
    err instanceof EngineApiError &&
    (err.code === "daemon_down" || err.code === "sidecar_down")
  );
}

function int16ToBase64(pcm: Int16Array): string {
  const bytes = new Uint8Array(pcm.buffer, pcm.byteOffset, pcm.byteLength);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

/** RMS-shaped 0..1 level from an AnalyserNode's time-domain buffer.
 *  Reuses a caller-owned Uint8Array to avoid per-frame allocations. */
function sampleLevel(
  analyser: AnalyserNode | null,
  buf: Uint8Array | null,
): number {
  if (!analyser || !buf) return 0;
  // The DOM lib's getByteTimeDomainData typing was tightened in recent
  // TS releases to require Uint8Array<ArrayBuffer>. Cast through —
  // we always allocate a fresh Uint8Array so the underlying buffer
  // is ArrayBuffer, not SharedArrayBuffer.
  analyser.getByteTimeDomainData(buf as Uint8Array<ArrayBuffer>);
  let sumSq = 0;
  for (let i = 0; i < buf.length; i++) {
    const v = (buf[i] - 128) / 128; // -1..1
    sumSq += v * v;
  }
  const rms = Math.sqrt(sumSq / buf.length); // 0..1 (typically 0..0.3 for speech)
  // Stretch the typical speech range to fill 0..1 with a soft cap.
  return Math.min(1, rms * 3.5);
}

function base64ToInt16(base64: string): Int16Array {
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Int16Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 2);
}

/** Soft connect chime — two-note arpeggio (E5 → B5) with a quick
 *  attack and gentle exponential release. ~400 ms total, peak ~-22
 *  dBFS. Pure Web Audio so we don't ship an asset. Triggered on
 *  setupComplete; harmless if it fails (autoplay restrictions etc.). */
function playConnectChime(): void {
  try {
    const ctx = new AudioContext();
    const now = ctx.currentTime;

    const playNote = (freq: number, start: number, dur: number) => {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = "sine";
      osc.frequency.value = freq;
      // Envelope: tiny attack → sustained dip → exponential release.
      // Peak below 0.1 so it's polite over the user's other audio.
      gain.gain.setValueAtTime(0.0001, start);
      gain.gain.exponentialRampToValueAtTime(0.09, start + 0.015);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + dur);
      osc.connect(gain).connect(ctx.destination);
      osc.start(start);
      osc.stop(start + dur + 0.02);
    };

    playNote(659.25, now, 0.28); // E5
    playNote(987.77, now + 0.12, 0.32); // B5

    // Tear down the context after the chime fully decays so we don't
    // accumulate AudioContexts across repeated connects.
    setTimeout(() => {
      void ctx.close().catch(() => {});
    }, 700);
  } catch {
    /* chime is decoration — never block on audio failures */
  }
}

/** Inline AudioWorklet that pulls Float32 input → emits Int16Array
 *  chunks back to the main thread. Built as a blob URL so the service
 *  ships as one file. */
function makeMicWorkletUrl(): string {
  const src = `
    class MicPcmWorklet extends AudioWorkletProcessor {
      process(inputs) {
        const ch = inputs[0]?.[0];
        if (!ch || ch.length === 0) return true;
        const out = new Int16Array(ch.length);
        for (let i = 0; i < ch.length; i++) {
          const s = Math.max(-1, Math.min(1, ch[i]));
          out[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
        }
        this.port.postMessage(out, [out.buffer]);
        return true;
      }
    }
    registerProcessor("mic-pcm-worklet", MicPcmWorklet);
  `;
  return URL.createObjectURL(new Blob([src], { type: "application/javascript" }));
}

export const geminiLive = new GeminiLiveSession();
