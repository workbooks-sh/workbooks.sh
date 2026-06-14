import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [sveltekit()],
  // @workos-inc/widgets is ESM React; let Vite pre-bundle React for the island
  ssr: { noExternal: ['@workos-inc/widgets'] }
});
