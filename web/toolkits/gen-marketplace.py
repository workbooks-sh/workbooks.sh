#!/usr/bin/env python3
"""
gen-marketplace.py — build the Workbooks toolkit MARKETPLACE (workbooks.sh/toolkits/).

Reads every  toolkits/<slug>/manifest.org  and emits, into  web/toolkits/ :
  1. catalog.json                — machine catalog [{slug,title,tagline,version,kind,caps[],integration?,category,logo}]
  2. index.html                  — the marketplace: hero + responsive card grid + client-side search/filter
  3. <slug>.html                 — a Zapier-style detail page per toolkit

This is the MARKETPLACE on the main site (logos, cards, per-toolkit pages),
distinct from docs.workbooks.sh. Brand = the landing page (workbooks.sh):
paper #f7f6f1, ink #121316, bloom green #13d943, Groothan headers, JetBrains
Mono body — all sans/mono, NO serif. The nav pill is mounted from /nav.js.

No third-party deps — stdlib only.  Run:  python3 web/toolkits/gen-marketplace.py
"""

import json
import os
import re
import html
from datetime import datetime, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TK_DIR = os.path.join(ROOT, "toolkits")
OUT_DIR = os.path.join(ROOT, "web", "toolkits")
RELEASES = os.path.join(TK_DIR, "releases.json")

# ── manifest parsing ────────────────────────────────────────────────────────

def read_headers(text):
    """Collect all `#+KEY: value` org keywords (last-wins, plus list for repeats)."""
    hdr = {}
    for m in re.finditer(r"^#\+([A-Z_]+):[ \t]*(.*)$", text, re.M):
        k, v = m.group(1), m.group(2).strip()
        hdr[k] = v
    return hdr


def first_prose(text):
    """The first real paragraph of body prose (skips headers, drawers, headings)."""
    lines = text.splitlines()
    buf, started = [], False
    for ln in lines:
        s = ln.strip()
        if s.startswith("#+") or s.startswith("* ") or s.startswith(":") or not s:
            if started and not s:
                break
            continue
        # skip property-drawer noise / heading stars
        if re.match(r"^\*+ ", s) or s.upper() == s and ":END:" in s:
            continue
        started = True
        buf.append(s)
        if len(buf) >= 3:
            break
    out = " ".join(buf)
    out = re.sub(r"=([^=]+)=", r"\1", out)        # org verbatim → plain
    out = re.sub(r"~([^~]+)~", r"\1", out)        # org code → plain
    out = re.sub(r"\s+", " ", out).strip()
    return out


# ── derivation: capabilities, integration, category ─────────────────────────

# external services we recognize (env-key prefix / name → display label)
INTEGRATIONS = {
    "asana": "Asana", "linear": "Linear", "brandnana": "Brandnana",
    "cloudflare": "Cloudflare", "wrangler": "Cloudflare", "railway": "Railway",
    "byod": "Postgres + Railway", "stripe": "Stripe", "slack": "Slack",
    "github": "GitHub", "fly": "Fly.io", "tauri": "Tauri", "capacitor": "Capacitor",
}

# slug → category bucket (marketplace facet). Falls back to KIND-based mapping.
KIND_CATEGORY = {
    "federation": "Integration",
    "render": "Rendering",
    "knowledge+assets": "Assets",
    "knowledge+pipeline": "Pipeline",
    "toolkit": "Capability",
}
SLUG_CATEGORY = {
    "ffmpeg": "Media", "video": "Media", "image": "Media",
    "git": "Dev tools", "toolkit-forge": "Dev tools", "sandbox": "Dev tools",
    "ctk": "Dev tools",
    "cloudflare": "Deploy", "wrangler": "Deploy", "railway": "Deploy",
    "byod": "Deploy", "publish": "Deploy", "tauri": "Deploy", "capacitor": "Deploy",
    "asana": "Integration", "linear": "Integration", "brandnana": "Integration",
    "3w": "Research", "docs": "Pipeline", "orgitorial": "Pipeline",
    "glyphs": "Assets", "icons": "Assets", "open-avatars": "Assets",
    "palette": "Design", "mono": "Design", "wavelet": "Design",
    "presentation": "Design",
    "wraith": "Dev tools", "workbooks-system": "System",
}

