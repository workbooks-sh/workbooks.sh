import adapter from "@sveltejs/adapter-cloudflare";
import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

/**
 * Cloudflare adapter — apps/viewer ships on Cloudflare Pages at
 * workbooks.sh/w/* (or viewer.workbooks.sh during dev).
 *
 * @type {import('@sveltejs/kit').Config}
 */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter(),
    // The viewer is served at workbooks.sh (via the lander's
    // transparent proxy to this Pages project) AND at
    // sandbox.workbooks.sh directly. After the proxy, SvelteKit sees
    // its host as workbooks-viewer.pages.dev while the runner form's
    // Origin header is workbooks.sh — so the default same-origin CSRF
    // check rejects the comment + unlock form posts with 403
    // "Cross-site POST form submissions are forbidden". Trust the
    // first-party surfaces the runner is actually served from.
    csrf: {
      trustedOrigins: [
        "https://workbooks.sh",
        "https://sandbox.workbooks.sh",
        "https://workbooks-viewer.pages.dev",
      ],
    },
  },
};

export default config;
