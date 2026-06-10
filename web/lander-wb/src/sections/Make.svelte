<script>
  import { onMount } from "svelte";
  import Section from "../lib/Section.svelte";
  import VoicePair from "../lib/VoicePair.svelte";
  import Card from "../lib/Card.svelte";
  let typed = $state("");
  onMount(() => {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) { typed = "a reading list with covers"; return; }
    const ex = ["a reading list with covers","a workout log","a client CRM","a recipe box","a standup tracker"];
    let i = 0, k = 0, dir = 1, hold = 0;
    const id = setInterval(() => {
      const s = ex[i % ex.length];
      if (hold > 0) { hold--; return; }
      k += dir; typed = s.slice(0, k);
      if (k >= s.length) { dir = -1; hold = 28; }
      if (k <= 0) { dir = 1; i++; }
    }, 45);
    return () => clearInterval(id);
  });
</script>
<Section name="make">
  <div class="head"><span class="num">3</span><span class="kick">make one</span></div>
  <div class="split">
    <Card>
      <VoicePair>
        {#snippet claim()}<h2>Say what you need.<br>An agent builds it.</h2>{/snippet}
        {#snippet receipt()}<span class="p">›</span> plan · write · run · fix <span class="ok">→ a workbook</span>{/snippet}
      </VoicePair>
      <p class="sub">Describe the tool in plain words and hand it off. The agent plans, writes, runs, and fixes — then hands you a workbook: a working app in one file. Refine it the same way, just by talking.</p>
    </Card>
    <Card>
      <div class="mlabel mono">describe an app</div>
      <div class="prompt mono"><span class="q">›</span> <span>{typed}</span><span class="caret"></span></div>
      <div class="mnote mono">an agent will plan, write, run, and fix it</div>
    </Card>
  </div>
</Section>
<style>
  .head{display:flex;align-items:center;gap:.7rem;margin-bottom:clamp(1.4rem,3vw,2.2rem)}
  .num{font-family:var(--mono);font-size:.8rem;color:var(--ink3);width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1px solid var(--hair);border-radius:7px}
  .kick{font-family:var(--mono);font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;font-weight:700;color:var(--rose-text)}
  .split{display:grid;grid-template-columns:1fr 1fr;gap:1rem;align-items:stretch} @media(max-width:820px){.split{grid-template-columns:1fr}}
  h2{font-size:clamp(1.7rem,3vw,2.4rem)} .sub{color:var(--ink2);margin-top:1rem}
  .mono{font-family:var(--mono)}
  .mlabel{font-size:.66rem;text-transform:uppercase;letter-spacing:.1em;color:var(--ink3);margin-bottom:.9rem}
  .prompt{background:var(--bg2);border:1px solid var(--hair);border-radius:12px;padding:.85rem 1rem;font-size:.98rem;display:flex;align-items:center;gap:.5rem;min-height:3.1rem}
  .q{color:var(--rose-text);font-weight:700}
  .caret{width:.5em;height:1.1em;background:var(--blue);display:inline-block;vertical-align:-.15em;animation:bl 1s steps(2) infinite}
  @keyframes bl{50%{opacity:0}}
  .mnote{font-size:.76rem;color:var(--ink3);margin-top:.9rem}
  :global(.machine .p){color:var(--rose-text);font-weight:700} :global(.machine .ok){color:var(--green-ink)}
</style>
