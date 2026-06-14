import adapter from '@sveltejs/adapter-cloudflare';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
export default {
  preprocess: vitePreprocess(),
  // Cloudflare Pages/Workers. The WorkOS Node SDK needs Node built-ins → nodejs_compat
  // (set the compatibility flag on the Pages project too).
  kit: { adapter: adapter() }
};
