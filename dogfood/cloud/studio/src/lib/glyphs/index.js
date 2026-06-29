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
// toolkit-logos.json is ~5.4MB (635 full-colour Nango logos) — by FAR the biggest blob. Dynamic-import it as
// its own chunk so it's NOT in the main bundle's parse (which blocks first paint); fold it in when it lands.
// Logos render on the Toolkits page, by which time this has resolved.
import('./toolkit-logos.json').then((m) => configure({ ...base, logos: m.default || m })).catch(() => {})

const iconSlugs = new Set(Object.keys(simpleIcons).concat(Object.keys(icons)))
export { glyph, glyphAsync, iconSlugs }
