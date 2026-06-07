import { svelte } from "@sveltejs/vite-plugin-svelte";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";

/* Plain Vite SPA — no SvelteKit. Tauri loads this build off the
 * filesystem; the dev server uses a fixed port and ignores src-tauri
 * so Rust recompiles don't trigger a full frontend reload. */
const host = process.env.TAURI_DEV_HOST;

export default defineConfig({
  plugins: [tailwindcss(), svelte()],
  resolve: {
    alias: {
      $lib: fileURLToPath(new URL("./src/lib", import.meta.url)),
    },
  },
  clearScreen: false,
  server: {
    port: 5178,
    strictPort: true,
    host: host || false,
    hmr: host ? { protocol: "ws", host, port: 5179 } : undefined,
    watch: { ignored: ["**/src-tauri/**"] },
  },
});
