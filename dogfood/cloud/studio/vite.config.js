import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import tailwindcss from '@tailwindcss/vite'

// base:'./' emits RELATIVE asset URLs so the bundle works when served behind the nexus /cloud mount
// (and its injected <base href="/cloud/_v/<ver>/">) — absolute /assets paths would bypass the base and 404.
export default defineConfig({
  base: './',
  plugins: [tailwindcss(), svelte()],
  server: { port: 5180 }
})
