// Brand registry (DESIGN.md §"inline brand logos"). Curated, INLINED full-color
// SVG marks for the brands the seed content names. Sourced per skills/icons.org:
//   svgl (full color) → lobehub *-color → simple-icons (monochrome, brand hex).
// Each mark is normalized to a 24-viewBox, sized by the wrapper to ~1em (so it
// scales with its heading), and carries its OWN color (monochrome marks get the
// brand hex baked into fill) — these are the SECOND sanctioned color exception.
//
// Honesty law: a brand with no good logo gets `svg: null` (or is simply absent)
// and BrandTag renders the name alone — never a broken/approximated mark.
//
// Sources used (2026-06-10):
//   google     — lobehub google-color (clean 4-color G)
//   deepmind   — lobehub deepmind-color (#4285F4)
//   nvidia     — simple-icons, brand green #76b900
//   amazon     — simple-icons, brand orange #FF9900
//   anthropic  — simple-icons, brand ink #181818
//   openai     — simple-icons, brand ink #000000
//   intel      — simple-icons, brand blue #0068B5
//   tsmc/micron/bloomberg/ECMWF/EU — no clean mark → name-only (svg:null)

// ── full-color marks ────────────────────────────────────────────────────────
const GOOGLE = `<svg viewBox="0 0 24 24" width="1em" height="1em" aria-hidden="true"><path d="M23 12.245c0-.905-.075-1.565-.236-2.25h-10.54v4.083h6.186c-.124 1.014-.797 2.542-2.294 3.569l-.021.136 3.332 2.53.23.022C21.779 18.417 23 15.593 23 12.245z" fill="#4285F4"/><path d="M12.225 23c3.03 0 5.574-.978 7.433-2.665l-3.542-2.688c-.948.648-2.22 1.1-3.891 1.1a6.745 6.745 0 01-6.386-4.572l-.132.011-3.465 2.628-.045.124C4.043 20.531 7.835 23 12.225 23z" fill="#34A853"/><path d="M5.84 14.175A6.65 6.65 0 015.463 12c0-.758.138-1.491.361-2.175l-.006-.147-3.508-2.67-.115.054A10.831 10.831 0 001 12c0 1.772.436 3.447 1.197 4.938l3.642-2.763z" fill="#FBBC05"/><path d="M12.225 5.253c2.108 0 3.529.892 4.34 1.638l3.167-3.031C17.787 2.088 15.255 1 12.225 1 7.834 1 4.043 3.469 2.197 7.062l3.63 2.763a6.77 6.77 0 016.398-4.572z" fill="#EB4335"/></svg>`;

const DEEPMIND = `<svg viewBox="0 0 24 24" width="1em" height="1em" aria-hidden="true"><path fill="#4285F4" fill-rule="evenodd" d="M5.988 1.622A8.539 8.539 0 003.45 8.446c.349 4.408 4.506 7.995 8.276 7.995 3.507 0 4.88-3.061 4.541-5.14a4.318 4.318 0 00-.95-2.073c.632.34 1.244.776 1.809 1.3 1.52 1.415 2.44 3.229 2.587 5.1C20.04 19.763 16.98 24 11.863 24c-1.695 0-3.48-.432-4.98-1.143C2.816 20.937 0 16.797 0 12.002 0 7.571 2.405 3.7 5.988 1.622zM12.136 0c1.696 0 3.481.432 4.98 1.143C21.186 3.063 24 7.203 24 11.998c0 4.431-2.405 8.303-5.988 10.38a8.539 8.539 0 002.538-6.824c-.349-4.408-4.506-7.995-8.276-7.995-3.507 0-4.88 3.061-4.541 5.14a4.3 4.3 0 00.953 2.073 8.723 8.723 0 01-1.81-1.3c-1.52-1.415-2.44-3.227-2.589-5.1C3.96 4.237 7.02 0 12.137 0z"/></svg>`;

