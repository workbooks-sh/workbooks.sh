#!/usr/bin/env python3
"""Site-wide discoverability — the ONE source of truth for the crawl surface.

Regenerates, from the real content trees (never a hand-kept list):

  web/sitemap.xml        root + every /learn/<slug> (from learn/lms.json)
                         + every docs page (docs.workbooks.sh, from docs/dist)
                         + /toolkits + /blog when those routes actually exist.
  web/llms.txt           root LLM index → learn + docs + toolkits, one-liners.
  web/learn/llms.txt     the learning-center index (from lms.json).

Run after editing lms.json or rebuilding the docs. Idempotent.

Canonical-URL rule (matches _worker.js + the built pages):
  learn lessons live at https://workbooks.sh/learn/<slug>  (clean, no .html)
  docs pages   live at https://docs.workbooks.sh/<path>    (clean, no .html)
"""
import json, os, datetime, xml.sax.saxutils as sx

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = "https://workbooks.sh"
DOCS = "https://docs.workbooks.sh"
TODAY = datetime.date.today().isoformat()


def lastmod(path):
    """File mtime as YYYY-MM-DD, or today if the file is missing."""
    try:
        return datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()
    except OSError:
        return TODAY


# ── learn: lms.json is the curriculum truth ────────────────────────────────
lms = json.load(open(os.path.join(HERE, "learn", "lms.json")))
LESSONS = [l for u in lms["units"] for l in u["lessons"]]


def docs_pages():
    """Every built docs page under docs/dist as (clean-url, lastmod). index.html
    at any level collapses to its directory URL; everything else drops .html."""
    root = os.path.join(HERE, "docs", "dist")
    out = []
    if not os.path.isdir(root):
        return out
    for dirpath, _dirs, files in os.walk(root):
        for f in sorted(files):
            if not f.endswith(".html"):
                continue
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if rel == "index.html":
                url = DOCS + "/"
            elif rel.endswith("/index.html"):
                url = DOCS + "/" + rel[: -len("/index.html")]
            else:
                url = DOCS + "/" + rel[: -len(".html")]
            out.append((url, lastmod(full)))
    return sorted(set(out))


def extra_routes():
    """/toolkits and /blog ship in the sitemap only once they are real routes
    (a dir with index.html, or a top-level <name>.html) — never list a 404."""
    out = []
    for name in ("toolkits", "blog"):
        idx = os.path.join(HERE, name, "index.html")
        flat = os.path.join(HERE, name + ".html")
        target = idx if os.path.isfile(idx) else (flat if os.path.isfile(flat) else None)
        if target:
            out.append((SITE + "/" + name, lastmod(target)))
    return out


# ── sitemap.xml ────────────────────────────────────────────────────────────
def build_sitemap():
    entries = [(SITE + "/", lastmod(os.path.join(HERE, "index.html"))),
               (SITE + "/learn", lastmod(os.path.join(HERE, "learn", "index.html")))]
    for l in LESSONS:
        f = os.path.join(HERE, "learn", l["slug"] + ".html")
        entries.append((SITE + "/learn/" + l["slug"], lastmod(f)))
    entries += extra_routes()
    entries += docs_pages()

    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for loc, lm in entries:
        lines.append("  <url><loc>%s</loc><lastmod>%s</lastmod></url>" % (sx.escape(loc), lm))
    lines.append("</urlset>")
    lines.append("")
    open(os.path.join(HERE, "sitemap.xml"), "w").write("\n".join(lines))
    return len(entries)


