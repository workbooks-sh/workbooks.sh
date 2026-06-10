<script>
  import Section from "../lib/Section.svelte";
  import Cell from "../lib/Cell.svelte";
</script>
<Section name="proof" band>
  <div class="head"><span class="num">2</span><span class="kick">the proof</span></div>
  <h2 class="ask">This page is a workbook too.</h2>
  <p class="sub">An agent composed it. A Workbooks runtime serves it. And it keeps working on it — one small, reversible edit at a time, in the open.</p>
  <div class="cells">
    <Cell accent="green" glyph="✶" title="Composed by an agent">lander-keeper wrote this page and maintains it on a loop.</Cell>
    <Cell accent="blue" glyph="◷" title="Served live">the runtime renders it on request — what you see is the current file.</Cell>
    <Cell accent="rose" glyph="≡" title="Open by default">read its source and the agent's changelog in the inspector →</Cell>
  </div>
  <p class="machine"><span class="p">$</span> wb verify workbooks.html <span class="c">→</span> <span class="ok">"valid": true</span></p>
</Section>
<style>
  .head{display:flex;align-items:center;gap:.7rem;justify-content:center;margin-bottom:1.4rem}
  .num{font-family:var(--mono);font-size:.8rem;color:var(--ink3);width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1px solid var(--hair);border-radius:7px}
  .kick{font-family:var(--mono);font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;font-weight:700;color:var(--blue-text)}
  .ask{text-align:center;font-size:clamp(2rem,4.5vw,3.2rem);max-width:18ch;margin:0 auto}
  .sub{text-align:center;color:var(--ink2);max-width:52ch;margin:1rem auto 0}
  .cells{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin-top:clamp(1.6rem,3vw,2.4rem)}
  @media(max-width:760px){.cells{grid-template-columns:1fr}}
  .machine{font-family:var(--mono);font-size:.8rem;color:var(--ink2);text-align:center;margin-top:1.6rem}
  .machine .p{color:var(--green-ink);font-weight:700} .machine .c{color:var(--ink3)} .machine .ok{color:var(--green-ink)}
</style>
