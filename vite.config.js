import { defineConfig } from 'vite'
import wasm from 'vite-plugin-wasm'
import topLevelAwait from 'vite-plugin-top-level-await'

export default defineConfig({
  root: 'app',
  plugins: [
    wasm(),
    topLevelAwait(),
  ],
  server: {
    host: '0.0.0.0',
    port: 5173,
    // Serve pkg/ with correct MIME — belt-and-suspenders alongside vite-plugin-wasm
    headers: {
      'Cross-Origin-Embedder-Policy': 'credentialless',
    },
    fs: {
      // Allow serving from project root (for pkg/ which is outside app/)
      allow: ['..'],
    },
  },
  build: {
    outDir: '../dist',
    rollupOptions: {
      input: {
        index: 'app/index.html',
        dashboard: 'app/dashboard.html',
        'brand-creator': 'app/brand-creator.html',
        'team-designer': 'app/team-designer.html',
      },
    },
  },
})
