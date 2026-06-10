<script>
  import Section from "../lib/Section.svelte";
  import VoicePair from "../lib/VoicePair.svelte";
  import LogoCard from "../lib/LogoCard.svelte";
</script>
<Section name="yours" band>
  <div class="sh"><span class="no mono">[ 04 ]</span><h2 class="kk">yours</h2></div>
  <div class="split">
    <div>
      <VoicePair>
        {#snippet claim()}<h2 class="big mixed">It runs on <em>your machine.</em></h2>{/snippet}
        {#snippet receipt()}<span class="p">$</span> wb deploy apply <span class="c">→</span> <span class="ok">your infra</span>{/snippet}
      </VoicePair>
      <p class="sub">Private by default, works offline, no account. Free and open source — no plan to outgrow, no company to outlive. Want a server? Deploy your own with one command.</p>
    </div>
    <div class="cells">
      <LogoCard accent="green" title="On your disk">Private. Offline. No middleman.</LogoCard>
      <LogoCard accent="blue" title="Your AI key">Their bill, our zero percent.</LogoCard>
      <LogoCard accent="rose" title="Open source">Apache-2.0, end to end. Files don't need us.</LogoCard>
    </div>
  </div>
</Section>
<style>
  .sh{display:flex;align-items:center;gap:.7rem;margin-bottom:var(--s5)}
  .no{font-size:.8rem;color:var(--ink3);width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1px solid var(--hair);border-radius:7px}
  .kk{font-family:var(--mono);font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;font-weight:700;color:var(--rose-text)}
  .split{display:grid;grid-template-columns:1fr 1fr;gap:var(--s5);align-items:center} @media(max-width:820px){.split{grid-template-columns:1fr}}
  .big{font-size:clamp(1.8rem,3.4vw,2.7rem)} .sub{color:var(--ink2);margin-top:var(--s4);line-height:1.6}
  .cells{display:grid;gap:var(--s3)}
  :global(.machine .p){color:var(--green-ink);font-weight:700} :global(.machine .c){color:var(--ink3)} :global(.machine .ok){color:var(--green-ink)}
</style>
