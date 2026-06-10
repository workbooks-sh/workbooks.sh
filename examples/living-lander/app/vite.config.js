import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// base: './' → relative asset paths so a dumb static server can serve dist/.
export default defineConfig({
  base: './',
  plugins: [svelte()],
});
