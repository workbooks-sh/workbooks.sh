#!/usr/bin/env python3
"""Build the Learning Center — a real course interface (Kajabi-style), not blog
posts. Generates from lms.json + content/<slug>.html:
  /learn/index.html        the course dashboard (overview + start/continue)
  /learn/<slug>.html       the lesson player (curriculum sidebar + lesson pane)
Progress lives in the browser (localStorage); no backend. Re-run after edits.
"""
import json, os, html

HERE = os.path.dirname(os.path.abspath(__file__))
lms = json.load(open(os.path.join(HERE, "lms.json")))
units = lms["units"]

# flat ordered list with unit context + prev/next
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

# doc metadata for the go-deeper box (titles from the catalog)
cat = json.load(open(os.path.join(HERE, "lessons.json")))
doc_title = {}
for t in cat["tiers"]:
    for cl in t["lessons"]:
        doc_title[cl["slug"]] = cl.get("title", cl["slug"])
        for s in cl.get("sublessons", []):
            doc_title[s["slug"]] = s.get("title", s["slug"])

def esc(s): return html.escape(s or "")

WORDMARK = ('<svg viewBox="0 0 113.444 65.6" fill="currentColor" aria-hidden="true">'
  '<path d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308c0.291 9.772-0.064 19.654 0.223 29.43'
  '0.025 0.83 0.409 1.404 0.929 2.005 5.717 1.721 18.361-17.898 24.53-20.003 2.986 0.604 9.166 8.258 11.352 10.717'
  '-3.543 5.96-19 18.234-20.891 22.546 0.018 1.284 0.068 1.322 0.775 2.439 1.55 1.195 26.095 0.545 30.976 1.022'
  '0.437 5.52 0.298 11.4 0.258 16.964-11.721 0.02-26.712 1.352-36.918-3.738-8.424-4.163-14.823-11.531-17.769-20.452'
  '-0.765-2.653-1.317-5.088-1.924-7.771-1.181 5.233-2.103 9.52-4.859 14.238-12.117 20.736-31.693 17.75-51.856 17.683'
  '-0.058-5.743-0.006-11.488 0.222-17.228 5.29-0.025 28.203 0.581 31.477-0.89 0.163-0.374 0.206-0.422 0.288-0.866'
  '0.685-3.723-17.429-19.055-20.368-23.566l-0.246-0.382c1.804-2.549 7.974-9.383 10.69-10.683 3.728-0.563 17.939 18.057 22.393 19.915'
  '1.389 0.579 1.612 0.542 2.835 0.062 1.375-1.953 0.915-8.93 0.926-11.598L48.271 0.137Z"/></svg>')

def sidebar(cur_slug=None):
    out = ['<aside class="side" id="side">',
           '<a class="brand" href="/">%s<span>Workbooks</span></a>' % WORDMARK,
           '<a class="overview" href="/learn">Course overview</a>',
           '<div class="prog"><div class="bar"><i id="pbar"></i></div><span id="ptxt">0 of %d complete</span></div>' % TOTAL,
           '<nav class="curr" id="curr">']
    for u in units:
        out.append('<div class="umod"><div class="uhd"><span class="un">Unit %d</span>%s</div>'
                   % (u["n"], esc(u["title"])))
        for l in u["lessons"]:
            cls = "li" + (" cur" if l["slug"] == cur_slug else "")
            out.append('<a class="%s" data-slug="%s" href="/learn/%s">'
                       '<span class="dot"></span><span class="t">%s</span></a>'
                       % (cls, l["slug"], esc(l["slug"]), esc(l["title"])))
        out.append('</div>')
    out.append('</nav></aside>')
    return "".join(out)

HEAD = """<!doctype html>
<html lang="en" style="--pc:#a8d4f0;">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="preload" href="../fonts/GroothanMixed-Regular.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="../fonts/fonts.css">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta property="og:type" content="{ogtype}"><meta property="og:site_name" content="Workbooks · Learning Center">
<meta property="og:title" content="{title}"><meta property="og:description" content="{desc}">
<meta property="og:url" content="{url}">
<style>{css}</style>
</head>
<body class="{bodycls}">
{topbar}
<div class="app">
{sidebar}
<main class="pane">
{main}
</main>
</div>
<div class="scrim" id="scrim"></div>
<script>{js}</script>
</body>
</html>
"""

