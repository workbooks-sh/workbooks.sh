import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// Point the dashboard at a real runtime for local "live" validation:
//   VITE_WB_RUNTIME=http://localhost:4010 VITE_WB_TENANT=smoke bun run dev
// The proxy forwards same-origin /api → that runtime (no CORS), matching the
// hosted model where the dashboard is served same-origin as the runtime.
// (read from process.env so a shell-exported var works, not just a .env file)
const runtime = process.env.VITE_WB_RUNTIME;

export default defineConfig({
  plugins: [sveltekit()],
  // @workos-inc/widgets is ESM React; let Vite pre-bundle React for the island
  ssr: { noExternal: ['@workos-inc/widgets'] },
  server: runtime ? { proxy: { '/api': { target: runtime, changeOrigin: true } } } : {}
});
