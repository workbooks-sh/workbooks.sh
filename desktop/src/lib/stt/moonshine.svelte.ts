/**
 * Moonshine on-device speech-to-text — wb-xxbm.2.
 *
 * Wraps @moonshine-ai/moonshine-js's MicrophoneTranscriber as a Svelte
 * reactive service so the composer's mic button can toggle dictation
 * and append committed transcripts to the draft text.
 *
 * Permission model: getUserMedia is called by MicrophoneTranscriber on
 * .start(). It triggers the browser's native mic permission prompt the
 * first time. This is a direct user-gesture flow — no Workgate hop. When
 * the wb-80q0.10 Tauri+Svelte modal lands, this service should be
 * refactored to call `Workgate.request('mic', …)` first and only
 * .start() after the permit is granted; today the renderer-side prompt
 * is sufficient because mic access is initiated by an explicit user
 * click.
 *
 * Assets: model weights, onnxruntime-web, and Silero VAD are fetched
 * from their respective CDNs (Moonshine's `Settings.BASE_ASSET_PATH`
 * defaults). For offline support the model files would be bundled into
 * `static/moonshine/` and the paths overridden — deferred to a follow-up.
 *
 * Lifecycle: `state` is one of "idle" | "starting" | "listening" |
 * "stopping" | "error". The composer reads `active` (true when
 * listening) for the button's pressed state.
 */

import * as Moonshine from "@moonshine-ai/moonshine-js";

type Transcriber = {
  start: () => Promise<void>;
  stop: () => Promise<void>;
};

type MoonshineModule = {
  MicrophoneTranscriber: new (
    modelUrl: string,
    callbacks: {
      onTranscriptionCommitted?: (text: string) => void;
      onTranscriptionUpdated?: (text: string) => void;
    },
    useVAD?: boolean,
  ) => Transcriber;
};

type State = "idle" | "starting" | "listening" | "stopping" | "error";

class MoonshineSttStore {
  state = $state<State>("idle");
  error = $state<string | null>(null);
  /** Set to true to disable VAD and stream interim transcripts via
   *  `onUpdate`. v1 keeps VAD on so the user gets a single committed
   *  chunk per utterance — matches how dictation feels in macOS. */
  streamMode = $state(false);

  active = $derived(this.state === "listening");
  disabled = $derived(
    this.state === "starting" || this.state === "stopping",
  );

  #transcriber: Transcriber | null = null;
  #onCommit: ((text: string) => void) | null = null;
  #onUpdate: ((text: string) => void) | null = null;

  /** Begin dictation. The browser prompts for mic permission on first
   *  call; subsequent starts reuse the granted permission. */
  async start(
    onCommit: (text: string) => void,
    onUpdate?: (text: string) => void,
  ): Promise<void> {
    if (this.state !== "idle" && this.state !== "error") return;

    this.#onCommit = onCommit;
    this.#onUpdate = onUpdate ?? null;
    this.state = "starting";
    this.error = null;

    try {
      const M = Moonshine as unknown as MoonshineModule;
      this.#transcriber = new M.MicrophoneTranscriber(
        "model/tiny",
        {
          onTranscriptionCommitted: (text: string) => {
            this.#onCommit?.(text);
          },
          onTranscriptionUpdated: (text: string) => {
            this.#onUpdate?.(text);
          },
        },
        !this.streamMode,
      );

      await this.#transcriber.start();
      this.state = "listening";
    } catch (err) {
      this.state = "error";
      this.error =
        err instanceof Error ? err.message : "Failed to start dictation";
      this.#transcriber = null;
    }
  }

  async stop(): Promise<void> {
    if (this.state !== "listening") return;

    this.state = "stopping";
    try {
      await this.#transcriber?.stop();
    } catch (err) {
      // Logged but not user-surfaced: stop() failures don't matter
      // much because the user has already moved on.
      console.warn("[moonshine] stop failed:", err);
    } finally {
      this.#transcriber = null;
      this.#onCommit = null;
      this.#onUpdate = null;
      this.state = "idle";
    }
  }

  /** Composer mic-button handler. Idempotent: toggles. */
  async toggle(
    onCommit: (text: string) => void,
    onUpdate?: (text: string) => void,
  ): Promise<void> {
    if (this.active) {
      await this.stop();
    } else {
      await this.start(onCommit, onUpdate);
    }
  }
}

export const moonshineStt = new MoonshineSttStore();
