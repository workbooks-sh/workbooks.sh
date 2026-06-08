// Generic History-API / Vite adapter for the RCP RouteGate (rzip part b). NO
// framework: drives the browser History API directly and hands each navigation's
// RouteGate.load outcome to render callbacks you supply. This is the fallback for
// a hand-rolled SPA, a Vite app with no router, or a raw .html bundle.
//
// Shape: it owns popstate + an intercepted navigate(); on each path it calls
// gate.load and dispatches to one of your handlers (onContent / onPublic /
// onDenied / onUnavailable / onNotFound). You own the DOM; it owns the gate wiring.
//
// Usage:
//   const nav = createHistoryGate(gate, {
//     onPublic: (p) => renderStatic(p),
//     onContent: (p, content) => renderGated(p, content),
//     onDenied: (p) => location.assign(`/login?next=${encodeURIComponent(p)}`),
//     onUnavailable: () => renderBanner("runtime offline"),
//     onNotFound: () => render404(),
//   });
//   nav.start();                 // resolve the current URL + listen for back/fwd
//   nav.navigate("/secret");     // pushState + resolve

import type { RouteGate } from "../routing";

export interface HistoryHandlers {
  onPublic: (path: string) => void;
  onContent: (path: string, content: unknown) => void;
  onDenied: (path: string, reason: string) => void;
  onUnavailable: (path: string) => void;
  onNotFound: (path: string) => void;
}

export interface HistoryGate {
  /** Resolve the current location and attach the popstate listener. */
  start(): void;
  /** pushState to `path` and resolve it through the gate. */
  navigate(path: string): Promise<void>;
  /** Re-resolve the current location without a history entry. */
  refresh(): Promise<void>;
  /** Detach the popstate listener. */
  stop(): void;
}

export function createHistoryGate(gate: RouteGate, handlers: HistoryHandlers): HistoryGate {
  const resolve = async (path: string): Promise<void> => {
    const res = await gate.load(path);
    switch (res.status) {
      case "public":
        return handlers.onPublic(path);
      case "ok":
        return handlers.onContent(path, res.content);
      case "denied":
        return handlers.onDenied(path, res.reason);
      case "unavailable":
        return handlers.onUnavailable(path);
      case "not_found":
        return handlers.onNotFound(path);
    }
  };

  const onPop = () => void resolve(location.pathname);

  return {
    start() {
      window.addEventListener("popstate", onPop);
      void resolve(location.pathname);
    },
    async navigate(path: string) {
      history.pushState({}, "", path);
      await resolve(path);
    },
    async refresh() {
      await resolve(location.pathname);
    },
    stop() {
      window.removeEventListener("popstate", onPop);
    },
  };
}
