import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { unified } from 'unified'
import uniorgParse from 'uniorg-parse'
import uniorg2rehype from 'uniorg-rehype'
import rehypeStringify from 'rehype-stringify'

const processor = unified()
  .use(uniorgParse)
  .use(uniorg2rehype)
  .use(rehypeStringify)

// Virtual module: import 'virtual:org?./path/to/file.org' → { html, title }
// Path is resolved relative to the Vite project root.
function orgPlugin() {
  return {
    name: 'vite-plugin-org',
    resolveId(id) {
      if (id.startsWith('virtual:org?')) return '\0' + id
    },
    async load(id) {
      if (!id.startsWith('\0virtual:org?')) return
      const rel = id.slice('\0virtual:org?'.length)
      const absPath = resolve(process.cwd(), rel)
      const src = readFileSync(absPath, 'utf8')
      const file = await processor.process(src)
      const titleMatch = src.match(/^#\+TITLE:\s*(.+)$/m)
      const title = titleMatch ? titleMatch[1].trim() : 'Workbooks'
      return `export const html = ${JSON.stringify(String(file))};
export const title = ${JSON.stringify(title)};`
    },
  }
}

export default defineConfig({
  plugins: [orgPlugin(), svelte()],
  build: { outDir: 'dist' },
})
