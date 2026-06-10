<script>
  import { onMount } from "svelte";
  import { theme, toggleTheme, applyTheme } from "./lib/theme.svelte.js";
  import Button from "./lib/Button.svelte";
  import Chip from "./lib/Chip.svelte";
  import Card from "./lib/Card.svelte";
  import Cell from "./lib/Cell.svelte";
  import VoicePair from "./lib/VoicePair.svelte";
  import Ascii from "./lib/Ascii.svelte";
  import Workbook from "./lib/Workbook.svelte";
  import Inspector from "./lib/Inspector.svelte";
  import { insp, openInsp } from "./lib/inspector.svelte.js";
  import habits from "../demos/habits.html?raw";
  onMount(applyTheme);
  const swatches = [["green","#00ff44"],["blue","#0080ff"],["rose","#ff0066"],["ink","var(--ink)"]];
</script>

<Inspector />

<header class="head">
  <span class="brand"><svg viewBox="0 0 257 206" fill="none" aria-label="Workbooks"><path d="M0 206V0.00231147H69.1194V76L126.393 0L168.946 0.00231147V76L223.295 0L257 0.00231147V183C257 195.703 246.703 206 234 206H116.27L112.626 140.5L41.5 206H0Z" fill="currentColor"/></svg> Workbooks</span>
  <span class="tag mono">component sheet · real svelte components</span>
  <span class="sp"></span>
  <button class="tt" onclick={toggleTheme}><span class="dot"></span>{theme.mode === "dark" ? "light" : "dark"}</button>
  <Button variant="soft" sm onclick={() => openInsp("elements")}>open inspector</Button>
</header>

<main class="sheet">
  <section class="spec">
    <div class="sh"><span class="no mono">[ 01 ]</span><h2>Color — the trio</h2></div>
    <div class="sw-grid">
      {#each swatches as [name, hex]}
        <div class="sw"><b class="mono">{name}</b><span class="mono">{hex}</span><span class="bar" style="background:{hex}"></span></div>
      {/each}
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 02 ]</span><h2>Type — two voices</h2></div>
    <VoicePair>
      {#snippet claim()}<h1 class="xl">This is <em>a workbook.</em></h1>{/snippet}
      {#snippet receipt()}<span class="p">$</span> wb bundle . <span class="c">→</span> app.html <span class="ok">· source inside</span>{/snippet}
    </VoicePair>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 03 ]</span><h2>Actions</h2></div>
    <div class="row">
      <Button variant="ink">Download the app</Button>
      <Button variant="green">Green</Button>
      <Button variant="blue">Blue</Button>
      <Button variant="rose">Rose</Button>
      <Button variant="soft">Soft</Button>
      <Button variant="text">Text →</Button>
    </div>
    <div class="row" style="margin-top:1rem">
      <Chip tone="live">live</Chip><Chip tone="run">running</Chip><Chip tone="err">error</Chip><Chip>neutral</Chip>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 04 ]</span><h2>Cells — trio-accented</h2></div>
    <div class="g3">
      <Cell accent="green" glyph="✶" title="Composed by an agent">lander-keeper wrote this and maintains it.</Cell>
      <Cell accent="blue" glyph="◷" title="Served live">the runtime renders the current file.</Cell>
      <Cell accent="rose" glyph="∞" title="Open source">Apache-2.0, end to end.</Cell>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 05 ]</span><h2>Cards</h2></div>
    <div class="g2">
      <Card><h3>A card</h3><p class="sub">Panel, hairline, soft shadow, radius. The surface everything sits on.</p></Card>
      <Card><h3>Another</h3><p class="sub">Compose voice-pairs, cells, and chips inside cards.</p></Card>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 06 ]</span><h2>Signal — the ASCII field</h2></div>
    <div class="ascii-tile"><Ascii dense speed={0.7} /></div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 07 ]</span><h2>Workbook — a live one</h2></div>
    <div class="g2">
      <Workbook name="habits.html" size="5.5 KB" accent="green" html={habits} caption="A real workbook, running. Tap the grid." />
    </div>
  </section>
</main>

<style>
  .head{position:sticky;top:0;z-index:40;display:flex;align-items:center;gap:.9rem;padding:.9rem var(--edge);
    background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--hair)}
  .brand{display:flex;align-items:center;gap:.5rem;font-family:var(--serif);font-weight:600;font-size:1.3rem}
  .brand svg{height:19px} .tag{font-size:.72rem;color:var(--ink3)} .sp{flex:1}
  .mono{font-family:var(--mono)}
  .tt{display:inline-flex;align-items:center;gap:.5rem;cursor:pointer;border:0;font-family:var(--mono);font-size:.72rem;color:var(--ink2);background:var(--bg2);padding:.42rem .75rem;border-radius:999px}
  .tt .dot{width:9px;height:9px;border-radius:50%;background:var(--ink)} :global([data-theme="dark"]) .tt .dot{background:var(--green)}
  .sheet{max-width:1100px;margin:0 auto;padding:0 var(--edge) 6rem}
  .spec{margin-top:3.5rem}
  .sh{display:flex;align-items:baseline;gap:1rem;border-bottom:1px solid var(--hair);padding-bottom:.7rem;margin-bottom:1.5rem}
  .sh h2{font-size:1.35rem} .no{font-size:.72rem;color:var(--ink3)}
  .row{display:flex;gap:.8rem;flex-wrap:wrap;align-items:center}
  .g2{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:1rem}
  .g3{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:1rem}
  .sub{color:var(--ink2);margin-top:.5rem;font-size:.95rem} h3{font-size:1.2rem}
  .xl{font-size:clamp(2.6rem,6vw,4.4rem)} .xl em{font-style:normal;color:var(--blue-text)}
  .sw-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:1px;background:var(--hair);border-radius:14px;overflow:hidden}
  .sw{padding:1.1rem .9rem 3.4rem;position:relative;background:var(--card)}
  .sw b{font-size:.74rem;display:block} .sw span{font-size:.66rem;color:var(--ink3)}
  .sw .bar{position:absolute;inset:auto 0 0 0;height:2.4rem}
  .ascii-tile{position:relative;border-radius:14px;overflow:hidden;background:var(--bg2);min-height:200px;height:200px}
  :global(.machine .p){color:var(--green-ink);font-weight:700} :global(.machine .c){color:var(--ink3)} :global(.machine .ok){color:var(--green-ink)}
</style>
