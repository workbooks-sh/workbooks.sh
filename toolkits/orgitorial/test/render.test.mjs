// orgitorial render tests — plain asserts, no deps.  run: node test/render.test.mjs
import assert from "node:assert";
import { render, parseMeta } from "../dist/orgitorial.js";

let pass = 0;
function ok(name, cond, detail) {
  if (cond) {
    pass++;
  } else {
    console.error(`FAIL: ${name}${detail ? "\n  " + detail : ""}`);
    process.exitCode = 1;
  }
}
function has(name, org, needle, opts) {
  const html = render(org, opts);
  ok(name, html.includes(needle), `expected to contain: ${needle}\n  got: ${html}`);
}

// metadata
const meta = parseMeta("#+TITLE: Hi\n#+AUTHOR: Ada\n#+DATE: 2031-11-22\n#+keywords: a, b c");
ok("meta.title", meta.title === "Hi");
ok("meta.author", meta.author === "Ada");
ok("meta.date", meta.date === "2031-11-22");
ok("meta.keywords", meta.keywords.length === 3 && meta.keywords[0] === "a");

has("header renders title", "#+TITLE: Hi\n\nbody", '<h1 class="org-title">Hi</h1>');
has("header off", "#+TITLE: Hi\n\nbody", "<article", { header: false });
ok("header off no h1", !render("#+TITLE: Hi\n\nx", { header: false }).includes("org-title"));

// meta return shape
const r = render("#+TITLE: T\n\nx", { meta: true });
ok("meta return shape", typeof r === "object" && r.html.includes("org-doc") && r.meta.title === "T");

// headlines + todo + tags
has("h1->h2", "* Heading", '<h2 class="org-h">');
has("h2->h3", "** Sub", '<h3 class="org-h">');
has("todo state", "* TODO Task", 'class="org-h org-todo"');
has("todo kw chip", "* TODO Task", '<span class="org-todo-kw">TODO</span>');
has("done state", "* DONE Task", 'class="org-h org-done"');
has("tags", "* Heading :work:urgent:", '<span class="org-tag">work</span>');

// paragraphs + emphasis
has("paragraph", "hello world", '<p class="org-p">hello world</p>');
has("bold", "a *bold* b", "<strong>bold</strong>");
has("italic", "a /it/ b", "<em>it</em>");
has("underline", "a _u_ b", "<u>u</u>");
has("strike", "a +s+ b", "<del>s</del>");
has("verbatim", "a =v= b", '<code class="org-verbatim">v</code>');
has("code", "a ~c~ b", '<code class="org-code">c</code>');

// links
has("link with desc", "[[https://x.com][X site]]", '<a class="org-link" href="https://x.com">X site</a>');
has("bare link", "see https://x.com here", '<a class="org-link-url" href="https://x.com">');
has("image link", "[[photo.png]]", '<img class="org-img" src="photo.png"');

// lists
has("unordered list", "- one\n- two", '<ul class="org-list">');
has("ordered list", "1. one\n2. two", '<ol class="org-list">');
has("nested list", "- a\n  - b", '<ul class="org-list"><li class="org-item">a<ul');
has("checkbox unchecked", "- [ ] todo", '<li class="org-check" data-checked="false">');
has("checkbox checked", "- [X] done", '<li class="org-check" data-checked="true">');
has("checkbox partial", "- [-] some", '<li class="org-check" data-checked="partial">');

// tables
const tbl = "| A | B |\n|---+---|\n| 1 | 2 |";
has("table tag", tbl, '<table class="org-table">');
has("table header", tbl, "<thead><tr><th>A</th><th>B</th></tr></thead>");
has("table body", tbl, "<td>1</td><td>2</td>");

// src block
const src = "#+begin_src python\nprint(1)\n#+end_src";
has("src pre", src, '<pre class="org-src" data-lang="python">');
has("src lang class", src, 'class="org-src-code language-python"');
has("src escaped", "#+begin_src js\na < b\n#+end_src", "a &lt; b");

// quote / example / verse
has("quote", "#+begin_quote\nwise words\n#+end_quote", '<blockquote class="org-quote">');
has("example", "#+begin_example\nraw\n#+end_example", '<pre class="org-example">raw</pre>');
has("verse", "#+begin_verse\nl1\nl2\n#+end_verse", '<p class="org-verse">l1<br>l2</p>');

// drawer
const drw = ":PROPERTIES:\n:ID: abc\n:END:";
has("drawer", drw, '<details class="org-drawer">');
has("drawer summary", drw, '<summary class="org-drawer-name">PROPERTIES</summary>');
has("drawer prop", drw, "<span class=\"org-prop-key\">ID</span>");

// footnotes
const fn = "Text[fn:1] more.\n\n[fn:1] The note.";
has("fn ref", fn, '<sup class="org-fnref" id="fnref-1">');
has("fn def", fn, '<li class="org-fn" id="fn-1">');
has("fn section", fn, '<section class="org-footnotes">');

// horizontal rule
has("hr", "above\n\n-----\n\nbelow", '<hr class="org-rule">');

// timestamp
has("timestamp", "due <2031-11-22 Sat>", '<time class="org-ts" datetime="2031-11-22">');

// unknown block preserved, escaped
has("unknown block preserved", "#+begin_weird\n<x>\n#+end_weird", 'class="org-raw" data-block="weird"');
ok("unknown block escaped", render("#+begin_weird\n<x>\n#+end_weird").includes("&lt;x&gt;"));

// html escaping in plain text
ok("text escaped", render("a < b & c").includes("a &lt; b &amp; c"));

// malformed input never throws -> degrades, returns string
let threw = false;
let outHtml = "";
try {
  outHtml = render("* [[broken\n#+begin_src\nunterminated =verbatim ~code [[\n** :weird drawer\n[fn:");
} catch (e) {
  threw = true;
}
ok("malformed no throw", !threw);
ok("malformed returns article", typeof outHtml === "string" && outHtml.includes("org-doc"));

// code spans are literal — markup inside =...= / ~...~ is NOT processed,
// and no placeholder sentinel ever leaks into output (regression)
has("verbatim is literal", "drop =[fn:1]= inline", '<code class="org-verbatim">[fn:1]</code>');
ok("no sentinel leak (fn in verbatim)", !/[]/.test(render("text =[fn:1]= and =[[x]]= here")));
has("code is literal", "use ~[[a][b]]~ token", '<code class="org-code">[[a][b]]</code>');
ok("no sentinel leak (kitchen sink)", !/[]/.test(
  render("Note[fn:1] and =verb= and [[u][d]].\n\n[fn:1] def with =[fn:2]= inside.")
));

// null / non-string input
ok("null input", typeof render(null) === "string");
ok("number input", typeof render(42) === "string");
ok("empty input", render("") === '<article class="org-doc"></article>');

console.log(`\n${pass} assertions passed${process.exitCode ? " (with failures above)" : ""}`);
