// workponents · validate — design-lint.
//
// Sibling to rules.js (field/data validation); this is the DESIGN-system gate.
// It enforces the theme contract — that every element styles ONLY from the
// `--work-*` tokens (no raw hex / off-system radius/space/font literals / typo'd
// tokens), that declared variants conform, and that each registered theme is
// WCAG-legible. Pure logic, zero deps, same result shape as rules.js:
//
//   { valid: Boolean, errors: [ { path, rule, message } ] }
//
// where `path` is the source location (element name / token pair) and `rule` is
// the failing rule key. Static analysis over element SOURCE TEXT (no DOM, no
// build) so it runs as a fast CLI gate. The theme contract (theme-contract.json)
// is the single source of allowed tokens / variants / themes; the registry seed
// supplies the resolved token colors for contrast.

// ── rule keys ───────────────────────────────────────────────────────────────
//   off-token-color   literal hex/rgb/hsl in static styles (not transparent/…)
//   off-system-value  radius/space/font literal where a --work-* token exists
//   unknown-token     var(--work-foo) not in the contract (typo guard)
//   variant-conformance  a defineVariants option/default outside the contract
//   contrast          a registered theme pair below its WCAG minimum

const ALLOWED_LITERAL_WORDS = new Set([
  "transparent", "currentColor", "currentcolor", "inherit", "none", "unset", "initial", "auto",
]);

// hex (#abc / #aabbcc / #aabbccdd) or rgb()/rgba()/hsl()/hsla() function color.
const HEX_RE = /#[0-9a-fA-F]{3,8}\b/g;
const FUNC_COLOR_RE = /\b(?:rgb|rgba|hsl|hsla)\s*\([^)]*\)/g;
// var(--work-foo) references — capture the token and whether a fallback follows
// (`var(--work-foo, …)`). A fallback-backed reference is an element override
// HOOK (safe: degrades to its default); a bare reference to a non-contract token
// is a typo that breaks rendering.
const VAR_WORK_RE = /var\(\s*(--work-[a-z0-9-]+)\s*(,)?/g;
// a `prop: value;` declaration with a bare ABSOLUTE px length (off the design
// scale) — flagged for radius/padding/margin/gap/font-size props. Relative units
// (em/%, and clamp() fluid type) are intentional and NOT flagged: the contract
// governs the design SCALE (px radius/space), not fluid/relative sizing.
const SIZE_PROP_RE = /(border-radius|padding|margin|gap|font-size|font-family|font)\s*:\s*([^;{}]+)[;}]/g;
const BARE_LEN_RE = /(?<![\w-])\d*\.?\d+px\b/;

// ── color parsing for contrast ────────────────────────────────────────────────
function parseColor(c) {
  if (!c) return null;
  c = String(c).trim();
  let m = /^#([0-9a-f]{3,8})$/i.exec(c);
  if (m) {
    let h = m[1];
    if (h.length === 3) h = h.split("").map((x) => x + x).join("");
    if (h.length === 4) h = h.slice(0, 3).split("").map((x) => x + x).join("") + h.slice(3) + h.slice(3);
    const r = parseInt(h.slice(0, 2), 16), g = parseInt(h.slice(2, 4), 16), b = parseInt(h.slice(4, 6), 16);
    const a = h.length >= 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
    return { r, g, b, a };
  }
  m = /^rgba?\(([^)]+)\)$/i.exec(c);
  if (m) {
    const parts = m[1].split(/[,\s/]+/).filter(Boolean);
    const r = +parts[0], g = +parts[1], b = +parts[2];
    const a = parts[3] != null ? +parts[3] : 1;
    if ([r, g, b].some(Number.isNaN)) return null;
    return { r, g, b, a };
  }
  return null; // hsl/named not needed for the seeded theme palettes
}

