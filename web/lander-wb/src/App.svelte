<script>
  import { onMount } from "svelte";
  import { theme, toggleTheme, applyTheme } from "./lib/theme.svelte.js";
  import Button from "./lib/Button.svelte";
  import Chip from "./lib/Chip.svelte";
  import Card from "./lib/Card.svelte";
  import LogoCard from "./lib/LogoCard.svelte";
  import VoicePair from "./lib/VoicePair.svelte";
  import Ascii from "./lib/Ascii.svelte";
  import Workbook from "./lib/Workbook.svelte";
  import Rule from "./lib/Rule.svelte";
  import Inspector from "./lib/Inspector.svelte";
  import { openInsp } from "./lib/inspector.svelte.js";
  import habits from "../demos/habits.html?raw";
  onMount(applyTheme);

  const W = "M0 206V0.00231147H69.1194V76L126.393 0L168.946 0.00231147V76L223.295 0L257 0.00231147V183C257 195.703 246.703 206 234 206H116.27L112.626 140.5L41.5 206H0Z";
  const trio = [["green", "#00ff44", "go · live · positive"], ["blue", "#0080ff", "running · links · focus"], ["rose", "#ff0066", "alert · error · accent"]];
  const neutrals = [["bg", "page"], ["bg2", "subtle fill"], ["card", "surface"], ["ink", "text"], ["ink2", "muted"], ["ink3", "faint"], ["hair", "hairline"]];
</script>

<Inspector />

<header class="head">
  <span class="brand"><svg viewBox="0 0 257 206" fill="none" aria-label="Workbooks"><path d={W}/></svg> Workbooks</span>
  <span class="tag mono">design system · v3 · real svelte components</span>
  <span class="sp"></span>
  <button class="tt" onclick={toggleTheme}><span class="dot"></span>{theme.mode === "dark" ? "light" : "dark"}</button>
  <Button variant="soft" sm onclick={() => openInsp("elements")}>inspect</Button>
</header>

