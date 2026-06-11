// glyphs tests — plain asserts, zero deps. run: node test/glyph.test.mjs
import assert from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { glyph, glyphAsync, configure, parseRef } from "../dist/glyphs.js";
import { avatar } from "../packs/open-avatars/open-avatars.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const P = (...p) => join(__dirname, "..", "packs", ...p);
const load = (f) => JSON.parse(readFileSync(P(f), "utf8"));

const brands = load("curated-brands.json");
const icons = load("curated-icons.json");
const svglIndex = load("svgl-index.json");
const openPeeps = load("open-avatars/open-peeps.bundle.json");

configure({
  brands,
  icons,
  svglIndex,
  avatarPacks: { "open-peeps": openPeeps },
  avatarFn: avatar,
});

let pass = 0;
function ok(name, cond, detail) {
  if (cond) pass++;
  else {
    console.error(`FAIL: ${name}${detail ? "\n  " + detail : ""}`);
    process.exitCode = 1;
  }
}
const isSvg = (s) =>
  typeof s === "string" && s.trim().startsWith("<svg") && s.trim().endsWith("</svg>");

// ---------- ref parsing ----------
{
  ok("parse brand:google", JSON.stringify(parseRef("brand:google")) === JSON.stringify({ kind: "brand", id: "google" }));
  ok("parse icon:html5", parseRef("icon:html5").id === "html5");
  ok("avatar keeps pack/seed in id", parseRef("avatar:open-peeps/wren").id === "open-peeps/wren");
  ok("social keeps provider/user in id", parseRef("social:github/octocat").id === "github/octocat");
  ok("kind is lowercased", parseRef("Brand:Google").kind === "brand");
  ok("no colon → null", parseRef("google") === null);
  ok("empty id → null", parseRef("brand:") === null);
  ok("non-string → null", parseRef(null) === null);
}

