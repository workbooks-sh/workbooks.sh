import { sveltekit } from "@sveltejs/kit/vite";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

/* Tauri's dev server consumes Vite on a fixed port and watches
 * src-tauri/ separately. Strict port + ignored src-tauri prevent
 * Vite from triggering a full reload every time Rust recompiles. */
const host = process.env.TAURI_DEV_HOST;

export default defineConfig({
  plugins: [tailwindcss(), sveltekit()],
  clearScreen: false,
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
  },
});