// monochrome single-path marks (simple-icons), brand hex baked into fill
const NVIDIA = `<svg viewBox="0 0 24 24" width="1em" height="1em" fill="#76b900" aria-hidden="true"><path d="M8.948 8.798v-1.43a6.7 6.7 0 0 1 .424-.018c3.922-.124 6.493 3.374 6.493 3.374s-2.774 3.851-5.75 3.851c-.398 0-.787-.062-1.158-.185v-4.346c1.528.185 1.837.857 2.747 2.385l2.04-1.714s-1.492-1.952-4-1.952a6.016 6.016 0 0 0-.796.035m0-4.735v2.138l.424-.027c5.45-.185 9.01 4.47 9.01 4.47s-4.08 4.964-8.33 4.964c-.37 0-.733-.034-1.104-.096v1.322c.305.039.61.06.916.06 3.957 0 6.82-2.022 9.593-4.41.459.371 2.341 1.265 2.73 1.66-2.633 2.205-8.776 3.985-12.253 3.985-.336 0-.66-.02-.986-.052v1.859H24V4.063zm0 10.32v1.128c-3.658-.652-4.673-4.455-4.673-4.455s1.755-1.945 4.673-2.262v1.236l-.006-.001c-1.532-.184-2.729 1.245-2.729 1.245s.671 2.408 2.735 3.109M2.617 10.626s2.165-3.195 6.331-3.515V5.974C4.328 6.354 0 10.21 0 10.21s2.45 7.086 8.948 7.697v-1.207c-4.768-.597-6.331-6.075-6.331-6.075z"/></svg>`;

const AMAZON = `<svg viewBox="0 0 24 24" width="1em" height="1em" fill="#FF9900" aria-hidden="true"><path d="M.045 18.02c.072-.116.187-.124.348-.022 3.636 2.11 7.594 3.166 11.87 3.166 2.852 0 5.668-.533 8.447-1.595l.315-.14c.138-.06.234-.1.293-.13.226-.088.39-.046.525.13.12.174.09.336-.12.48-.256.19-.6.41-1.006.654-1.244.743-2.64 1.316-4.185 1.726a17.617 17.617 0 0 1-10.951-.577 17.88 17.88 0 0 1-5.43-3.35c-.1-.074-.151-.15-.151-.22 0-.047.021-.09.051-.13zm6.565-6.218c0-1.005.247-1.863.743-2.577.495-.71 1.17-1.25 2.04-1.615.796-.335 1.756-.575 2.912-.72.39-.046 1.033-.103 1.92-.174v-.37c0-.93-.1-1.553-.302-1.875-.302-.43-.78-.65-1.43-.65h-.18c-.477.046-.888.196-1.232.448-.343.254-.564.6-.662 1.045-.06.286-.203.45-.42.494l-2.423-.304c-.234-.05-.35-.176-.35-.371 0-.04.006-.082.016-.13.235-1.225.812-2.135 1.733-2.724.92-.586 1.997-.913 3.222-.983h.523c1.566 0 2.785.402 3.66 1.21.13.135.252.28.357.435.108.150.195.29.265.435.067.139.124.34.18.595.052.255.094.426.122.515.027.09.05.292.06.6.013.31.02.49.02.546v5.182c0 .37.054.71.162 1.018.107.31.213.532.315.667.105.134.275.35.512.644.085.12.13.226.13.318 0 .104-.052.197-.157.28-1.084.94-1.67 1.45-1.76 1.53-.15.12-.33.13-.54.03-.176-.15-.33-.29-.46-.426l-.272-.305a8.8 8.8 0 0 1-.276-.366l-.245-.376c-.658.715-1.305 1.16-1.93 1.34-.39.12-.874.18-1.45.18-.882 0-1.607-.27-2.174-.814-.567-.54-.85-1.31-.85-2.305zm3.234-.376c0 .447.115.808.343 1.084.228.276.532.413.91.413.034 0 .08-.006.138-.018.06-.012.1-.018.12-.018.48-.127.85-.435 1.115-.927.13-.218.226-.456.29-.713.063-.257.097-.464.105-.624.008-.16.012-.422.012-.785v-.422c-.84 0-1.48.058-1.92.174-1.287.367-1.93 1.18-1.93 2.443zm9.737 7.948c.036-.06.087-.117.15-.174.39-.26.763-.437 1.118-.53a8.61 8.61 0 0 1 1.715-.255c.15-.012.297-.006.44.018.714.063 1.142.18 1.285.35.063.084.095.212.095.384v.15c0 .5-.135 1.09-.405 1.766-.27.677-.646 1.222-1.13 1.635-.073.06-.138.09-.196.09-.024 0-.048-.006-.072-.018-.085-.04-.105-.117-.06-.234.55-1.296.825-2.195.825-2.696 0-.16-.03-.276-.09-.35-.15-.18-.57-.27-1.26-.27-.255 0-.555.018-.9.054-.376.048-.72.096-1.035.144-.09.024-.15.036-.18.036-.09 0-.135-.034-.135-.103 0-.034.018-.078.054-.13z"/></svg>`;