<main class="sheet">

  <section class="spec hero-spec">
    <div class="mark"><svg viewBox="0 0 257 206" fill="none" aria-hidden="true"><path d={W}/></svg></div>
    <div>
      <p class="no mono">the brand</p>
      <h1 class="xl mixed">Two voices. <em>One file.</em></h1>
      <p class="lead">A <b>human</b> voice (Newsreader serif — the claim) always paired with a <b>machine</b> voice (Spline Mono — the proof). Flat electric trio on quiet neutrals. Hairlines and solid fills — no gradients, no strokes-as-decoration. This page is the system, rendered from its own components.</p>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 01 ]</span><h2>Color</h2><span class="note">the trio is theme-constant — it's the brand. neutrals flip light/dark.</span></div>
    <div class="g3">
      {#each trio as [name, hex, use]}
        <div class="sw"><span class="fill" style="background:{hex}"></span><div class="meta"><b class="mono">{name}</b><span class="mono">{hex}</span><span class="use">{use}</span></div></div>
      {/each}
    </div>
    <div class="neutrals">
      {#each neutrals as [v, label]}<div class="nrow"><span class="chipv" style="background:var(--{v})"></span><b class="mono">--{v}</b><span class="mono">{label}</span></div>{/each}
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 02 ]</span><h2>Type</h2><span class="note">emphasis mixes FONTS, never color — serif claim, mono accent.</span></div>
    <div class="typ">
      <h1 class="xl mixed">This is <em>a workbook.</em></h1>
      <h2 class="l mixed">Software, <em>alive.</em></h2>
      <p class="body">Body — Newsreader at reading size for prose. Calm, editorial, never shouty.</p>
      <p class="machine"><span class="p">$</span> the machine voice — Spline Mono <span class="c"># receipts, never decoration</span></p>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 03 ]</span><h2>Actions</h2></div>
    <div class="row">
      <Button variant="ink">Download the app</Button>
      <Button variant="green">Green</Button><Button variant="blue">Blue</Button><Button variant="rose">Rose</Button>
      <Button variant="soft">Soft</Button><Button variant="text">Text →</Button>
    </div>
    <div class="row" style="margin-top:1rem">
      <Chip tone="live">live</Chip><Chip tone="run">running</Chip><Chip tone="err">error</Chip><Chip>neutral</Chip>
      <span class="input mono"><span class="q">›</span> describe an app…</span>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 04 ]</span><h2>Cards</h2><span class="note">full-color cards carry a tonal W-mark — no accent stripes.</span></div>
    <div class="g3">
      <LogoCard accent="green" title="Composed by an agent">lander-keeper wrote this page and maintains it on a loop.</LogoCard>
      <LogoCard accent="blue" title="Served live">the runtime renders the current file on request.</LogoCard>
      <LogoCard accent="rose" title="Open source">Apache-2.0, end to end. Files don't need us.</LogoCard>
    </div>
    <div class="g2" style="margin-top:var(--s4)">
      <Card><h3>Plain surface</h3><p class="body">Panel, hairline, soft shadow, radius — the quiet base everything sits on.</p></Card>
      <LogoCard accent="ink" title="Inverted">For a single emphatic statement — the ink card with a ghost mark.</LogoCard>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 05 ]</span><h2>Signal — the ASCII field</h2><span class="note">the machine "thinking" texture. theme-aware, throttled, viewport-paused.</span></div>
    <div class="ascii-tile"><Ascii dense speed={0.7} /></div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 06 ]</span><h2>Surfaces — a live workbook</h2></div>
    <div class="g2">
      <Workbook name="habits.html" size="5.5 KB" html={habits} caption="A real workbook, running in the sheet. Tap the grid — data stays in your browser." />
      <Card>
        <div class="kv"><span class="k mono">OUTSTANDING</span><span class="v">$8,400</span></div>
        <p class="body" style="margin-top:var(--s2)">Key-value, list rows, app frames — the surfaces a workbook composes from.</p>
        <VoicePair>
          {#snippet receipt()}<span class="p">$</span> wb run app.html <span class="ok">· ready</span>{/snippet}
        </VoicePair>
      </Card>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 07 ]</span><h2>Rules</h2><span class="note">the design concepts, as checkable rules.</span></div>
    <div class="g2">
      <Rule kind="do">Express emphasis with a <em>font shift</em> — serif claim, mono accent.</Rule>
      <Rule kind="dont">Don't tint headline words <em>blue</em> (or any color) for emphasis.</Rule>
      <Rule kind="do">Use <em>full-color cards</em> with a tonal W-mark for categorized content.</Rule>
      <Rule kind="dont">Don't use <em>accent stripes</em> (top borders, left rules) on cards.</Rule>
      <Rule kind="do">Pair every human <em>claim</em> with a machine <em>receipt</em> (real output).</Rule>
      <Rule kind="dont">Don't fabricate receipts, metrics, or praise — pre-launch, there are none.</Rule>
      <Rule kind="do">On the bright <em>green</em>, set text in ink/black — it's high-luminance.</Rule>
      <Rule kind="dont">Don't put <em>white</em> on green; white is for blue &amp; rose.</Rule>
      <Rule kind="do">Hairlines and <em>solid fills</em>; the trio is constant across themes.</Rule>
      <Rule kind="dont">No gradients-as-decoration, no drop-shadow chrome, no strokes.</Rule>
    </div>
  </section>

  <section class="spec">
    <div class="sh"><span class="no mono">[ 08 ]</span><h2>Tokens</h2></div>
    <div class="tokens mono">
      <div><b>radius</b><span>18px cards · 14px tiles · 999px pills</span></div>
      <div><b>shadow</b><span>1px seam + soft 24px lift, never harder</span></div>
      <div><b>fonts</b><span>Newsreader · Spline Sans Mono · system sans</span></div>
      <div><b>motion</b><span>skeleton → rise .6s · cubic-bezier(.2,.7,.2,1)</span></div>
    </div>
  </section>

</main>

