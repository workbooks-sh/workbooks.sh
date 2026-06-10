<script>
  // §4.9 Presence (inherited, re-skinned). The compact presence card with the
  // ONE allowed gradient — the animated conic rim ported from the lander,
  // thin. Agent-name tag (wren, not waldo), thought bubble in mono at 11px.
  // Static specimen (no live feed) but the rim animates. The card shows the
  // agent "off-page": what it's working on, scaled glimpse, a thought line.
  let {
    agent = 'wren',
    verb = 'drafting',
    target = 'deepmind-weather.html',
    thought = '',
    excerpt = '',
  } = $props();
</script>

<div class="portal">
  <div class="inner">
    <div class="head mono">
      <span class="dot"></span>
      <span class="tag">{agent}</span>
      <span class="verb">{verb}: {target}</span>
    </div>
    {#if thought}<p class="thought mono">{thought}</p>{/if}
    {#if excerpt}<pre class="excerpt mono">{excerpt}</pre>{/if}
    <div class="jump mono">watch live →</div>
  </div>
</div>

<style>
  /* The 1px animated GRADIENT RIM is a ::before behind .inner — the only
     gradient allowed in the whole system (§3/§4.9). Conic sweep, masked to
     the rim by the inner background. Kept thin (1px padding). */
  .portal {
    position: relative; width: 260px;
    border-radius: var(--r); padding: 1px; overflow: hidden;
  }
  .portal::before {
    content: ""; position: absolute; inset: 0; border-radius: inherit;
    background: conic-gradient(from var(--pang, 0deg),
      var(--wire), #5ea2ff, #b48cff, var(--up), var(--wire));
    animation: sweep 6s linear infinite; opacity: .9;
  }
  @property --pang { syntax: '<angle>'; inherits: false; initial-value: 0deg; }
  @keyframes sweep { to { --pang: 360deg; } }

  .inner {
    position: relative; border-radius: calc(var(--r) - 1px);
    padding: 12px 13px 12px;
    background: var(--paper);
  }

  .head { display: flex; align-items: center; gap: 7px; }
  .dot {
    width: 6px; height: 6px; border-radius: 50%; background: var(--wire);
    flex: 0 0 auto; animation: breathe 2.4s ease-in-out infinite;
  }
  @keyframes breathe { 50% { opacity: .35; } }
  .tag {
    font-size: 11px; font-weight: 500; color: var(--ink);
    letter-spacing: 0.02em;
  }
  .verb {
    font-size: 10.5px; color: var(--ink-3);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }

  .thought {
    margin: 8px 0 0; font-size: 11px; line-height: 1.5; color: var(--ink-2);
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .excerpt {
    margin: 8px 0 0; font-size: 9.5px; line-height: 1.6; color: var(--ink-3);
    white-space: pre-wrap; word-break: break-word; max-height: 52px;
    overflow: hidden;
  }
  .jump { margin-top: 9px; font-size: 10px; color: var(--wire); letter-spacing: 0.03em; }
</style>
