<script>
  // Inline brand logos (DESIGN.md §"inline brand logos"). Given plain `text`,
  // brandify() wraps each registered brand's FIRST mention with an em-scaled
  // full-color mark + the name. The mark scales with whatever type size this
  // sits in (headline, dek, body) because it's sized in `em`. Honest: a brand
  // with no sourced logo renders the name alone. NEVER used in the mono meta row.
  import { brandify } from './brands.js';
  let { text = '' } = $props();
  const html = $derived(brandify(text));
</script>

{@html html}
