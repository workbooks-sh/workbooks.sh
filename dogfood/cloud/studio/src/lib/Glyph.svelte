<script>
  // <Glyph ref="brand:github" /> — resolves a mark through our glyphs toolkit: curated (sync) first,
  // then svgl (async) for the long tail; if everything misses it renders the iconoir `fallback` glyph
  // (so a tool CLI with no brand mark, e.g. ripgrep, still shows a sensible icon). Honest null contract.
  import { glyph, glyphAsync } from './glyphs/index.js'
  import { iconSvgByName } from './icons.js'
  let { ref = '', size = 18, fallback = 'tools', color = '' } = $props()

  function resolve(r) {
    if (!r) return null
    const sync = glyph(r, { size, color })
    if (sync) return Promise.resolve(sync)
    return glyphAsync(r, { size, color }).catch(() => null)
  }
  let svg = $state(null)
  $effect(() => { svg = null; const r = ref; resolve(r)?.then((s) => { if (ref === r) svg = s }) })
</script>

{#if svg}{@html svg}{:else}{@html iconSvgByName(fallback, size)}{/if}
