#!/usr/bin/env python3
"""Generate the Learning Center index at /learn from lms.json — the net-new
deep conceptual curriculum (NOT the docs). Re-run after editing lms.json."""
import json, os, html
HERE = os.path.dirname(os.path.abspath(__file__))
lms = json.load(open(os.path.join(HERE, "lms.json")))
units = lms["units"]
total = sum(len(u["lessons"]) for u in units)
live = sum(1 for u in units for l in u["lessons"] if l.get("status") == "live")
ACC = ["#a8d4f0","#f3c5a3","#aee5c2","#c5b8e8","#f2ddb0","#b8e0e8","#f0b8b8","#d9dbd3"]
def esc(s): return html.escape(s or "")
def card(n, l):
    on = l.get("status") == "live"
    body = ('<span class="seq">%02d</span><span class="lt"><b>%s</b><i>%s</i></span>'
            % (n, esc(l["title"]), esc(l.get("teaches",""))))
    if on:
        return '<a class="step" href="%s">%s<span class="go">→</span></a>' % (esc(l["slug"]), body)
    return '<div class="step soon">%s<span class="tag">soon</span></div>' % body
rail = "".join('<a href="#u%d"><span style="background:%s"></span>%s</a>'
              % (u["n"], ACC[(u["n"]-1)%len(ACC)], esc(u["title"])) for u in units)
secs=""; n=0
for u in units:
    rows=""
    for l in u["lessons"]:
        n+=1; rows+=card(n,l)
    secs += ('<section class="unit" id="u%d" style="--ua:%s"><header class="uh">'
             '<span class="un">Unit %d</span><h2>%s</h2><p>%s</p></header>'
             '<div class="steps">%s</div></section>'
             % (u["n"], ACC[(u["n"]-1)%len(ACC)], u["n"], esc(u["title"]), esc(u["dek"]), rows))