CAP_RULES = [
    # (regex over the manifest text, capability label)
    (r"\bsearch\b|web search|deep.?research", "web-search"),
    (r"\bfetch\b|\bread\b.*url|readability|render", "fetch"),
    (r"\bvideo\b|ffmpeg|transcode|h264|gif", "video"),
    (r"\baudio\b|\bmp3\b|\bwav\b", "audio"),
    (r"\bimage\b|\bresize\b|\bcrop\b|montage|overlay", "image"),
    (r"\bpalette\b|design token|type scale", "design-tokens"),
    (r"\bfont\b|typeface|wavelet|\bmono\b", "fonts"),
    (r"\blogo\b|icon|svg|glyph|avatar", "assets"),
    (r"\bD1\b|postgres|sqlite|\bdatabase\b|data.?source", "database"),
    (r"\bdeploy\b|wrangler|railway|fly\.io|pages|hosting", "deploy"),
    (r"\bauth\b|betterauth|session|jwt|oauth", "auth"),
    (r"\bgit\b|version control|rebase|commit", "git"),
    (r"\bdesktop\b|tauri", "desktop"),
    (r"\bmobile\b|capacitor|ios|android", "mobile"),
    (r"\bsandbox\b|wasm|isolat", "sandbox"),
    (r"\bagent\b|\bai\b|workers ai|vision", "ai"),
    (r"task|federation|issues|project", "tasks"),
    (r"\bdocs?\b|documentation|diátaxis|diataxis", "docs"),
    (r"\bbrand\b|\bad\b|creative|catalog|social", "brand"),
    (r"presentation|slides|deck", "slides"),
]


def derive_caps(text, hdr):
    caps = []
    # explicit #+CAPS: wins, comma/space separated
    if hdr.get("CAPS"):
        caps = [c.strip() for c in re.split(r"[,\s]+", hdr["CAPS"]) if c.strip()]
    low = text.lower()
    for rx, label in CAP_RULES:
        if label in caps:
            continue
        if re.search(rx, low):
            caps.append(label)
    return caps[:8]


def derive_integration(slug, hdr):
    if slug in INTEGRATIONS:
        return INTEGRATIONS[slug]
    env = (hdr.get("ENV_KEYS") or "").lower()
    for key, label in INTEGRATIONS.items():
        if key in env:
            return label
    return None


def derive_category(slug, hdr):
    if slug in SLUG_CATEGORY:
        return SLUG_CATEGORY[slug]
    return KIND_CATEGORY.get((hdr.get("KIND") or "").strip(), "Capability")


def maturity(status):
    s = (status or "").lower()
    return {
        "stable": ("Stable", "stable"),
        "beta": ("Beta", "beta"),
        "experimental": ("Experimental", "exp"),
        "exp": ("Experimental", "exp"),
        "partial": ("Partial", "exp"),
    }.get(s, ("Experimental", "exp"))


# ── catalog build ───────────────────────────────────────────────────────────

def load_releases():
    try:
        with open(RELEASES) as f:
            return json.load(f)
    except Exception:
        return {}


