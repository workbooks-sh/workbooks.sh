<script>
  // <Glyph ref="icon:stripe" color="#635BFF" /> — resolves a clean monochrome simple-icon through our glyphs
  // toolkit and tints it with `color` (a hand-assigned brand hex, or a CSS var like var(--color-ink) for
  // neutral marks). currentColor marks inherit that colour. If the ref misses entirely it renders the iconoir
  // `fallback` glyph. The caller (markFor) already picked the right ref+colour, incl. the language-icon fallback.
  import { glyph, glyphAsync } from './glyphs/index.js'
  import { iconSvgByName } from './icons.js'
  let { ref = '', size = 18, fallback = 'tools', color = 'currentColor' } = $props()

  function resolve(r) {
    if (!r) return null
    const sync = glyph(r, { size })
    if (sync) return Promise.resolve(sync)
    return glyphAsync(r, { size }).catch(() => null)
  }
  let svg = $state(null)
  $effect(() => { svg = null; const r = ref; resolve(r)?.then((s) => { if (ref === r) svg = s }) })
</script>

<span class="glyph-host contents" style="color:{color}">
  {#if svg}{@html svg}{:else}{@html iconSvgByName(fallback, size)}{/if}
</span>
