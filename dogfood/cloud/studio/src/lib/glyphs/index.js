// Our own glyphs toolkit (vendored from toolkits/glyphs) — the ONE mark resolver. A ref is
// "<kind>:<id>" — brand:github, icon:rust. glyph() is sync curated-only (offline, null on miss);
// glyphAsync() falls through to svgl for the long tail. Configured once with the curated packs +
// the svgl name→route index. We use it for every toolkit/integration icon (NOT Simple Icons/Logo.dev).
import { glyph, glyphAsync, configure } from './glyphs.js'
import './glyphs.css' // .glyph--icon { fill: currentColor } — makes monochrome marks inherit color
import brands from './curated-brands.json'
import icons from './curated-icons.json'
import svglIndex from './svgl-index.json'
import simpleIcons from './simple-icons.json' // vendored simple-icons (clean monochrome glyphs we tint by hand)

// Two mark sources: `logo:<id>` → a vendored full-colour brand logo (Nango, ~635 of them); `icon:<slug>` →
// a simple-icon (vendored 16 + CDN long-tail) we tint by hand. Glyph decides per-mark whether to keep the
// colour (chromatic) or ink it (neutral). `iconSlugs` lets callers check existence for the language fallback.
const base = { brands, icons: { ...simpleIcons, ...icons }, svglIndex }
configure({ ...base, logos: {} })

// toolkit-logos.json is ~5.4MB raw / 3.6MB gzipped (635 full-colour Nango brand logos) — by FAR the biggest
// asset. It's ONLY needed for the Toolkits → Integrations brand glyphs, so we load it ON DEMAND (loadLogos),
// NOT at module load — otherwise it downloads 3.6MB on every app boot (measured: the #1 cold-load cost).
let _logosLoaded = false
export async function loadLogos() {
  if (_logosLoaded) return
  _logosLoaded = true
  try {
    const m = await import('./toolkit-logos.json')
    configure({ ...base, logos: m.default || m })
  } catch (_) { _logosLoaded = false }
}

const iconSlugs = new Set(Object.keys(simpleIcons).concat(Object.keys(icons)))
export { glyph, glyphAsync, iconSlugs }
