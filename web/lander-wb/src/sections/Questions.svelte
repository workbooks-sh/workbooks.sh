<script>
  import Section from "../lib/Section.svelte";
  import Card from "../lib/Card.svelte";
  const qs = [
    ["Do I have to code?", "No. Describe it, look, refine. If you do code, it's real source — open the file, it's all there."],
    ["Free how?", "The app costs nothing, forever. AI usage is between you and your provider — your key, their bill, our zero percent."],
    ["Where's my data?", "In the file, on your machine. If you deploy a server, it's your server — your infrastructure, your keys."],
    ["What if you shut down?", "Your workbooks keep opening. Each carries its own source and the runtime is open. Files don't need us."],
  ];
</script>
<Section name="questions">
  <h2 class="qh mixed">Fair <em>questions.</em></h2>
  <div class="qa">
    {#each qs as [q, a]}<Card><h3>{q}</h3><p>{a}</p></Card>{/each}
  </div>
  <p class="machine"><span class="p">$</span> wb unbundle app.html <span class="c">→</span> source/ <span class="ok">· yours to rebuild</span></p>
</Section>
<style>
  .qh{text-align:center;font-size:clamp(2rem,4vw,3rem)}
  .qa{display:grid;grid-template-columns:1fr 1fr;gap:var(--s4);margin-top:var(--s6)} @media(max-width:680px){.qa{grid-template-columns:1fr}}
  :global(.qa h3){font-size:1.1rem} :global(.qa p){margin-top:.5rem;color:var(--ink2);font-size:.95rem;line-height:1.55}
  .machine{font-family:var(--mono);font-size:.8rem;color:var(--ink2);text-align:center;margin-top:var(--s5)}
  .machine .p{color:var(--green-ink);font-weight:700} .machine .c{color:var(--ink3)} .machine .ok{color:var(--green-ink)}
</style>