<style>
  .head{position:sticky;top:0;z-index:40;display:flex;align-items:center;gap:.9rem;padding:1.1rem var(--edge);
    background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--hair)}
  .brand{display:flex;align-items:center;gap:.5rem;font-family:var(--serif);font-weight:600;font-size:1.3rem}
  .brand svg{height:19px;fill:currentColor} .tag{font-size:.72rem;color:var(--ink3)} .sp{flex:1} .mono{font-family:var(--mono)}
  .tt{display:inline-flex;align-items:center;gap:.5rem;cursor:pointer;border:0;font-family:var(--mono);font-size:.72rem;color:var(--ink2);background:var(--bg2);padding:.42rem .75rem;border-radius:999px}
  .tt .dot{width:9px;height:9px;border-radius:50%;background:var(--ink)} :global([data-theme="dark"]) .tt .dot{background:var(--green)}

  .sheet{max-width:1100px;margin:0 auto;padding:var(--s5) var(--edge) var(--s8)}
  .spec{margin-top:var(--s8)}
  .sh{display:flex;align-items:baseline;gap:1rem;flex-wrap:wrap;border-bottom:1px solid var(--hair);padding-bottom:1.1rem;margin-bottom:var(--s6)}
  .sh h2{font-size:1.4rem} .no{font-size:.72rem;color:var(--ink3)} .note{font-size:.78rem;color:var(--ink3);margin-left:auto}

  .hero-spec{display:grid;grid-template-columns:auto 1fr;gap:var(--s7);align-items:center;margin-top:var(--s7);padding-block:var(--s4)}
  @media(max-width:680px){.hero-spec{grid-template-columns:1fr}}
  .mark svg{width:120px;height:auto;fill:var(--ink)}
  .xl{font-size:clamp(2.4rem,5.5vw,4rem)} .l{font-size:clamp(1.8rem,3.5vw,2.6rem)}
  .lead{color:var(--ink2);font-size:1.08rem;line-height:1.6;max-width:58ch;margin-top:var(--s4)} .lead b{color:var(--ink);font-weight:600}
  .typ{display:flex;flex-direction:column;gap:var(--s4)}
  .body{font-family:var(--serif);font-size:1.1rem;color:var(--ink2);max-width:56ch}
  .machine{font-family:var(--mono);font-size:.85rem;color:var(--ink2)} .machine .p{color:var(--green-ink);font-weight:700} .machine .c{color:var(--ink3)} .machine .ok{color:var(--green-ink)}

  .g2{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:var(--s4)}
  .g3{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:var(--s4)}
  .row{display:flex;gap:var(--s3);flex-wrap:wrap;align-items:center}
  h3{font-size:1.2rem}

  .sw{background:var(--card);border:1px solid var(--hair);border-radius:14px;overflow:hidden}
  .sw .fill{display:block;height:4.2rem} .sw .meta{padding:.8rem .9rem;display:flex;flex-direction:column;gap:.1rem}
  .sw b{font-size:.78rem} .sw span{font-size:.66rem;color:var(--ink3)} .sw .use{color:var(--ink2);margin-top:.2rem}
  .neutrals{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:.5rem;margin-top:1rem}
  .nrow{display:flex;align-items:center;gap:.5rem;font-size:.72rem}
  .chipv{width:18px;height:18px;border-radius:5px;border:1px solid var(--hair);flex:none} .nrow b{font-size:.72rem} .nrow span{color:var(--ink3)}

  .input{display:inline-flex;align-items:center;gap:.5rem;background:var(--bg2);border-radius:999px;padding:.5rem 1rem;font-size:.84rem;color:var(--ink3)} .input .q{color:var(--rose-text);font-weight:700}
  .ascii-tile{position:relative;border-radius:14px;overflow:hidden;background:var(--bg2);height:200px}
  .kv .k{font-size:.66rem;letter-spacing:.05em;color:var(--ink3)} .kv .v{font-family:var(--serif);font-size:2.2rem;font-weight:600;letter-spacing:-.02em;display:block}
  .tokens{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:.6rem}
  .tokens div{background:var(--card);border:1px solid var(--hair);border-radius:12px;padding:.9rem 1rem;font-size:.76rem}
  .tokens b{display:block;color:var(--ink);margin-bottom:.2rem} .tokens span{color:var(--ink3)}
</style>