const ANTHROPIC = `<svg viewBox="0 0 24 24" width="1em" height="1em" fill="#181818" aria-hidden="true"><path d="M17.3041 3.541h-3.6718l6.696 16.918H24Zm-10.6082 0L0 20.459h3.7442l1.3693-3.5527h7.0052l1.3693 3.5528h3.7442L10.5363 3.5409Zm-.3712 10.2232 2.2914-5.9456 2.2914 5.9456Z"/></svg>`;

const OPENAI = `<svg viewBox="0 0 24 24" width="1em" height="1em" fill="#000000" aria-hidden="true"><path d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"/></svg>`;

const INTEL = `<svg viewBox="0 0 24 24" width="1em" height="1em" fill="#0068B5" aria-hidden="true"><path d="M20.42 7.345v9.18h1.651v-9.18zM0 7.475v1.737h1.737V7.474zm9.78.352v6.053c0 .513.044.945.13 1.292.087.34.235.618.44.828.203.21.475.359.803.451.334.093.754.136 1.255.136h.216v-1.533c-.24 0-.445-.012-.593-.037a.672.672 0 0 1-.39-.173.693.693 0 0 1-.173-.377 4.002 4.002 0 0 1-.037-.606v-2.182h1.193v-1.4H11.45V7.827zm-3.131 2.46c-.501 0-.96.118-1.354.358a2.531 2.531 0 0 0-.886.965c-.21.408-.315.872-.315 1.39 0 .513.099.977.296 1.39.198.407.482.734.854.976.371.241.83.365 1.373.365.544 0 1.014-.124 1.404-.371a2.55 2.55 0 0 0 .897-.97l-1.193-.91a1.116 1.116 0 0 1-.402.464 1.18 1.18 0 0 1-.65.16c-.32 0-.587-.099-.798-.297a1.378 1.378 0 0 1-.39-.798h3.69V12.92c0-.508-.087-.97-.272-1.378a2.346 2.346 0 0 0-.823-.966c-.365-.241-.805-.359-1.318-.359zm10.317.012c-.464 0-.86.118-1.175.365-.315.241-.526.594-.625 1.045l-.006.03v-1.323h-1.627v5.764h1.645v-3.014c0-.439.099-.762.303-.978.21-.21.464-.315.755-.315.346 0 .606.105.773.322.167.21.247.514.247.903v3.082h1.65V12.66c0-.74-.19-1.323-.575-1.756-.384-.426-.928-.637-1.638-.637zm-10.33 1.292c.55 0 .92.297 1.082.879H5.797c.044-.198.118-.371.222-.514.21-.247.475-.365.817-.365zm9.872 4.65c.117 0 .21-.037.297-.117a.39.39 0 0 0 .117-.297.397.397 0 0 0-.117-.296.394.394 0 0 0-.297-.118.405.405 0 0 0-.303.118.398.398 0 0 0-.118.296c0 .118.037.21.118.297a.418.418 0 0 0 .303.117zm-15.063.013H1.681V10.65H.117zm14.952-.198c.025.062.062.118.105.16.05.05.105.08.167.105a.531.531 0 0 0 .402 0c.062-.025.118-.062.167-.105.05-.05.08-.105.105-.16a.5.5 0 0 0 .037-.198.5.5 0 0 0-.037-.198.39.39 0 0 0-.105-.167.39.39 0 0 0-.167-.105.49.49 0 0 0-.198-.037.49.49 0 0 0-.204.037.39.39 0 0 0-.167.105c-.05.05-.08.105-.105.167a.49.49 0 0 0-.037.198.49.49 0 0 0 .037.198zm.105-.353a.327.327 0 0 1 .074-.117c.03-.031.068-.062.111-.08a.376.376 0 0 1 .142-.026c.05 0 .093.013.136.026a.4.4 0 0 1 .117.08c.031.03.056.074.075.117a.421.421 0 0 1 .03.155.421.421 0 0 1-.03.154.327.327 0 0 1-.075.117.349.349 0 0 1-.117.08.376.376 0 0 1-.136.026.395.395 0 0 1-.142-.025.349.349 0 0 1-.111-.08.39.39 0 0 1-.074-.118.421.421 0 0 1-.031-.154c0-.056.012-.105.03-.155z"/></svg>`;

