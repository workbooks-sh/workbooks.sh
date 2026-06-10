<script>
  // The live timeline: peek chip, hide/show drawer behaviors, and the feed
  // list (#tlList) which the engine fills imperatively. Status text + follow
  // button are likewise engine-driven through their ids.
  import { registerRef, openPanel, closePanel, toggleFollow } from './stores.js';
  let tlListEl;
  $effect(() => { registerRef('tlList', tlListEl); });
</script>

<aside class="panel" id="timeline" aria-label="Agent timeline">
  <div class="pcard hello">
    <button class="phide" id="phide" aria-label="Hide timeline" onclick={closePanel}>×</button>
    <h3>This site is a workbook.</h3>
    <p>An agent named Waldo ships to it every 15 minutes and audits its own
    work each hour. Every change lands below, live — stick around and you'll
    catch it working.</p>
  </div>

  <div class="pcard status">
    <div class="row">
      <span class="state"><span class="pulse"></span><span id="stState">connecting…</span></span>
      <span class="v" id="stLast"></span>
    </div>
    <div class="row"><span class="k">next check-in</span><span class="v on" id="stNext">—</span></div>
    <button class="follow" id="followBtn" onclick={toggleFollow} hidden>follow along — it's working now</button>
  </div>

  <div class="tl"><div id="tlList" bind:this={tlListEl}></div></div>
</aside>

<button class="peek" id="peek" aria-label="Show timeline" onclick={openPanel}><span class="dot"></span>timeline</button>
