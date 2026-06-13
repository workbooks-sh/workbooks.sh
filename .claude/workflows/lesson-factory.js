export const meta = {
  name: 'lesson-factory',
  description: 'Research → write → adversarial review for a batch of deep-dive lessons',
  whenToUse: 'One batch (1-3 lessons) of the learn deep-dive build-out (epic wb-sgoa). Args: {lessons: [{slug, parent, title, dek, evidence, color, nn}]}',
  phases: [
    { title: 'Research', detail: 'facts + outline from the cited code' },
    { title: 'Write', detail: 'full page + audio script' },
    { title: 'Review', detail: 'adversarial gate, then fixes' },
  ],
}

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['verdict', 'findings'],
  properties: {
    verdict: { type: 'string', enum: ['pass', 'fail'] },
    findings: { type: 'array', items: { type: 'string' } },
  },
}

const REPO = '/Users/shinyobjectz/Apps/workbooks'

// args may arrive as a JSON string depending on the caller — normalize.
// {file: "<path>"} loads the lesson list from disk (the library run).
let input = typeof args === 'string' ? JSON.parse(args) : args
if (input && input.file) {
  const loader = await agent(
    'Print the EXACT raw contents of ' + input.file + ' and nothing else — no commentary, no fences.',
    { label: 'load:args' }
  )
  input = JSON.parse(loader.slice(loader.indexOf('{')))
}
const lessons = Array.isArray(input) ? input : input.lessons
if (!Array.isArray(lessons) || !lessons.length) throw new Error('args.lessons must be a non-empty array')