def build_catalog():
    releases = load_releases()
    items = []
    for name in sorted(os.listdir(TK_DIR)):
        mpath = os.path.join(TK_DIR, name, "manifest.org")
        if not os.path.isfile(mpath):
            continue
        with open(mpath, encoding="utf-8") as f:
            text = f.read()
        hdr = read_headers(text)
        slug = (hdr.get("TOOLKIT") or name).strip()
        title = slug
        tagline = hdr.get("TAGLINE", "").strip()
        version = (hdr.get("VERSION") or releases.get(slug, {}).get("version") or "0.1.0").strip()
        kind = (hdr.get("KIND") or "toolkit").strip()
        status = (hdr.get("STATUS") or "experimental").strip()
        caps = derive_caps(text, hdr)
        integration = derive_integration(slug, hdr)
        category = derive_category(slug, hdr)
        logo = f"/toolkits/logos/{slug}.svg"
        logo_exists = os.path.isfile(os.path.join(OUT_DIR, "logos", f"{slug}.svg"))
        items.append({
            "slug": slug,
            "title": title,
            "tagline": tagline,
            "version": version,
            "kind": kind,
            "status": status,
            "caps": caps,
            "integration": integration,
            "category": category,
            "logo": logo,
            "logo_exists": logo_exists,
            "cli_bin": (hdr.get("CLI_BIN") or "").strip() or None,
            "env_keys": [e for e in re.split(r"\s+", (hdr.get("ENV_KEYS") or "").strip()) if e],
            "requires": (hdr.get("REQUIRES") or "").strip() or None,
            "flow": (hdr.get("FLOW") or "").strip() or None,
            "env_note": (hdr.get("ENV_NOTE") or "").strip() or None,
            "description": first_prose(text),
            "updated": releases.get(slug, {}).get("updated"),
        })
    return items


# ── HTML shared chrome ──────────────────────────────────────────────────────

def head(title, desc, canonical, extra=""):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc)}">
<link rel="canonical" href="{canonical}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/fonts/fonts.css">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Workbooks">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(desc)}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="https://workbooks.sh/og.jpg">
<meta name="twitter:card" content="summary_large_image">
{extra}
<style>
{BASE_CSS}
</style>
</head>"""


NAV = '<div id="site-nav"></div><script src="/nav.js?v=13"></script>'

BASE_CSS = """
@font-face{ font-family:"Groothan"; src:url("/fonts/GroothanMixed-Regular.woff2") format("woff2"),
  url("/fonts/GroothanMixed-Regular.woff") format("woff"); font-weight:400; font-display:swap; }
:root{
  --paper:#f7f6f1; --card:#fff; --ink:#121316; --bloom:#13d943; --bloomd:#149157;
  --dim:#6a6f68; --line:rgba(18,19,22,.12);
  --display:"Groothan","Arial Black",sans-serif;
  --mono:"JetBrains Mono",ui-monospace,monospace;
}
*{ box-sizing:border-box; margin:0; }
html{ scrollbar-width:thin; scrollbar-color:#565b54 transparent; }
body{ background:var(--paper); color:var(--ink); font-family:var(--mono); line-height:1.65;
  -webkit-font-smoothing:antialiased; }
a{ color:inherit; }
.wrap{ max-width:1280px; margin:0 auto; padding:0 28px; }

/* ── hero ── */
.hero{ padding:170px 28px 50px; max-width:1280px; margin:0 auto; }
.hero .kick{ font:700 11px var(--mono); letter-spacing:.32em; text-transform:uppercase;
  color:var(--bloomd); margin-bottom:18px; }
.hero h1{ font-family:var(--display); font-weight:400; font-size:clamp(40px,6vw,78px);
  line-height:.98; letter-spacing:-.01em; }
.hero h1 em{ font-style:normal; color:var(--bloomd); }
.hero p{ margin-top:20px; max-width:62ch; font-size:14px; color:var(--dim); line-height:1.8; }
.hero .stat{ margin-top:24px; display:flex; gap:26px; flex-wrap:wrap;
  font:700 11px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--ink); }
.hero .stat b{ color:var(--bloomd); }

/* ── controls ── */
.controls{ position:sticky; top:0; z-index:5; background:var(--paper);
  border-bottom:2px solid var(--ink); padding:16px 0; }
.controls .wrap{ display:flex; gap:14px; align-items:center; flex-wrap:wrap; }
.search{ flex:1 1 260px; display:flex; align-items:center; gap:10px; background:var(--card);
  border:2px solid var(--ink); border-radius:10px; padding:10px 14px; box-shadow:3px 3px 0 var(--ink); }
.search svg{ width:16px; height:16px; flex:0 0 auto; color:var(--dim); }
.search input{ border:0; outline:0; background:none; font:500 13px var(--mono); color:var(--ink);
  width:100%; }
