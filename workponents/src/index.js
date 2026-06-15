// workponents — register every element + re-export the classes.
// Import this for the whole set, or import a single element from ./elements/<name>.js
// to keep a workbook lean. Theme via ./theme/tokens.css.
export { WbElement, define } from "./core/element.js";
export { WbHost, configureHost, getHost } from "./core/host.js";
export { defineVariants, resolveVariant, variantAttrs, lintVariants } from "./core/variants.js";

// elements (one per domain grows here: wb-table, wb-chart, wb-thread, ...)
export { WbButton } from "./elements/wb-button.js";
