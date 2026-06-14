#!/usr/bin/env python3
"""Build /search-index.json — the static index THE search overlay (search.js)
loads. Two sources, one flat list of {title, sub, kind, url, text} records:

  learn lessons  ← learn/lms.json   → title + teaches, url /learn/<slug>
  docs pages     ← docs/site.org    → link label, url https://docs.workbooks.sh/<path>

Keep it dependency-free (stdlib only) and re-run after editing either source:
    python3 build-search-index.py

DOCS PAGES — to get the same Cmd/Ctrl-K overlay on docs.workbooks.sh, the org->HTML
publisher must inject `<script src="/search.js" defer></script>` before </body> on
every docs page (search.js self-mounts search.css + fetches /search-index.json from
the site root; both must be deployed alongside the docs). The learn pages already
include it via learn/build-lms.py's HEAD template; the public site nav can fire the
overlay anywhere by dispatching `window.dispatchEvent(new CustomEvent('wb-search-open'))`.
"""
import json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))


def learn_records():
    lms = json.load(open(os.path.join(HERE, "learn", "lms.json")))
    out = []
    for u in lms["units"]:
        for l in u["lessons"]:
            if l.get("status") not in (None, "live"):
                continue
            out.append({
                "title": l["title"],
                "sub": "Lesson · %s" % u["title"],
                "kind": "learn",
                "url": "/learn/" + l["slug"],
                # searchable body: the teaches blurb (no markup)
                "text": l.get("teaches", ""),
            })
    return out


# [[path][label]]  and  [[path]]  org links (path may be an .org file or a URL)
ORG_LINK = re.compile(r"\[\[([^\]]+?)\](?:\[([^\]]*?)\])?\]")


def docs_records():
    site = open(os.path.join(HERE, "docs", "site.org")).read()
    base = "https://docs.workbooks.sh"
    out, seen = [], set()
    current_section = ""
    for raw in site.splitlines():
        line = raw.strip()
        # a top-level heading line that is NOT itself a link = a section name
        if line.startswith("*") and "[[" not in line:
            current_section = line.lstrip("* ").strip()
            continue
        for m in ORG_LINK.finditer(raw):
            target, label = m.group(1), (m.group(2) or "").strip()
            if target.startswith("http"):
                url = target
            else:
                # foo/bar.org → /docs/foo/bar ; index.org → /docs
                path = re.sub(r"\.org$", "", target.strip())
                path = re.sub(r"(^|/)index$", "", path).strip("/")
                url = base + "/docs" + ("/" + path if path else "")
            if not label or url in seen:
                continue
            seen.add(url)
            out.append({
                "title": label,
                "sub": "Docs" + (" · " + current_section if current_section else ""),
                "kind": "docs",
                "url": url,
                "text": "",
            })
    return out


def main():
    records = learn_records() + docs_records()
    out = {"generated": True, "count": len(records), "records": records}
    dest = os.path.join(HERE, "search-index.json")
    with open(dest, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    n_learn = sum(1 for r in records if r["kind"] == "learn")
    n_docs = sum(1 for r in records if r["kind"] == "docs")
    print("search-index.json: %d records (%d learn, %d docs)" % (len(records), n_learn, n_docs))


if __name__ == "__main__":
    main()