.search input::placeholder{ color:var(--dim); }
.facets{ display:flex; gap:8px; flex-wrap:wrap; }
.chip{ font:700 10.5px var(--mono); letter-spacing:.04em; text-transform:uppercase;
  border:1.5px solid var(--ink); background:var(--card); color:var(--ink); border-radius:999px;
  padding:7px 13px; cursor:pointer; transition:transform .12s ease, background .12s ease; }
.chip:hover{ transform:translateY(-1px); }
.chip.on{ background:var(--bloom); border-color:var(--ink); }
.facet-group{ display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
.facet-group .lbl{ font:700 9px var(--mono); letter-spacing:.18em; text-transform:uppercase;
  color:var(--dim); margin-right:2px; }

/* ── grid ── */
.grid{ display:grid; grid-template-columns:repeat(auto-fill,minmax(300px,1fr)); gap:18px;
  padding:34px 0 90px; }
.count{ font:700 11px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim);
  padding-top:24px; }
.card{ display:flex; flex-direction:column; background:var(--card); border:2px solid var(--ink);
  border-radius:14px; padding:20px; text-decoration:none; box-shadow:4px 4px 0 var(--ink);
  transition:transform .14s ease, box-shadow .14s ease; }
.card:hover{ transform:translate(-2px,-2px); box-shadow:7px 7px 0 var(--bloom); }
.card .top{ display:flex; align-items:center; gap:13px; margin-bottom:13px; }
.logo{ width:46px; height:46px; border-radius:11px; flex:0 0 auto; display:flex;
  align-items:center; justify-content:center; overflow:hidden; border:1.5px solid var(--line);
  background:var(--paper); }
.logo img{ width:30px; height:30px; object-fit:contain; }
.logo .mono{ font-family:var(--display); font-size:22px; color:var(--ink); }
.card h3{ font-family:var(--display); font-weight:400; font-size:23px; line-height:1; }
.card .ver{ font:700 9.5px var(--mono); letter-spacing:.05em; color:var(--dim); margin-top:5px; }
.card .tag{ font-size:12px; color:var(--dim); line-height:1.6; flex:1;
  display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
.card .chips{ display:flex; gap:6px; flex-wrap:wrap; margin-top:14px; }
.cc{ font:700 9px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--ink);
  background:var(--paper); border:1px solid var(--line); border-radius:6px; padding:4px 7px; }
.cc.cat{ background:var(--bloom); border-color:var(--ink); }
.badge-m{ font:700 9px var(--mono); letter-spacing:.06em; text-transform:uppercase;
  padding:3px 8px; border-radius:6px; border:1.5px solid var(--ink); }
.m-stable{ background:#aee5c2; } .m-beta{ background:#a8d4f0; } .m-exp{ background:#f2ddb0; }
.empty{ padding:70px 0; text-align:center; color:var(--dim); font-size:13px; }

/* ── detail ── */
.detail{ max-width:1080px; margin:0 auto; padding:150px 28px 90px; }
.crumb{ font:700 11px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim);
  margin-bottom:26px; }
.crumb a{ text-decoration:none; color:var(--dim); }
.crumb a:hover{ color:var(--bloomd); }
.dhead{ display:flex; gap:22px; align-items:flex-start; flex-wrap:wrap; }
.dhead .logo{ width:78px; height:78px; border-radius:18px; }
.dhead .logo img{ width:50px; height:50px; }
.dhead .logo .mono{ font-size:38px; }
.dhead h1{ font-family:var(--display); font-weight:400; font-size:clamp(38px,5vw,60px); line-height:.96; }
.dhead .meta{ display:flex; gap:10px; align-items:center; margin-top:12px; flex-wrap:wrap; }
.dhead .lede{ margin-top:18px; font-size:15px; line-height:1.8; color:var(--ink); max-width:70ch; }
.cols{ display:grid; grid-template-columns:1fr 320px; gap:48px; margin-top:48px; align-items:start; }
.sec{ margin-bottom:42px; }
.sec h2{ font-family:var(--display); font-weight:400; font-size:28px; margin-bottom:16px; }
.sec p{ font-size:14px; line-height:1.85; color:var(--ink); margin-bottom:14px; }
.sec .dim{ color:var(--dim); }
.caplist{ display:flex; gap:9px; flex-wrap:wrap; }
.caplist .cc{ font-size:11px; padding:7px 11px; }
.install{ background:var(--ink); color:var(--paper); border-radius:12px; padding:18px 20px;
  font:500 13px var(--mono); display:flex; align-items:center; justify-content:space-between; gap:14px; }
