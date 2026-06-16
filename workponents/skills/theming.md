# Theming workponents UI

Kind: skill

Summary: Generate on-brand UI from the `--work-*` token contract only — never raw hex; pick variants from the declared enums; set the artifact theme; lint before done.

## When to use

When you (the agent) emit any `work-*` element, a workbook artifact, or any
markup styled with the workponents design system. The goal: UI that inherits the
active theme automatically and stays legible under every theme, with zero
hardcoded palette.

## The one rule: style only from `--work-*` tokens

Every visual value comes from a token in [theme-contract.json](../theme-contract.json) — the single
source of truth for token names, roles, variant enums, and theme ids. Read it,
don't guess.

- NEVER emit a raw color (`#fff`, `rgb(...)`, `hsl(...)`). Use the token whose
  ROLE matches: text on a solid fill → `var(--work-on-brand)` / `var(--work-on-state)`;
  surfaces → `var(--work-surface)`; borders → `var(--work-border)`; brand accent
  → `var(--work-brand)`; state → `var(--work-ok|warn|err)` and their `-soft` tints.
- NEVER hardcode the design scale. Radius → `var(--work-radius*)`; spacing →
  `var(--work-space-1..5)`; type → `var(--work-font*)` / `var(--work-text*)`.
  (Fluid `clamp()` and relative `em` sizing are fine.)
- Only these literals are allowed in styles: `transparent`, `currentColor`,
  `inherit`, `none`. Anything else color-like is a leak.

## Pick variants from the declared enums

Each element declares its variant attributes + allowed values in the contract's
`variants` map. Choose from those enums ONLY — an out-of-enum value silently
falls back to the default. Example: `work-button` → `variant ∈
{solid,soft,outline,ghost}`, `tone ∈ {brand,neutral,ok,warn,err}`, `size ∈
{sm,md,lg}`.

## Set the artifact's theme

For a workbook artifact, set `workbook-spec.theme` to the workspace brand id (a
registered theme — see `themes` in the contract: `light`, `dark`, `signal`, or a
per-workspace brand). On hydrate the artifact calls
`applyTheme(spec.theme, {mode})` ([registry.js](../src/theme/registry.js)) which writes the `--work-*`
tokens inline. Don't hardcode a palette per artifact — register/apply a theme.

Inside the desktop (or any host that already speaks `--color-*`), load
`src/theme/bridge.css` instead — `--work-*` then derives from the host's
`--color-*` registry automatically, no per-artifact theme needed.

## Lint before declaring done

Run the design gate and fix anything it flags on the UI you authored:

```sh
cd workponents && npm run lint:design   # = node tools/design-lint.mjs
```

It flags: off-token color, off-system radius/space/font literals, unknown
`var(--work-foo)` tokens (typos), variant non-conformance, and WCAG contrast
failures per theme. A clean element produces zero findings for its name.

## Checklist

- [ ] No raw hex / rgb / hsl in any style.
- [ ] Every value maps to a `--work-*` token by role.
- [ ] Variants chosen from the contract enums.
- [ ] Artifact `workbook-spec.theme` set to the workspace brand.
- [ ] `npm run lint:design` shows no findings for the authored element(s).
