<script>
  // §4.8 Crew panel — the inspect panel redesigned for a newsroom. Opens
  // from the masthead toggle on every page; ALWAYS terminal-skinned
  // (dark, mono-dominant) regardless of page theme. Exactly the doc layout:
  //   one row per agent: live dot (wire working / ink-3 idle), name, role,
  //   doing-now, watch → · THE WIRE commit list · PIPELINE counts.
  // Slide-in 150ms (§5: fast or absent). Can render as a docked overlay
  // (toggleable) OR inline (a static open specimen) via `inline`.
  let {
    open = false,
    inline = false,
    filter = null,         // agent name the panel is scoped to (from a byline click)
    clock = '14:02:33',
    agents = [],
    wire = [],
    pipeline = '',
    onclose,
  } = $props();
</script>

<aside
  class="crew"
  class:inline
  class:open={inline || open}
  data-theme="terminal"
  aria-hidden={!(inline || open)}
>
  <div class="phead mono">
    <span class="title">THE CREW</span>
    <span class="time">{clock} UTC</span>
    {#if !inline}<button class="x" onclick={onclose} aria-label="close crew panel">×</button>{/if}
  </div>
  <div class="rule mono">──────────────────────────────────────────</div>

  <div class="agents">
    {#each agents as a}
      <div class="arow mono" class:dim={a.state === 'idle'} class:hit={filter && filter === a.name}>
        <span class="dot" class:live={a.state !== 'idle'}>●</span>
        <span class="name">{a.name}</span>
        <span class="role">{a.role}</span>
        <span class="doing">{a.doing}</span>
        {#if a.state !== 'idle'}<button class="watch">watch →</button>{/if}
      </div>
    {/each}
  </div>

  <div class="rule mono">──────────────────────────────────────────</div>
  <div class="shead mono">THE WIRE <span class="sub">(live commits)</span></div>
  <div class="commits">
    {#each wire as c}
      <div class="crow mono">
        <span class="ct">{c.time}</span>
        <span class="cw">{c.who}</span>
        <span class="cm">{c.msg}</span>
      </div>
    {/each}
  </div>

  <div class="rule mono">──────────────────────────────────────────</div>
  <div class="pipe mono"><span class="plabel">PIPELINE</span> {pipeline}</div>
</aside>

<style>
  .crew {
    /* terminal skin always — vars resolve via data-theme=terminal */
    background: var(--paper);
    color: var(--ink);
    font-family: var(--mono);
    font-size: 12px; line-height: 1.5;
  }

  /* docked overlay (toggle) */
  .crew:not(.inline) {
    position: fixed; top: 0; right: 0; z-index: 80;
    width: 360px; max-width: 88vw; height: 100vh;
    padding: 18px 18px 24px;
    border-left: 1px solid var(--rule);
    overflow-y: auto;
    transform: translateX(100%);
    transition: transform .15s ease-out;   /* §4.8 slide-in 150ms */
    box-shadow: -8px 0 40px -20px rgba(0,0,0,.5);
  }
  .crew:not(.inline).open { transform: none; }

  /* inline specimen */
  .crew.inline {
    width: 100%; padding: 18px 18px 20px;
    border: 1px solid var(--rule);
  }

  .phead {
    display: flex; align-items: baseline; gap: 12px;
    font-size: 12px; letter-spacing: 0.06em;
  }
  .title { color: var(--ink); font-weight: 500; }
  .time { color: var(--wire); margin-left: auto; font-variant-numeric: tabular-nums; }
  .x {
    background: none; border: 0; color: var(--ink-3);
    font-size: 18px; line-height: 1; padding: 0 0 0 8px; cursor: pointer;
  }
  .x:hover { color: var(--ink); }

  .rule { color: var(--rule); margin: 10px 0; overflow: hidden; white-space: nowrap; user-select: none; }

  .agents { display: flex; flex-direction: column; gap: 7px; }
  .arow {
    display: grid;
    grid-template-columns: 14px 56px 78px 1fr auto;
    align-items: baseline; gap: 8px;
    font-size: 12px;
  }
  .arow.hit { background: color-mix(in srgb, var(--wire) 14%, transparent); margin: 0 -6px; padding: 2px 6px; }
  .dot { color: var(--ink-3); }
  .dot.live { color: var(--wire); animation: breathe 2.4s ease-in-out infinite; }
  @keyframes breathe { 50% { opacity: .4; } }
  .name { color: var(--ink); font-weight: 500; }
  .role { color: var(--ink-2); }
  .doing { color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .arow.dim .doing { color: var(--ink-3); }
  .watch {
    background: none; border: 0; padding: 0; cursor: pointer;
    font: inherit; color: var(--wire); white-space: nowrap;
  }
  .watch:hover { text-decoration: underline; }

  .shead { color: var(--ink-2); letter-spacing: 0.06em; margin-bottom: 8px; }
  .shead .sub { color: var(--ink-3); }
  .commits { display: flex; flex-direction: column; gap: 5px; }
  .crow {
    display: grid; grid-template-columns: 46px 52px 1fr; gap: 8px;
    font-size: 12px;
  }
  .ct { color: var(--wire); font-variant-numeric: tabular-nums; }
  .cw { color: var(--ink); }
  .cm { color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  .pipe { color: var(--ink-2); font-size: 12px; }
  .plabel { color: var(--ink); font-weight: 500; letter-spacing: 0.06em; }
</style>
