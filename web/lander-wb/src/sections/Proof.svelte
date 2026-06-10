<script>
  import Section from "../lib/Section.svelte";
  import LogoCard from "../lib/LogoCard.svelte";
</script>
<Section name="proof" band>
  <div class="sh"><span class="no mono">[ 02 ]</span><h2 class="kk blue">the proof</h2></div>
  <h2 class="ask mixed">This page is <em>a workbook too.</em></h2>
  <p class="sub">An agent composed it. A Workbooks runtime serves it. And it keeps working on it — one small, reversible edit at a time, in the open.</p>
  <div class="cells">
    <LogoCard accent="green" title="Composed by an agent">lander-keeper wrote this page and maintains it on a loop.</LogoCard>
    <LogoCard accent="blue" title="Served live">the runtime renders the current file on request.</LogoCard>
    <LogoCard accent="rose" title="Open by default">read its source and the agent's log in the inspector →</LogoCard>
  </div>
  <p class="machine"><span class="p">$</span> wb verify workbooks.html <span class="c">→</span> <span class="ok">"valid": true</span></p>
</Section>
<style>
  .sh{display:flex;align-items:center;gap:.7rem;justify-content:center;margin-bottom:var(--s4)}
  .no{font-size:.8rem;color:var(--ink3);width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1px solid var(--hair);border-radius:7px}
  .kk{font-family:var(--mono);font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;font-weight:700}.kk.blue{color:var(--blue-text)}
  .ask{text-align:center;font-size:clamp(2rem,4.5vw,3.4rem);max-width:20ch;margin:0 auto}
  .sub{text-align:center;color:var(--ink2);max-width:54ch;margin:var(--s4) auto 0;line-height:1.6}
  .cells{display:grid;grid-template-columns:repeat(3,1fr);gap:var(--s4);margin-top:var(--s6)}
  @media(max-width:760px){.cells{grid-template-columns:1fr}}
  .machine{font-family:var(--mono);font-size:.8rem;color:var(--ink2);text-align:center;margin-top:var(--s5)}
  .machine .p{color:var(--green-ink);font-weight:700} .machine .c{color:var(--ink3)} .machine .ok{color:var(--green-ink)}
</style>