.install code{ color:var(--bloom); }
.install button{ font:700 10px var(--mono); letter-spacing:.06em; text-transform:uppercase;
  background:var(--paper); color:var(--ink); border:0; border-radius:7px; padding:8px 12px; cursor:pointer; }
.aside{ position:sticky; top:120px; }
.box{ background:var(--card); border:2px solid var(--ink); border-radius:14px;
  box-shadow:4px 4px 0 var(--ink); padding:20px; margin-bottom:20px; }
.box h4{ font:700 10px var(--mono); letter-spacing:.18em; text-transform:uppercase;
  color:var(--dim); margin-bottom:12px; }
.box .kv{ display:flex; justify-content:space-between; gap:12px; font-size:12px; padding:7px 0;
  border-bottom:1px solid var(--line); }
.box .kv:last-child{ border-bottom:0; }
.box .kv b{ font-weight:700; }
.related{ display:flex; flex-direction:column; gap:10px; }
.related a{ display:flex; align-items:center; gap:11px; text-decoration:none; padding:8px;
  border-radius:9px; }
.related a:hover{ background:var(--paper); }
.related .logo{ width:34px; height:34px; border-radius:9px; }
.related .logo img{ width:22px; height:22px; }
.related .logo .mono{ font-size:17px; }
.related b{ font:700 12px var(--mono); }
.related small{ display:block; font:400 10px var(--mono); color:var(--dim); }
.foot{ border-top:2px solid var(--ink); padding:40px 28px; text-align:center;
  font:500 11px var(--mono); letter-spacing:.04em; color:var(--dim); }
