import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import tailwindcss from '@tailwindcss/vite'
import importMetaUrlPlugin from '@codingame/esbuild-import-meta-url-plugin'
import { readFileSync } from 'node:fs'

// every @codingame/monaco-vscode-* package must be excluded from pre-bundling TOGETHER (see note below);
// derive the list from package.json so adding a service override can't silently re-break it.
const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url)))
const vscodeDeps = Object.keys({ ...pkg.dependencies, ...pkg.devDependencies })
  .filter((n) => n.startsWith('@codingame/monaco-vscode'))

// base:'./' emits RELATIVE asset URLs so the bundle works when served behind the nexus /cloud mount
// (and its injected <base href="/cloud/_v/<ver>/">) — absolute /assets paths would bypass the base and
// 404. This is the single highest-risk integration detail of the cutover (eng review).
export default defineConfig({
  base: './',
  plugins: [tailwindcss(), svelte()],
  server: { port: 5180 },
  // monaco-vscode-api (the IDE workbench) ships ESM workers via `new URL(..., import.meta.url)` and `?worker`.
  // The esbuild plugin rewrites those for the dev pre-bundle; worker.format 'es' makes built workers ESM.
  // CRITICAL: ALL @codingame/* packages must be excluded from pre-bundling together. If some are optimized
  // into .vite/deps and others resolve from source, vite creates TWO copies of the vscode API and commands
  // double-register ("Cannot register two commands with the same id: workbench.action.gotoLine"). One copy
  // only ⇒ exclude every @codingame/monaco-vscode-* package.
  worker: { format: 'es' },
  optimizeDeps: {
    esbuildOptions: { plugins: [importMetaUrlPlugin] },
    exclude: vscodeDeps
  }
})
