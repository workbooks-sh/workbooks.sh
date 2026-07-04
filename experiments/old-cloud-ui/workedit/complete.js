// workedit/complete — `.work` autocompletion (P3). A composer add-on for the editor island: offers
// block kinds as `do…end` snippets at the start of a line, and inner-language keywords elsewhere.
// Built against the host's @codemirror/autocomplete instance (passed in) so it shares one state.
// Self-contained; reuse `ac.snippetCompletion` for the skeletons. Symbol-aware ref completion
// ([[backlinks]] from the workbook graph) is a later add-on.

// Block kinds that take a `do … end` body → offered as snippets with a :name + body placeholder.
const BLOCK_KINDS = [
  ['server', 'server :${name} do\n\t${}\nend'],
  ['client', 'client :${name} do\n\t${}\nend'],
  ['def', 'def ${name} do\n\t${}\nend'],
  ['data', 'data ${Name} do\n\t${}\nend'],
  ['agent', 'agent :${name} do\n\t${}\nend'],
  ['flow', 'flow :${name} do\n\t${}\nend'],
  ['hook', 'hook :${name} do\n\t${}\nend'],
  ['check', 'check :${name} do\n\t${}\nend'],
  ['resource', 'resource :${name} do\n\t${}\nend'],
  ['record', 'record :${name} do\n\t${}\nend'],
  ['sandbox', 'sandbox :${name} do\n\t${}\nend'],
  ['toolkit', 'toolkit :${name} do\n\t${}\nend'],
  ['test', 'test :${name} do\n\t${}\nend'],
  ['app', 'app :${name} do\n\t${}\nend'],
  ['auth', 'auth :${name} do\n\t${}\nend'],
];
// Flat declaration keywords (no do…end body) — plain word completions, line start.
const DECLS = ['type', 'task', 'user', 'deps', 'checks', 'theme', 'show', 'query', 'workbook', 'nexus', 'grant', 'route'];
// Inner-language keywords offered anywhere inside a block.
const KEYWORDS = ['do', 'end', 'fn', 'case', 'cond', 'with', 'when', 'if', 'else', 'for', 'try', 'rescue', 'after', 'import', 'alias', 'require', 'use'];

export function workCompletion(ac) {
  const blockOpts = BLOCK_KINDS.map(([label, tmpl]) =>
    ac.snippetCompletion(tmpl, { label, type: 'class', detail: 'block', boost: 2 }));
  const declOpts = DECLS.map((label) => ({ label, type: 'keyword', detail: 'declaration' }));
  const kwOpts = KEYWORDS.map((label) => ({ label, type: 'keyword' }));

  function source(ctx) {
    const word = ctx.matchBefore(/[a-zA-Z_]\w*/);
    if (!word || (word.from === word.to && !ctx.explicit)) return null;
    const line = ctx.state.doc.lineAt(word.from);
    const atLineStart = /^\s*$/.test(line.text.slice(0, word.from - line.from));
    // At the start of a line → kinds/declarations (structure). Otherwise → inner keywords.
    const options = atLineStart ? blockOpts.concat(declOpts) : kwOpts.concat(blockOpts);
    return { from: word.from, options, validFor: /^[a-zA-Z_]\w*$/ };
  }

  return ac.autocompletion({ override: [source], icons: false });
}
