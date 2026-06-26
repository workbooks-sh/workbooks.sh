// Our own glyphs toolkit (vendored from toolkits/glyphs) — the ONE mark resolver. A ref is
// "<kind>:<id>" — brand:github, icon:rust. glyph() is sync curated-only (offline, null on miss);
// glyphAsync() falls through to svgl for the long tail. Configured once with the curated packs +
// the svgl name→route index. We use it for every toolkit/integration icon (NOT Simple Icons/Logo.dev).
import { glyph, glyphAsync, configure } from './glyphs.js'
import brands from './curated-brands.json'
import icons from './curated-icons.json'
import svglIndex from './svgl-index.json'

configure({ brands, icons, svglIndex })

export { glyph, glyphAsync }
