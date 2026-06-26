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

// Marks are simple-icons (one clean glyph, currentColor) tinted with a hand-assigned brand colour — cleaner
// than svgl's full-colour/wordmark marks. Vendored locally (simple-icons.json) so icon: refs resolve SYNC +
// offline. `iconSlugs` lets callers check existence before falling back to a CLI's language icon.
configure({ brands, icons: { ...simpleIcons, ...icons }, svglIndex })

const iconSlugs = new Set(Object.keys(simpleIcons).concat(Object.keys(icons)))
export { glyph, glyphAsync, iconSlugs }
