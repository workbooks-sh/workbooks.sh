import adapter from "@sveltejs/adapter-static";
import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

/**
 * Static adapter — Tauri loads the frontend off the filesystem as
 * pre-rendered assets, no Node/CF runtime in the loop. SPA fallback
 * via `index.html` keeps client-side routing working without a server.
 *
 * @type {import('@sveltejs/kit').Config}
 */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter({
      pages: "build",
      assets: "build",
      fallback: "index.html",
      precompress: false,
      strict: true,
    }),
    // workponents is the sibling SDK package (the real <work-*> Lit
    // elements). The desktop imports it as `$workponents/...` so the chat
    // surface renders the SAME elements we ship, not Svelte twins.
    alias: {
      $workponents: "../workponents/src",
    },
  },
};

export default config;
