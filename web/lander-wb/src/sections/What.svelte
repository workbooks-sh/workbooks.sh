<script>
  import Section from "../lib/Section.svelte";
  import VoicePair from "../lib/VoicePair.svelte";
  import Card from "../lib/Card.svelte";
  import Workbook from "../lib/Workbook.svelte";
  import habits from "../../demos/habits.html?raw";
  import budget from "../../demos/budget.html?raw";
</script>
<Section name="what">
  <div class="head"><span class="num">1</span><span class="kick">what it is</span></div>
  <div class="split">
    <Card>
      <VoicePair>
        {#snippet claim()}<h2>One file.<br>The whole app.</h2>{/snippet}
        {#snippet receipt()}<span class="p">$</span> wb bundle . <span class="c">→</span> app.html <span class="ok">· source inside</span>{/snippet}
      </VoicePair>
      <p class="sub">Interface, data, and the source that runs it — together in a single document on your disk. No server it depends on, no account it lives behind. Open it next decade; still the app, still yours to change.</p>
    </Card>
    <Card>
      <div class="glyph">
        <svg viewBox="0 0 96 120" fill="none"><path d="M8 4h56l24 24v88H8z" class="fb"/><path d="M64 4v24h24" class="ff"/><path d="M24 56h48M24 72h48M24 88h32" class="fl"/></svg>
        <span class="mono fn">app.html</span>
      </div>
    </Card>
  </div>
  <p class="sub mid">You're already using one. Here are two more — real workbooks, running right here:</p>
  <div class="apps">
    <Workbook name="habits.html" size="5.5 KB" accent="green" html={habits} caption="A habit tracker. Tap the grid — it's live, data stays in your browser." />
    <Workbook name="budget.html" size="6.6 KB" accent="blue" html={budget} caption="A budget with a live burn chart. Edit a number — it recomputes, in the file." />
  </div>
</Section>
<style>
  .head{display:flex;align-items:center;gap:.7rem;margin-bottom:clamp(1.4rem,3vw,2.2rem)}
  .num{font-family:var(--mono);font-size:.8rem;color:var(--ink3);width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1px solid var(--hair);border-radius:7px}
  .kick{font-family:var(--mono);font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;font-weight:700;color:var(--green-ink)}
  .split{display:grid;grid-template-columns:1.4fr 1fr;gap:1rem;align-items:stretch}
  @media(max-width:820px){.split{grid-template-columns:1fr}}
  h2{font-size:clamp(1.8rem,3vw,2.5rem)} .sub{color:var(--ink2);margin-top:1rem;font-size:1.02rem}
  .sub.mid{text-align:center;margin:2.4rem auto 1.4rem;max-width:48ch}
  .glyph{display:flex;flex-direction:column;align-items:center;gap:1rem;justify-content:center;height:100%}
  .glyph svg{width:90px;height:112px} .fb{fill:var(--bg2);stroke:var(--ink);stroke-width:3} :global([data-theme="dark"]) .fb{fill:#1c1c20}
  .ff{fill:none;stroke:var(--ink);stroke-width:3} .fl{stroke:var(--blue);stroke-width:4;stroke-linecap:round}
  .fn{font-size:.8rem;color:var(--ink2)} .mono{font-family:var(--mono)}
  .apps{display:grid;grid-template-columns:1fr 1fr;gap:1rem} @media(max-width:820px){.apps{grid-template-columns:1fr}}
  :global(.machine .p){color:var(--green-ink);font-weight:700} :global(.machine .c){color:var(--ink3)} :global(.machine .ok){color:var(--green-ink)}
</style>
