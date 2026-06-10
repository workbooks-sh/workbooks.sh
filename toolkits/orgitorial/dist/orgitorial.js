/*!
 * orgitorial — org-mode → HTML renderer (zero dependencies)
 *
 * Pure string → string. Runs in a browser <script> tag (window.Orgitorial),
 * as an ES module (export { render }), in Node, and in QuickJS-wasm. No DOM,
 * no Node APIs. Malformed input never throws — it degrades to paragraphs.
 *
 * API:
 *   render(orgText, opts) -> string            // article HTML
 *   render(orgText, { meta: true }) -> { html, meta }
 *   parseMeta(orgText) -> { title, author, date, keywords:[] }
 *
 * opts:
 *   header   (bool, default true)  render an <header class="org-header"> from metadata
 *   meta     (bool, default false) return { html, meta } instead of a string
 *
 * The CLASS CONTRACT (stable API — see skills/components.org):
 *   article.org-doc            document root
 *   header.org-header          metadata header  (h1.org-title, .org-meta)
 *   h2..h5.org-h               headlines (level N+1); .org-todo/.org-done state
 *   span.org-todo-kw           TODO/DONE keyword chip
 *   span.org-tag               :tag: pill
 *   p.org-p                    paragraph
 *   p.org-raw                  unsupported construct, escaped & preserved
 *   strong/em/u/del            bold/italic/underline/strike
 *   code.org-verbatim          =verbatim=
 *   code.org-code              ~code~
 *   a.org-link / a.org-link-url    [[link][desc]] / bare url
 *   img.org-img                image link
 *   ul.org-list / ol.org-list  lists (nested)
 *   li.org-item                list item
 *   li.org-check[data-checked] checkbox item ("true"|"false"|"partial")
 *   pre.org-src[data-lang]     #+begin_src  (header bar + code.language-<lang>)
 *   blockquote.org-quote       #+begin_quote
 *   pre.org-example            #+begin_example
 *   p.org-verse                #+begin_verse
 *   table.org-table            tables (thead/tbody, th/td)
 *   details.org-drawer         :PROPERTIES: drawer (summary.org-drawer-name)
 *   sup.org-fnref / .org-fn    footnote ref / definition list
 *   hr.org-rule                horizontal rule
 *   time.org-ts                inline <timestamp>
 */

// Placeholder sentinels: private-use code points that never occur in org prose,
// are not regex-special, and are untouched by HTML escaping. A protected span
// becomes  PH_OPEN + index + PH_CLOSE  and is restored verbatim at the end.
var PH_OPEN = String.fromCharCode(1);
var PH_CLOSE = String.fromCharCode(2);

// ---------- helpers ----------

