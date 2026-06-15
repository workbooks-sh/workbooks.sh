/**
 * Streaming PCM playback for the voice loop. Schedules LINEAR16 chunks
 * back-to-back on a Web Audio timeline so they play gaplessly as they arrive,
 * and drops the whole queue instantly on barge-in.
 *
 * Extracted from the Gemini Live transport's inline player so the Inworld voice
 * client can reuse it; the Gemini path keeps its own copy for now (dedupe is a
 * follow-up).
 */
export class PcmPlayer {
  readonly rate: number;
  #ctx: AudioContext | null = null;
  #gain: GainNode | null = null;
  #analyser: AnalyserNode | null = null;
  #queueAt = 0;
  #buf = new Uint8Array(128);

  constructor(rate = 24_000) {
    this.rate = rate;
  }

  #ensure(): AudioContext {
    if (this.#ctx) return this.#ctx;
    const ctx = new AudioContext({ sampleRate: this.rate });
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 256;
    analyser.smoothingTimeConstant = 0.6;
    const gain = ctx.createGain();
    gain.connect(analyser);
    gain.connect(ctx.destination);
    this.#ctx = ctx;
    this.#gain = gain;
    this.#analyser = analyser;
    this.#queueAt = ctx.currentTime;
    return ctx;
  }

  /** Append one raw LINEAR16 (s16le mono) chunk to the playback queue. */
  push(pcm: ArrayBuffer): void {
    if (pcm.byteLength < 2) return;
    const ctx = this.#ensure();
    const ints = new Int16Array(pcm, 0, Math.floor(pcm.byteLength / 2));
    const buf = ctx.createBuffer(1, ints.length, this.rate);
    const channel = buf.getChannelData(0);
    for (let i = 0; i < ints.length; i++) channel[i] = ints[i] / 0x7fff;

    const node = ctx.createBufferSource();
    node.buffer = buf;
    node.connect(this.#gain ?? ctx.destination);
    const startAt = Math.max(this.#queueAt, ctx.currentTime);
    node.start(startAt);
    this.#queueAt = startAt + buf.duration;
  }

  /** True while audio is still scheduled to play. */
  get playing(): boolean {
    return !!this.#ctx && this.#queueAt > this.#ctx.currentTime + 0.02;
  }

  /** RMS-shaped 0..1 output level for reactive UI. */
  level(): number {
    if (!this.#analyser) return 0;
    this.#analyser.getByteTimeDomainData(this.#buf as Uint8Array<ArrayBuffer>);
    let sumSq = 0;
    for (let i = 0; i < this.#buf.length; i++) {
      const v = (this.#buf[i] - 128) / 128;
      sumSq += v * v;
    }
    return Math.min(1, Math.sqrt(sumSq / this.#buf.length) * 3.5);
  }

  /** Drop everything queued — barge-in. Closes the context so the next push
   *  starts a fresh timeline. */
  flush(): void {
    void this.#ctx?.close().catch(() => {});
    this.#ctx = null;
    this.#gain = null;
    this.#analyser = null;
    this.#queueAt = 0;
  }

  close(): void {
    this.flush();
  }
}

/** Soft two-note connect chime (E5 → B5), pure Web Audio, ~400ms. Harmless if
 *  autoplay restrictions block it. */
export function playConnectChime(): void {
  try {
    const ctx = new AudioContext();
    const now = ctx.currentTime;
    const note = (freq: number, start: number, dur: number) => {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = "sine";
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0.0001, start);
      gain.gain.exponentialRampToValueAtTime(0.09, start + 0.015);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + dur);
      osc.connect(gain).connect(ctx.destination);
      osc.start(start);
      osc.stop(start + dur + 0.02);
    };
    note(659.25, now, 0.28);
    note(987.77, now + 0.12, 0.32);
    setTimeout(() => void ctx.close().catch(() => {}), 700);
  } catch {
    /* decoration only */
  }
}
