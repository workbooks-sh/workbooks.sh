import { sveltekit } from "@sveltejs/kit/vite";
import tailwindcss from "@tailwindcss/vite";
import { fileURLToPath } from "node:url";
import { defineConfig, type Plugin } from "vite";

/* The desktop's own node_modules is the SINGLE source of `lit`. The sibling
 * workponents package ($workponents/src) imports `lit` BARE; with no
 * workponents/node_modules symlink those specifiers can't resolve from the
 * workponents source dir. Aliasing `lit` (+ its subpaths) to the desktop's
 * own copy makes them resolve regardless of any symlink, so a fresh checkout
 * boots `work-gen-block` without the fragile symlink. dedupe pins one Lit. */
const litDir = fileURLToPath(new URL("./node_modules/lit", import.meta.url));

/* Tauri's dev server consumes Vite on a fixed port and watches
 * src-tauri/ separately. Strict port + ignored src-tauri prevent
 * Vite from triggering a full reload every time Rust recompiles. */
const host = process.env.TAURI_DEV_HOST;

/* Reliability over granular HMR: any edit under src/ forces a full page
 * reload so changes ALWAYS propagate. Svelte's hot-swap client can wedge
 * (a partial update throws once → further updates silently stop applying →
 * a soft reload doesn't recover), which is maddening during design
 * iteration. A full reload on every source change makes "I don't see my
 * change" impossible. Component-level iteration speed comes from the
 * workbench (small graph), not from in-place hot-swap of the whole app. */
function fullReloadOnSrcChange(): Plugin {
  return {
    name: "wb-full-reload-on-src-change",
    apply: "serve",
    handleHotUpdate({ file, server }) {
      if (file.includes("/src/")) {
        server.config.logger.info(
          `[wb] full reload → ${file.split("/src/")[1] ?? file}`,
        );
        server.ws.send({ type: "full-reload", path: "*" });
      }
    },
  };
}

export default defineConfig({
  plugins: [tailwindcss(), sveltekit(), fullReloadOnSrcChange()],
  clearScreen: false,
  resolve: {
    // Pin a single Lit instance and resolve workponents' bare `lit`
    // imports to the desktop's own node_modules (no symlink required).
    dedupe: ["lit"],
    alias: [
      { find: /^lit$/, replacement: litDir },
      { find: /^lit\/(.*)$/, replacement: `${litDir}/$1` },
    ],
  },
  /* Expose WB_FF_* feature flags to client code via import.meta.env
   * (wb-aakl.1), alongside SvelteKit's own PUBLIC_ vars. VITE_ kept so
   * the default Vite prefix still resolves. */
  envPrefix: ["VITE_", "PUBLIC_", "WB_FF_"],
  server: {
    port: 5178,
    strictPort: true,
    host: host || false,
    hmr: host
      ? { protocol: "ws", host, port: 5179 }
      : undefined,
    watch: {
      ignored: ["**/src-tauri/**"],
    },
    /* When node_modules is symlinked from another checkout (disk-safe
     * worktree dev), the SvelteKit runtime resolves to a realpath outside
     * Vite's default fs root and gets 403'd. Either WB_FS_ALLOW or
     * WB_VITE_FS_ALLOW (colon-separated absolute roots) opts those paths
     * back in. Unset in normal builds — no effect. */
    fs: (() => {
      const extra = [
        process.env.WB_FS_ALLOW,
        process.env.WB_VITE_FS_ALLOW,
      ]
        .filter(Boolean)
        .flatMap((v) => (v as string).split(":"));
      // The sibling workponents package ($workponents alias) lives outside
      // the desktop root; allow Vite to serve its source.
      return { allow: [".", "../workponents", ...extra] };
    })(),
  },
});