function esc(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function attr(s) {
  return esc(s);
}

var TODO_KEYWORDS = ["TODO", "NEXT", "WAITING", "STARTED", "IN-PROGRESS"];
var DONE_KEYWORDS = ["DONE", "CANCELLED", "CANCELED"];
var IMG_RE = /\.(png|jpe?g|gif|svg|webp|avif|bmp)$/i;
var PH_RE = new RegExp(PH_OPEN + "(\\d+)" + PH_CLOSE, "g");
var PH_SPLIT = new RegExp("(" + PH_OPEN + "\\d+" + PH_CLOSE + ")");
var PH_TEST = new RegExp("^" + PH_OPEN + "\\d+" + PH_CLOSE + "$");

// ---------- inline markup ----------
//
// Order matters. We tokenize protected spans (code/verbatim/links/footnotes/
// timestamps) first so their contents are not re-processed, then apply
// emphasis to the remaining text, then restore the protected spans.

function inline(text) {
  if (text == null) return "";
  var slots = [];
  var hold = function (html) {
    slots.push(html);
    return PH_OPEN + (slots.length - 1) + PH_CLOSE;
  };

  var s = String(text);

  // Code spans FIRST: their contents are literal and must be protected before
  // any other inline rule can see (and mangle) them — e.g. =[fn:1]= or =[[x]]=.
  // =verbatim=
  s = s.replace(/(^|[\s(])=([^=\s](?:[^=]*[^=\s])?)=(?=[\s.,;:!?)]|$)/g, function (m, pre, body) {
    return pre + hold('<code class="org-verbatim">' + esc(body) + "</code>");
  });
  // ~code~
  s = s.replace(/(^|[\s(])~([^~\s](?:[^~]*[^~\s])?)~(?=[\s.,;:!?)]|$)/g, function (m, pre, body) {
    return pre + hold('<code class="org-code">' + esc(body) + "</code>");
  });

  // footnote references: [fn:NAME] or [fn:NAME:inline def]
  s = s.replace(/\[fn:([^\]:]+)(?::([^\]]*))?\]/g, function (_, name) {
    var id = esc(name);
    return hold(
      '<sup class="org-fnref" id="fnref-' + id + '"><a href="#fn-' + id + '">[' + id + "]</a></sup>"
    );
  });

  // links: [[target][desc]] or [[target]]
  s = s.replace(/\[\[([^\]]+?)\](?:\[([^\]]*?)\])?\]/g, function (_, target, desc) {
    var t = target.trim();
    if (IMG_RE.test(t) && !desc) {
      return hold('<img class="org-img" src="' + attr(t) + '" alt="' + attr(t) + '">');
    }
    if (IMG_RE.test(t) && desc) {
      return hold('<img class="org-img" src="' + attr(t) + '" alt="' + attr(desc) + '">');
    }
    var label = desc != null && desc !== "" ? inlineEmph(desc) : esc(t);
    return hold('<a class="org-link" href="' + attr(t) + '">' + label + "</a>");
  });

  // bare urls (not already inside a held link)
  s = s.replace(/(^|[\s(])((?:https?|mailto):[^\s)<>\]]+)/g, function (m, pre, url) {
    return pre + hold('<a class="org-link-url" href="' + attr(url) + '">' + esc(url) + "</a>");
  });

  // inline timestamps <YYYY-MM-DD ...> and [YYYY-MM-DD ...]
  s = s.replace(/[<\[](\d{4}-\d{2}-\d{2}(?:[^>\]]*)?)[>\]]/g, function (_, ts) {
    var clean = ts.trim();
    return hold('<time class="org-ts" datetime="' + attr(clean.slice(0, 10)) + '">' + esc(clean) + "</time>");
  });

  // escape what's left, then emphasis
  s = inlineEmph(s);

  // restore protected slots (loop: a slot may itself contain a placeholder)
  var guard = 0;
  while (PH_RE.test(s) && guard++ < slots.length + 2) {
    PH_RE.lastIndex = 0;
    s = s.replace(PH_RE, function (_, i) {
      return slots[+i] != null ? slots[+i] : "";
    });
  }
  PH_RE.lastIndex = 0;
  return s;
}

// emphasis on already-protected text; escapes html in the unprotected parts
function inlineEmph(text) {
  var parts = String(text).split(PH_SPLIT);
  return parts
    .map(function (part) {
      if (PH_TEST.test(part)) return part;
      var s = esc(part);
      // *bold*  /italic/  _underline_  +strike+
      s = s.replace(/(^|[\s(])\*([^*\s](?:[^*]*[^*\s])?)\*(?=[\s.,;:!?)]|$)/g, "$1<strong>$2</strong>");
      s = s.replace(/(^|[\s(])\/([^/\s](?:[^/]*[^/\s])?)\/(?=[\s.,;:!?)]|$)/g, "$1<em>$2</em>");
      s = s.replace(/(^|[\s(])_([^_\s](?:[^_]*[^_\s])?)_(?=[\s.,;:!?)]|$)/g, "$1<u>$2</u>");
      s = s.replace(/(^|[\s(])\+([^+\s](?:[^+]*[^+\s])?)\+(?=[\s.,;:!?)]|$)/g, "$1<del>$2</del>");
      return s;
    })
    .join("");
}

// ---------- metadata ----------

function parseMeta(orgText) {
  var meta = { title: "", author: "", date: "", keywords: [] };
  var lines = String(orgText == null ? "" : orgText).split(/\r?\n/);
  for (var k = 0; k < lines.length; k++) {
    var m = /^#\+(\w+):\s*(.*)$/.exec(lines[k]);
    if (!m) continue;
    var key = m[1].toLowerCase();
    var val = m[2].trim();
    if (key === "title") meta.title = val;
    else if (key === "author") meta.author = val;
    else if (key === "date") meta.date = val;
    else if (key === "keywords" || key === "tags")
      meta.keywords = val.split(/[,\s]+/).filter(Boolean);
  }
  return meta;
}

