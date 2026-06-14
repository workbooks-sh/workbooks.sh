#!/usr/bin/env python3
"""Build the Learning Center — a WIDE, dashboard-style course app (not a narrow
column). Generates from lms.json + content/<slug>.html:
  /learn/index.html     the course dashboard — full-width: curriculum rail +
                        a progress/continue band + a grid of unit cards.
  /learn/<slug>.html    the lesson player — three panes: curriculum · reading ·
                        course controls (audio, position, prev/next, complete).
Progress lives in the browser (localStorage). Re-run after edits.
"""
import json, os, html, re

HERE = os.path.dirname(os.path.abspath(__file__))
lms = json.load(open(os.path.join(HERE, "lms.json")))
units = lms["units"]

flat = []
for u in units:
    for l in u["lessons"]:
        flat.append({**l, "unit": u["n"], "unit_title": u["title"]})
for i, l in enumerate(flat):
    l["i"] = i
    l["prev"] = flat[i-1] if i > 0 else None
    l["next"] = flat[i+1] if i < len(flat)-1 else None
TOTAL = len(flat)
LIVE = sum(1 for l in flat if l["status"] == "live")

QUIZ = json.load(open(os.path.join(HERE, "quizzes.json")))

cat = json.load(open(os.path.join(HERE, "lessons.json")))
doc_title = {}
for t in cat["tiers"]:
    for cl in t["lessons"]:
        doc_title[cl["slug"]] = cl.get("title", cl["slug"])
        for s in cl.get("sublessons", []):
            doc_title[s["slug"]] = s.get("title", s["slug"])