.foot a{ color:var(--bloomd); text-decoration:none; }
@media (max-width:860px){
  .cols{ grid-template-columns:1fr; }
  .aside{ position:static; }
  .controls{ position:static; }
}
"""


def logo_tile(item, cls=""):
    """Render a logo <img> with monogram fallback baked in (JS-free)."""
    slug = item["slug"]
    mono = html.escape(slug[:1].upper())
    if item.get("logo_exists"):
        return (f'<span class="logo {cls}"><img src="{item["logo"]}" alt="{html.escape(slug)} logo" '
                f'onerror="this.replaceWith(Object.assign(document.createElement(\'span\'),'
                f'{{className:\'mono\',textContent:\'{mono}\'}}))"></span>')
    return f'<span class="logo {cls}"><span class="mono">{mono}</span></span>'


# ── index.html ──────────────────────────────────────────────────────────────

def render_index(items):
    cats = sorted({i["category"] for i in items})
    all_caps = sorted({c for i in items for c in i["caps"]})
    integrations = sorted({i["integration"] for i in items if i["integration"]})

    cards = []
    for i in items:
        chips = "".join(f'<span class="cc">{html.escape(c)}</span>' for c in i["caps"][:4])
        m_label, m_cls = maturity(i["status"])
        searchblob = " ".join([
            i["slug"], i["title"], i["tagline"], i["category"],
            i["integration"] or "", " ".join(i["caps"]),
        ]).lower()
        cards.append(f"""
    <a class="card" href="/toolkits/{i['slug']}.html"
       data-blob="{html.escape(searchblob)}"
       data-cat="{html.escape(i['category'])}"
       data-int="{html.escape(i['integration'] or '')}"
       data-caps="{html.escape(' '.join(i['caps']))}">
      <div class="top">
        {logo_tile(i)}
        <div>
          <h3>{html.escape(i['title'])}</h3>
          <div class="ver">v{html.escape(i['version'])}</div>
        </div>
        <span class="badge-m m-{m_cls}" style="margin-left:auto">{m_label}</span>
      </div>
      <div class="tag">{html.escape(i['tagline'] or i['description'])}</div>
      <div class="chips"><span class="cc cat">{html.escape(i['category'])}</span>{chips}</div>
    </a>""")

    cap_chips = "".join(
        f'<button class="chip" data-fcap="{html.escape(c)}">{html.escape(c)}</button>'
        for c in all_caps)
    cat_chips = "".join(
        f'<button class="chip" data-fcat="{html.escape(c)}">{html.escape(c)}</button>'
        for c in cats)

    extra = '<script type="application/ld+json">' + json.dumps({
        "@context": "https://schema.org", "@type": "CollectionPage",
        "name": "Toolkit Marketplace — Workbooks",
        "description": "The marketplace of capabilities and integrations any Workbooks workbook or agent can install.",
        "url": "https://workbooks.sh/toolkits/",
    }) + "</script>"

    body = f"""<body>
{NAV}
<section class="hero">
  <div class="kick">the marketplace ■ {len(items)} toolkits</div>
  <h1>Every capability a workbook<br>can <em>install.</em></h1>
  <p>Toolkits are the powers a workbook (or its agent) reaches for — sandboxed-WASM
  capabilities and live service integrations alike. Add one with <code>wbx</code>,
  and it's wired into the workbook's Dock. Search the catalog, filter by capability
  or category, open any one for the full write-up.</p>
  <div class="stat">
    <span><b>{len(items)}</b> toolkits</span>
    <span><b>{len(all_caps)}</b> capabilities</span>
    <span><b>{len(integrations)}</b> integrations</span>
  </div>
</section>

<div class="controls">
  <div class="wrap">
    <label class="search">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="7"/><path d="M21 21l-5.2-5.2"/></svg>
      <input id="q" type="search" placeholder="Search toolkits, capabilities, integrations…" autocomplete="off">
    </label>
    <div class="facet-group"><span class="lbl">Category</span>{cat_chips}</div>
    <div class="facet-group"><span class="lbl">Capability</span>{cap_chips}</div>
  </div>
</div>

<div class="wrap">
  <div class="count" id="count"></div>
  <div class="grid" id="grid">{''.join(cards)}</div>
  <div class="empty" id="empty" style="display:none">No toolkits match — clear a filter.</div>
</div>

<div class="foot">
  Open source · forever — <a href="https://github.com/workbooks-sh/toolkits">github.com/workbooks-sh/toolkits</a>
  · <a href="https://docs.workbooks.sh/">read the docs</a>
</div>

