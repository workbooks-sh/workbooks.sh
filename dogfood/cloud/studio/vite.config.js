import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import tailwindcss from '@tailwindcss/vite'
import importMetaUrlPlugin from '@codingame/esbuild-import-meta-url-plugin'

// base:'./' emits RELATIVE asset URLs so the bundle works when served behind the nexus /cloud mount
// (and its injected <base href="/cloud/_v/<ver>/">) — absolute /assets paths would bypass the base and
// 404. This is the single highest-risk integration detail of the cutover (eng review).
export default defineConfig({
  base: './',
  plugins: [tailwindcss(), svelte()],
  server: { port: 5180 },
  // monaco-vscode-api (the IDE recon spike) ships ESM workers referenced via `new URL(..., import.meta.url)`
  // and `?worker`. The esbuild plugin rewrites those for the dev pre-bundle; worker.format 'es' makes the
  // built workers ESM. We do NOT pre-bundle the api packages — their deep sub-path imports defeat esbuild's
  // optimizer, so let vite resolve them on demand.
  worker: { format: 'es' },
  optimizeDeps: {
    esbuildOptions: { plugins: [importMetaUrlPlugin] },
    exclude: [
      '@codingame/monaco-vscode-api',
      '@codingame/monaco-vscode-editor-api',
      '@codingame/monaco-vscode-files-service-override',
      '@codingame/monaco-vscode-theme-service-override',
      '@codingame/monaco-vscode-theme-defaults-default-extension'
    ]
  }
})
