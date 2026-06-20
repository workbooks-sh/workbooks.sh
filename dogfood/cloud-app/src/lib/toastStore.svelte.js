// ── Lightweight toast store (runes module) ───────────────────────────────────
let toasts = $state([]);
let seq = 0;

export const toastStore = {
  get all() {
    return toasts;
  },
  push(msg, kind = 'ok', ms = 3000) {
    const id = ++seq;
    toasts = [...toasts, { id, msg, kind }];
    if (ms) setTimeout(() => this.dismiss(id), ms);
    return id;
  },
  dismiss(id) {
    toasts = toasts.filter((t) => t.id !== id);
  }
};

/** convenience helper */
export const toast = (msg, kind, ms) => toastStore.push(msg, kind, ms);