/** Composite `fg` over `bg` when fg has alpha (so contrast is real, not naive). */
function composite(fg, bg) {
  if (fg.a >= 1) return fg;
  const a = fg.a;
  return {
    r: fg.r * a + bg.r * (1 - a),
    g: fg.g * a + bg.g * (1 - a),
    b: fg.b * a + bg.b * (1 - a),
    a: 1,
  };
}

function relLum({ r, g, b }) {
  const lin = (v) => {
    v /= 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

/** WCAG contrast ratio between two parsed colors (fg composited over bg). */
export function contrastRatio(fgRaw, bgRaw) {
  const bg = parseColor(bgRaw);
  let fg = parseColor(fgRaw);
  if (!fg || !bg) return null;
  fg = composite(fg, bg);
  const l1 = relLum(fg), l2 = relLum(bg);
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1];
  return (hi + 0.05) / (lo + 0.05);
}

// ── element-source lint ───────────────────────────────────────────────────────
/**
 * Lint one element's source text against the contract.
 * @param {string} name e.g. "work-button"
 * @param {string} source the .js file text
 * @param {object} contract parsed theme-contract.json
 * @returns {{path,rule,message}[]}
 */
export function lintElementSource(name, source, contract) {
  const errors = [];
  const known = new Set(Object.keys(contract.tokens));
  const literalWords = new Set([...ALLOWED_LITERAL_WORDS, ...(contract.allowedLiterals || [])]);

  // Isolate the `static styles = css\`...\`` block(s) — only style text is linted.
  const styleBlocks = [...source.matchAll(/static\s+styles\s*=\s*css`([\s\S]*?)`/g)].map((m) => m[1]);
  const styleText = styleBlocks.join("\n");

  // (a) off-token color — literal hex / rgb / hsl in static styles.
  for (const re of [HEX_RE, FUNC_COLOR_RE]) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(styleText))) {
      const lit = m[0];
      if (literalWords.has(lit.toLowerCase())) continue;
      errors.push({
        path: `${name} static styles`,
        rule: "off-token-color",
        message: `literal color "${lit}" — use a --work-* token (e.g. var(--work-on-brand))`,
      });
    }
  }

  // (b) off-system value — radius/space/font literals on system props.
  SIZE_PROP_RE.lastIndex = 0;
  let sm;
  while ((sm = SIZE_PROP_RE.exec(styleText))) {
    const [, prop, valueRaw] = sm;
    const value = valueRaw.trim();
    // skip declarations that already reference a token, or use fluid clamp()
    if (value.includes("var(--work-")) continue;
    if (value.includes("clamp(")) continue;
    if (prop === "font-family" || prop === "font") {
      // font literal that names a family but no token → off-system
      if (!value.includes("var(--work-") && /[a-z]/i.test(value) && !/^(inherit|unset|initial)$/i.test(value)) {
        errors.push({
          path: `${name} static styles`,
          rule: "off-system-value",
          message: `font "${value}" not from --work-font* — use var(--work-font)/var(--work-font-mono)`,
        });
      }
      continue;
    }
    if (BARE_LEN_RE.test(value)) {
      errors.push({
        path: `${name} static styles`,
        rule: "off-system-value",
        message: `${prop} "${value}" uses a raw length — use --work-radius*/--work-space*`,
      });
    }
  }

  // (c) unknown token — var(--work-foo) referenced but neither a contract token
  // nor a custom prop the element DEFINES locally (`--work-foo: …`). Element-
  // private theming hooks (e.g. --work-diff-add-bg, set on :host) are legitimate
  // — only an undefined, non-contract --work-* reference is a typo/leak.
  const localDefs = new Set(
    [...source.matchAll(/(--work-[a-z0-9-]+)\s*:/g)].map((m) => m[1].replace(/^--/, "")),
  );
  VAR_WORK_RE.lastIndex = 0;
  let vm;
  const seen = new Set();
  while ((vm = VAR_WORK_RE.exec(source))) {
    const tok = vm[1].replace(/^--/, "");
    const hasFallback = vm[2] === ",";
    if (seen.has(tok)) continue;
    seen.add(tok);
    if (!known.has(tok) && !localDefs.has(tok) && !hasFallback) {
      errors.push({
        path: `${name}`,
        rule: "unknown-token",
        message: `var(--${tok}) is not a contract token (typo? not in theme-contract.json)`,
      });
    }
  }

  // (d) variant conformance — defineVariants options/default vs the contract.
  const declared = contract.variants[name];
  if (declared) {
    const dv = [...source.matchAll(/(\w+)\s*:\s*\{\s*options:\s*\[([^\]]*)\]\s*,\s*default:\s*"([^"]*)"/g)];
    for (const [, attr, optsRaw, def] of dv) {
      const allowed = declared[attr];
      if (!allowed) continue; // attr not in contract (informational); skip
      const opts = optsRaw.split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
      for (const o of opts) {
        if (!allowed.includes(o)) {
          errors.push({ path: `${name} ${attr}`, rule: "variant-conformance", message: `option "${o}" not in contract enum [${allowed.join(", ")}]` });
        }
      }
      if (!allowed.includes(def)) {
        errors.push({ path: `${name} ${attr}`, rule: "variant-conformance", message: `default "${def}" not in contract enum [${allowed.join(", ")}]` });
      }
    }
  }

  return errors;
}

