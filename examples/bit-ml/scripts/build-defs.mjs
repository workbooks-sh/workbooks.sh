// Compose deployable crew defs: each role's runnable def = the shared laws +
// the role body, inlined as one `<work-system>` inside a `<work-agent>` element
// (AgentDef.run reads exactly that). Source defs stay split for editing
// (agents/shared.md + agents/<role>.html); this produces agents/dist/<role>.html
// for seeding to the box. Run: node examples/bit-ml/scripts/build-defs.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
const A = join(dirname(new URL(import.meta.url).pathname), '..', 'agents');

const decode = (s) => s
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
const encode = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// The role body is the text of the role file's <work-system> element.
const roleBody = (html) => {
  const m = html.match(/<work-system>([\s\S]*?)<\/work-system>/i);
  if (!m) throw new Error('no <work-system> in role def');
  return decode(m[1]).trim();
};

// shared.md is plain markdown laws — inlined verbatim as the laws preamble.
const shared = readFileSync(join(A, 'shared.md'), 'utf8').trim();
const roles = { desk: ['desk', 'x-ai/grok-4.20'], researcher: ['moss', 'xiaomi/mimo-v2.5'],
                writer: ['wren', 'xiaomi/mimo-v2.5'], editor: ['hale', 'xiaomi/mimo-v2.5'] };

mkdirSync(join(A, 'dist'), { recursive: true });
for (const [f, [id, model]] of Object.entries(roles)) {
  const role = roleBody(readFileSync(join(A, `${f}.html`), 'utf8'));
  const system = encode(`${shared}\n\n${role}`);
  const doc = `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<title>${id} — bit.ml newsroom agent</title>\n</head>\n<body>\n<work-agent id="${id}" model="${model}">\n  <work-system>\n${system}\n  </work-system>\n</work-agent>\n</body>\n</html>\n`;
  writeFileSync(join(A, 'dist', `${f}.html`), doc);
  console.log(`built dist/${f}.html (${doc.length}c, id=${id}, model=${model})`);
}