# quiz payload for the browser: questions + the titles the modal header needs.
# Serialized once and "</" escaped so it can't break out of the inline <script>.
QUIZ_PAYLOAD = {
    "lessons": QUIZ.get("lessons", {}),
    "units": QUIZ.get("units", {}),
    "unitTitles": {str(u["n"]): u["title"] for u in units},
    "lessonTitles": {l["slug"]: l["title"] for l in flat},
}
QUIZ_JSON = json.dumps(QUIZ_PAYLOAD, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")

def esc(s): return html.escape(s or "")

# Per-unit pastel color map — light pastel (--u) + a deep readable companion (--ud).
# Adjacent units are visibly different. Deep reads on white; light pastel reads on dark.
UNIT_COLORS = {
    1: ("#a8d4f0", "#2f6fa8"),  # blue
    2: ("#aee5c2", "#2f8f5a"),  # green
    3: ("#f3c5a3", "#b5662a"),  # orange
    4: ("#d9c5f0", "#6b4ba8"),  # purple
    5: ("#b8e0e8", "#2f8290"),  # cyan
    6: ("#f0b8b8", "#b04a4a"),  # pink
    7: ("#f2ddb0", "#9a7d1f"),  # amber
    8: ("#a8d4f0", "#2f6fa8"),  # blue
    9: ("#d9c5f0", "#6b4ba8"),  # purple
}
def unit_color(n):
    return UNIT_COLORS.get(n, ("#a8d4f0", "#2f6fa8"))

SITE = "https://workbooks.sh"
PROVIDER = {"@type": "Organization", "name": "Workbooks", "url": SITE}

def jsonld_tag(obj):
    """Render a schema.org JSON-LD <script>. ensure_ascii keeps it byte-safe; the
    closing-tag escape guards against any '</script>' slipping out of a string."""
    payload = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    return '<script type="application/ld+json">%s</script>' % payload

def lesson_jsonld(l):
    """LearningResource per lesson, tied to the parent Course via isPartOf."""
    return jsonld_tag({
        "@context": "https://schema.org",
        "@type": "LearningResource",
        "name": l["title"],
        "description": l.get("teaches", ""),
        "url": SITE + "/learn/" + l["slug"],
        "inLanguage": "en",
        "learningResourceType": "lesson",
        "educationalLevel": "beginner",
        "timeRequired": mins_to_iso(l.get("mins", "")),
        "isPartOf": {"@type": "Course", "name": "Workbooks Learning Center", "url": SITE + "/learn"},
        "provider": PROVIDER,
        "position": l["i"] + 1,
    })

def course_jsonld():
    """Course for the Learning Center index, with the full lesson list as a
    syllabus (ItemList of Course instances per Google's Course carousel guidance)."""
    items = [{
        "@type": "ListItem", "position": x["i"] + 1,
        "item": {"@type": "Course", "name": x["title"],
                 "url": SITE + "/learn/" + x["slug"],
                 "description": x.get("teaches", "")}
    } for x in flat]
    return jsonld_tag({
        "@context": "https://schema.org",
        "@type": "Course",
        "name": "Workbooks Learning Center",
        "description": "Learn Workbooks from zero — %d plain-language lessons, no technical background needed." % TOTAL,
        "url": SITE + "/learn",
        "inLanguage": "en",
        "provider": PROVIDER,
        "hasCourseInstance": {
            "@type": "CourseInstance",
            "courseMode": "online",
            "courseWorkload": "PT4H",
        },
        "syllabusSections": {"@type": "ItemList", "numberOfItems": TOTAL, "itemListElement": items},
    })

def mins_to_iso(mins):
    """'8 min' -> ISO-8601 duration 'PT8M'. Empty/unparseable -> '' (omitted)."""
    m = re.search(r"\d+", mins or "")
    return "PT%sM" % m.group(0) if m else ""

# set once the retrofuturism hype reel exists (Higgsfield); None = no splash video yet
HYPE_VIDEO = None   # video removed from production — lessons-only learning center
HYPE_POSTER = None
PLAY_SVG = '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>'

def vplayer_html(src, poster=""):
    p = ' poster="%s"' % esc(poster) if poster else ""
    return ('<div class="vplayer"><video preload="metadata" playsinline%s>'
            '<source src="%s" type="video/mp4"></video>'
            '<button class="vplay" aria-label="Play">%s</button>'
            '<div class="vbar"><i></i></div></div>' % (p, esc(src), PLAY_SVG))

WORDMARK = ('<svg viewBox="0 0 113.444 65.6" fill="currentColor" aria-hidden="true">'
  '<path d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308c0.291 9.772-0.064 19.654 0.223 29.43'
  '0.025 0.83 0.409 1.404 0.929 2.005 5.717 1.721 18.361-17.898 24.53-20.003 2.986 0.604 9.166 8.258 11.352 10.717'
  '-3.543 5.96-19 18.234-20.891 22.546 0.018 1.284 0.068 1.322 0.775 2.439 1.55 1.195 26.095 0.545 30.976 1.022'
  '0.437 5.52 0.298 11.4 0.258 16.964-11.721 0.02-26.712 1.352-36.918-3.738-8.424-4.163-14.823-11.531-17.769-20.452'
  '-0.765-2.653-1.317-5.088-1.924-7.771-1.181 5.233-2.103 9.52-4.859 14.238-12.117 20.736-31.693 17.75-51.856 17.683'
  '-0.058-5.743-0.006-11.488 0.222-17.228 5.29-0.025 28.203 0.581 31.477-0.89 0.163-0.374 0.206-0.422 0.288-0.866'
  '0.685-3.723-17.429-19.055-20.368-23.566l-0.246-0.382c1.804-2.549 7.974-9.383 10.69-10.683 3.728-0.563 17.939 18.057 22.393 19.915'
  '1.389 0.579 1.612 0.542 2.835 0.062 1.375-1.953 0.915-8.93 0.926-11.598L48.271 0.137Z"/></svg>')

# petal logo (the favicon mark) — the brand glyph, drawn in currentColor so it
# themes with the sidebar. Sits next to the workbooks wordmark set in Franie.
PETAL = ('<svg viewBox="0 0 113.444 65.6" fill="currentColor" aria-hidden="true">'
  '<path d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308c0.291 9.772-0.064 19.654 0.223 29.43'
  '0.025 0.83 0.409 1.404 0.929 2.005 5.717 1.721 18.361-17.898 24.53-20.003 2.986 0.604 9.166 8.258 11.352 10.717'
  '-3.543 5.96-19 18.234-20.891 22.546 0.018 1.284 0.068 1.322 0.775 2.439 1.55 1.195 26.095 0.545 30.976 1.022'
  '0.437 5.52 0.298 11.4 0.258 16.964-11.721 0.02-26.712 1.352-36.918-3.738-8.424-4.163-14.823-11.531-17.769-20.452'
  '-0.765-2.653-1.317-5.088-1.924-7.771-1.181 5.233-2.103 9.52-4.859 14.238-12.117 20.736-31.693 17.75-51.856 17.683'
  '-0.058-5.743-0.006-11.488 0.222-17.228 5.29-0.025 28.203 0.581 31.477-0.89 0.163-0.374 0.206-0.422 0.288-0.866'
  '0.685-3.723-17.429-19.055-20.368-23.566l-0.246-0.382c1.804-2.549 7.974-9.383 10.69-10.683 3.728-0.563 17.939 18.057 22.393 19.915'
  '1.389 0.579 1.612 0.542 2.835 0.062 1.375-1.953 0.915-8.93 0.926-11.598L48.271 0.137Z"/></svg>')

# Sun/moon theme toggle button — fires the JS theme switch; both glyphs ship, CSS
# shows the right one for the active theme.
THEME_TOGGLE = ('<button class="themetog" id="themetog" type="button" aria-label="Toggle dark mode">'
  '<svg class="ic-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">'
  '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/></svg>'
  '<svg class="ic-moon" viewBox="0 0 24 24" fill="currentColor"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>'
  '</button>')

# DNA strip — full-width brand-pastel breather at the very top of the left panel.
# Matches the docs sidebar: ~20 segments cycling the 7 brand pastels, varying
# flex-grow, staggered scaleY breathe. Pastels stay pastel in both themes.
DNA_PASTELS = ["#a8d4f0", "#aee5c2", "#f3c5a3", "#f2ddb0", "#d9c5f0", "#f0b8b8", "#b8e0e8"]
DNA_STRIP = ('<div class="dnastrip" aria-hidden="true">'
  + "".join('<i style="background:%s;animation-delay:-%.2fs"></i>'
            % (DNA_PASTELS[k % len(DNA_PASTELS)], k * 0.62)
            for k in range(22))
  + '</div>')

def sidebar(cur_slug=None):
    out = ['<aside class="side" id="side">',
           DNA_STRIP,
           '<div class="brandrow"><a class="brand" href="/">%s<span>workbooks</span></a>%s</div>'
           % (PETAL, THEME_TOGGLE),
           '<a class="overview%s" href="/learn"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>Dashboard</a>'
              % (" on" if cur_slug is None else ""),
           '<div class="prog"><div class="bar"><i id="pbar"></i></div><span id="ptxt">0 of %d complete</span></div>' % TOTAL,
           '<nav class="curr" id="curr">']
    for u in units:
        ulight, udeep = unit_color(u["n"])
        out.append('<div class="umod" style="--u:%s;--ud:%s"><div class="uhd"><span class="un">Unit %d</span>%s</div>'
                   % (ulight, udeep, u["n"], esc(u["title"])))
        for l in u["lessons"]:
            cls = "li" + (" cur" if l["slug"] == cur_slug else "")
            out.append('<a class="%s" data-slug="%s" href="/learn/%s">'
                       '<span class="dot"></span><span class="t">%s</span></a>'
                       % (cls, l["slug"], esc(l["slug"]), esc(l["title"])))
        # unit cumulative quiz entry — opens the shared modal
        out.append('<button class="uquiz" data-unit="%d" type="button">'
                   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">'
                   '<path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/></svg>'
                   '<span class="t">Unit %d quiz</span><span class="uscore" data-uscore="%d"></span></button>'
                   % (u["n"], u["n"], u["n"]))
        out.append('</div>')
    out.append('</nav></aside>')
    return "".join(out)

HEAD = """<!doctype html>
<html lang="en" style="{htmlstyle}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="darkreader-lock">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="preload" href="../fonts/Franie-SemiBold.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="../fonts/fonts.css">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta property="og:type" content="{ogtype}"><meta property="og:site_name" content="Workbooks · Learning Center">
<meta property="og:title" content="{title}"><meta property="og:description" content="{desc}">
<meta property="og:url" content="{url}">
<link rel="canonical" href="{url}">
{jsonld}
<script>/* no-flash theme: set the attribute before first paint */
(function(){{try{{var t=localStorage.getItem("wb-lms-theme");
if(!t)t=matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light";
document.documentElement.setAttribute("data-theme",t);}}catch(e){{}}}})();</script>
<style>{css}</style>
</head>
<body class="{bodycls}">
{topbar}
<div class="app">
{sidebar}
<div class="main">{main}</div>
</div>
<div class="scrim" id="scrim"></div>
{quizmodal}
<script>window.WB_QUIZ={quizdata};</script>
<script>{js}</script>
<script src="../search.js" defer></script>
</body>
</html>
"""

QUIZ_MODAL = ('<div class="qmodal" id="qmodal"><div class="qcard" id="qcard">'
  '<div class="qhead"><div><div class="qk" id="qkick">Quiz</div><h3 id="qtitle"></h3></div>'
  '<button class="qclose" id="qclose" aria-label="Close">×</button></div>'
  '<div class="qbody" id="qbody"></div>'
  '<div class="qfoot"><button class="qsubmit" id="qsubmit">Submit answers</button>'
  '<button class="qretry" id="qretry" style="display:none">Try again</button>'
  '<span class="qresult" id="qresult"></span></div>'
  '</div></div>')

CSS = """
@font-face{ font-family:"Franie"; src:url("../fonts/Franie-Light.woff2") format("woff2"); font-weight:300; font-display:block; }
@font-face{ font-family:"Franie"; src:url("../fonts/Franie-SemiBold.woff2") format("woff2"); font-weight:600; font-display:block; }
@font-face{ font-family:"Franie"; src:url("../fonts/Franie-SemiBoldItalic.woff2") format("woff2"); font-weight:600; font-style:italic; font-display:block; }
@font-face{ font-family:"Franie"; src:url("../fonts/Franie-Bold.woff2") format("woff2"); font-weight:700; font-display:block; }
@font-face{ font-family:"Franie"; src:url("../fonts/Franie-BoldItalic.woff2") format("woff2"); font-weight:700; font-style:italic; font-display:swap; }
@font-face{ font-family:"Franie"; src:url("../fonts/Franie-Black.woff2") format("woff2"); font-weight:900; font-display:block; }
:root{ color-scheme:light; --paper:#f7f6f1; --card:#fff; --ink:#1a1b1e; --bloom:#13d943; --bloomd:#149157; --dim:#6a6f68;
  --line:#e7e5db; --pc:#a8d4f0; --pcd:#2f6fa8; --stroke:var(--ink); --shadow:var(--ink);
  /* semantic tones derived from the palette so every surface themes from one place */
  --prose:#34372f;        /* warm body/aside grey (light) */
  --prose-strong:#26282b; /* lead / strongest prose grey */
  --li-ink:#3a3e38;       /* sidebar lesson-row text */
  --well:#fff;            /* recessed fill: progress track, sunken caps */
  --hover:rgba(18,19,22,.05);   /* faint hover wash on light surfaces */
  --hover-soft:rgba(18,19,22,.03);
  --kbd-line:rgba(18,19,22,.22); /* keycap hairline */
  --dash:rgba(18,19,22,.3);      /* dashed "soon" badge */
  --scrim-q:rgba(10,10,12,.5);   /* quiz-modal backdrop */
  --scrim-side:rgba(0,0,0,.32);  /* mobile sidebar scrim */
  --video-bg:#0c0d0f;            /* video letterbox (dark in both modes) */
  --vbar-track:rgba(255,255,255,.22); /* video scrubber track (over video) */
  --vplay-bg:rgba(247,246,241,.94);   /* video play-button cap */
  --bad:#d9534f;                  /* wrong-answer red */
  --bad-fill:rgba(217,83,79,.13);
  --good-fill:rgba(63,224,129,.16); /* right-answer green wash */
  --on-bloom:#10120f;             /* ink that sits on a bloom fill */
  --display:"Franie",sans-serif; --mono:"JetBrains Mono",monospace; --read:"EB Garamond",Georgia,serif; }
*{ box-sizing:border-box; }
html{ scroll-behavior:smooth; }
body{ margin:0; background:var(--paper); color:var(--ink); font-family:var(--read); -webkit-font-smoothing:antialiased; }
a{ color:inherit; text-decoration:none; }
.app{ display:flex; align-items:flex-start; min-height:100vh; }
.main{ flex:1; min-width:0; }

/* ── curriculum sidebar (persistent app rail) ── */
.side{ width:300px; flex:0 0 300px; position:sticky; top:0; height:100vh; overflow-y:auto;
  border-right:2px solid var(--stroke); background:var(--paper); padding:22px 14px 40px; z-index:30; }
/* DNA strip — bleeds to the panel edges (cancels .side's 22px/14px padding), gentle breathe */
.dnastrip{ display:flex; width:auto; height:8px; overflow:hidden; flex:0 0 auto;
  margin:-22px -14px 18px; }
.dnastrip i{ height:100%; flex:1 1 0; min-width:2px; animation:dnaw 9s ease-in-out infinite; }
@keyframes dnaw{ 0%,100%{ flex-grow:1; } 50%{ flex-grow:3.4; } }
@media (prefers-reduced-motion:reduce){ .dnastrip i{ animation:none; } }
.brandrow{ display:flex; align-items:center; justify-content:space-between; padding:4px 8px 16px; }
.brand{ display:flex; align-items:center; gap:9px; min-width:0; }
.brand svg{ width:24px; height:auto; color:var(--ink); flex:0 0 auto; }
.brand span{ font-family:var(--display); font-weight:600; font-size:21px; line-height:1; letter-spacing:.005em;
  color:var(--ink); text-transform:none; }
/* light/dark toggle — a small keycap; shows sun in dark theme, moon in light */
.themetog{ flex:0 0 auto; width:34px; height:34px; display:flex; align-items:center; justify-content:center;
  border:2px solid var(--stroke); border-radius:9px; background:var(--card); color:var(--ink); cursor:pointer;
  box-shadow:2px 2px 0 var(--shadow); transition:transform .08s, box-shadow .08s; }
.themetog:hover{ transform:translate(-1px,-1px); box-shadow:3px 3px 0 var(--shadow); }
.themetog:active{ transform:translate(1px,1px); box-shadow:1px 1px 0 var(--shadow); }
.themetog svg{ width:16px; height:16px; display:block; }
.themetog .ic-sun{ display:none; }
[data-theme="dark"] .themetog .ic-sun{ display:block; }
[data-theme="dark"] .themetog .ic-moon{ display:none; }
.overview{ display:flex; align-items:center; gap:9px; font:700 10px var(--mono); letter-spacing:.16em;
  text-transform:uppercase; color:var(--dim); padding:9px 8px; border-radius:8px; }
.overview svg{ width:14px; height:14px; }
.overview:hover{ background:var(--hover); color:var(--ink); }
.overview.on{ background:var(--ink); color:var(--paper); }
.prog{ margin:14px 8px 18px; }
.prog .bar{ height:7px; border:2px solid var(--stroke); border-radius:999px; overflow:hidden; background:var(--well); }
/* progress bar — pastel rainbow of the 7 brand pastels */
.prog .bar i{ display:block; height:100%; width:0; transition:width .3s;
  background:linear-gradient(90deg,#a8d4f0,#aee5c2,#f3c5a3,#f2ddb0,#d9c5f0,#f0b8b8,#b8e0e8); }
.prog span{ display:block; margin-top:7px; font:700 10px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
/* per-unit colour: deep companion reads on white, light pastel reads on dark */
.umod{ margin-bottom:13px; --utext:var(--ud); }
[data-theme="dark"] .umod{ --utext:var(--u); }
.uhd{ display:flex; align-items:baseline; gap:8px; padding:8px 8px 6px; font:700 12px var(--mono); color:var(--utext); }
.uhd .un{ font-size:8.5px; letter-spacing:.18em; text-transform:uppercase; color:var(--dim); }
.li{ display:flex; align-items:flex-start; gap:10px; padding:9px 8px; border-radius:8px; font-size:14.5px; line-height:1.3; color:var(--li-ink); }
.li:hover{ background:var(--hover); }
.li .dot{ width:15px; height:15px; flex:0 0 auto; margin-top:1px; border:2px solid var(--dim); border-radius:50%; position:relative; }
/* done checks take the SECTION colour, not green */
.li.done .dot{ background:var(--u); border-color:var(--u); }
.li.done .dot::after{ content:""; position:absolute; left:4px; top:1px; width:4px; height:8px; border:solid var(--stroke); border-width:0 2px 2px 0; transform:rotate(45deg); }
/* current row: faint section-tint wash + section edge — works in BOTH themes */
.li.cur{ background:color-mix(in srgb,var(--u) 16%,transparent); box-shadow:inset 2px 0 0 var(--u); }
.li.cur .dot{ border-color:var(--u); }
.li.cur .dot::after{ content:""; position:absolute; inset:2px; background:var(--u); border-radius:50%; }
.li.cur .t{ font-weight:600; color:var(--ink); }

/* ════ SPLASH — welcome to a living internet + what you'll be able to do + one CTA ════ */
.splash{ min-height:100vh; display:flex; flex-direction:column; justify-content:center;
  gap:clamp(28px,4vh,50px); padding:5vh 6vw; }
.hype{ width:100%; max-width:1180px; margin:0 auto; }
.hype .wlabel{ font:700 11px var(--mono); letter-spacing:.24em; text-transform:uppercase; color:var(--dim); margin:0 0 12px; }
.hype .vplayer{ aspect-ratio:16/9; max-height:58vh; margin:0 auto; }
.swrap{ display:grid; grid-template-columns:1.05fr .95fr; gap:clamp(40px,6vw,86px); align-items:center;
  width:100%; max-width:1180px; margin:0 auto; }
.sintro .kick{ font:700 11px var(--mono); letter-spacing:.24em; text-transform:uppercase; color:var(--dim); }
/* Franie display: sentence-case SemiBold; emphasis via italic <em> (SemiBoldItalic). */
.sintro h1{ font-family:var(--display); font-weight:600; font-size:clamp(40px,5vw,78px); line-height:.95;
  margin:14px 0 0; letter-spacing:-.01em; color:var(--ink); }
.sintro h1 em{ font-style:italic; }
.sintro .lead{ margin:24px 0 0; font-size:21px; line-height:1.56; color:var(--prose); max-width:30em; }
.sintro .cta{ margin:34px 0 0; display:flex; align-items:center; gap:20px; flex-wrap:wrap; }
/* slim search bar — sits above the splash; fires the wb-search-open overlay */
.lsearch{ display:flex; align-items:center; gap:12px; width:100%; max-width:1180px; margin:0 auto 4px;
  background:var(--card); border:2px solid var(--stroke); border-radius:12px; box-shadow:4px 4px 0 var(--shadow);
  padding:13px 16px; cursor:text; text-align:left; }
.lsearch:hover{ box-shadow:5px 5px 0 var(--shadow); transform:translate(-1px,-1px); transition:transform .1s,box-shadow .1s; }
.lsearch svg{ width:18px; height:18px; flex:0 0 auto; color:var(--dim); }
.lsearch .ph{ flex:1; font:500 14px var(--mono); color:var(--dim); letter-spacing:-.01em; }
.lsearch kbd{ font:700 10px var(--mono); letter-spacing:.06em; color:var(--dim);
  border:1.5px solid var(--kbd-line); border-radius:6px; padding:4px 7px; background:var(--paper); }
/* keyboard-key button: white/paper cap, ink border, a downward ink lip (the keycap depth); presses down on click */
.start{ display:inline-flex; align-items:center; gap:10px; font:700 13px var(--mono); letter-spacing:.05em;
  text-transform:uppercase; color:var(--ink); background:var(--card); border:2px solid var(--stroke); border-radius:12px;
  padding:16px 28px; box-shadow:0 5px 0 var(--shadow); transition:transform .08s, box-shadow .08s; }
.start:hover{ background:var(--paper); transform:translateY(-1px); box-shadow:0 6px 0 var(--shadow); }
.start:active{ transform:translateY(4px); box-shadow:0 1px 0 var(--shadow); }
.sintro .note{ font:700 11px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
.souts{ border-left:2px solid var(--stroke); padding-left:clamp(24px,3vw,46px); }
.souts .lab{ font:700 11px var(--mono); letter-spacing:.18em; text-transform:uppercase; color:var(--dim); }
.souts ul{ list-style:none; margin:20px 0 0; padding:0; display:flex; flex-direction:column; gap:16px; }
.souts li{ display:flex; gap:15px; align-items:flex-start; font-size:20px; line-height:1.38; color:var(--ink); }
.souts li .ic{ flex:0 0 auto; width:38px; height:38px; border:2px solid var(--stroke); border-radius:10px;
  display:flex; align-items:center; justify-content:center; box-shadow:2px 2px 0 var(--shadow); }
.souts li .ic svg{ width:19px; height:19px; stroke:var(--ink); fill:none; stroke-width:2; stroke-linecap:round; stroke-linejoin:round; }
.souts li .tx{ padding-top:6px; }
.souts li b{ font-weight:600; }
@media (max-width:900px){ .splash{ min-height:0; padding:30px 22px 70px; gap:30px; }
  .hype .vplayer{ aspect-ratio:16/9; max-height:none; }
  .swrap{ grid-template-columns:1fr; gap:38px; }
  .souts{ border-left:0; padding-left:0; border-top:2px solid var(--stroke); padding-top:28px; } }

/* ════ LESSON PLAYER — three panes ════ */
.pane{ display:grid; grid-template-columns:minmax(0,1fr) 326px; gap:0; }
.reading{ min-width:0; max-width:760px; margin:0 auto; padding:60px 56px 80px; justify-self:center; width:100%; }
.crumb{ font:700 11px var(--mono); letter-spacing:.16em; text-transform:uppercase; color:var(--pcd); }
.reading h1{ font-family:var(--read); font-weight:600; font-size:clamp(34px,4vw,52px); line-height:1.08; margin:15px 0 0; letter-spacing:-.012em; }
.promise{ font-size:clamp(19px,2.2vw,23px); line-height:1.5; color:var(--prose); margin:18px 0 0; font-style:italic; }
article{ margin-top:40px; }
article > p{ font-size:20px; line-height:1.66; margin:0 0 23px; }
article > p.lead{ font-size:23px; line-height:1.55; color:var(--prose-strong); }
article h2{ font-family:var(--display); font-weight:600; font-size:clamp(24px,3vw,31px); line-height:1.15; margin:50px 0 17px; }
article b,article strong{ font-weight:600; } article em{ font-style:italic; }
article .aside{ margin:28px 0; padding:19px 23px; border-left:3px solid var(--pc); background:var(--card); font-size:18.5px; line-height:1.6; color:var(--prose); border-radius:0 10px 10px 0; }
article .big{ font-family:var(--display); font-weight:600; font-size:clamp(23px,3.4vw,33px); line-height:1.18; margin:42px 0; letter-spacing:-.01em; }
article hr{ border:0; border-top:1px solid var(--line); margin:44px 0; }
.deeper{ margin:52px 0 0; padding:24px; border:2px solid var(--stroke); border-radius:16px; background:var(--card); box-shadow:4px 4px 0 var(--shadow); }
.deeper .dh{ font:700 11px var(--mono); letter-spacing:.16em; text-transform:uppercase; color:var(--dim); }
.deeper p{ font-size:17px; line-height:1.55; margin:8px 0 15px; color:var(--prose); }
.deeper .links{ display:flex; flex-direction:column; gap:8px; }
.deeper a.ddl{ display:flex; align-items:center; gap:11px; padding:11px 13px; border:1.5px solid var(--line); border-radius:10px; }
.deeper a.ddl:hover{ border-color:var(--ink); background:var(--hover-soft); }
.deeper a.ddl b{ font:700 13px var(--mono); } .deeper a.ddl span{ font-size:11px; color:var(--dim); margin-left:auto; }
.soon-pane{ margin-top:40px; }
.soon-pane .badge{ display:inline-block; font:700 10px var(--mono); letter-spacing:.16em; text-transform:uppercase; color:var(--dim); border:2px dashed var(--dash); border-radius:999px; padding:8px 15px; }
.soon-pane p{ font-size:20px; line-height:1.6; margin:22px 0; color:var(--prose); }

/* right pane — course controls */
.rail{ border-left:1px solid var(--line); padding:62px 30px; position:sticky; top:0; align-self:start; min-height:100vh; display:flex; flex-direction:column; }
.rail .pos{ font:700 10px var(--mono); letter-spacing:.14em; text-transform:uppercase; color:var(--dim); }
.rail .audio{ margin:18px 0 0; }
.play{ display:flex; align-items:center; gap:13px; padding:12px 16px; border:2px solid var(--stroke); border-radius:999px;
  background:var(--card); box-shadow:3px 3px 0 var(--shadow); cursor:pointer; user-select:none; }
.play .ico{ width:28px; height:28px; flex:0 0 auto; border-radius:50%; background:var(--ink); display:flex; align-items:center; justify-content:center; }
.play .ico svg{ width:12px; height:12px; fill:var(--paper); display:block; }
.play .lab{ font:700 12px var(--mono); letter-spacing:.05em; text-transform:uppercase; }
.play .time{ font:500 11px var(--mono); color:var(--dim); margin-left:auto; }
.play.playing .ico{ background:var(--bloomd); }
.scrub{ margin:12px 4px 0; }
.scrub .sbar{ height:6px; border-radius:999px; background:color-mix(in srgb,var(--ink) 14%,transparent);
  cursor:pointer; overflow:hidden; }
.scrub .sbar i{ display:block; height:100%; width:0; background:var(--pc); border-radius:999px; transition:width .08s linear; }
.scrub .stime{ display:flex; justify-content:space-between; margin-top:7px; font:500 10.5px var(--mono); color:var(--dim); }
/* ── custom video player (reusable: lesson rail + splash hype reel) ── */
.vplayer{ position:relative; border:2px solid var(--stroke); border-radius:12px; overflow:hidden;
  box-shadow:4px 4px 0 var(--shadow); background:var(--video-bg); aspect-ratio:16/9; cursor:pointer; }
.vplayer video{ display:block; width:100%; height:100%; object-fit:cover; }
.vplayer .vplay{ position:absolute; inset:0; margin:auto; width:54px; height:54px; border-radius:50%;
  background:var(--vplay-bg); border:2px solid var(--stroke); display:flex; align-items:center; justify-content:center;
  box-shadow:2px 2px 0 var(--shadow); transition:opacity .15s, transform .1s; }
.vplayer:hover .vplay{ transform:translateY(-1px); }
.vplayer.playing .vplay{ opacity:0; pointer-events:none; }
.vplayer .vplay svg{ width:19px; height:19px; fill:var(--ink); margin-left:2px; display:block; }
.vplayer .vbar{ position:absolute; left:0; right:0; bottom:0; height:5px; background:var(--vbar-track); cursor:pointer; }
.vplayer .vbar i{ display:block; height:100%; width:0; background:var(--pc); }
.rail .vwrap{ margin:16px 0 0; }
.rail .vwrap .vlab{ font:700 10px var(--mono); letter-spacing:.14em; text-transform:uppercase; color:var(--dim); margin:0 0 8px; }
/* big CTA — light-pastel unit fill + dark ink reads in BOTH themes */
.rail .cont{ margin:18px 0 0; width:100%; display:inline-flex; align-items:center; justify-content:center; gap:9px;
  font:700 12px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:#10120f; background:var(--pc);
  border:2px solid var(--stroke); border-radius:11px; padding:15px 18px; cursor:pointer; box-shadow:4px 4px 0 var(--shadow);
  transition:transform .1s, box-shadow .1s; }
.rail .cont:hover{ transform:translate(-1px,-1px); box-shadow:5px 5px 0 var(--shadow); }
.rail .cont:active{ transform:translate(2px,2px); box-shadow:2px 2px 0 var(--shadow); }
.rail .cont.done{ background:var(--pc); }
/* notes — full-bleed, browser-cached scratchpad; not a boxed input */
.rail .notes{ display:block; width:100%; flex:1 1 auto; min-height:calc(100vh - 360px);
  margin:24px 0 0; padding:20px 0 0; border:0; border-top:1px solid var(--line); border-radius:0;
  background:transparent; resize:none; outline:none; overflow-y:auto;
  font:400 15px/1.7 var(--read); color:var(--prose); -webkit-font-smoothing:antialiased; }
.rail .notes::placeholder{ color:var(--dim); opacity:.85; }

/* topbar (mobile) */
.topbar{ display:none; }
.scrim{ display:none; }

@media (max-width:1080px){
  .pane{ grid-template-columns:1fr; }
  .rail{ border-left:0; border-top:2px solid var(--stroke); position:static; min-height:0; padding:26px 56px 60px;
    max-width:760px; margin:0 auto; width:100%; display:flex; flex-wrap:wrap; gap:14px; align-items:center; }
  .rail .audio{ margin:0; } .rail .cont{ margin:0; width:auto; flex:1; min-width:220px; }
  .rail .notes{ margin:8px 0 0; width:100%; min-height:200px; flex:0 0 auto; }
  .reading{ padding:40px 56px 40px; }
}
@media (max-width:900px){
  .topbar{ display:flex; align-items:center; gap:13px; position:sticky; top:0; z-index:40; background:var(--paper);
    border-bottom:2px solid var(--stroke); padding:11px 16px; }
  .topbar .burger{ width:26px; height:19px; display:flex; flex-direction:column; justify-content:center; gap:5px; background:none; border:0; padding:0; cursor:pointer; }
  .topbar .burger span{ display:block; height:2.5px; border-radius:2px; background:var(--ink); }
  .topbar .tt{ font:700 11px var(--mono); letter-spacing:.04em; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .topbar .tp{ margin-left:auto; font:700 10px var(--mono); color:var(--dim); white-space:nowrap; }
  .side{ position:fixed; top:0; left:0; height:100vh; transform:translateX(-100%); transition:transform .25s ease; box-shadow:6px 0 0 rgba(0,0,0,.08); }
  .side.open{ transform:translateX(0); }
  .scrim.show{ display:block; position:fixed; inset:0; background:var(--scrim-side); z-index:25; }
  .dash{ min-height:0; padding:40px 22px 70px; gap:34px; } .arc{ flex-wrap:wrap; } .arc .u{ flex:1 1 44%; }
  .reading{ padding:28px 22px 30px; max-width:none; } .rail{ padding:22px 22px 70px; max-width:none; }
}

/* ════ DARK MODE ════
   One [data-theme="dark"] palette. The variables flip; the handful of hardcoded
   literals scattered in the light CSS (reading prose greys, white cards, ink
   tints) get explicit overrides so nothing reads as a light island on dark. */
[data-theme="dark"]{
  color-scheme:dark;
  --paper:#16171a; --card:#1f2125; --ink:#ecebe5; --dim:#8c9189;
  --bloom:#3fe081; --bloomd:#37c873; --line:#2d2f34; --stroke:#31343a; --shadow:#000;
  /* --pc / --pcd are the per-lesson unit colours, set inline on <html>; in dark
     they STAY (light pastel + dark ink reads great on dark), so no !important wash. */
  /* dark values for every semantic tone — surfaces theme purely from these */
  --prose:#c9ccc2; --prose-strong:#d4d7cd; --li-ink:#c4c8bf;
  --well:#0f1012; --hover:rgba(255,255,255,.05); --hover-soft:rgba(255,255,255,.04);
  --kbd-line:#3a3d42; --dash:rgba(255,255,255,.22); --scrim-q:rgba(0,0,0,.6);
  --vplay-bg:rgba(28,30,34,.94);
  --good-fill:rgba(63,224,129,.16); --bad:#e8736f; --bad-fill:rgba(232,115,111,.16);
  --on-bloom:#10120f;
}
[data-theme="dark"] body{ background:var(--paper); color:var(--ink); }
[data-theme="dark"] .prog .bar{ border-color:#3a3d42; }
/* done-check dot is the light pastel section colour in both themes → dark tick */
[data-theme="dark"] .li.done .dot::after{ border-color:#16171a; }
[data-theme="dark"] .overview.on{ background:rgba(255,255,255,.12); color:var(--ink); }
/* kicker/crumb: deep companion is too dark on dark → use the light pastel */
[data-theme="dark"] .crumb{ color:var(--pc); }
[data-theme="dark"] .uquiz{ border-color:#3a3d42; }
[data-theme="dark"] .uquiz:hover{ border-color:var(--bloomd); }
/* the .souts icon tiles stay pastel (brand accent) → ink the glyph dark on them */
[data-theme="dark"] .souts li .ic svg{ stroke:#16171a; }
[data-theme="dark"] .qsubmit{ color:var(--on-bloom); }
[data-theme="dark"] .topbar .burger span{ background:var(--ink); }

/* ════ QUIZ — Listen-style trigger button + modal ════ */
.rail .quizbtn{ margin:12px 0 0; width:100%; display:inline-flex; align-items:center; gap:13px;
  padding:12px 16px; border:2px solid var(--stroke); border-radius:999px; background:var(--card);
  box-shadow:3px 3px 0 var(--shadow); cursor:pointer; user-select:none;
  transition:transform .08s, box-shadow .08s; }
.rail .quizbtn:hover{ transform:translate(-1px,-1px); box-shadow:4px 4px 0 var(--shadow); }
.rail .quizbtn .ico{ width:28px; height:28px; flex:0 0 auto; border-radius:50%; background:var(--pc);
  display:flex; align-items:center; justify-content:center; }
.rail .quizbtn .ico svg{ width:15px; height:15px; stroke:#10120f; fill:none; stroke-width:2.4;
  stroke-linecap:round; stroke-linejoin:round; display:block; }
.rail .quizbtn .lab{ font:700 12px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--ink); }
.rail .quizbtn .score{ margin-left:auto; font:700 11px var(--mono); color:var(--bloomd); }
.qzbadge{ display:inline-flex; align-items:center; gap:4px; font:700 9px var(--mono); letter-spacing:.06em;
  color:var(--bloomd); margin-left:6px; }

/* unit-quiz entry — looks exactly like a lesson row (.li), just a quiz icon */
.uquiz{ display:flex; align-items:flex-start; gap:10px; padding:9px 8px; border-radius:8px;
  font-size:14.5px; line-height:1.3; color:var(--li-ink); width:100%; text-align:left;
  background:none; border:0; cursor:pointer; font-family:inherit; }
.uquiz:hover{ background:var(--hover); }
.uquiz svg{ width:15px; height:15px; flex:0 0 auto; margin-top:1px; color:var(--utext); }
.uquiz .t{ flex:1; }
.uquiz .uscore{ margin-left:auto; font:700 11px var(--mono); color:var(--utext); }

/* modal */
.qmodal{ position:fixed; inset:0; z-index:60; display:none; align-items:flex-start; justify-content:center;
  background:var(--scrim-q); padding:5vh 18px; overflow-y:auto; }
.qmodal.show{ display:flex; }
.qcard{ width:100%; max-width:620px; background:var(--paper); border:2px solid var(--stroke); border-radius:18px;
  box-shadow:8px 8px 0 var(--shadow); padding:26px 28px 30px; }
.qhead{ display:flex; align-items:flex-start; gap:12px; }
.qhead .qk{ font:700 10px var(--mono); letter-spacing:.18em; text-transform:uppercase; color:var(--bloomd); }
.qhead h3{ font-family:var(--display); font-weight:600; font-size:26px; line-height:1.1; margin:6px 0 0;
  letter-spacing:-.01em; color:var(--ink); }
.qclose{ margin-left:auto; flex:0 0 auto; width:32px; height:32px; border:2px solid var(--stroke); border-radius:8px;
  background:var(--card); color:var(--ink); cursor:pointer; font:700 16px var(--mono); line-height:1; }
.qclose:hover{ background:var(--pc); }
.qbody{ margin:22px 0 0; display:flex; flex-direction:column; gap:24px; }
.qitem{ }
.qitem .qq{ font-size:18px; line-height:1.4; font-weight:600; color:var(--ink); margin:0 0 12px; }
.qitem .qq .qn{ font:700 11px var(--mono); color:var(--dim); margin-right:7px; }
.qopt{ display:flex; align-items:flex-start; gap:11px; padding:11px 13px; border:2px solid var(--line);
  border-radius:11px; margin:0 0 8px; cursor:pointer; font-size:15.5px; line-height:1.4; color:var(--ink);
  background:var(--card); transition:border-color .1s, background .1s; }
.qopt:hover{ border-color:var(--dim); }
.qopt input{ margin:3px 0 0; accent-color:var(--bloomd); flex:0 0 auto; }
.qopt.sel{ border-color:var(--ink); background:var(--pc); }
/* graded states */
.qitem.graded .qopt{ cursor:default; }
.qitem.graded .qopt.right{ border-color:var(--bloomd); background:var(--good-fill); }
.qitem.graded .qopt.wrong{ border-color:var(--bad); background:var(--bad-fill); }
.qitem .qexpl{ display:none; margin:9px 2px 0; font-size:13.5px; line-height:1.5; color:var(--dim);
  padding-left:12px; border-left:3px solid var(--bloomd); }
.qitem.graded .qexpl{ display:block; }
.qfoot{ margin:26px 0 0; display:flex; align-items:center; gap:14px; flex-wrap:wrap; }
.qsubmit{ font:700 12px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:#10120f;
  background:var(--pc); border:2px solid var(--stroke); border-radius:11px; padding:14px 22px; cursor:pointer;
  box-shadow:3px 3px 0 var(--shadow); transition:transform .08s, box-shadow .08s; }
.qsubmit:hover{ transform:translate(-1px,-1px); box-shadow:4px 4px 0 var(--shadow); }
.qsubmit:active{ transform:translate(2px,2px); box-shadow:1px 1px 0 var(--shadow); }
[data-theme="dark"] .qsubmit{ color:var(--on-bloom); }
.qretry{ font:700 11px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim);
  background:none; border:0; cursor:pointer; }
.qretry:hover{ color:var(--ink); }
.qresult{ font:700 13px var(--mono); letter-spacing:.03em; }
.qresult .pct{ font-family:var(--display); font-weight:600; font-size:30px; line-height:1; margin-right:8px;
  color:var(--bloomd); vertical-align:-3px; }
.qresult.pass .pct{ color:var(--bloomd); }
.qresult.fail .pct{ color:var(--bad); }
@media (max-width:1080px){ .rail .quizbtn{ margin:0; width:auto; flex:1; min-width:220px; } }
"""

JS = """
(function(){
  var KEY="wb-lms-done", LAST="wb-lms-last";
  function done(){ try{ return JSON.parse(localStorage.getItem(KEY))||[]; }catch(e){ return []; } }
  function save(a){ localStorage.setItem(KEY, JSON.stringify(a)); }
  var d=done(), total=%TOTAL%;
  document.querySelectorAll(".li,.ll").forEach(function(el){ if(d.indexOf(el.dataset.slug)>=0) el.classList.add("done"); });
  var pct=Math.round(d.length/total*100);
  ["pbar","dpbar"].forEach(function(id){ var e=document.getElementById(id); if(e) e.style.width=pct+"%"; });
  var pt=document.getElementById("ptxt"); if(pt) pt.textContent=d.length+" of "+total+" complete";
  var dpn=document.getElementById("dpn"); if(dpn) dpn.textContent=d.length+" of "+total+" lessons complete";
  var tp=document.getElementById("tprog"); if(tp) tp.textContent=pct+"%";
  var cur=document.body.dataset.slug;
  if(cur) localStorage.setItem(LAST, cur);
  // dashboard continue card
  var sb=document.getElementById("startbtn"), nl=document.getElementById("nextlesson"), nld=document.getElementById("nextdek"), cu=document.getElementById("cuptext");
  if(sb){
    var last=localStorage.getItem(LAST), target=sb.dataset.first, label="Start the course";
    if(last && d.length){ target=last; label="Resume lesson"; if(cu) cu.textContent="Pick up where you left off"; }
    sb.href="/learn/"+target; sb.querySelector("span").textContent=label;
  }
  var cc=document.getElementById("cc");
  if(cc){
    if(d.indexOf(cur)>=0){ cc.classList.add("done"); cc.querySelector("span").textContent="Completed"; }
    cc.addEventListener("click",function(){
      var a=done(); if(a.indexOf(cur)<0){ a.push(cur); save(a); }
      var nx=cc.dataset.next; location.href = nx ? "/learn/"+nx : "/learn";
    });
  }
  var ls=document.getElementById("lsearch");
  if(ls) ls.addEventListener("click",function(){ window.dispatchEvent(new CustomEvent("wb-search-open")); });
  var side=document.getElementById("side"), scrim=document.getElementById("scrim"), b=document.getElementById("burger");
  function close(){ side&&side.classList.remove("open"); scrim&&scrim.classList.remove("show"); }
  if(b) b.addEventListener("click",function(){ side.classList.toggle("open"); scrim.classList.toggle("show"); });
  if(scrim) scrim.addEventListener("click",close);
  var pl=document.getElementById("play");
  if(pl){ var lab=document.getElementById("playlab"), pico=document.getElementById("playico");
    var fill=document.getElementById("sbfill"), sbar=document.getElementById("sbar");
    var scur=document.getElementById("scur"), sdur=document.getElementById("sdur");
    var PLAYSVG='<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>';
    var PAUSESVG='<svg viewBox="0 0 24 24"><rect x="6.5" y="5" width="4" height="14" rx="1"></rect><rect x="13.5" y="5" width="4" height="14" rx="1"></rect></svg>';
    var au=new Audio(); au.preload="metadata"; au.src=pl.dataset.src;
    function setPlaying(p){ pl.classList.toggle("playing",p); if(lab) lab.textContent=p?"Pause":"Listen"; if(pico) pico.innerHTML=p?PAUSESVG:PLAYSVG; }
    function fmt(t){ if(!isFinite(t)) return "--:--"; t=Math.max(0,t|0); var m=(t/60)|0,s=t%60; return m+":"+(s<10?"0":"")+s; }
    au.addEventListener("loadedmetadata",function(){ if(sdur) sdur.textContent=fmt(au.duration); });
    au.addEventListener("timeupdate",function(){ if(au.duration){ if(fill) fill.style.width=(au.currentTime/au.duration*100)+"%"; if(scur) scur.textContent=fmt(au.currentTime); } });
    au.addEventListener("ended",function(){ setPlaying(false); if(fill) fill.style.width="0%"; });
    pl.addEventListener("click",function(){ if(au.paused){ au.play(); setPlaying(true); } else { au.pause(); setPlaying(false); } });
    if(sbar){
      var drag=false;
      function seek(cx){ var r=sbar.getBoundingClientRect(); var x=Math.min(1,Math.max(0,(cx-r.left)/r.width)); if(au.duration){ au.currentTime=x*au.duration; if(fill) fill.style.width=(x*100)+"%"; } }
      sbar.addEventListener("mousedown",function(e){ drag=true; seek(e.clientX); e.preventDefault(); });
      document.addEventListener("mousemove",function(e){ if(drag) seek(e.clientX); });
      document.addEventListener("mouseup",function(){ drag=false; });
      sbar.addEventListener("touchstart",function(e){ if(e.touches[0]) seek(e.touches[0].clientX); },{passive:true});
      sbar.addEventListener("touchmove",function(e){ if(e.touches[0]) seek(e.touches[0].clientX); },{passive:true});
    }
  }
  var nt=document.getElementById("notes");
  if(nt){ var nk="wb-lms-notes:"+nt.dataset.slug;
    try{ nt.value=localStorage.getItem(nk)||""; }catch(e){}
    nt.addEventListener("input",function(){ try{ localStorage.setItem(nk,nt.value); }catch(e){} });
  }
  // custom video players
  document.querySelectorAll(".vplayer").forEach(function(vp){
    var v=vp.querySelector("video"), bar=vp.querySelector(".vbar i"), track=vp.querySelector(".vbar");
    if(!v) return;
    function toggle(){ if(v.paused){ v.play(); vp.classList.add("playing"); } else { v.pause(); vp.classList.remove("playing"); } }
    vp.addEventListener("click",function(e){ if(e.target.closest(".vbar")) return; toggle(); });
    v.addEventListener("timeupdate",function(){ if(v.duration) bar.style.width=(v.currentTime/v.duration*100)+"%"; });
    v.addEventListener("pause",function(){ vp.classList.remove("playing"); });
    v.addEventListener("play",function(){ vp.classList.add("playing"); });
    v.addEventListener("ended",function(){ vp.classList.remove("playing"); v.currentTime=0; });
    if(track) track.addEventListener("click",function(e){ var r=this.getBoundingClientRect(); if(v.duration) v.currentTime=(e.clientX-r.left)/r.width*v.duration; });
  });

  // ── light / dark toggle ──
  var TKEY="wb-lms-theme", root=document.documentElement;
  var tog=document.getElementById("themetog");
  if(tog) tog.addEventListener("click",function(){
    var cur=root.getAttribute("data-theme")==="dark"?"dark":"light";
    var nx=cur==="dark"?"light":"dark";
    root.setAttribute("data-theme",nx); try{ localStorage.setItem(TKEY,nx); }catch(e){}
  });

  // ── quiz module ──
  var Q=window.WB_QUIZ||{lessons:{},units:{},unitTitles:{},lessonTitles:{}};
  var QKEY="wb-lms-quiz";
  function qscores(){ try{ return JSON.parse(localStorage.getItem(QKEY))||{}; }catch(e){ return {}; } }
  function qsave(o){ localStorage.setItem(QKEY, JSON.stringify(o)); }
  function setOf(kind,id,questions){ // returns array {kind,id,questions,key}
    return {kind:kind,id:id,questions:questions,key:kind+":"+id};
  }
  var modal=document.getElementById("qmodal"), qbody=document.getElementById("qbody"),
      qtitle=document.getElementById("qtitle"), qkick=document.getElementById("qkick"),
      qsubmit=document.getElementById("qsubmit"), qretry=document.getElementById("qretry"),
      qresult=document.getElementById("qresult"), qclose=document.getElementById("qclose"),
      qcard=document.getElementById("qcard");
  var active=null;
  function renderQuiz(){
    qbody.innerHTML="";
    qresult.textContent=""; qresult.className="qresult";
    qsubmit.style.display=""; qretry.style.display="none";
    active.questions.forEach(function(item,qi){
      var it=document.createElement("div"); it.className="qitem"; it.dataset.qi=qi;
      var h=document.createElement("div"); h.className="qq";
      h.innerHTML='<span class="qn">'+(qi+1)+'.</span>'+esc(item.q); it.appendChild(h);
      item.options.forEach(function(opt,oi){
        var lab=document.createElement("label"); lab.className="qopt"; lab.dataset.oi=oi;
        var inp=document.createElement("input"); inp.type="radio"; inp.name="q"+qi; inp.value=oi;
        var sp=document.createElement("span"); sp.innerHTML=esc(opt);
        lab.appendChild(inp); lab.appendChild(sp);
        inp.addEventListener("change",function(){
          it.querySelectorAll(".qopt").forEach(function(o){ o.classList.remove("sel"); });
          lab.classList.add("sel");
        });
        it.appendChild(lab);
      });
      var ex=document.createElement("div"); ex.className="qexpl"; ex.textContent=item.explain||""; it.appendChild(ex);
      qbody.appendChild(it);
    });
    qcard.scrollTop=0;
  }
  function esc(s){ var d=document.createElement("div"); d.textContent=s==null?"":s; return d.innerHTML; }
  function openQuiz(set){
    if(!set||!set.questions||!set.questions.length) return;
    active=set;
    qtitle.textContent = set.kind==="lesson"
      ? (Q.lessonTitles[set.id]||set.id)
      : ("Unit "+set.id+" — "+(Q.unitTitles[set.id]||""));
    qkick.textContent = set.kind==="lesson" ? "Lesson quiz" : "Unit quiz";
    renderQuiz();
    modal.classList.add("show"); document.body.style.overflow="hidden";
  }
  function closeQuiz(){ modal.classList.remove("show"); document.body.style.overflow=""; active=null; }
  function gradeQuiz(){
    if(!active) return;
    var n=active.questions.length, correct=0;
    active.questions.forEach(function(item,qi){
      var it=qbody.querySelector('.qitem[data-qi="'+qi+'"]');
      it.classList.add("graded");
      var picked=it.querySelector('input[name="q'+qi+'"]:checked');
      var pickedOi=picked?parseInt(picked.value,10):-1;
      it.querySelectorAll(".qopt").forEach(function(o){
        var oi=parseInt(o.dataset.oi,10);
        if(oi===item.answer) o.classList.add("right");
        else if(oi===pickedOi) o.classList.add("wrong");
        o.querySelector("input").disabled=true;
      });
      if(pickedOi===item.answer) correct++;
    });
    var pct=Math.round(correct/n*100), pass=pct>=70;
    qresult.className="qresult "+(pass?"pass":"fail");
    qresult.innerHTML='<span class="pct">'+correct+'/'+n+'</span>'+pct+'%';
    qsubmit.style.display="none"; qretry.style.display="";
    // persist best score
    var sc=qscores(); var prev=sc[active.key]; var rec={correct:correct,total:n,pct:pct};
    if(!prev||pct>prev.pct) sc[active.key]=rec;
    qsave(sc); reflectQuizScores();
    qcard.scrollTop=0;
  }
  function reflectQuizScores(){
    var sc=qscores();
    document.querySelectorAll("[data-lscore]").forEach(function(el){
      var r=sc["lesson:"+el.dataset.lscore]; el.textContent=r?(r.correct+"/"+r.total):"";
    });
    document.querySelectorAll("[data-uscore]").forEach(function(el){
      var r=sc["unit:"+el.dataset.uscore]; el.textContent=r?(r.correct+"/"+r.total):"";
    });
  }
  if(modal){
    qsubmit.addEventListener("click",gradeQuiz);
    qretry.addEventListener("click",renderQuiz);
    qclose.addEventListener("click",closeQuiz);
    modal.addEventListener("click",function(e){ if(e.target===modal) closeQuiz(); });
    document.addEventListener("keydown",function(e){ if(e.key==="Escape"&&modal.classList.contains("show")) closeQuiz(); });
    document.querySelectorAll("[data-quiz-lesson]").forEach(function(b){
      b.addEventListener("click",function(){
        var id=b.dataset.quizLesson, qs=(Q.lessons||{})[id];
        if(qs) openQuiz(setOf("lesson",id,qs));
      });
    });
    document.querySelectorAll(".uquiz[data-unit]").forEach(function(b){
      b.addEventListener("click",function(){
        var id=b.dataset.unit, qs=(Q.units||{})[id];
        if(qs) openQuiz(setOf("unit",id,qs));
      });
    });
    reflectQuizScores();
  }
})();
""".replace("%TOTAL%", str(TOTAL))

def topbar(label):
    return ('<header class="topbar"><button class="burger" id="burger" aria-label="Curriculum">'
            '<span></span><span></span><span></span></button>'
            '<span class="tt">%s</span><span class="tp">Learning Center · <b id="tprog">0%%</b></span></header>'
            % esc(label))

def deeper_box(docs):
    if not docs: return ""
    links = "".join('<a class="ddl" href="/learn/%s"><b>%s</b><span>the deep doc</span></a>'
                    % (esc(s), esc(doc_title.get(s, s))) for s in docs)
    return ('<div class="deeper"><div class="dh">Go deeper — the technical docs</div>'
            '<p>That was the idea. When you want the literal version — the actual format, the bytes, the proof — start here.</p>'
            '<div class="links">%s</div></div>' % links)

def lesson_page(l):
    live = l["status"] == "live" and os.path.exists(os.path.join(HERE, "content", l["slug"] + ".html"))
    crumb = "Unit %d · %s" % (l["unit"], esc(l["unit_title"]))
    if live:
        body = open(os.path.join(HERE, "content", l["slug"] + ".html")).read()
        reading = ('<div class="crumb">%s</div><h1>%s</h1>%s<article>%s</article>%s'
                   % (crumb, esc(l["title"]),
                      '<p class="promise">%s</p>' % esc(l["promise"]) if l.get("promise") else "",
                      body, deeper_box(l.get("docs"))))
    else:
        reading = ('<div class="crumb">%s</div><h1>%s</h1>'
                   '<div class="soon-pane"><span class="badge">Lesson coming soon</span><p>%s</p>'
                   '<p>While this lesson is being written, the technical docs below already cover the ground.</p></div>%s'
                   % (crumb, esc(l["title"]), esc(l.get("teaches", "")), deeper_box(l.get("docs"))))
    audio = ""
    if l.get("audio"):
        audio = ('<div class="audio"><div class="play" id="play" data-src="%s"><span class="ico" id="playico">'
                 '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg></span>'
                 '<span class="lab" id="playlab">Listen</span><span class="time">%s</span></div>'
                 '<div class="scrub"><div class="sbar" id="sbar"><i id="sbfill"></i></div>'
                 '<div class="stime"><span id="scur">0:00</span><span id="sdur">--:--</span></div></div></div>'
                 % (esc(l["audio"]), esc(l.get("mins", ""))))
    nxt = l["next"]["slug"] if l["next"] else ""
    cclabel = "Complete & continue" if l["next"] else "Complete & finish"
    # quiz button — directly below the Listen/audio button — only if questions exist
    quizbtn = ""
    if QUIZ.get("lessons", {}).get(l["slug"]):
        quizbtn = ('<button class="quizbtn" type="button" data-quiz-lesson="%s"><span class="ico">'
                   '<svg viewBox="0 0 24 24"><path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/></svg></span>'
                   '<span class="lab">Take the quiz</span><span class="score" data-lscore="%s"></span></button>'
                   % (esc(l["slug"]), esc(l["slug"])))
    rail = ('<aside class="rail"><div class="pos">Lesson %d of %d</div>%s%s'
            '<button class="cont" id="cc" data-next="%s"><span>%s</span> →</button>'
            '<textarea class="notes" id="notes" data-slug="%s" spellcheck="false"'
            ' placeholder="Notes are taken here — saved to your browser cache."></textarea></aside>'
            % (l["i"]+1, TOTAL, audio, quizbtn, esc(nxt), cclabel, esc(l["slug"])))
    main = '<div class="pane"><div class="reading">%s</div>%s</div>' % (reading, rail)
    plight, pdeep = unit_color(l["unit"])
    return HEAD.format(
        htmlstyle="--pc:%s;--pcd:%s;" % (plight, pdeep),
        title=esc(l["title"]) + " — Learning Center — Workbooks",
        desc=esc(l.get("teaches", "")), ogtype="article",
        url="https://workbooks.sh/learn/" + l["slug"], jsonld=lesson_jsonld(l), css=CSS, js=JS,
        bodycls='lesson" data-slug="%s' % esc(l["slug"]),
        topbar=topbar(l["title"]), sidebar=sidebar(l["slug"]), main=main,
        quizmodal=QUIZ_MODAL, quizdata=QUIZ_JSON)

def dashboard():
    first = next((x["slug"] for x in flat if x["status"] == "live"), flat[0]["slug"])
    # Franie display: sentence case, SemiBold; emphasis via italic <em>.
    title = "Learning <em>center.</em>"
    I = {  # simple line icons, one per outcome
        "file": '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
        "bolt": '<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>',
        "spark": '<path d="M12 3l2.1 5.8L20 11l-5.9 2.2L12 19l-2.1-5.8L4 11l5.9-2.2z"/>',
        "loop": '<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/>',
        "globe": '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18"/>',
    }
    outs = [  # each icon a different palette colour
        ("file",  "#a8d4f0", "Build real software in a <b>single file</b> you own, send, and keep — no servers, no setup."),
        ("spark", "#aee5c2", "Put <b>AI agents</b> to work safely, and turn plans into <b>software that runs itself</b>."),
        ("globe", "#f3c5a3", "Ship something <b>living to the internet</b> — and prove that it's yours."),
    ]
    lis = "".join('<li><span class="ic" style="background:%s"><svg viewBox="0 0 24 24">%s</svg></span><span class="tx">%s</span></li>'
                  % (col, I[k], t) for k, col, t in outs)
    if HYPE_VIDEO:
        hype = ('<div class="hype"><div class="wlabel">welcome to the learning center</div>%s</div>'
                % vplayer_html(HYPE_VIDEO, HYPE_POSTER or ""))
        kicker = ""
    else:
        hype = ""
        kicker = '<div class="kick">welcome to the learning center</div>'
    searchbar = ('<button class="lsearch" id="lsearch" aria-label="Search lessons and docs">'
                 '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round">'
                 '<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/></svg>'
                 '<span class="ph">Search lessons &amp; docs…</span>'
                 '<kbd>⌘K</kbd></button>')
    main = ('<div class="splash">' + searchbar + hype + '<div class="swrap">'
            '<div class="sintro">' + kicker +
            '<h1>%s</h1>'
            '<p class="lead">The internet is becoming something you can hold — software in a single file, '
            'built by people and AI together. Learn it here, from zero. No experience required.</p>'
            '<div class="cta"><a class="start" id="startbtn" data-first="%s" href="/learn/%s">'
            '<span>Start the course</span> →</a>'
            '<span class="note">%d lessons · no experience needed</span></div></div>'
            '<div class="souts"><div class="lab">What you\'ll be able to do</div><ul>%s</ul></div>'
            '</div></div>' % (title, esc(first), esc(first), TOTAL, lis))
    return HEAD.format(
        htmlstyle="--pc:#a8d4f0;--pcd:#2f6fa8;",
        title="Learning Center — Workbooks",
        desc="Learn Workbooks from zero — %d plain-language lessons, no technical background needed." % TOTAL,
        ogtype="website", url="https://workbooks.sh/learn", jsonld=course_jsonld(), css=CSS, js=JS,
        bodycls="dashpage", topbar=topbar("Learning Center"), sidebar=sidebar(None), main=main,
        quizmodal=QUIZ_MODAL, quizdata=QUIZ_JSON)

open(os.path.join(HERE, "index.html"), "w").write(dashboard())
for l in flat:
    open(os.path.join(HERE, l["slug"] + ".html"), "w").write(lesson_page(l))
print("Learning Center (wide) built: dashboard + %d lesson pages (%d live)" % (TOTAL, LIVE))
