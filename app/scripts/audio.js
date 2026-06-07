// WebAudio juice layer — gesture-gated AudioContext, synthesized SFX, no assets.
// Stems: infrastructure present; playback requires buffers (see docs/audio-plan.org).

import { isSoundEnabled } from './settings.js';

let ctx = null;
let unlocked = false;

function ac() {
  if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
  return ctx;
}

// Call on first user gesture (touchstart / pointerdown) to lift the iOS suspension.
export async function unlockAudio() {
  const c = ac();
  if (c.state === 'suspended') {
    await c.resume().catch(() => {});
  }
  if (!unlocked) {
    // prime the buffer: iOS needs at least one real output before it plays
    const b = c.createBuffer(1, 1, c.sampleRate);
    const s = c.createBufferSource();
    s.buffer = b;
    s.connect(c.destination);
    s.start(0);
    unlocked = true;
  }
}

function live() { return ctx && ctx.state === 'running'; }

function osc(type, freq, dur, vol = 0.15, pitchEnd = 0) {
  if (!live() || !isSoundEnabled()) return;
  const c = ctx, now = c.currentTime;
  const g = c.createGain();
  g.gain.setValueAtTime(vol, now);
  g.gain.exponentialRampToValueAtTime(0.0001, now + dur);
  g.connect(c.destination);
  const o = c.createOscillator();
  o.type = type;
  o.frequency.setValueAtTime(freq, now);
  if (pitchEnd) o.frequency.exponentialRampToValueAtTime(pitchEnd, now + dur);
  o.connect(g);
  o.start(now);
  o.stop(now + dur + 0.01);
}

// ---- synthesized SFX (no audio files required) ----

// sfxTap: light UI confirmation (button, card select)
export function sfxTap() { osc('sine', 880, 0.055, 0.11); }

// sfxDeal: card placed into slot — descending pitch sweep
export function sfxDeal() { osc('triangle', 420, 0.08, 0.13, 200); }

// sfxKill: ad killed — low thud
export function sfxKill() { osc('sawtooth', 160, 0.12, 0.16, 120); }

// sfxError: rejected action — short buzz
export function sfxError() { osc('sawtooth', 130, 0.09, 0.14); }

// sfxBell: A/B winner bell — ascending triad
export function sfxBell() {
  if (!live() || !isSoundEnabled()) return;
  [523, 659, 784].forEach((freq, i) => {
    const c = ctx, t = c.currentTime + i * 0.085;
    const g = c.createGain();
    g.gain.setValueAtTime(0.12, t);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 0.55);
    g.connect(c.destination);
    const o = c.createOscillator();
    o.type = 'sine'; o.frequency.value = freq;
    o.connect(g); o.start(t); o.stop(t + 0.56);
  });
}

// sfxWin: week passed — bell + high cap
export function sfxWin() {
  sfxBell();
  setTimeout(() => osc('sine', 1047, 0.4, 0.08), 290);
}

// sfxMiss: week missed — descending sag
export function sfxMiss() {
  osc('sawtooth', 220, 0.14, 0.13);
  setTimeout(() => osc('sawtooth', 165, 0.16, 0.12), 130);
}

// sfxTick: AP dot refill / day counter tick
export function sfxTick() { osc('square', 1100, 0.028, 0.055); }

// sfxSlotPop: card slot pulse during recap
export function sfxSlotPop() { osc('sine', 660, 0.04, 0.08); }

// ---- stem infrastructure (playback requires audio buffers) ----
// Wire an AudioBufferSourceNode as `stemNode` to play a looping BGM stem.
// ---- interruption / resume ----
// iOS: page hide → suspend; page show → resume.
document.addEventListener('visibilitychange', () => {
  if (!ctx) return;
  if (document.hidden) ctx.suspend().catch(() => {});
  else if (!document.hidden) ctx.resume().catch(() => {});
});
