// Variants — the cva-style contract for web components.
//
// Variants are REFLECTED ATTRIBUTES the component CSS targets via :host([...]).
// This util doesn't generate classes; it (1) declares the allowed values +
// defaults for an element (so authoring is typed/validated and the design-lint
// can check conformance), and (2) normalizes the live attribute, applying the
// default when unset or invalid. The actual styling lives in the component CSS:
//
//   static styles = `
//     :host([variant="solid"]) button { background: var(--wb-brand); }
//     :host([size="sm"])      button { padding: var(--wb-space-1) var(--wb-space-2); }
//   `;
//
// Usage in an element:
//   static variants = defineVariants({
//     variant: { options: ["solid", "soft", "ghost"], default: "solid" },
//     size:    { options: ["sm", "md", "lg"],        default: "md" },
//     tone:    { options: ["brand", "neutral", "ok", "warn", "err"], default: "brand" },
//   });
//   // in render(): this.variant("variant") -> the resolved value

export function defineVariants(spec) {
  return spec;
}

/** Resolve a variant attribute on `el` to a valid value (default on miss). */
export function resolveVariant(el, spec, name) {
  const def = spec[name];
  if (!def) return el.getAttribute(name);
  const v = el.getAttribute(name);
  return def.options.includes(v) ? v : def.default;
}

/** Every variant attribute name an element declares (for observedAttributes). */
export function variantAttrs(spec) {
  return Object.keys(spec || {});
}

/** Design-lint helper: report any variant attr set to a non-allowed value. */
export function lintVariants(el, spec) {
  const bad = [];
  for (const [name, def] of Object.entries(spec || {})) {
    const v = el.getAttribute(name);
    if (v != null && !def.options.includes(v)) bad.push({ name, value: v, allowed: def.options });
  }
  return bad;
}