// key → { name, svg } — name is the canonical display label (longest-match wins
// over substrings, see brandify). svg:null → name renders alone (honesty law).
export const BRANDS = {
  google:    { name: 'Google',    svg: GOOGLE },
  deepmind:  { name: 'DeepMind',  svg: DEEPMIND },
  nvidia:    { name: 'Nvidia',    svg: NVIDIA },
  amazon:    { name: 'Amazon',    svg: AMAZON },
  anthropic: { name: 'Anthropic', svg: ANTHROPIC },
  openai:    { name: 'OpenAI',    svg: OPENAI },
  intel:     { name: 'Intel',     svg: INTEL },
  // honest gaps — named in seed content, no clean mark sourced → name-only
  tsmc:      { name: 'TSMC',      svg: null },
  micron:    { name: 'Micron',    svg: null },
  bloomberg: { name: 'Bloomberg', svg: null },
  ecmwf:     { name: 'ECMWF',     svg: null },
  eu:        { name: 'EU',        svg: null },
};

// ── brandify(text) → HTML string ─────────────────────────────────────────────
// Scan plain text for registered brand names (word-boundary, case-insensitive,
// LONGEST-MATCH-FIRST so "OpenAI" wins over a stray "Open"). On the FIRST match
// of a given brand within this call, emit the mark + name; later mentions of the
// same brand render as plain text (tasteful: logo once per block). `seen` is
// per-call so each render block tracks its own first-mentions.
//
// Returns an HTML string for {@html}. Text is HTML-escaped; only our own
// <span>/<svg> wrappers are injected — brand SVGs are first-party constants.

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
function esc(s) { return s.replace(/[&<>"']/g, (c) => ESC[c]); }

// Build the match list once: [{ key, name, re }] sorted by name length desc.
// 'EU' is intentionally NOT auto-matched (too short / ambiguous in prose); it
// stays in the registry for explicit use but is excluded from the scanner.
const SKIP_AUTOMATCH = new Set(['eu']);
const MATCHERS = Object.entries(BRANDS)
  .filter(([key]) => !SKIP_AUTOMATCH.has(key))
  .map(([key, b]) => ({ key, name: b.name }))
  .sort((a, b) => b.name.length - a.name.length)
  .map((m) => ({
    ...m,
    // word-boundary, case-insensitive. \b works for the alnum brand names here.
    re: new RegExp(`\\b${m.name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\$&')}\\b`, 'i'),
  }));

// One <span class="brand"> wrapper: mark (if any) + the matched (original-cased)
// text. The mark span is em-scaled so it grows with its heading.
function wrap(key, matchedText) {
  const b = BRANDS[key];
  const mark = b.svg
    ? `<span class="brand-mark">${b.svg}</span>`
    : '';
  return `<span class="brand">${mark}${esc(matchedText)}</span>`;
}

export function brandify(text) {
  if (!text) return '';
  const seen = new Set();           // first-mention tracking, per call
  let out = '';
  let rest = String(text);

  // Greedy left-to-right scan: at each step find the earliest brand match among
  // all matchers; among ties at the same index, the longest name wins (MATCHERS
  // is length-desc, and we prefer the lowest index then the first matcher).
  while (rest.length) {
    let best = null; // { index, length, key, matchedText }
    for (const m of MATCHERS) {
      const hit = m.re.exec(rest);
      if (!hit) continue;
      const idx = hit.index;
      const len = hit[0].length;
      if (!best || idx < best.index || (idx === best.index && len > best.length)) {
        best = { index: idx, length: len, key: m.key, matchedText: hit[0] };
      }
    }
    if (!best) { out += esc(rest); break; }

    out += esc(rest.slice(0, best.index));
    if (seen.has(best.key)) {
      // already shown this block — plain text, no repeat mark
      out += esc(best.matchedText);
    } else {
      seen.add(best.key);
      out += wrap(best.key, best.matchedText);
    }
    rest = rest.slice(best.index + best.length);
  }
  return out;
}
