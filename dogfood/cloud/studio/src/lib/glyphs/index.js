// Our own glyphs toolkit (vendored from toolkits/glyphs) — the ONE mark resolver. A ref is
// "<kind>:<id>" — brand:github, icon:rust. glyph() is sync curated-only (offline, null on miss);
// glyphAsync() falls through to svgl for the long tail. Configured once with the curated packs +
// the svgl name→route index. We use it for every toolkit/integration icon (NOT Simple Icons/Logo.dev).
import { glyph, glyphAsync, configure } from './glyphs.js'
import './glyphs.css' // .glyph--icon { fill: currentColor } — makes monochrome marks inherit color
import brands from './curated-brands.json'
import icons from './curated-icons.json'
import svglIndex from './svgl-index.json'
import svglBrands from './svgl-brands.json' // the WHOLE svgl library, vendored full-colour + alias-keyed

// svgl.app blocks CORS, so the network fall-through never resolved its colour marks. We vendor the full
// library locally (svgl-brands.json: 700 marks, alias-keyed bare/normalised/variant) and merge it UNDER
// our 15 hand-curated brands — curated wins, svgl fills the long tail. Now every brand: ref resolves
// SYNC, offline, full-colour; Glyph decides per-mark whether to keep the colour or ink it (mono).
configure({ brands: { ...svglBrands, ...brands }, icons, svglIndex })

export { glyph, glyphAsync }
