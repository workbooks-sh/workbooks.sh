# icons — overview

# When to use this
  You are about to put an icon on something — a workbook item, a file row, a
  brand mark, a spec field that the desktop will render — and you need the
  *value string*, not an image file. NOT for seeded avatars or full-color
  curated brand packs (that's the `glyphs` toolkit) and NOT for generating
  artwork (that's image gen).

# The grammar (the one contract)
## grammar
  Run `icons grammar` — it prints the authoritative table. Short form: `"" `
  initials · `mi:<def>` material svg · `lobe:<slug>` brand svg ·
  `lucide:<Name>` legacy (maps to mi:) · `data:image/…` inline image ·
  anything else = emoji text. The desktop resolves the SAME grammar
  (`desktop/src/lib/ui/Icon.svelte` — the file carries a matching sync note),
  so a value you emit here renders there unchanged. Unresolvable prefixed
  values fall back to initials, never raw text.

# Finding a value
## search and the for-* resolvers
  - `icons search rocket` — one ranked list across material defs, emoji
    names, lobe slugs (exact > prefix > substring). Narrow with
    `--kind material|emoji|lobe`, widen with `--limit N`.
  - `icons for-file main.rs` → `mi:rust` — the desktop's exact resolution
    (fileNames first, then longest multi-dot extension, then the `file`
    default). Pass a basename or a full path.
  - `icons for-folder src --open` → `mi:folder-src-open`.
  - Line mode is tab-separated (`value\tkind\tname\turl`); add `--json` for
    structured output. Exit 1 on no match / unknown value.

# Inspecting a value you met
## get
  `icons get <value>` classifies any grammar string and tells you what it
  renders as and from where: `icons get mi:rust` (known + URL),
  `icons get lobe:openai` (slug + raw URL), `icons get 🚀` (reverse-names the
  emoji), `icons get lucide:Rocket` (→ `mi:rocket`, the legacy map). Unknown
  `mi:` defs report "renders as initials" and exit 1 — trust that signal, do
  not write the value.

# Getting actual SVG bytes
  The toolkit deliberately emits URLs, not bytes (the packs stay small; the
  renderer caches). In the sandbox, pipe the URL to your fetch-capable
  command; in the desktop the renderer fetches + caches itself.

# Regenerating the packs (maintainers)
## packs
  `node scripts/build-packs.mjs` refreshes `packs/*.json` AND regenerates the
  committed `src/index.js` (data prologue + `src/cli.js`). Edit logic ONLY in
  `src/cli.js`. Bump `MIT_VERSION` in the script when the desktop bumps
  material-icon-theme. Then `node test/icons.test.mjs` must pass.

# Verification checklist
  - [ ] `node test/icons.test.mjs` — all checks green
  - [ ] `work toolkit verify icons` — structural checks pass
  - [ ] `work toolkit build icons` — registers the `icons` command (provisioned runtime)
