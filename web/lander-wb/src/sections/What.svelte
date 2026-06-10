<script>
  import Section from "../lib/Section.svelte";
  import VoicePair from "../lib/VoicePair.svelte";
  import Card from "../lib/Card.svelte";
  import Workbook from "../lib/Workbook.svelte";
  import habits from "../../demos/habits.html?raw";
  import budget from "../../demos/budget.html?raw";
</script>
<Section name="what">
  <div class="sh"><span class="no mono">[ 01 ]</span><h2 class="kk">what it is</h2></div>
  <VoicePair>
    {#snippet claim()}<h2 class="big mixed">One file. <em>The whole app.</em></h2>{/snippet}
    {#snippet receipt()}<span class="p">$</span> wb bundle . <span class="c">→</span> app.html <span class="ok">· source inside</span>{/snippet}
  </VoicePair>
  <p class="sub">Interface, data, and the source that runs it — together in a single document on your disk. No server it leans on, no account it lives behind. You're already using one. Here are two more, running right here:</p>
  <div class="apps">
    <Workbook name="habits.html" size="5.5 KB" html={habits} caption="A habit tracker. Tap the grid — it's live; data stays in your browser." />
    <Workbook name="budget.html" size="6.6 KB" html={budget} caption="A budget with a live burn chart. Edit a number — it recomputes, in the file." />
  </div>
</Section>
<style>
  .sh{display:flex;align-items:center;gap:.7rem;margin-bottom:var(--s5)}
  .no{font-size:.8rem;color:var(--ink3);width:1.7rem;height:1.7rem;display:grid;place-items:center;border:1px solid var(--hair);border-radius:7px}
  .kk{font-family:var(--mono);font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;font-weight:700;color:var(--green-ink)}
  .big{font-size:clamp(2rem,4vw,3rem)}
  .sub{color:var(--ink2);font-size:1.08rem;max-width:60ch;margin-top:var(--s4);line-height:1.6}
  .apps{display:grid;grid-template-columns:1fr 1fr;gap:var(--s4);margin-top:var(--s5)}
  @media(max-width:820px){.apps{grid-template-columns:1fr}}
  :global(.machine .p){color:var(--green-ink);font-weight:700} :global(.machine .c){color:var(--ink3)} :global(.machine .ok){color:var(--green-ink)}
</style>
