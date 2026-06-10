// Compose deployable crew defs: each role's runnable def = the shared laws +
// the role body, inlined under a `** System prompt` heading inside the :agent:
// node (AgentDef.run reads exactly that). Source defs stay split for editing
// (agents/shared.org + agents/<role>.org); this produces agents/dist/<role>.org
// for seeding to the box. Run: node examples/bit-ml/scripts/build-defs.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
const A = join(dirname(new URL(import.meta.url).pathname), '..', 'agents');

const stripHeader = (s) => {
  const lines = s.split('\n'); let i = 0;
  while (i < lines.length && (lines[i].startsWith('#') || !lines[i].trim())) i++;
  return lines.slice(i).join('\n').trim();
};
const demote = (body) => body.split('\n')
  .map((l) => l.replace(/^(\*+)(\s+\S)/, (_, s, r) => '*'.repeat(s.length + 2) + r)).join('\n');

const shared = stripHeader(readFileSync(join(A, 'shared.org'), 'utf8'));
const roles = { desk: ['desk', 'x-ai/grok-4.20'], researcher: ['moss', 'xiaomi/mimo-v2.5'],
                writer: ['wren', 'xiaomi/mimo-v2.5'], editor: ['hale', 'xiaomi/mimo-v2.5'] };

mkdirSync(join(A, 'dist'), { recursive: true });
for (const [f, [id, model]] of Object.entries(roles)) {
  const role = stripHeader(readFileSync(join(A, `${f}.org`), 'utf8'));
  const doc = `#+TITLE: ${id} — bit.ml newsroom agent\n\n* agent :agent:\n  :PROPERTIES:\n  :ID:    ${id}\n  :MODEL: ${model}\n  :END:\n** System prompt\n\n${demote(shared)}\n\n${demote(role)}\n`;
  writeFileSync(join(A, 'dist', `${f}.org`), doc);
  console.log(`built dist/${f}.org (${doc.length}c, id=${id}, model=${model})`);
}