OUT = f"""<!doctype html>
<html lang="en" style="--pc:#a8d4f0; --ac:#2b6fd0;">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Learning Center — Workbooks</title>
<meta name="description" content="Learn Workbooks from zero. {total} deep, plain-language lessons in order — no technical background needed. Each one teaches a single big idea, then points you to the docs for the details.">
<link rel="preload" href="../fonts/GroothanMixed-Regular.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="../fonts/fonts.css">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta property="og:type" content="website"><meta property="og:site_name" content="Workbooks">
<meta property="og:title" content="Learning Center — Workbooks">
<meta property="og:description" content="Learn Workbooks from zero — {total} plain-language lessons, no technical background needed.">
<meta property="og:url" content="https://workbooks.sh/learn">
<style>
:root{{ --paper:#f7f6f1; --ink:#1a1b1e; --bloom:#13d943; --dim:#6a6f68; --line:#e3e1d8;
  --display:"Groothan","Anton",sans-serif; --mono:"JetBrains Mono",monospace; --read:"EB Garamond",Georgia,serif; }}
*{{ box-sizing:border-box; }} html{{ scroll-behavior:smooth; }}
body{{ margin:0; background:var(--paper); color:var(--ink); font-family:var(--read); overflow-x:hidden; -webkit-font-smoothing:antialiased; }}
a{{ color:inherit; text-decoration:none; }}
.lchero{{ max-width:1180px; margin:0 auto; padding:140px 7vw 0; }}
.lchero .kick{{ font:700 11px var(--mono); letter-spacing:.24em; text-transform:uppercase; color:var(--dim); }}
.lchero h1{{ font-family:var(--display); font-weight:400; font-size:clamp(46px,8vw,96px); line-height:.92; margin:14px 0 0; display:flex; flex-wrap:wrap; gap:0 .24em; align-items:baseline; }}
.lchero h1 .bub{{ color:var(--pc); --bub-stroke:5.4; }}
.lchero .dek{{ margin:22px 0 0; font-size:21px; line-height:1.55; color:#34372f; max-width:30em; }}
.lchero .stat{{ margin-top:22px; display:flex; gap:8px; flex-wrap:wrap; }}
.lchero .stat span{{ font:700 10.5px var(--mono); letter-spacing:.08em; text-transform:uppercase; border:2px solid var(--ink); border-radius:999px; padding:7px 13px; }}
.lchero .stat span.on{{ background:var(--pc); }}
.center{{ display:grid; grid-template-columns:210px 1fr; gap:56px; align-items:start; max-width:1180px; margin:50px auto 0; padding:0 7vw 120px; }}
.rail{{ position:sticky; top:118px; display:flex; flex-direction:column; gap:1px; }}
.rail a{{ display:flex; align-items:center; gap:11px; padding:9px 10px; border-radius:8px; font:700 11px var(--mono); letter-spacing:.03em; color:var(--dim); }}
.rail a span{{ width:13px; height:13px; flex:0 0 auto; border-radius:4px; border:1.5px solid var(--ink); }}
.rail a:hover{{ color:var(--ink); background:rgba(18,19,22,.05); }}
.units{{ display:flex; flex-direction:column; gap:60px; min-width:0; }}
.unit{{ scroll-margin-top:108px; }}
.uh{{ border-bottom:2px solid var(--ink); padding-bottom:15px; margin-bottom:20px; }}
.uh .un{{ font:700 10px var(--mono); letter-spacing:.24em; text-transform:uppercase; color:var(--dim); }}
.uh h2{{ font-family:var(--display); font-weight:400; font-size:clamp(27px,3.4vw,38px); line-height:1; margin:8px 0 0; }}
.uh p{{ margin:10px 0 0; font-family:var(--read); font-size:17px; line-height:1.5; color:var(--dim); max-width:50em; }}
.steps{{ display:flex; flex-direction:column; gap:9px; }}
.step{{ display:flex; align-items:center; gap:15px; padding:16px 18px; border:2px solid var(--ink); border-radius:13px; background:#fff; box-shadow:3px 3px 0 var(--ink); transition:transform .12s, box-shadow .12s; }}
.step:hover{{ transform:translate(-1px,-1px); box-shadow:5px 5px 0 var(--ink); }}
.step .seq{{ font:700 12px var(--mono); color:var(--ua,var(--dim)); flex:0 0 auto; }}
.step .lt{{ display:flex; flex-direction:column; gap:3px; min-width:0; flex:1; }}
.step .lt b{{ font-family:var(--display); font-weight:400; font-size:19px; letter-spacing:.005em; }}
.step .lt i{{ font-style:normal; font-size:15px; line-height:1.45; color:var(--dim); }}
.step .go{{ margin-left:auto; font-size:17px; color:var(--ac); flex:0 0 auto; opacity:0; transition:opacity .12s; }}
.step:hover .go{{ opacity:1; }}
.step.soon{{ background:none; box-shadow:none; border-style:dashed; border-color:rgba(18,19,22,.26); opacity:.6; }}
.step.soon:hover{{ transform:none; box-shadow:none; }}
.step .tag{{ margin-left:auto; font:700 8.5px var(--mono); letter-spacing:.14em; text-transform:uppercase; color:var(--dim); border:1.5px solid currentColor; border-radius:5px; padding:2px 6px; flex:0 0 auto; }}
@media (max-width:860px){{
  .lchero{{ padding-top:104px; }}
  .center{{ grid-template-columns:1fr; gap:0; padding-bottom:90px; }}
  .rail{{ position:static; flex-direction:row; flex-wrap:wrap; gap:6px; margin-bottom:34px; }}
  .rail a{{ border:2px solid rgba(18,19,22,.16); }}
}}
</style>
</head>
<body>
<!-- the order is the teacher. each lesson assumes the ones above and points to the ones below.
     this is the plain-language path; the literal proofs live one click away in the docs. -->
<div id="site-nav"></div>
<script src="../nav.js?v=9"></script>
<header class="lchero">
  <div class="kick">learn workbooks from zero</div>
  <h1><span>Learning</span> <span class="bub">CENTER</span></h1>
  <p class="dek">No technical background needed. {total} lessons, in the order that makes them teach — each one a single big idea, in plain language, with the deep docs one click away.</p>
  <div class="stat"><span class="on">8 units</span><span>{live} of {total} ready</span><span>start at the top</span></div>
</header>
<div class="center">
  <nav class="rail" aria-label="Units">{rail}</nav>
  <div class="units">{secs}</div>
</div>
</body>
</html>
"""
open(os.path.join(HERE,"index.html"),"w").write(OUT)
print(f"learn/index.html (Learning Center) — {total} lessons, {live} live")
