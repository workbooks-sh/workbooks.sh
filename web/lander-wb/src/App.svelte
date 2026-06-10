<script>
  import { onMount } from "svelte";
  import { applyTheme } from "./lib/theme.svelte.js";
  import { reveal } from "./lib/build.svelte.js";
  import { openInsp, closeInsp, logLine, logUpdate, insp } from "./lib/inspector.svelte.js";
  import Inspector from "./lib/Inspector.svelte";
  import Nav from "./sections/Nav.svelte";
  import Hero from "./sections/Hero.svelte";
  import What from "./sections/What.svelte";
  import Proof from "./sections/Proof.svelte";
  import Make from "./sections/Make.svelte";
  import Yours from "./sections/Yours.svelte";
  import Questions from "./sections/Questions.svelte";
  import Get from "./sections/Get.svelte";
  import Footer from "./sections/Footer.svelte";

  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const LIVE = location.pathname.startsWith("/live") ? "/live" : "";
  const order = ["hero", "what", "proof", "make", "yours", "questions", "get"];
  const wait = ms => new Promise(r => setTimeout(r, ms));

  let headSha = null;
  async function poll(first) {
    try {
      const r = await fetch(LIVE + "/_changes", { cache: "no-store" });
      if (!r.ok) return;
      const j = await r.json();
      if (!j.changes?.length) return;
      insp.changes = j.changes;
      const top = j.changes[0].sha;
      if (first) headSha = top;
      else if (top !== headSha) setTimeout(() => location.reload(), 1800);
    } catch (_) {}
  }

  onMount(async () => {
    applyTheme();
    if (reduce) { order.forEach(reveal); poll(true); setInterval(() => poll(false), 30000); return; }
    openInsp("console");
    logLine(`<span class="pr">$</span> wb agent run <span class="kw">"compose workbooks.sh"</span>`);
    await wait(600);
    for (const name of order) {
      const e = logLine(`<span class="dim">∙</span> composing <span class="kw">${name}</span> …`);
      await wait(460);
      reveal(name);
      logUpdate(e, `<span class="dim">∙</span> composing <span class="kw">${name}</span> <span class="ok">✓</span>`);
      await wait(140);
    }
    logLine(`rendered ${order.length} sections · <span class="ok">live</span>`);
    await wait(900);
    closeInsp();
    poll(true);
    setInterval(() => poll(false), 30000);
  });
</script>

<Inspector />
<Nav />
<main>
  <Hero />
  <What />
  <Proof />
  <Make />
  <Yours />
  <Questions />
  <Get />
</main>
<Footer />