// ── theme contrast lint ───────────────────────────────────────────────────────
/**
 * Lint registered themes for WCAG contrast on the contract's pairs.
 * @param {object} contract parsed theme-contract.json
 * @param {Function} resolveTokens (id, mode) => {token:value} (from registry.js)
 * @returns {{path,rule,message}[]}
 */
export function lintThemeContrast(contract, resolveTokens) {
  const errors = [];
  const pairs = (contract.contrastTargets && contract.contrastTargets.pairs) || [];
  for (const id of contract.themes) {
    for (const mode of ["light", "dark"]) {
      const tokens = resolveTokens(id, mode);
      if (!tokens || Object.keys(tokens).length === 0) continue; // theme has no map for this mode
      // A translucent bg token (a soft tint) is laid OVER the theme surface, so
      // composite it over work-surface (then work-bg) before measuring — else a
      // tint reads as near-transparent and the ratio is meaningless.
      const baseBg = tokens["work-surface"] || tokens["work-bg"];
      for (const p of pairs) {
        const fg = tokens[p.fg];
        let bg = tokens[p.bg];
        if (!fg || !bg) continue; // token not overridden in this theme/mode — base covers it
        const bgParsed = parseColor(bg);
        if (bgParsed && bgParsed.a < 1 && baseBg) {
          const over = composite(bgParsed, parseColor(baseBg) || { r: 255, g: 255, b: 255, a: 1 });
          bg = `rgb(${Math.round(over.r)},${Math.round(over.g)},${Math.round(over.b)})`;
        }
        const ratio = contrastRatio(fg, bg);
        if (ratio == null) continue;
        if (ratio < p.min) {
          errors.push({
            path: `theme:${id}/${mode} ${p.fg}|${p.bg}`,
            rule: "contrast",
            message: `${ratio.toFixed(2)}:1 below WCAG ${p.kind} min ${p.min}:1`,
          });
        }
      }
    }
  }
  return errors;
}

/**
 * Full design-lint over a set of element sources + the themes.
 * @param {{name,source}[]} elements
 * @param {object} contract
 * @param {Function} resolveTokens
 * @returns {{valid:boolean, errors:{path,rule,message}[]}}
 */
export function designLint(elements, contract, resolveTokens) {
  const errors = [];
  for (const { name, source } of elements) {
    for (const e of lintElementSource(name, source, contract)) errors.push(e);
  }
  for (const e of lintThemeContrast(contract, resolveTokens)) errors.push(e);
  return { valid: errors.length === 0, errors };
}