const results = await pipeline(
  lessons,

  // ── 1 · RESEARCH: a facts dossier nobody can hand-wave past ──
  (l) => agent(
    `Research dossier for the deep-dive lesson "${l.title}" (slug ${l.slug}, under the "${l.parent}" lesson) on workbooks.sh/learn. Repo: ${REPO}.

Dek: ${l.dek}
Evidence trail (verify and EXPAND it — read these files plus whatever they lead to): ${l.evidence}

Also read ${REPO}/web/learn/${l.parent}.html fully — the parent's scope, voice, and what it already teaches. The deep dive must go DEEPER, never repeat.

Produce a dossier as your final message:
1. FACTS — every claim the lesson can make, each with the file:line or module that proves it. Include real constants, real shapes, real flows (e.g. actual env vars, actual function names, actual limits). Mark anything uncertain as UNCERTAIN rather than guessing.
2. NARRATIVE ARC — the problem the reader has, the aha, the mechanics, the honest limits. What would a USER actually want from this page?
3. SECTION OUTLINE — 8-12 sections in house order (problem → definition → mechanics/depth sections → honesty → FAQ), with one line each on what it covers and which diagram (mermaid flowchart/sequence/table) would genuinely explain it. Mark depth-rung (skippable) sections.
4. CROSS-LINKS — which other lessons/deep-dives this should reference (extensionless hrefs).
5. THREE WORKED DETAILS — concrete examples/snippets (real org, real commands, real output shapes) the writer must include so nothing stays abstract.`,
    { label: `research:${l.slug}`, phase: 'Research', model: 'opus' }
  ).then((dossier) => ({ l, dossier })),

  // ── 2 · WRITE: the full page + narration script ──
  ({ l, dossier }) => agent(
    `Write the COMPLETE deep-dive lesson "${l.title}" for workbooks.sh/learn. Repo: ${REPO}. You are writing FILES, not a reply.

THE DOSSIER (your single source of facts — do not invent beyond it):
${dossier}

FORMAT CONTRACT — study these exemplars first and match them exactly:
- ${REPO}/web/learn/workflows.html (structure, mermaid usage, voice)
- ${REPO}/web/learn/vfs.html (depth benchmark)
- ${REPO}/web/learn/autopoet.html (a sub-lesson: kicker style "learn / NN·i — under <parent> · <title>")

Write ${REPO}/web/learn/${l.slug}.html:
- html style: --pc:${l.color}; --ac:#13d943. Kicker: "learn / ${l.nn} — <b>under ${l.parent} · ${l.title}</b>". Three-line h1 with ONE Groothan .bub word (the formula: the bub word fills with the page color automatically).
- Hero figure: <img src="img/${l.slug}-hero.jpg"> with a descriptive 1970s-sci-fi alt (the art is generated separately; write alt text that doubles as the art brief — subject matching the lesson's metaphor, bright, monumental-vs-small-figure).
- Full TOC, 8-12 sections per the dossier outline, defcard with the canon-noun definition, 2-4 brand mermaid diagrams (<pre class="mermaid">, include <script type="module" src="learn-mermaid.js"></script>), pre.orgsample for real snippets, .cmp tables where comparing, an HONESTY section, FAQ (4-6 real questions), lnext cards (parent lesson first), workbook-spec org block (SLUG ${l.slug}, NN ${l.nn}, PC ${l.color}), window.LEARN mix led by ${l.color}, nav include <script src="../nav.js?v=8"></script>, learn.css?v=4, audio.js defer.
- VOICE CANON (hard rules): agents are "agents" never "crew"; never "software that runs itself"; honesty over hype; em-dashes; short declaratives; ALL internal links extensionless; an HTML-comment easter egg after <body> that teaches this lesson's idea to source-readers.
- DEPTH: every section must say something the dossier proves. No filler, no "simply", no hand-waving. If the dossier marked something UNCERTAIN, either omit it or state the uncertainty honestly.

Write ${REPO}/web/learn/audio/scripts/${l.slug}.json:
- Read ${REPO}/web/learn/audio/README.md first — its rules are HARD (no double-quote chars in text, only the proven tag set, 10-16 tags, ellipses beats, every list enumerated First…Second…, never read a table aloud).
- Same structure as scripts/autopoet.json: slug, title "${l.title} — under ${l.parent}", tracks matching the page sections (intro…outro), intro says "Lesson ${l.nn.replace('·', ' point ')}" and names the parent; outro hands back to the parent lesson.
- EYES-CLOSED RULE (README rule 6, hard): every track opens by speaking its section's headline naturally; every mermaid diagram, org sample, and table in that section gets a spoken walkthrough woven into the narration (describe the graph as a story, read the sample aloud, give the table's verdict) — never "as shown above/below". A driver must fully follow the argument.

VERIFY before finishing: the JSON parses (python3 json.load); zero '\"' inside script text values; zero internal .html hrefs in the page; mermaid loader present if any pre.mermaid; all includes present. Return one line per file written plus the section count.`,
    { label: `write:${l.slug}`, phase: 'Write', model: 'opus' }
  ).then((note) => ({ l, dossier, note })),

  // ── 3 · REVIEW: adversarial gate ──
  ({ l, dossier, note }) => agent(
    `Adversarially review the new lesson ${REPO}/web/learn/${l.slug}.html and ${REPO}/web/learn/audio/scripts/${l.slug}.json. Try to FAIL it.

Check, with evidence:
1. FACTS: sample 6+ technical claims from the page and verify each against the actual code (the dossier cited: ${l.evidence}). Any claim the code contradicts = fail.
2. DEPTH: would a reader who needs "${l.title}" leave satisfied? Flag hand-waving, filler sections, or anything the parent lesson (${REPO}/web/learn/${l.parent}.html) already covers verbatim.
3. CANON: "crew" used for agents = fail. "runs itself" framing = fail. Missing honesty section = fail. Internal .html hrefs = fail. Bub word count != 1 in h1 = fail.
4. MECHANICS: audio JSON parses + obeys README rules (no double quotes in texts, tags from the proven set only, lists enumerated); page includes learn-mermaid.js iff pre.mermaid exists; workbook-spec block present; mermaid blocks have plausible syntax (no obvious parse-breakers like unquoted special chars in node labels).
5. LINKS: every internal href resolves to an existing page in ${REPO}/web/learn/ (extensionless → file.html) or is an anchor.

If anything fails: FIX IT YOURSELF in the files (you have write access) when the fix is mechanical (links, quotes, canon words, missing includes), and re-check. Only verdict=fail for problems requiring a rewrite (factual contradictions, hollow depth). findings = everything you found and what you did about it.

Writer's note for context: ${note}
Dossier summary (first 2000 chars): ${String(dossier).slice(0, 2000)}`,
    { label: `review:${l.slug}`, phase: 'Review', schema: REVIEW_SCHEMA, model: 'opus' }
  ).then((review) => ({ slug: l.slug, parent: l.parent, nn: l.nn, verdict: review.verdict, findings: review.findings }))
)

return results.filter(Boolean)
