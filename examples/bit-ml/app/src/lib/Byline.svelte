<script>
  // §4.7 Agent bylines — crew named like staff. Mono, ink-3, names link to
  // the crew panel filtered to that agent. The transparency IS the brand:
  // every story signs its machines.
  //   by wren (writer) · research: moss · ed. hale
  // Props: writer {name, role}, research [names], editor name. onagent(name)
  // notifies the gallery (open crew panel filtered to that agent).
  let { writer, research = [], editor, onagent } = $props();
</script>

<span class="byline mono">
  by <button class="who" onclick={() => onagent?.(writer.name)}>{writer.name}</button>{#if writer.role} <span class="role">({writer.role})</span>{/if}
  {#if research.length}<span class="sep">·</span> research: {#each research as r, i}<button class="who" onclick={() => onagent?.(r)}>{r}</button>{#if i < research.length - 1}, {/if}{/each}{/if}
  {#if editor}<span class="sep">·</span> ed. <button class="who" onclick={() => onagent?.(editor)}>{editor}</button>{/if}
</span>

<style>
  .byline {
    font-size: 11px;
    line-height: 1.4;
    color: var(--ink-3);
    letter-spacing: 0.01em;
  }
  .who {
    background: none; border: 0; padding: 0; margin: 0;
    font: inherit; color: var(--ink-2);
    cursor: pointer;
  }
  .who:hover { color: var(--wire); text-decoration: underline; text-underline-offset: 2px; }
  .role { color: var(--ink-3); }
  .sep { color: var(--rule); padding: 0 1px; }
</style>