# ── llms.txt (root) ────────────────────────────────────────────────────────
ROOT_LLMS = """# Workbooks

> Workbooks is a software ecosystem where people and AI build together — and what
> they build runs anywhere, stays connected, and keeps getting better. The core
> unit is a workbook: a single HTML file that carries a whole piece of software
> (interface, code, data, history) and opens anywhere a browser does. The Nexus
> is the engine you own that runs workbooks (laptop or cloud) and makes them
> isolated, stateful, and agentic. Toolkits are real programs compiled to
> WebAssembly wrapped in readable manuals that teach people and agents alike.

The CLI is `wbx` (installed via https://workbooks.sh/install.sh). With a coding
agent, install the skills: `npx skills add workbooks-sh/workbooks.sh`.

## Learn
The Learning Center teaches Workbooks from zero — plain-language lessons, no
technical background needed. Full index: https://workbooks.sh/learn/llms.txt
{learn}

## Docs
Reference and guides at https://docs.workbooks.sh — full index:
https://docs.workbooks.sh/llms.txt
{docs}

## Try
- [hello-workbook.html](https://workbooks.sh/learn/hello-workbook.html): a real workbook that explains itself — live WebAssembly inside
- [Source](https://github.com/workbooks-sh/workbooks.sh): Apache-2.0, open forever
"""

# A short, hand-curated set of the most useful entry doors (one line each). These
# are the doors an LLM should walk through first; the full crawl is the sitemap.
DOCS_HIGHLIGHTS = [
    ("https://docs.workbooks.sh/start/install", "Install the wbx CLI and the engine"),
    ("https://docs.workbooks.sh/start/your-first-workbook", "Direct an agent to build your first workbook"),
    ("https://docs.workbooks.sh/concepts/what-is-a-toolkit", "What a toolkit is — wasm program + readable manual"),
    ("https://docs.workbooks.sh/concepts/the-dock", "The Dock & capabilities — the host membrane"),
    ("https://docs.workbooks.sh/reference/cli", "wbx CLI — every verb, mode, and flag"),
    ("https://docs.workbooks.sh/deploy/cloud", "Deploy a workbook to the cloud"),
    ("https://docs.workbooks.sh/maturity", "Capability matrix — the honest 'what works?' answer"),
]


def build_root_llms():
    learn = "\n".join(
        "- [%s](%s/learn/%s): %s" % (l["title"], SITE, l["slug"], (l.get("teaches", "") or "").split(".")[0])
        for l in LESSONS[:8])
    docs = "\n".join("- [%s](%s): %s" % (url.rsplit("/", 1)[-1] or "overview", url, desc)
                     for url, desc in DOCS_HIGHLIGHTS)
    open(os.path.join(HERE, "llms.txt"), "w").write(ROOT_LLMS.format(learn=learn, docs=docs))


# ── learn/llms.txt ─────────────────────────────────────────────────────────
def build_learn_llms():
    out = ["# Workbooks — Learning Center",
           "",
           "> Learn Workbooks from zero — %d plain-language lessons, no technical" % len(LESSONS),
           "> background needed. A graduated path for non-technical people to direct an",
           "> AI agent to build real software, safely. Lessons live at",
           "> https://workbooks.sh/learn/<slug> (clean URLs).",
           ""]
    for u in lms["units"]:
        out.append("## Unit %d — %s" % (u["n"], u["title"]))
        if u.get("dek"):
            out.append("%s" % u["dek"])
        for l in u["lessons"]:
            one = (l.get("teaches", "") or "").split(".")[0].strip()
            out.append("- [%s](%s/learn/%s): %s" % (l["title"], SITE, l["slug"], one))
        out.append("")
    open(os.path.join(HERE, "learn", "llms.txt"), "w").write("\n".join(out))


# ── robots.txt ─────────────────────────────────────────────────────────────
ROBOTS = """User-agent: *
Allow: /

Sitemap: https://workbooks.sh/sitemap.xml
"""


def build_robots():
    open(os.path.join(HERE, "robots.txt"), "w").write(ROBOTS)


if __name__ == "__main__":
    n = build_sitemap()
    build_root_llms()
    build_learn_llms()
    build_robots()
    print("SEO built: sitemap.xml (%d urls), llms.txt, learn/llms.txt, robots.txt" % n)