CSS = """
:root{ --paper:#f7f6f1; --ink:#1a1b1e; --bloom:#13d943; --bloomd:#149157; --dim:#6a6f68; --line:#e7e5db; --pc:#a8d4f0;
  --display:"Groothan","Anton",sans-serif; --mono:"JetBrains Mono",monospace; --read:"EB Garamond",Georgia,serif; }
*{ box-sizing:border-box; }
html{ scroll-behavior:smooth; }
body{ margin:0; background:var(--paper); color:var(--ink); font-family:var(--read); -webkit-font-smoothing:antialiased; }
a{ color:inherit; text-decoration:none; }
.app{ display:flex; align-items:flex-start; min-height:100vh; }

/* ── curriculum sidebar ── */
.side{ width:316px; flex:0 0 316px; position:sticky; top:0; height:100vh; overflow-y:auto;
  border-right:2px solid var(--ink); background:var(--paper); padding:24px 16px 40px; z-index:30; }
.brand{ display:flex; align-items:center; gap:10px; padding:4px 8px 18px; }
.brand svg{ width:26px; height:auto; color:var(--ink); }
.brand span{ font:700 13px var(--mono); letter-spacing:.04em; }
.overview{ display:block; font:700 10px var(--mono); letter-spacing:.18em; text-transform:uppercase; color:var(--dim);
  padding:8px; border-radius:7px; }
.overview:hover{ background:rgba(18,19,22,.05); color:var(--ink); }
.prog{ margin:8px 8px 20px; }
.prog .bar{ height:7px; border:2px solid var(--ink); border-radius:999px; overflow:hidden; background:#fff; }
.prog .bar i{ display:block; height:100%; width:0; background:var(--bloom); transition:width .3s; }
.prog span{ display:block; margin-top:7px; font:700 10px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
.umod{ margin-bottom:14px; }
.uhd{ display:flex; align-items:baseline; gap:8px; padding:8px 8px 7px; font:700 12px var(--mono); letter-spacing:.02em; }
.uhd .un{ font-size:8.5px; letter-spacing:.18em; text-transform:uppercase; color:var(--dim); }
.li{ display:flex; align-items:flex-start; gap:10px; padding:9px 8px; border-radius:8px; font-size:15px; line-height:1.3;
  color:#3a3e38; }
.li:hover{ background:rgba(18,19,22,.05); }
.li .dot{ width:15px; height:15px; flex:0 0 auto; margin-top:1px; border:2px solid var(--dim); border-radius:50%;
  position:relative; }
.li.done .dot{ background:var(--bloom); border-color:var(--bloomd); }
.li.done .dot::after{ content:""; position:absolute; left:4px; top:1px; width:4px; height:8px;
  border:solid var(--ink); border-width:0 2px 2px 0; transform:rotate(45deg); }
.li.cur{ background:var(--pc); }
.li.cur .dot{ border-color:var(--ink); }
.li.cur .dot::after{ content:""; position:absolute; inset:2px; background:var(--ink); border-radius:50%; }
.li.cur .t{ font-weight:600; color:var(--ink); }

/* ── lesson pane ── */
.pane{ flex:1; min-width:0; max-width:744px; margin:0 auto; padding:74px 44px 60px; }
.crumb{ font:700 11px var(--mono); letter-spacing:.16em; text-transform:uppercase; color:var(--bloomd); }
.pane h1{ font-family:var(--display); font-weight:400; font-size:clamp(34px,4.6vw,52px); line-height:1.04;
  margin:14px 0 0; letter-spacing:-.005em; }
.promise{ font-size:clamp(19px,2.4vw,23px); line-height:1.5; color:#34372f; margin:18px 0 0; font-style:italic; }
.play{ display:flex; align-items:center; gap:13px; margin:28px 0 0; padding:12px 16px; border:2px solid var(--ink);
  border-radius:999px; width:max-content; max-width:100%; background:#fff; box-shadow:3px 3px 0 var(--ink); cursor:pointer; user-select:none; }
.play .ico{ width:28px; height:28px; flex:0 0 auto; border-radius:50%; background:var(--ink); display:flex; align-items:center; justify-content:center; }
.play .ico svg{ width:12px; height:12px; fill:var(--paper); display:block; }
.play .lab{ font:700 12px var(--mono); letter-spacing:.05em; text-transform:uppercase; }
.play .time{ font:500 11px var(--mono); color:var(--dim); }
.play.playing .ico{ background:var(--bloomd); }

article{ margin-top:42px; }
article > p{ font-size:20px; line-height:1.66; margin:0 0 23px; }
article > p.lead{ font-size:23px; line-height:1.55; color:#26282b; }
article h2{ font-family:var(--display); font-weight:400; font-size:clamp(24px,3.4vw,31px); line-height:1.1; margin:50px 0 17px; }
article b,article strong{ font-weight:600; } article em{ font-style:italic; }
article .aside{ margin:28px 0; padding:19px 23px; border-left:3px solid var(--pc); background:#fff; font-size:18.5px;
  line-height:1.6; color:#34372f; border-radius:0 10px 10px 0; }
article .big{ font-family:var(--display); font-weight:400; font-size:clamp(23px,3.8vw,33px); line-height:1.18;
  margin:42px 0; letter-spacing:-.01em; }
article hr{ border:0; border-top:1px solid var(--line); margin:44px 0; }

.deeper{ margin:52px 0 0; padding:24px; border:2px solid var(--ink); border-radius:16px; background:#fff; box-shadow:4px 4px 0 var(--ink); }
.deeper .dh{ font:700 11px var(--mono); letter-spacing:.16em; text-transform:uppercase; color:var(--dim); }
.deeper p{ font-size:17px; line-height:1.55; margin:8px 0 15px; color:#34372f; }
.deeper .links{ display:flex; flex-direction:column; gap:8px; }
.deeper a.dl{ display:flex; align-items:center; gap:11px; padding:11px 13px; border:1.5px solid var(--line); border-radius:10px; }
.deeper a.dl:hover{ border-color:var(--ink); background:rgba(18,19,22,.03); }
.deeper a.dl b{ font:700 13px var(--mono); } .deeper a.dl span{ font-size:11px; color:var(--dim); margin-left:auto; }

.foot{ display:flex; align-items:center; gap:14px; margin:54px 0 0; padding-top:28px; border-top:1px solid var(--line); }
.foot .prevl{ font:700 11px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim); }
.foot .prevl:hover{ color:var(--ink); }
.foot .cont{ margin-left:auto; display:inline-flex; align-items:center; gap:9px; font:700 12px var(--mono);
  letter-spacing:.05em; text-transform:uppercase; color:var(--paper); background:var(--ink); border:2px solid var(--ink);
  border-radius:999px; padding:13px 22px; cursor:pointer; box-shadow:3px 3px 0 var(--bloomd); }
.foot .cont:hover{ background:var(--bloomd); border-color:var(--bloomd); box-shadow:3px 3px 0 var(--ink); }
.foot .cont.done{ background:var(--bloom); color:var(--ink); border-color:var(--bloomd); }

/* soon pane */
.soon-pane{ margin-top:42px; }
.soon-pane .badge{ display:inline-block; font:700 10px var(--mono); letter-spacing:.16em; text-transform:uppercase;
  color:var(--dim); border:2px dashed rgba(18,19,22,.3); border-radius:999px; padding:8px 15px; }
.soon-pane p{ font-size:20px; line-height:1.6; margin:22px 0; color:#34372f; }

/* topbar (mobile only) */
.topbar{ display:none; }
.scrim{ display:none; }

/* ── dashboard ── */
.dash{ flex:1; min-width:0; }
.dhero{ max-width:900px; margin:0 auto; padding:120px 7vw 0; }
.dhero .kick{ font:700 11px var(--mono); letter-spacing:.22em; text-transform:uppercase; color:var(--dim); }
.dhero h1{ font-family:var(--display); font-weight:400; font-size:clamp(44px,7vw,88px); line-height:.92; margin:14px 0 0;
  display:flex; flex-wrap:wrap; gap:0 .22em; align-items:baseline; }
.dhero h1 .bub{ color:var(--pc); --bub-stroke:5.4; }
.dhero .dek{ margin:22px 0 0; font-size:21px; line-height:1.55; color:#34372f; max-width:30em; }
.dhero .cta{ margin:30px 0 0; display:flex; gap:12px; flex-wrap:wrap; align-items:center; }
.dhero .start{ display:inline-flex; align-items:center; gap:10px; font:700 13px var(--mono); letter-spacing:.05em;
  text-transform:uppercase; color:var(--paper); background:var(--ink); border:2px solid var(--ink); border-radius:999px;
  padding:15px 26px; box-shadow:4px 4px 0 var(--bloomd); }
.dhero .start:hover{ background:var(--bloomd); border-color:var(--bloomd); box-shadow:4px 4px 0 var(--ink); }
.dhero .dprog{ font:700 11px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
.dunits{ max-width:900px; margin:56px auto 0; padding:0 7vw 120px; display:flex; flex-direction:column; gap:50px; }
.dunit .duh{ border-bottom:2px solid var(--ink); padding-bottom:13px; margin-bottom:16px; }
.dunit .duh .un{ font:700 10px var(--mono); letter-spacing:.22em; text-transform:uppercase; color:var(--dim); }
.dunit .duh h2{ font-family:var(--display); font-weight:400; font-size:clamp(25px,3.2vw,34px); line-height:1; margin:8px 0 0; }
.dunit .duh p{ margin:9px 0 0; font-size:16px; line-height:1.5; color:var(--dim); max-width:48em; }
.dsteps{ display:flex; flex-direction:column; gap:8px; }
.dstep{ display:flex; align-items:center; gap:14px; padding:15px 18px; border:2px solid var(--ink); border-radius:13px;
  background:#fff; box-shadow:3px 3px 0 var(--ink); transition:transform .12s,box-shadow .12s; }
.dstep:hover{ transform:translate(-1px,-1px); box-shadow:5px 5px 0 var(--ink); }
.dstep .dot{ width:17px; height:17px; flex:0 0 auto; border:2px solid var(--dim); border-radius:50%; position:relative; }
.dstep.done .dot{ background:var(--bloom); border-color:var(--bloomd); }
.dstep.done .dot::after{ content:""; position:absolute; left:5px; top:1px; width:4px; height:9px; border:solid var(--ink); border-width:0 2px 2px 0; transform:rotate(45deg); }
.dstep .lt{ display:flex; flex-direction:column; gap:3px; min-width:0; flex:1; }
.dstep .lt b{ font-family:var(--display); font-weight:400; font-size:19px; }
.dstep .lt i{ font-style:normal; font-size:15px; line-height:1.45; color:var(--dim); }
.dstep .go{ margin-left:auto; font-size:17px; color:var(--bloomd); opacity:0; }
.dstep:hover .go{ opacity:1; }
.dstep.soon{ background:none; box-shadow:none; border-style:dashed; border-color:rgba(18,19,22,.26); opacity:.62; }
.dstep.soon:hover{ transform:none; box-shadow:none; }
.dstep.soon .tag{ margin-left:auto; font:700 8.5px var(--mono); letter-spacing:.14em; text-transform:uppercase; color:var(--dim); border:1.5px solid currentColor; border-radius:5px; padding:2px 6px; }

@media (max-width:900px){
  .topbar{ display:flex; align-items:center; gap:13px; position:sticky; top:0; z-index:40; background:var(--paper);
    border-bottom:2px solid var(--ink); padding:11px 16px; }
  .topbar .burger{ width:26px; height:19px; display:flex; flex-direction:column; justify-content:center; gap:5px;
    background:none; border:0; padding:0; cursor:pointer; }
  .topbar .burger span{ display:block; height:2.5px; border-radius:2px; background:var(--ink); }
  .topbar .tt{ font:700 11px var(--mono); letter-spacing:.04em; }
  .topbar .tp{ margin-left:auto; font:700 10px var(--mono); color:var(--dim); }
  .side{ position:fixed; top:0; left:0; height:100vh; transform:translateX(-100%); transition:transform .25s ease;
    box-shadow:6px 0 0 rgba(0,0,0,.08); }
  .side.open{ transform:translateX(0); }
  .scrim.show{ display:block; position:fixed; inset:0; background:rgba(0,0,0,.32); z-index:25; }
  .pane{ padding:30px 22px 90px; max-width:none; }
  .dhero{ padding-top:30px; } .dunits{ padding-bottom:80px; }
  .foot{ flex-wrap:wrap; } .foot .cont{ margin-left:0; width:100%; justify-content:center; }
}
"""

