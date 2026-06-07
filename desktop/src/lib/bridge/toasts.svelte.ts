// wb-i38o.13 — toast/notification store.
//
// Minimal in-process toast queue. Each toast has a kind (progress /
// success / error), a message, and an optional `sticky` flag for
// errors the user should see until they dismiss it.
//
// Non-sticky toasts auto-dismiss after `AUTO_DISMISS_MS`. Progress
// toasts stay open until they're upgraded to success/error via
// `update()` (the bundle/unbundle flows use this for "Bundling … →
// Bundled to /path").

export type ToastKind = "progress" | "success" | "error" | "info";

export interface Toast {
  id: number;
  kind: ToastKind;
  message: string;
  sticky: boolean;
}

const AUTO_DISMISS_MS = 4000;

class ToastStore {
  items = $state<Toast[]>([]);
  #nextId = 1;
  #dismissTimers = new Map<number, ReturnType<typeof setTimeout>>();

  push(
    init: Omit<Toast, "id" | "sticky"> & { sticky?: boolean },
  ): number {
    const id = this.#nextId++;
    const toast: Toast = {
      id,
      kind: init.kind,
      message: init.message,
      sticky: init.sticky ?? false,
    };
    this.items = [...this.items, toast];
    this.#armDismiss(toast);
    return id;
  }

  update(
    id: number,
    patch: Partial<Omit<Toast, "id">>,
  ): void {
    const idx = this.items.findIndex((t) => t.id === id);
    if (idx === -1) return;
    const next: Toast = { ...this.items[idx], ...patch };
    this.items = [
      ...this.items.slice(0, idx),
      next,
      ...this.items.slice(idx + 1),
    ];
    // Re-arm the timer with the new state.
    const existing = this.#dismissTimers.get(id);
    if (existing) {
      clearTimeout(existing);
      this.#dismissTimers.delete(id);
    }
    this.#armDismiss(next);
  }

  dismiss(id: number): void {
    this.items = this.items.filter((t) => t.id !== id);
    const t = this.#dismissTimers.get(id);
    if (t) clearTimeout(t);
    this.#dismissTimers.delete(id);
  }

  #armDismiss(toast: Toast): void {
    if (toast.sticky || toast.kind === "progress") return;
    const t = setTimeout(() => {
      this.dismiss(toast.id);
    }, AUTO_DISMISS_MS);
    this.#dismissTimers.set(toast.id, t);
  }
}

export const toasts = new ToastStore();
