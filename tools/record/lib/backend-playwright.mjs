// Playwright backend — for polished WEB walkthroughs (dev frontend at :5178, the
// landing page, or any web target) where a visible animated cursor + realistic
// typing matter and Chromium is fair game (NOT the Tauri/WKWebView app — that's
// the MCP backend). Records native WebM video, captures console for the verifier,
// and draws a visible cursor that moves on human-ish Bézier paths (ghost-cursor
// shape, inlined — no extra dependency).

import path from "node:path";
import fs from "node:fs/promises";
import { gaussianDelay, sleep } from "./intents.mjs";

const CURSOR_CSS = `
#__wb_cursor__{position:fixed;z-index:2147483647;width:22px;height:22px;margin:-3px 0 0 -3px;
pointer-events:none;transition:opacity .2s;left:0;top:0;will-change:transform;}
#__wb_cursor__ svg{filter:drop-shadow(0 1px 2px rgba(0,0,0,.45));}
#__wb_cursor__.click svg{transform:scale(.82);}
`;
const CURSOR_HTML = `<div id="__wb_cursor__"><svg width="22" height="22" viewBox="0 0 22 22">
<path d="M2 2 L2 16 L6 12 L9 19 L12 18 L9 11 L15 11 Z" fill="#111" stroke="#fff" stroke-width="1.2"/></svg></div>`;

// inject: a visible cursor + a window error sink the verifier can read.
const INIT_SCRIPT = `(()=>{
  const sink = (window.__WB_REC_ERRORS__ = window.__WB_REC_ERRORS__ || []);
  window.addEventListener('error', e => sink.push({type:'error',msg:String(e.message),at:Date.now()}));
  window.addEventListener('unhandledrejection', e => sink.push({type:'rejection',msg:String(e.reason),at:Date.now()}));
  // addInitScript runs in EVERY frame; the visible cursor must live only in the
  // top frame, or each workbook iframe spawns its own (a 2nd, un-driven cursor
  // parked at the iframe's origin). The top-frame cursor is position:fixed at
  // max z-index, so it already floats over iframe content.
  if(window.top !== window.self) return;
  function ensure(){
    if(document.getElementById('__wb_cursor__')) return;
    if(!document.body){ return requestAnimationFrame(ensure); }
    const s=document.createElement('style'); s.textContent=${JSON.stringify(CURSOR_CSS)}; document.head.appendChild(s);
    const d=document.createElement('div'); d.innerHTML=${JSON.stringify(CURSOR_HTML)}; document.body.appendChild(d.firstElementChild);
  }
  window.__wb_cursor_move=(x,y)=>{const c=document.getElementById('__wb_cursor__'); if(c) c.style.transform='translate('+x+'px,'+y+'px)';};
  window.__wb_cursor_click=on=>{const c=document.getElementById('__wb_cursor__'); if(c) c.classList.toggle('click',on);};
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',ensure); else ensure();
  try{
    var root=document.documentElement;
    if(root) new MutationObserver(ensure).observe(root,{childList:true,subtree:false});
  }catch(_){ /* re-injected before DOM exists; DOMContentLoaded path covers it */ }
})();`;

// cubic Bézier point
function bez(p0, p1, p2, p3, t) {
  const mt = 1 - t;
  return {
    x: mt ** 3 * p0.x + 3 * mt ** 2 * t * p1.x + 3 * mt * t ** 2 * p2.x + t ** 3 * p3.x,
    y: mt ** 3 * p0.y + 3 * mt ** 2 * t * p1.y + 3 * mt * t ** 2 * p2.y + t ** 3 * p3.y,
  };
}

export class PlaywrightBackend {
  constructor({ outDir, headless = false, viewport = { width: 1440, height: 900 } }) {
    this.outDir = outDir;
    this.headless = headless;
    this.viewport = viewport;
    this.kind = "playwright";
    this.pos = { x: viewport.width / 2, y: viewport.height / 2 };
    this.console = [];
  }

  async connect() {
    let chromium;
    try {
      ({ chromium } = await import("playwright"));
    } catch {
      ({ chromium } = await import("@playwright/test"));
    }
    this.browser = await chromium.launch({ headless: this.headless });
    this.ctx = await this.browser.newContext({
      viewport: this.viewport,
      // The Workbooks shell is dark-first and picks its variant from
      // prefers-color-scheme; Chromium defaults to light, which washes the
      // shell out on capture. Force dark so the recording matches the app.
      colorScheme: "dark",
      recordVideo: { dir: this.outDir, size: this.viewport },
    });
    await this.ctx.addInitScript(INIT_SCRIPT);
    this.page = await this.ctx.newPage();
    this.page.on("console", (m) => this.console.push({ type: m.type(), msg: m.text(), at: Date.now() }));
    this.page.on("pageerror", (e) => this.console.push({ type: "error", msg: String(e), at: Date.now() }));
    return this;
  }