JS = """
(function(){
  var KEY="wb-lms-done", LAST="wb-lms-last";
  function done(){ try{ return JSON.parse(localStorage.getItem(KEY))||[]; }catch(e){ return []; } }
  function save(a){ localStorage.setItem(KEY, JSON.stringify(a)); }
  var d=done(), total=%TOTAL%;
  // paint sidebar + progress
  document.querySelectorAll(".li,.dstep").forEach(function(el){
    if(d.indexOf(el.dataset.slug)>=0) el.classList.add("done");
  });
  var pct=Math.round(d.length/total*100);
  var bar=document.getElementById("pbar"), txt=document.getElementById("ptxt");
  if(bar) bar.style.width=pct+"%";
  if(txt) txt.textContent=d.length+" of "+total+" complete";
  var tp=document.getElementById("tprog"); if(tp) tp.textContent=pct+"%";
  var dp=document.getElementById("dprog"); if(dp) dp.textContent=(d.length?d.length+" of "+total+" complete":total+" lessons");
  // record visit (for continue)
  var cur=document.body.dataset.slug;
  if(cur) localStorage.setItem(LAST, cur);
  // continue button on dashboard
  var cont=document.getElementById("startbtn");
  if(cont){
    var last=localStorage.getItem(LAST);
    if(last && d.length){ cont.textContent="Continue →"; cont.href="/learn/"+last; }
  }
  // complete & continue
  var cc=document.getElementById("cc");
  if(cc){
    if(d.indexOf(cur)>=0){ cc.classList.add("done"); cc.firstChild.textContent="Completed "; }
    cc.addEventListener("click",function(){
      var a=done(); if(a.indexOf(cur)<0){ a.push(cur); save(a); }
      var nx=cc.dataset.next;
      if(nx) location.href="/learn/"+nx; else location.href="/learn";
    });
  }
  // mobile drawer
  var side=document.getElementById("side"), scrim=document.getElementById("scrim"), b=document.getElementById("burger");
  function close(){ side&&side.classList.remove("open"); scrim&&scrim.classList.remove("show"); }
  if(b) b.addEventListener("click",function(){ side.classList.toggle("open"); scrim.classList.toggle("show"); });
  if(scrim) scrim.addEventListener("click",close);
  // audio
  var pl=document.getElementById("play");
  if(pl){ var au=null, lab=document.getElementById("playlab");
    pl.addEventListener("click",function(){
      if(!au){ au=new Audio(pl.dataset.src); au.addEventListener("ended",function(){ pl.classList.remove("playing"); lab.textContent="Listen"; }); }
      if(au.paused){ au.play(); pl.classList.add("playing"); lab.textContent="Pause"; }
      else{ au.pause(); pl.classList.remove("playing"); lab.textContent="Listen"; }
    });
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
    links = "".join('<a class="dl" href="/learn/%s"><b>%s</b><span>the deep doc</span></a>'
                    % (esc(s), esc(doc_title.get(s, s))) for s in docs)
    return ('<div class="deeper"><div class="dh">Go deeper — the technical docs</div>'
            '<p>That was the idea. When you want the literal version — the actual format, the bytes, the proof — start here.</p>'
            '<div class="links">%s</div></div>' % links)

def lesson_page(l):
    live = l["status"] == "live" and os.path.exists(os.path.join(HERE, "content", l["slug"] + ".html"))
    crumb = "Unit %d · %s · Lesson %d" % (l["unit"], esc(l["unit_title"]), l["i"]+1)
    player = ""
    if l.get("audio"):
        player = ('<div class="play" id="play" data-src="%s"><span class="ico">'
                  '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg></span>'
                  '<span class="lab" id="playlab">Listen</span><span class="time">%s</span></div>'
                  % (esc(l["audio"]), esc(l.get("mins", ""))))
    if live:
        body = open(os.path.join(HERE, "content", l["slug"] + ".html")).read()
        main = ('<div class="crumb">%s</div><h1>%s</h1>%s%s<article>%s</article>%s'
                % (crumb, esc(l["title"]),
                   '<p class="promise">%s</p>' % esc(l["promise"]) if l.get("promise") else "",
                   player, body, deeper_box(l.get("docs"))))
    else:
        main = ('<div class="crumb">%s</div><h1>%s</h1>'
                '<div class="soon-pane"><span class="badge">Lesson coming soon</span>'
                '<p>%s</p><p>While this lesson is being written, the technical docs below already cover the ground.</p></div>%s'
                % (crumb, esc(l["title"]), esc(l.get("teaches", "")), deeper_box(l.get("docs"))))
    prev = ('<a class="prevl" href="/learn/%s">← %s</a>' % (esc(l["prev"]["slug"]), esc(l["prev"]["title"])) if l["prev"] else '<a class="prevl" href="/learn">← Overview</a>')
    nxt = l["next"]["slug"] if l["next"] else ""
    cclabel = "Mark complete & continue" if l["next"] else "Mark complete & finish"
    foot = ('<div class="foot">%s<button class="cont" id="cc" data-next="%s"><span>%s</span> →</button></div>'
            % (prev, esc(nxt), cclabel))
    return HEAD.format(
        title=esc(l["title"]) + " — Learning Center — Workbooks",
        desc=esc(l.get("teaches", "")), ogtype="article",
        url="https://workbooks.sh/learn/" + l["slug"], css=CSS, js=JS,
        bodycls='lesson" data-slug="%s' % esc(l["slug"]),
        topbar=topbar(l["title"]), sidebar=sidebar(l["slug"]),
        main=main + foot)

def dashboard():
    first = next((x["slug"] for x in flat if x["status"] == "live"), flat[0]["slug"])
    secs = ""
    n = 0
    for u in units:
        rows = ""
        for l in u["lessons"]:
            n += 1
            on = l["status"] == "live"
            inner = ('<span class="dot"></span><span class="lt"><b>%s</b><i>%s</i></span>'
                     % (esc(l["title"]), esc(l.get("teaches", ""))))
            if on:
                rows += '<a class="dstep" data-slug="%s" href="/learn/%s">%s<span class="go">→</span></a>' % (esc(l["slug"]), esc(l["slug"]), inner)
            else:
                rows += '<div class="dstep soon" data-slug="%s">%s<span class="tag">soon</span></div>' % (esc(l["slug"]), inner)
        secs += ('<div class="dunit"><div class="duh"><span class="un">Unit %d</span>'
                 '<h2>%s</h2><p>%s</p></div><div class="dsteps">%s</div></div>'
                 % (u["n"], esc(u["title"]), esc(u["dek"]), rows))
    main = ('<div class="dash"><header class="dhero"><div class="kick">learn workbooks from zero</div>'
            '<h1><span>Learning</span> <span class="bub">CENTER</span></h1>'
            '<p class="dek">No technical background needed. %d deep, plain-language lessons in order — each a single big idea, with the technical docs one click away.</p>'
            '<div class="cta"><a class="start" id="startbtn" href="/learn/%s">Start the course →</a>'
            '<span class="dprog" id="dprog">%d lessons</span></div></header>'
            '<div class="dunits">%s</div></div>'
            % (TOTAL, esc(first), TOTAL, secs))
    return HEAD.format(
        title="Learning Center — Workbooks",
        desc="Learn Workbooks from zero — %d plain-language lessons, no technical background needed." % TOTAL,
        ogtype="website", url="https://workbooks.sh/learn", css=CSS, js=JS,
        bodycls="dashpage", topbar=topbar("Learning Center"), sidebar="", main=main)

# write everything
open(os.path.join(HERE, "index.html"), "w").write(dashboard())
for l in flat:
    open(os.path.join(HERE, l["slug"] + ".html"), "w").write(lesson_page(l))
print("Learning Center built: dashboard + %d lesson pages (%d live)" % (TOTAL, LIVE))
