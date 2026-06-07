import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

/** Plain Svelte 5 (runes) — no SvelteKit, no adapters. */
export default {
  preprocess: vitePreprocess(),
};