// ---------- curated brand/icon hits are SYNC + valid SVG ----------
{
  const g = glyph("brand:google");
  ok("brand:google sync hit", isSvg(g));
  ok("brand carries glyph class", g.includes('class="glyph glyph--brand'));
  ok("brand is full color (keeps a hex fill)", /fill="#?[0-9a-fA-F]/.test(g) || /#[0-9a-fA-F]{3,6}/.test(g));

  const i = glyph("icon:elixir");
  ok("icon:elixir sync hit", isSvg(i));
  ok("icon carries glyph--icon class", i.includes("glyph--icon"));

  // a handful more curated marks resolve sync
  for (const ref of ["brand:anthropic", "brand:openai", "brand:github", "icon:react", "icon:rust", "icon:typescript"]) {
    ok(`${ref} sync hit`, isSvg(glyph(ref)), ref);
  }
}

// ---------- size / title / color / class opts ----------
{
  const px = glyph("icon:react", { size: 48 });
  ok("size number → px", px.includes("width:48px") && px.includes("height:48px"));
  const em = glyph("icon:react");
  ok("default size 1em", em.includes("width:1em"));
  const t = glyph("brand:google", { title: "Google" });
  ok("title injects <title>", t.includes("<title>Google</title>"));
  ok("title sets aria-label", t.includes('aria-label="Google"'));
  const c = glyph("icon:elixir", { color: "purple" });
  ok("color sets css color", c.includes("color:purple"));
  const cl = glyph("icon:elixir", { class: "big" });
  ok("custom class appended", cl.includes("glyph--icon big"));
}

// ---------- mono recolor ----------
{
  const plain = glyph("brand:google");
  const mono = glyph("brand:google", { mono: true });
  ok("mono adds glyph--mono class", mono.includes("glyph--mono"));
  ok("plain has no mono class", !plain.includes("glyph--mono"));
  // the CSS class drives grayscale; the mark string differs only by the class.
  ok("mono changes the output string", mono !== plain);
}

// ---------- miss → null (curated-only sync, no network) ----------
{
  ok("uncurated brand sync → null", glyph("brand:stripe") === null);
  ok("uncurated icon sync → null", glyph("icon:zig") === null);
  ok("unknown kind → null", glyph("widget:foo") === null);
  ok("garbage ref → null", glyph("nonsense") === null);
}

// ---------- avatar: delegated, deterministic ----------
{
  const a1 = glyph("avatar:open-peeps/wren");
  const a2 = glyph("avatar:open-peeps/wren");
  ok("avatar resolves to svg", isSvg(a1));
  ok("avatar same seed → byte-identical", a1 === a2);
  ok("avatar different seed → different", a1 !== glyph("avatar:open-peeps/moss"));
  ok("avatar matches direct open-avatars call", a1 === avatar(openPeeps, "wren", {}));
  ok("unknown avatar pack → null", glyph("avatar:nope/x") === null);
}

// ---------- social: an <img> the browser fetches ----------
{
  const s = glyph("social:github/octocat");
  ok("social returns <img>", s.startsWith("<img") && s.includes("src="));
  ok("social src = unavatar", s.includes("https://unavatar.io/github/octocat"));
  ok("social carries glyph--social", s.includes("glyph--social"));
  ok("social same ref → identical", s === glyph("social:github/octocat"));
}

// ---------- glyphAsync: curated hit resolves without network ----------
{
  const g = await glyphAsync("brand:google");
  ok("async curated brand hit", isSvg(g));
  ok("async curated == sync curated", g === glyph("brand:google"));
  const i = await glyphAsync("icon:elixir");
  ok("async curated icon hit", i === glyph("icon:elixir"));
  // avatar/social pass straight through async too.
  ok("async avatar == sync avatar", (await glyphAsync("avatar:open-peeps/wren")) === glyph("avatar:open-peeps/wren"));
}

// ---------- glyphAsync: CDN path with a MOCKED fetch ----------
{
  const realFetch = globalThis.fetch;
  const calls = [];
  const FAKE_BRAND = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#635BFF"><title>Stripe</title><path d="M0 0h24v24H0z"/></svg>';
  const FAKE_ICON = '<svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><title>Zig</title><path d="M0 0h24v24H0z"/></svg>';

  globalThis.fetch = async (url) => {
    calls.push(String(url));
    // svgl route for stripe lives in the bundled index; serve the brand svg.
    if (String(url).includes("stripe")) return { ok: true, text: async () => FAKE_BRAND };
    // simple-icons zig
    if (String(url).includes("/zig.svg")) return { ok: true, text: async () => FAKE_ICON };
    // everything else 404s (e.g. lobehub miss before simple-icons)
    return { ok: false, status: 404, text: async () => "" };
  };

  const stripe = await glyphAsync("brand:stripe");
  ok("async brand long-tail via CDN", isSvg(stripe), stripe);
  ok("brand:stripe used the svgl index route", calls.some((u) => u.includes("stripe")));
  ok("stripe came back full-color", stripe.includes("#635BFF"));

  const zig = await glyphAsync("icon:zig");
  ok("async icon long-tail via CDN", isSvg(zig), zig);
  ok("icon:zig hit simple-icons", calls.some((u) => u.includes("simple-icons") && u.includes("zig")));

  // a true miss: nothing curated, every CDN 404s → null.
  const miss = await glyphAsync("brand:doesnotexistxyz");
  ok("async total miss → null", miss === null);

  // opts apply on the async-resolved mark too.
  const sized = await glyphAsync("brand:stripe", { size: 32, mono: true });
  ok("async mark honors size opt", sized.includes("width:32px"));
  ok("async mark honors mono opt", sized.includes("glyph--mono"));

  globalThis.fetch = realFetch;
}

// ---------- fetch-absent: glyphAsync degrades to curated/null ----------
{
  const realFetch = globalThis.fetch;
  globalThis.fetch = undefined;
  const curated = await glyphAsync("brand:google");
  ok("no fetch: curated still works", isSvg(curated));
  const tail = await glyphAsync("brand:stripe");
  ok("no fetch: long-tail → null (documented caveat)", tail === null);
  globalThis.fetch = realFetch;
}

console.log(`glyphs: ${pass} checks passed${process.exitCode ? " (with FAILURES)" : ""}`);