  async _moveTo(x, y) {
    const from = this.pos;
    const dist = Math.hypot(x - from.x, y - from.y);
    const steps = Math.max(12, Math.min(60, Math.round(dist / 12)));
    // control points = midpoint +/- jitter for an organic arc
    const jx = (Math.random() - 0.5) * dist * 0.4;
    const jy = (Math.random() - 0.5) * dist * 0.4;
    const c1 = { x: from.x + (x - from.x) * 0.35 + jx, y: from.y + (y - from.y) * 0.35 + jy };
    const c2 = { x: from.x + (x - from.x) * 0.65 - jx, y: from.y + (y - from.y) * 0.65 - jy };
    for (let i = 1; i <= steps; i++) {
      const t = i / steps;
      const p = bez(from, c1, c2, { x, y }, t);
      await this.page.mouse.move(p.x, p.y);
      await this.page.evaluate(([px, py]) => window.__wb_cursor_move?.(px, py), [p.x, p.y]);
      await sleep(6 + Math.random() * 8);
    }
    this.pos = { x, y };
  }

  async _center(selector) {
    const el = this.page.locator(selector).first();
    await el.waitFor({ state: "visible", timeout: 10000 });
    const box = await el.boundingBox();
    if (!box) throw new Error(`no bounding box for ${selector}`);
    return { x: box.x + box.width / 2 + (Math.random() - 0.5) * box.width * 0.3, y: box.y + box.height / 2 };
  }

  async perform(step) {
    switch (step.intent) {
      case "navigate":
        await this.page.goto(step.url, { waitUntil: step.waitUntil || "domcontentloaded" });
        return {};
      case "click": {
        const { x, y } = step.selector ? await this._center(step.selector) : { x: step.x, y: step.y };
        await this._moveTo(x, y);
        await this.page.evaluate(() => window.__wb_cursor_click?.(true));
        await sleep(60);
        await this.page.mouse.click(x, y);
        await this.page.evaluate(() => window.__wb_cursor_click?.(false));
        return {};
      }
      case "type": {
        if (step.selector) {
          const { x, y } = await this._center(step.selector);
          await this._moveTo(x, y);
          await this.page.mouse.click(x, y);
        }
        for (const ch of step.text) {
          await this.page.keyboard.type(ch);
          await sleep(step.perKeyMs ?? gaussianDelay());
        }
        return {};
      }
      case "hover": {
        const { x, y } = step.selector ? await this._center(step.selector) : { x: step.x, y: step.y };
        await this._moveTo(x, y);
        return {};
      }
      case "wait":
        if (step.selector) {
          await this.page.locator(step.selector).first().waitFor({ timeout: step.timeoutMs || 10000 });
        } else {
          await sleep(step.ms || 500);
        }
        return {};
      case "eval_js":
        return { value: await this.page.evaluate(step.code) };
      case "dom_read":
        return {
          html: step.selector
            ? await this.page.locator(step.selector).first().innerHTML()
            : await this.page.content(),
        };
      case "screenshot":
        return await this.screenshot(step.name);
      default:
        throw new Error(`playwright backend: unhandled intent ${step.intent}`);
    }
  }

  async screenshot(name = `shot-${Date.now()}`) {
    const file = path.join(this.outDir, `${name}.png`);
    await this.page.screenshot({ path: file });
    return { path: file };
  }

  async collectSignals() {
    let injected = [];
    try {
      injected = await this.page.evaluate(() => (window.__WB_REC_ERRORS__ || []).slice(-50));
    } catch {}
    return { console: [...this.console, ...injected], html: await this.page.content().catch(() => null) };
  }

  // Finalize the WebM video (Playwright writes it on context close).
  async finishVideo(targetName) {
    const video = this.page.video();
    // Hold on the final state so the last action's result stays on screen — the
    // recording otherwise ends the instant the last intent returns, cutting the
    // tail. Overridable via WB_REC_TAIL_MS.
    await sleep(Number(process.env.WB_REC_TAIL_MS) || 1200);
    await this.ctx.close(); // flushes video to disk
    if (!video) return null;
    const raw = await video.path();
    const dest = path.join(this.outDir, `${targetName}.webm`);
    await fs.rename(raw, dest).catch(async () => {
      await fs.copyFile(raw, dest);
    });
    return dest;
  }

  async close() {
    try {
      await this.ctx?.close();
    } catch {}
    try {
      await this.browser?.close();
    } catch {}
  }
}
