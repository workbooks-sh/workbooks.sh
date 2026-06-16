// Phase 4b verification (own isolated chrome context, NOT the gate's contended one):
//   1. export a deck → a valid .pptx Blob → unzip + assert slide count + titles
//   2. import that .pptx back → assert it renders as <work-slide> children
//   3. export("video") routes to the wavelet path (or degrades to portable .html)
//   4. screenshot the rendered deck
// Real PptxGenJS + fflate lazy-load from CDN inside the page. Run from workponents/.
import { chromium } from "playwright";
import { startServer } from "./gate/server.js";
import { writeFileSync } from "node:fs";

const { url, close } = await startServer();
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1000, height: 640 } });
const errs = [];
page.on("pageerror", (e) => errs.push(String(e)));
page.on("console", (m) => { if (m.type() === "error") errs.push("console: " + m.text()); });

const DECK = `
  <work-deck id="d" controls aspect="16:9" hold="4s" transition="rise">
    <work-slide band="title" align="center" hold="3s"><h1>Quarterly Review</h1><p>FY26 Q2</p></work-slide>
    <work-slide band="content" align="start">
      <h2>Highlights</h2>
      <ul><li>Revenue up 24%</li><li>Churn down<ul><li>Enterprise</li><li>SMB</li></ul></li><li>NPS at 58</li></ul>
    </work-slide>
    <work-slide band="content" align="start"><h2>Outlook</h2><p>Strong pipeline into Q3.</p></work-slide>
  </work-deck>`;

await page.goto(`${url}/__gate/page.html`, { waitUntil: "load" });
await page.waitForFunction(() => window.__workponentsLoaded === true, { timeout: 15000 });

// register presentation domain + mount the deck into the stage
await page.evaluate(async (html) => {
  await import("/src/elements/presentation/index.js");
  // alias the embedded data-viz tags isn't needed here (plain HTML slides)
  const stage = document.querySelector("#stage") || document.body;
  stage.innerHTML = html;
  await customElements.whenDefined("work-deck");
  await customElements.whenDefined("work-slide");
  await new Promise((r) => setTimeout(r, 200));
}, DECK);

// ── 1+2. export → pptx Blob → unzip+assert → import back ──────────────────────
const result = await page.evaluate(async () => {
  const deck = document.querySelector("#d");
  const { importPptx, looksLikePptx } = await import("/src/elements/presentation/pptx-io.js");

  // export("pptx")
  const blob = await deck.export("pptx");
  const ab = await blob.arrayBuffer();
  const isZip = looksLikePptx(ab);

  // parse the pptx back: unzip + count ppt/slides/slideN.xml + pull <a:t> titles
  const fflate = window.__WB_FFLATE__ || (await import("https://esm.sh/fflate@0.8.2"));
  const unzip = (fflate.default || fflate).unzipSync;
  const zip = unzip(new Uint8Array(ab));
  const slideParts = Object.keys(zip).filter((p) => /^ppt\/slides\/slide\d+\.xml$/.test(p));
  const dec = new TextDecoder();
  const firstTitles = slideParts.sort().map((p) => {
    const xml = dec.decode(zip[p]);
    const m = xml.match(/<a:t>([^<]+)<\/a:t>/);
    return m ? m[1] : null;
  });

  // round-trip: import the pptx we just produced back into a fresh deck
  const src = await importPptx(ab);
  const host = document.createElement("work-deck");
  host.setAttribute("controls", "");
  document.querySelector("#stage").appendChild(host);
  const n = await host.import(ab);
  await new Promise((r) => setTimeout(r, 150));
  const renderedSlides = host.querySelectorAll(":scope > work-slide").length;
  const renderedTitles = Array.from(host.querySelectorAll(":scope > work-slide"))
    .map((s) => { const h = s.querySelector("h1,h2"); return h ? h.textContent.trim() : null; });
  const hasBullets = !!host.querySelector("work-slide ul li");

  return {
    blobType: blob.type, blobSize: blob.size, isZip,
    pptxSlideCount: slideParts.length, pptxTitles: firstTitles,
    importReturned: n, renderedSlides, renderedTitles, hasBullets,
    srcHasComment: src.startsWith("<!--"),
    srcHead: src.slice(0, 200),
  };
});

// ── 3. export("video") routes to wavelet (no Host → portable .html degrade) ───
const videoResult = await page.evaluate(async () => {
  const deck = document.querySelector("#d");
  // stub the download so the portable path doesn't actually trigger a navigation
  const realCreate = URL.createObjectURL; let downloadName = null;
  const realAppend = HTMLElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () { downloadName = this.download; };
  let detail = null;
  deck.addEventListener("work-deck-export", (e) => (detail = e.detail), { once: true });
  // host has no wavelet cap in this offline page → portable .html lane
  const out = await deck.export("video").catch((e) => ({ error: String(e) }));
  HTMLAnchorElement.prototype.click = realAppend;
  return { out, deckExportDetail: detail, downloadName };
});

await page.evaluate(() => { document.querySelector("#d").go(1); });
await page.waitForTimeout(300);
const shot = await page.locator("#d").screenshot();
writeFileSync(".shots-pptx-deck.png", shot);

await browser.close();
await close();

console.log("── ROUND-TRIP ──");
console.log(JSON.stringify(result, null, 2));
console.log("── VIDEO LANE ──");
console.log(JSON.stringify(videoResult, null, 2));
console.log("── PAGE ERRORS ──", errs.length ? errs : "none");

// assertions
const ok =
  result.isZip &&
  result.blobSize > 0 &&
  result.pptxSlideCount === 3 &&
  result.pptxTitles[0] === "Quarterly Review" &&
  result.renderedSlides >= 3 &&
  result.renderedTitles[0] === "Quarterly Review" &&
  result.hasBullets &&
  (videoResult.deckExportDetail && videoResult.deckExportDetail.format === "video" && videoResult.deckExportDetail.ok);
console.log(ok ? "\nVERIFY: PASS" : "\nVERIFY: FAIL");
process.exit(ok ? 0 : 1);
