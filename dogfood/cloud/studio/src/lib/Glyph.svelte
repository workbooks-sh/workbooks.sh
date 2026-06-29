<script>
  // <Glyph ref="logo:notion" ink={false} /> — resolves a mark through our glyphs toolkit (logo: = vendored
  // full-colour Nango logo; icon: = simple-icon). The colour decision is precomputed (luminance-aware) in the
  // registry generator and passed as `ink`: when true we rewrite the mark's fills to `color` (a brand hex, or
  // theme ink — theme-aware) so a too-dark/monochrome mark stays visible; when false the logo renders as-is.
  import { glyph, glyphAsync } from './glyphs/index.js'
  import { iconSvgByName } from './icons.js'
  let { ref = '', size = 18, fallback = 'tools', color = 'currentColor', ink = false } = $props()

  // rewrite solid fills to currentColor so the mark inherits `color`; never touch url(...) fills
  // (gradients/patterns/embedded images would break if their reference were overwritten).
  function inkify(raw) {
    let s = raw
      .replace(/fill\s*=\s*["']([^"']*)["']/g, (m, v) => (/^\s*url\(/i.test(v) ? m : 'fill="currentColor"'))
      .replace(/fill\s*:\s*(?!url\()[^;"'}]+/g, 'fill:currentColor')
    if (!/fill\s*=/.test(s)) s = s.replace('<svg', '<svg fill="currentColor"')
    return s
  }

  function resolve(r) {
    if (!r) return null
    const sync = glyph(r, { size })
    if (sync) return Promise.resolve(sync)
    return glyphAsync(r, { size }).catch(() => null)
  }
  let svg = $state(null)
  $effect(() => {
    svg = null
    const r = ref
    resolve(r)?.then((s) => { if (ref === r) svg = s ? (ink ? inkify(s) : s) : null })
  })
</script>

<span class="glyph-host contents" style="color:{color}">
  {#if svg}{@html svg}{:else}{@html iconSvgByName(fallback, size)}{/if}
</span>
