/**
 * Cell-anchor observer — host-side adapter that watches the workbook
 * iframe's DOM and exposes a reactive Map<cell_id, RectInfo> for
 * everything that wants to position overlays next to specific cells
 * (comment pins, anchored cursors, the open-thread popover).
 *
 * Scrape-first, not protocol-first. Workbooks already mark cells with
 * `data-cell-id="<id>"` (the broker's anchor-rewalk regex in
 * services/broker/worker/src/lib/anchorResolve.ts already depends on
 * it), so the host can read positions directly without any workbook-
 * side changes. A future opt-in postMessage protocol can take over by
 * superseding the scrape path — `setProtocolMode("protocol")` once a
 * workbook sends runner.hello.
 *
 * Required iframe sandbox attributes:
 *   allow-scripts allow-same-origin
 *
 * `allow-same-origin` lets the host read iframe.contentDocument across
 * the sandbox boundary; without it `contentDocument` is null and this
 * observer no-ops.
 *
 * The observer keeps its bookkeeping cheap:
 *   - MutationObserver on the iframe body catches add/remove + attr
 *     changes to data-cell-id.
 *   - ResizeObserver (one observer, many targets) covers content
 *     resize + reflow.
 *   - A single 'scroll' listener (capture, passive) on the iframe
 *     document refreshes rects when the user scrolls.
 *   - All rect reads are batched via requestAnimationFrame so a
 *     burst of mutations + scrolls produces one update per frame.
 *
 * The rects are reported in IFRAME-VIEWPORT coordinates (the same
 * coordinate space the iframe itself sees). The host viewer already
 * positions the iframe at left:0 top:0 width:100vw height:100vh, so
 * iframe-viewport == window-viewport for our case. Components that
 * render overlays read these rects directly.
 */

export interface CellRect {
  /** The element's bounding rect, in iframe viewport coordinates. */
  x: number;
  y: number;
  width: number;
  height: number;
  /** Centroid — handy for placing a single pin marker. */
  cx: number;
  cy: number;
  /** True when any portion of the cell is currently in the iframe
   *  viewport. Pins for off-screen cells are usually hidden. */
  inView: boolean;
}

export type CellRectMap = Map<string, CellRect>;

export class CellAnchorObserver {
  #iframe: HTMLIFrameElement | null = null;
  #doc: Document | null = null;
  #mo: MutationObserver | null = null;
  #ro: ResizeObserver | null = null;
  #onScroll: ((ev: Event) => void) | null = null;
  #rafScheduled = false;
  #disposed = false;

  /** Latest snapshot — exposed via $state so consumers can $derive. */
  rects = $state<CellRectMap>(new Map());

  /** True once we've successfully read at least one cell rect.
   *  Components use this to know if scraping is working at all. */
  ready = $state(false);

  attach(iframe: HTMLIFrameElement): void {
    this.detach();
    this.#disposed = false;
    this.#iframe = iframe;

    const tryWire = () => {
      if (this.#disposed) return;
      const doc = iframe.contentDocument;
      if (!doc) {
        // contentDocument is null until the iframe has its first load.
        // Listen for it and retry — also covers blob URL navigations.
        return;
      }
      this.#wire(doc);
    };

    // Some browsers fire 'load' before contentDocument is fully
    // populated for blob URLs; covered both directions.
    iframe.addEventListener("load", tryWire);
    tryWire();
  }

  detach(): void {
    this.#disposed = true;
    this.#mo?.disconnect();
    this.#mo = null;
    this.#ro?.disconnect();
    this.#ro = null;
    if (this.#doc && this.#onScroll) {
      this.#doc.removeEventListener("scroll", this.#onScroll, true);
      this.#doc.defaultView?.removeEventListener("resize", this.#onScroll);
    }
    this.#onScroll = null;
    this.#doc = null;
    this.#iframe = null;
    this.rects = new Map();
    this.ready = false;
  }

  /** Force an immediate rescan — useful after the host triggers a
   *  layout change (e.g. theme swap) that might shift cells. */
  rescan(): void {
    this.#scheduleUpdate();
  }

  #wire(doc: Document): void {
    this.#doc = doc;

    this.#mo = new MutationObserver(() => this.#scheduleUpdate());
    this.#mo.observe(doc.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["data-cell-id"],
    });

    this.#ro = new ResizeObserver(() => this.#scheduleUpdate());
    // Observe the body so any layout change re-runs the rect read.
    // Cells are observed individually too, below, so that targeted
    // changes don't pay the body-traversal cost on every frame.
    this.#ro.observe(doc.body);
    for (const el of doc.querySelectorAll<HTMLElement>("[data-cell-id]")) {
      this.#ro.observe(el);
    }

    this.#onScroll = () => this.#scheduleUpdate();
    // 'capture' so nested scroll containers fire too. 'passive' so we
    // don't impede touch scrolling.
    doc.addEventListener("scroll", this.#onScroll, { capture: true, passive: true });
    doc.defaultView?.addEventListener("resize", this.#onScroll);

    // Prime the map.
    this.#scheduleUpdate();
  }

  #scheduleUpdate(): void {
    if (this.#rafScheduled || this.#disposed) return;
    this.#rafScheduled = true;
    requestAnimationFrame(() => {
      this.#rafScheduled = false;
      if (this.#disposed) return;
      this.#refresh();
    });
  }

  #refresh(): void {
    const doc = this.#doc;
    const iframe = this.#iframe;
    if (!doc || !iframe) return;

    const next: CellRectMap = new Map();
    const winH = doc.defaultView?.innerHeight ?? iframe.clientHeight;
    const winW = doc.defaultView?.innerWidth ?? iframe.clientWidth;

    for (const el of doc.querySelectorAll<HTMLElement>("[data-cell-id]")) {
      const id = el.getAttribute("data-cell-id");
      if (!id) continue;
      const r = el.getBoundingClientRect();
      // Skip zero-area cells (display:none, etc).
      if (r.width === 0 && r.height === 0) continue;
      const inView = r.bottom > 0 && r.top < winH && r.right > 0 && r.left < winW;
      next.set(id, {
        x: r.left,
        y: r.top,
        width: r.width,
        height: r.height,
        cx: r.left + r.width / 2,
        cy: r.top + r.height / 2,
        inView,
      });
    }

    // Re-observe any newly-added cells; ResizeObserver.observe is
    // idempotent for already-observed targets.
    if (this.#ro) {
      for (const el of doc.querySelectorAll<HTMLElement>("[data-cell-id]")) {
        this.#ro.observe(el);
      }
    }

    this.rects = next;
    if (!this.ready && next.size > 0) this.ready = true;
  }
}