// ---------- block parser ----------

function headlineLevel(line) {
  var m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return null;
  return { stars: m[1].length, rest: m[2] };
}

function renderHeadline(stars, rest) {
  // level 1 org -> h2 (h1 reserved for title); cap at h5
  var level = Math.min(stars + 1, 5);
  var text = rest;
  var kw = "";
  var stateClass = "";

  var kwMatch = /^([A-Z][A-Z-]+)\s+/.exec(text);
  if (kwMatch) {
    var word = kwMatch[1];
    if (TODO_KEYWORDS.indexOf(word) >= 0) {
      kw = word;
      stateClass = " org-todo";
      text = text.slice(kwMatch[0].length);
    } else if (DONE_KEYWORDS.indexOf(word) >= 0) {
      kw = word;
      stateClass = " org-done";
      text = text.slice(kwMatch[0].length);
    }
  }

  // trailing :tag:tag:
  var tagsHtml = "";
  var tagMatch = /\s+(:(?:[\w@#%]+:)+)\s*$/.exec(text);
  if (tagMatch) {
    var tags = tagMatch[1].split(":").filter(Boolean);
    tagsHtml =
      " " +
      tags
        .map(function (t) {
          return '<span class="org-tag">' + esc(t) + "</span>";
        })
        .join("");
    text = text.slice(0, tagMatch.index);
  }

  var kwHtml = kw ? '<span class="org-todo-kw">' + esc(kw) + "</span> " : "";
  return (
    "<h" + level + ' class="org-h' + stateClass + '">' +
    kwHtml + inline(text.trim()) + tagsHtml +
    "</h" + level + ">"
  );
}

function renderTable(rows) {
  var parse = function (line) {
    return line
      .replace(/^\s*\|/, "")
      .replace(/\|\s*$/, "")
      .split("|")
      .map(function (c) {
        return c.trim();
      });
  };
  var isRule = function (line) {
    return /^\s*\|[-+|\s]*\|?\s*$/.test(line) && /-/.test(line);
  };

  var headerRows = [];
  var bodyRows = [];
  var sawRule = false;
  for (var r = 0; r < rows.length; r++) {
    var line = rows[r];
    if (isRule(line)) {
      if (!sawRule && bodyRows.length) {
        headerRows = bodyRows;
        bodyRows = [];
        sawRule = true;
      }
      continue;
    }
    bodyRows.push(parse(line));
  }

  var cell = function (c, tag) {
    return "<" + tag + ">" + inline(c) + "</" + tag + ">";
  };
  var html = '<table class="org-table">';
  if (headerRows.length) {
    html += "<thead>";
    for (var h = 0; h < headerRows.length; h++)
      html +=
        "<tr>" +
        headerRows[h]
          .map(function (c) {
            return cell(c, "th");
          })
          .join("") +
        "</tr>";
    html += "</thead>";
  }
  html += "<tbody>";
  for (var b = 0; b < bodyRows.length; b++)
    html +=
      "<tr>" +
      bodyRows[b]
        .map(function (c) {
          return cell(c, "td");
        })
        .join("") +
      "</tr>";
  html += "</tbody></table>";
  return html;
}

// list parsing: indentation-aware, ordered/unordered, checkboxes
function renderList(items) {
  var i = 0;
  function build(minIndent) {
    var ordered = items[i].ordered;
    var tag = ordered ? "ol" : "ul";
    var html = "<" + tag + ' class="org-list">';
    while (i < items.length && items[i].indent >= minIndent) {
      var it = items[i];
      if (it.indent > minIndent) break;
      var liClass = "org-item";
      var dataAttr = "";
      if (it.checkbox != null) {
        liClass = "org-check";
        dataAttr = ' data-checked="' + it.checkbox + '"';
      }
      var liInner = inline(it.text);
      i++;
      if (i < items.length && items[i].indent > it.indent) {
        liInner += build(items[i].indent);
      }
      html += '<li class="' + liClass + '"' + dataAttr + ">" + liInner + "</li>";
    }
    html += "</" + tag + ">";
    return html;
  }
  return build(items[0].indent);
}

function renderDrawer(name, lines) {
  var body = lines
    .map(function (l) {
      var m = /^\s*:([^:]+):\s*(.*)$/.exec(l);
      if (m)
        return (
          '<div class="org-prop"><span class="org-prop-key">' +
          esc(m[1]) +
          '</span> <span class="org-prop-val">' +
          inline(m[2]) +
          "</span></div>"
        );
      return '<div class="org-prop">' + inline(l.trim()) + "</div>";
    })
    .join("");
  return (
    '<details class="org-drawer"><summary class="org-drawer-name">' +
    esc(name) +
    "</summary>" +
    body +
    "</details>"
  );
}

// ---------- main render ----------

function render(orgText, opts) {
  opts = opts || {};
  var wantMeta = !!opts.meta;
  var header = opts.header !== false;
  var src = String(orgText == null ? "" : orgText);
  var meta = parseMeta(src);

  var body = "";
  try {
    body = renderBody(src);
  } catch (e) {
    // honor the never-throw contract: degrade whole doc to escaped paragraphs
    body = src
      .split(/\n{2,}/)
      .map(function (p) {
        return '<p class="org-raw">' + esc(p) + "</p>";
      })
      .join("\n");
  }

  var head = "";
  if (header && (meta.title || meta.author || meta.date)) {
    var m = "";
    if (meta.author) m += '<span class="org-author">' + inline(meta.author) + "</span>";
    if (meta.date) m += '<time class="org-date">' + esc(meta.date) + "</time>";
    if (meta.keywords.length)
      m +=
        '<span class="org-keywords">' +
        meta.keywords
          .map(function (k) {
            return '<span class="org-tag">' + esc(k) + "</span>";
          })
          .join("") +
        "</span>";
    head =
      '<header class="org-header">' +
      (meta.title ? '<h1 class="org-title">' + inline(meta.title) + "</h1>" : "") +
      (m ? '<div class="org-meta">' + m + "</div>" : "") +
      "</header>";
  }

  var html = '<article class="org-doc">' + head + body + "</article>";
  return wantMeta ? { html: html, meta: meta } : html;
}

function renderBody(src) {
  var lines = src.split(/\r?\n/);
  var out = [];
  var footnotes = [];
  var i = 0;
  var para = [];

  var flushPara = function () {
    if (!para.length) return;
    var text = para.join(" ").trim();
    if (text) out.push('<p class="org-p">' + inline(text) + "</p>");
    para = [];
  };

  while (i < lines.length) {
    var line = lines[i];

    // metadata keyword lines (handled separately) and comments
    if (/^#\+\w+:/.test(line) && !/^#\+begin_/i.test(line)) {
      flushPara();
      i++;
      continue;
    }
    if (/^#\s/.test(line) || line === "#") {
      i++;
      continue;
    }

    // blank line -> paragraph break
    if (/^\s*$/.test(line)) {
      flushPara();
      i++;
      continue;
    }

    // horizontal rule: 5+ dashes
    if (/^\s*-{5,}\s*$/.test(line)) {
      flushPara();
      out.push('<hr class="org-rule">');
      i++;
      continue;
    }

    // footnote definition: [fn:NAME] text...
    var fnDef = /^\[fn:([^\]:]+)\]\s*(.*)$/.exec(line);
    if (fnDef) {
      flushPara();
      var id = esc(fnDef[1]);
      var txt = fnDef[2];
      i++;
      while (i < lines.length && !/^\s*$/.test(lines[i]) && !/^\[fn:/.test(lines[i])) {
        txt += " " + lines[i];
        i++;
      }
      footnotes.push({
        id: id,
        html:
          '<li class="org-fn" id="fn-' +
          id +
          '"><a class="org-fn-back" href="#fnref-' +
          id +
          '">' +
          id +
          '</a> <span class="org-fn-body">' +
          inline(txt.trim()) +
          "</span></li>",
      });
      continue;
    }

    // headline
    var hl = headlineLevel(line);
    if (hl) {
      flushPara();
      out.push(renderHeadline(hl.stars, hl.rest));
      i++;
      continue;
    }

    // PROPERTIES / generic drawer
    var drawerOpen = /^\s*:([A-Za-z][\w-]*):\s*$/.exec(line);
    if (drawerOpen && drawerOpen[1].toUpperCase() !== "END") {
      flushPara();
      var name = drawerOpen[1];
      var drawerLines = [];
      i++;
      while (i < lines.length && !/^\s*:END:\s*$/i.test(lines[i])) {
        drawerLines.push(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // consume :END:
      out.push(renderDrawer(name, drawerLines));
      continue;
    }

    // blocks: #+begin_X ... #+end_X
    var blockOpen = /^\s*#\+begin_(\w+)\b(.*)$/i.exec(line);
    if (blockOpen) {
      flushPara();
      var kind = blockOpen[1].toLowerCase();
      var rest = blockOpen[2].trim();
      var content = [];
      i++;
      while (i < lines.length && !new RegExp("^\\s*#\\+end_" + kind + "\\b", "i").test(lines[i])) {
        content.push(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // consume end
      out.push(renderBlock(kind, rest, content));
      continue;
    }

    // table
    if (/^\s*\|/.test(line)) {
      flushPara();
      var trows = [];
      while (i < lines.length && /^\s*\|/.test(lines[i])) {
        trows.push(lines[i]);
        i++;
      }
      out.push(renderTable(trows));
      continue;
    }

    // list (unordered -/+/* or ordered N. / N))
    var listItem = matchListItem(line);
    if (listItem) {
      flushPara();
      var items = [];
      while (i < lines.length) {
        var it = matchListItem(lines[i]);
        if (it) {
          items.push(it);
          i++;
        } else if (/^\s+\S/.test(lines[i]) && items.length) {
          items[items.length - 1].text += " " + lines[i].trim();
          i++;
        } else {
          break;
        }
      }
      out.push(renderList(items));
      continue;
    }

    // default: paragraph text
    para.push(line.trim());
    i++;
  }
  flushPara();

  if (footnotes.length) {
    out.push(
      '<section class="org-footnotes"><h2 class="org-fn-title">Footnotes</h2><ol class="org-fn-list">' +
        footnotes
          .map(function (f) {
            return f.html;
          })
          .join("") +
        "</ol></section>"
    );
  }

  return out.join("\n");
}

function matchListItem(line) {
  var m = /^(\s*)([-+*]|\d+[.)])\s+(.*)$/.exec(line);
  if (!m) return null;
  var indent = m[1].length;
  var bullet = m[2];
  var ordered = /\d/.test(bullet);
  var text = m[3];
  var checkbox = null;
  var cb = /^\[([ xX-])\]\s*(.*)$/.exec(text);
  if (cb) {
    var c = cb[1];
    checkbox = c === "x" || c === "X" ? "true" : c === "-" ? "partial" : "false";
    text = cb[2];
  }
  return { indent: indent, ordered: ordered, checkbox: checkbox, text: text };
}

function renderBlock(kind, rest, content) {
  if (kind === "src") {
    var lang = (rest.split(/\s+/)[0] || "").toLowerCase();
    var code = content.map(esc).join("\n");
    var langAttr = lang ? ' data-lang="' + attr(lang) + '"' : "";
    var langClass = lang ? " language-" + attr(lang) : "";
    return (
      '<pre class="org-src"' + langAttr + '><code class="org-src-code' + langClass + '">' +
      code +
      "</code></pre>"
    );
  }
  if (kind === "example") {
    return '<pre class="org-example">' + content.map(esc).join("\n") + "</pre>";
  }
  if (kind === "quote") {
    var inner = content
      .join("\n")
      .split(/\n{2,}/)
      .map(function (p) {
        return "<p>" + inline(p.replace(/\n/g, " ").trim()) + "</p>";
      })
      .join("");
    return '<blockquote class="org-quote">' + inner + "</blockquote>";
  }
  if (kind === "verse") {
    return (
      '<p class="org-verse">' +
      content
        .map(function (l) {
          return inline(l);
        })
        .join("<br>") +
      "</p>"
    );
  }
  // unknown block -> preserve, escaped, never vanish
  return '<pre class="org-raw" data-block="' + attr(kind) + '">' + content.map(esc).join("\n") + "</pre>";
}

// ---------- exports ----------

var Orgitorial = { render: render, parseMeta: parseMeta, version: "0.1.0" };

// Browser global
if (typeof window !== "undefined") {
  window.Orgitorial = Orgitorial;
}
// CommonJS / QuickJS-with-module shim tolerance
if (typeof module !== "undefined" && module.exports) {
  module.exports = Orgitorial;
}

export { render, parseMeta };
export default Orgitorial;
