/**
 * Iframe pointer bridge (wb-v9ys.6 follow-up).
 *
 * The runner iframe fills the viewport, so when the recipient's
 * pointer is over the workbook, pointer events go to the IFRAME's
 * document — the parent window's `pointermove`/`click` never fire.
 * That means presence cursor tracking on the parent is dead for the
 * common case (mouse over the workbook).
 *
 * Fix: with `allow-same-origin` on the sandbox, the host can attach
 * listeners directly to `iframe.contentDocument`. The iframe sits at
 * (0,0) at full viewport size, so its client coordinates equal the
 * parent's — we just normalize to [0,1] for cross-device cursor
 * rendering.
 *
 * Handles the blob-URL load timing the same way the cell-anchor
 * observer does: wire on `load`, and immediately if the document is
 * already there. Returns a cleanup that detaches everything.
 */

export interface IframePointerHandlers {
  /** Normalized [0,1] viewport coordinates. */
  onMove(x: number, y: number): void;
  /** Fired on pointerdown inside the workbook — drives the click
   *  "ping" ripple peers see. Normalized coordinates. */
  onClick(x: number, y: number): void;
}

export function attachIframePointer(
  iframe: HTMLIFrameElement,
  handlers: IframePointerHandlers,
): () => void {
  let doc: Document | null = null;
  let win: Window | null = null;
  let disposed = false;

  const move = (e: PointerEvent | MouseEvent) => {
    if (!win) return;
    const w = win.innerWidth || iframe.clientWidth;
    const h = win.innerHeight || iframe.clientHeight;
    if (w === 0 || h === 0) return;
    handlers.onMove(e.clientX / w, e.clientY / h);
  };
  const down = (e: PointerEvent | MouseEvent) => {
    if (!win) return;
    const w = win.innerWidth || iframe.clientWidth;
    const h = win.innerHeight || iframe.clientHeight;
    if (w === 0 || h === 0) return;
    handlers.onClick(e.clientX / w, e.clientY / h);
  };

  const wire = () => {
    if (disposed) return;
    const d = iframe.contentDocument;
    const w = iframe.contentWindow;
    if (!d || !w || d === doc) return;
    // Detach any prior doc (blob URL re-navigation).
    unwire();
    doc = d;
    win = w;
    // Capture phase + passive so the workbook's own drag handlers
    // still run; we only observe.
    doc.addEventListener("pointermove", move, { capture: true, passive: true });
    doc.addEventListener("pointerdown", down, { capture: true, passive: true });
  };

  const unwire = () => {
    if (doc) {
      doc.removeEventListener("pointermove", move, true);
      doc.removeEventListener("pointerdown", down, true);
    }
    doc = null;
    win = null;
  };

  iframe.addEventListener("load", wire);
  wire();

  return () => {
    disposed = true;
    iframe.removeEventListener("load", wire);
    unwire();
  };
}
