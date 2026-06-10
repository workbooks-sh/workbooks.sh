<script>
  import Section from "../lib/Section.svelte";
  import VoicePair from "../lib/VoicePair.svelte";
  import Card from "../lib/Card.svelte";
  import Cell from "../lib/Cell.svelte";
</script>
<Section name="yours" band>
  <div class="head"><span class="num">4</span><span class="kick">yours</span></div>
  <div class="split">
    <Card>
      <VoicePair>
        {#snippet claim()}<h2>It runs on<br>your machine.</h2>{/snippet}
        {#snippet receipt()}<span class="p">$</span> wb deploy apply <span class="c">→</span> <span class="ok">your infra</span>{/snippet}
      </VoicePair>
      <p class="sub">Private by default, works offline, no account. It's free and open source — no plan to outgrow, no company to outlive. Want a server? Deploy your own with one command.</p>
    </Card>
    <div class="cells">
      <Cell accent="green" glyph="⌂" title="On your disk">Private. Offline. No middleman.</Cell>
      <Cell accent="blue" glyph="○" title="Your AI key">Their bill, our zero percent.</Cell>
      <Cell accent="rose" glyph="∞" title="Open source">Apache-2.0, end to end. Files don't need us.</Cell>
    </div>
  </div>
</Section>
<style>
  .head{display:flex;align-items:center;gap:.7rem;margin-bottom:clamp(1.4rem,3vw,2.2rem)}
  .num{font-family:var(--mono);font-size:.8rem;color:var(--ink3);width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1px solid var(--hair);border-radius:7px}
  .kick{font-family:var(--mono);font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;font-weight:700;color:var(--rose-text)}
  .split{display:grid;grid-template-columns:1fr 1fr;gap:1rem;align-items:stretch} @media(max-width:820px){.split{grid-template-columns:1fr}}
  h2{font-size:clamp(1.7rem,3vw,2.4rem)} .sub{color:var(--ink2);margin-top:1rem}
  .cells{display:grid;gap:.8rem}
  :global(.machine .p){color:var(--green-ink);font-weight:700} :global(.machine .c){color:var(--ink3)} :global(.machine .ok){color:var(--green-ink)}
</style>
