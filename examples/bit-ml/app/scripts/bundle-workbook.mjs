// Bundle dist/ into ONE self-contained HTML workbook: inline the JS module,
// the CSS, the content manifest, and every story org — open it from disk,
// no server. (Remote fonts/avatars stay remote: they're URLs, not files.)
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const dist = new URL('../dist', import.meta.url).pathname;
let html = readFileSync(join(dist, 'index.html'), 'utf8');

const js = readFileSync(join(dist, html.match(/assets\/(index-[^"]+\.js)/)[0]), 'utf8');
const css = readFileSync(join(dist, html.match(/assets\/(index-[^"]+\.css)/)[0]), 'utf8');
html = html.replace(/<script type="module"[^>]*><\/script>/, '');
html = html.replace(/<link rel="stylesheet"[^>]*assets\/[^>]*>/, `<style>\n${css}\n</style>`);

const manifest = readFileSync(join(dist, 'content/stories.json'), 'utf8');
let blocks = `<script type="application/json" id="wb-stories">${manifest.replace(/</g, '\\u003c')}</script>\n`;
for (const f of readdirSync(join(dist, 'content/stories'))) {
  const slug = f.replace(/\.org$/, '');
  const org = readFileSync(join(dist, 'content/stories', f), 'utf8');
  blocks += `<script type="text/org" data-slug="${slug}">${org.replace(/</g, '\\u003c')}</script>\n`;
}
// data blocks BEFORE the app module so the loader finds them at boot
html = html.replace('</body>', `${blocks}<script type="module">\n${js}\n</script>\n</body>`);

const out = join(dist, '..', 'bitml.html');
writeFileSync(out, html);
console.log('workbook:', out, (html.length / 1024).toFixed(1) + 'KB');
