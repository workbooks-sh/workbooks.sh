<script>
  // <Glyph ref="brand:github" /> — resolves a mark through our glyphs toolkit: curated (sync) first,
  // then svgl/lobehub (async) for the long tail; if everything misses it renders the iconoir `fallback`
  // glyph (so a tool CLI with no brand mark, e.g. ripgrep, still shows a sensible icon).
  //
  // Colour stance (procedural, not per-entry): we PREFER the full-colour mark svgl ships. We only synthesize
  // a colour when the mark is *naturally neutral* — every concrete fill is black/white/grey — in which case
  // we rewrite its fills to `currentColor` so it inherits the theme (light-on-dark / dark-on-light). A mark
  // carrying any real hue (Stripe purple, Supabase green) keeps its fills untouched. The host span carries
  // `is-color` | `is-mono` so the parent picks the right tile (colour marks want a light surface).
  import { glyph, glyphAsync } from './glyphs/index.js'
  import { iconSvgByName } from './icons.js'
  let { ref = '', size = 18, fallback = 'tools' } = $props()

  // a fill is chromatic if its channels spread > 24 (i.e. not a grey/black/white). Any chromatic fill ⇒
  // the mark is genuinely colourful and we leave it alone; otherwise it's a neutral mark we ink to the theme.
  function chromatic(c) {
    let r, g, b
    if (c[0] === '#') {
      let h = c.slice(1)
      if (h.length === 3) h = h.split('').map((x) => x + x).join('')
      if (h.length < 6) return false
      r = parseInt(h.slice(0, 2), 16); g = parseInt(h.slice(2, 4), 16); b = parseInt(h.slice(4, 6), 16)
    } else {
      const n = (c.match(/[\d.]+/g) || []).map(Number)
      ;[r, g, b] = n
    }
    if ([r, g, b].some((x) => x == null || isNaN(x))) return false
    return Math.max(r, g, b) - Math.min(r, g, b) > 24
  }

  function themeMark(raw) {
    if (!raw) return { svg: raw, mono: false }
    const re = /(?:fill|stop-color|stroke)\s*[:=]\s*["']?\s*(#[0-9a-fA-F]{3,8}|rgba?\([^)]*\))/g
    let m
    while ((m = re.exec(raw))) {
      if (chromatic(m[1].toLowerCase())) return { svg: raw, mono: false } // genuine colour mark — untouched
    }
    // neutral mark → force every fill to currentColor so it follows the theme ink
    let s = raw
      .replace(/fill\s*=\s*["'][^"']*["']/g, 'fill="currentColor"')
      .replace(/fill\s*:\s*[^;"'}]+/g, 'fill:currentColor')
    if (!/fill\s*=/.test(s)) s = s.replace('<svg', '<svg fill="currentColor"')
    return { svg: s, mono: true }
  }

  function resolve(r) {
    if (!r) return null
    const sync = glyph(r, { size })
    if (sync) return Promise.resolve(sync)
    return glyphAsync(r, { size }).catch(() => null)
  }
  let mark = $state(null) // { svg, mono } | null
  $effect(() => {
    mark = null
    const r = ref
    resolve(r)?.then((s) => { if (ref === r) mark = s ? themeMark(s) : null })
  })
</script>

{#if mark}
  <span class="glyph-host contents {mark.mono ? 'is-mono' : 'is-color'}">{@html mark.svg}</span>
{:else}
  <span class="glyph-host contents is-mono">{@html iconSvgByName(fallback, size)}</span>
{/if}
