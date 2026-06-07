// Two-queue animation kernel.
// Blocking queue: one step active at a time; callers await completion.
// Ambient: fire-and-forget; never blocks the ceremony queue.

// ---- queue -------------------------------------------------------

const CQ = [];  // [{fn: async ()=>void, resolve: ()=>void}]
let cLock = false;

async function drainC() {
  if (cLock) return;
  cLock = true;
  while (CQ.length) {
    const { fn, resolve } = CQ.shift();
    try { await fn(); } catch (e) { console.error('[ceremony]', e); }
    resolve();
  }
  cLock = false;
}

function ceremony(fn) {
  return new Promise(resolve => { CQ.push({ fn, resolve }); drainC(); });
}

// Fire-and-forget — runs immediately, never blocks ceremony.
export function ambient(fn) { fn(); }

// Shared sleep utility (re-exported so callers don't need their own).
export const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---- primitives --------------------------------------------------

// StampEl: show/hide an existing stamp overlay element.
export function stampEl(el, ms = 1800) {
  return ceremony(async () => {
    el.classList.add('show');
    await sleep(ms);
    el.classList.remove('show');
  });
}

// Shake: error/rejection oscillation. No-op when reduce-motion is active.
export function shake(el, ms = 420) {
  if (document.body.classList.contains('reduce-motion')) return Promise.resolve();
  return ceremony(async () => {
    el.classList.add('c-shake');
    await sleep(ms);
    el.classList.remove('c-shake');
  });
}