<script>
(function(){{
  var q=document.getElementById('q'), grid=document.getElementById('grid');
  var cards=[].slice.call(grid.querySelectorAll('.card'));
  var count=document.getElementById('count'), empty=document.getElementById('empty');
  var fcat=new Set(), fcap=new Set();

  function apply(){{
    var term=(q.value||'').trim().toLowerCase();
    var shown=0;
    cards.forEach(function(c){{
      var blob=c.dataset.blob;
      var okTerm=!term || blob.indexOf(term)>=0;
      var okCat=!fcat.size || fcat.has(c.dataset.cat);
      var caps=c.dataset.caps.split(' ');
      var okCap=!fcap.size || caps.some(function(x){{return fcap.has(x);}});
      var ok=okTerm && okCat && okCap;
      c.style.display=ok?'':'none';
      if(ok) shown++;
    }});
    count.textContent=shown+' of '+cards.length+' toolkits';
    empty.style.display=shown?'none':'block';
  }}
  q.addEventListener('input', apply);
  document.querySelectorAll('[data-fcat]').forEach(function(b){{
    b.addEventListener('click', function(){{
      var v=b.dataset.fcat;
      if(fcat.has(v)){{fcat.delete(v); b.classList.remove('on');}} else {{fcat.add(v); b.classList.add('on');}}
      apply();
    }});
  }});
  document.querySelectorAll('[data-fcap]').forEach(function(b){{
    b.addEventListener('click', function(){{
      var v=b.dataset.fcap;
      if(fcap.has(v)){{fcap.delete(v); b.classList.remove('on');}} else {{fcap.add(v); b.classList.add('on');}}
      apply();
    }});
  }});
  // deep-link: ?cap=foo or ?cat=Bar
  var p=new URLSearchParams(location.search);
  if(p.get('cat')){{ var bb=document.querySelector('[data-fcat="'+p.get('cat')+'"]'); if(bb) bb.click(); }}
  if(p.get('cap')){{ var bc=document.querySelector('[data-fcap="'+p.get('cap')+'"]'); if(bc) bc.click(); }}
  apply();
}})();
</script>
</body>
</html>"""
    return head(
        "Toolkit Marketplace — Workbooks",
        "The marketplace of capabilities and integrations any Workbooks workbook or agent can install — search and filter by capability, category, and integration.",
        "https://workbooks.sh/toolkits/", extra) + "\n" + body


# ── detail pages ────────────────────────────────────────────────────────────

def render_detail(item, all_items):
    i = item
    m_label, m_cls = maturity(i["status"])
    # related: same category (excluding self), up to 4
    related = [x for x in all_items if x["category"] == i["category"] and x["slug"] != i["slug"]][:4]
    if len(related) < 3:
        for x in all_items:
            if x["slug"] != i["slug"] and x not in related:
                related.append(x)
            if len(related) >= 4:
                break

    caps_html = "".join(f'<span class="cc">{html.escape(c)}</span>' for c in i["caps"]) or \
        '<span class="dim">general capability</span>'

    add_cmd = f"wbx toolkit add {i['slug']}"

    # integration write-up
    if i["integration"]:
        integ = (f"<p><b>{html.escape(i['integration'])}.</b> This toolkit connects a workbook to "
                 f"{html.escape(i['integration'])}. ")
        if i["env_keys"]:
            integ += (f"It reads its credential from the environment "
                      f"(<code>{html.escape(', '.join(i['env_keys']))}</code>) — toolkits never store keys; "
                      f"the host injects them at run time, scoped to the workbook's trust context. ")
        if i["env_note"]:
            integ += html.escape(i["env_note"])
        integ += "</p>"
    else:
        integ = ("<p>This is a <b>self-contained capability</b> — no external account or key required. "
                 "It runs inside the workbook's sandbox and is reachable through the Dock the moment it's added.</p>")
        if i["requires"]:
            integ += f"<p class=\"dim\">Requires: <code>{html.escape(i['requires'])}</code></p>"

    flow_html = ""
    if i["flow"]:
        flow_html = f"""
    <div class="sec">
      <h2>The flow</h2>
      <p class="dim">{html.escape(i['flow'])}</p>
    </div>"""

    related_html = "".join(f"""
      <a href="/toolkits/{r['slug']}.html">
        {logo_tile(r)}
        <span><b>{html.escape(r['title'])}</b><small>{html.escape(r['category'])} · v{html.escape(r['version'])}</small></span>
      </a>""" for r in related)

    kv = [("Version", "v" + i["version"]), ("Kind", i["kind"]), ("Category", i["category"]),
          ("Maturity", m_label)]
    if i["cli_bin"]:
        kv.append(("CLI", i["cli_bin"]))
    if i["integration"]:
        kv.append(("Integration", i["integration"]))
    if i["updated"]:
        kv.append(("Updated", i["updated"]))
    kv_html = "".join(f'<div class="kv"><span class="dim">{html.escape(k)}</span><b>{html.escape(str(v))}</b></div>'
                      for k, v in kv)

    extra = '<script type="application/ld+json">' + json.dumps({
        "@context": "https://schema.org", "@type": "SoftwareApplication",
        "name": i["title"] + " — Workbooks toolkit",
        "applicationCategory": "DeveloperApplication",
        "softwareVersion": i["version"],
        "description": i["tagline"] or i["description"],
        "url": f"https://workbooks.sh/toolkits/{i['slug']}.html",
        "isPartOf": {"@type": "WebSite", "name": "Workbooks", "url": "https://workbooks.sh/"},
    }) + "</script>"

    body = f"""<body>
{NAV}
<main class="detail">
  <div class="crumb"><a href="/toolkits/">Marketplace</a> / {html.escape(i['title'])}</div>

  <div class="dhead">
    {logo_tile(i)}
    <div>
      <h1>{html.escape(i['title'])}</h1>
      <div class="meta">
        <span class="badge-m m-{m_cls}">{m_label}</span>
        <span class="cc cat">{html.escape(i['category'])}</span>
        <span class="cc">v{html.escape(i['version'])}</span>
      </div>
      <p class="lede">{html.escape(i['tagline'] or i['description'])}</p>
    </div>
  </div>

  <div class="cols">
    <div>
      <div class="sec">
        <h2>What it does</h2>
        <p>{html.escape(i['description'] or i['tagline'])}</p>
      </div>

      <div class="sec">
        <h2>Capabilities it grants</h2>
        <div class="caplist">{caps_html}</div>
      </div>

      <div class="sec">
        <h2>Add it to a workbook</h2>
        <div class="install">
          <span>$ <code>{html.escape(add_cmd)}</code></span>
          <button data-copy="{html.escape(add_cmd)}">Copy</button>
        </div>
        <p class="dim" style="margin-top:14px">Once added, the toolkit is wired into the workbook's Dock —
        the agent reaches its verbs by name, the host brokers any capability it needs.
        <a href="https://docs.workbooks.sh/toolkits/{html.escape(i['slug'])}" style="color:var(--bloomd)">Read the docs →</a></p>
      </div>

      <div class="sec">
        <h2>Integration</h2>
        {integ}
      </div>
      {flow_html}
    </div>

    <aside class="aside">
      <div class="box">
        <h4>At a glance</h4>
        {kv_html}
      </div>
      <div class="box">
        <h4>Related toolkits</h4>
        <div class="related">{related_html}</div>
      </div>
    </aside>
  </div>
</main>

<div class="foot">
  Open source · forever — <a href="https://github.com/workbooks-sh/toolkits">github.com/workbooks-sh/toolkits</a>
  · <a href="/toolkits/">back to the marketplace</a>
</div>

<script>
document.querySelectorAll('button[data-copy]').forEach(function(b){{
  b.addEventListener('click', async function(){{
    try{{ await navigator.clipboard.writeText(b.dataset.copy); }}catch(e){{}}
    var t=b.textContent; b.textContent='Copied ✓';
    setTimeout(function(){{ b.textContent=t; }}, 1400);
  }});
}});
</script>
</body>
</html>"""
    return head(
        f"{i['title']} — Workbooks toolkit",
        (i["tagline"] or i["description"])[:300],
        f"https://workbooks.sh/toolkits/{i['slug']}.html", extra) + "\n" + body


# ── main ────────────────────────────────────────────────────────────────────

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    items = build_catalog()

    # 1. catalog.json (public shape — drop internal-only fields)
    public = [{k: v for k, v in i.items() if k != "logo_exists"} for i in items]
    with open(os.path.join(OUT_DIR, "catalog.json"), "w", encoding="utf-8") as f:
        json.dump(public, f, indent=2)

    # 2. index.html
    with open(os.path.join(OUT_DIR, "index.html"), "w", encoding="utf-8") as f:
        f.write(render_index(items))

    # 3. <slug>.html
    for i in items:
        with open(os.path.join(OUT_DIR, f"{i['slug']}.html"), "w", encoding="utf-8") as f:
            f.write(render_detail(i, items))

    print(f"catalog.json: {len(items)} toolkits")
    print(f"index.html: 1")
    print(f"detail pages: {len(items)}")
    print("generated:", datetime.now(timezone.utc).isoformat())


if __name__ == "__main__":
    main()
