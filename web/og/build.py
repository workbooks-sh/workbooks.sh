#!/usr/bin/env python3
"""Procedural social cards from each page's org spec.

Every CMS page carries <script type="text/org" id="workbook-spec"> — its
publishable record. This reads the spec (never the HTML around it), composes
the card (left: constructed lockup from the spec · right: the page's hero
art, full-bleed ~1/3), renders via headless Chrome, and writes og/<slug>.jpg.

Usage:  python3 og/build.py [slug ...]   (default: every learn/*.html w/ a spec)
"""
import glob, os, re, subprocess, sys, tempfile

WEB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

def parse_spec(html):
    m = re.search(r'<script type="text/org" id="workbook-spec">\n(.*?)</script>', html, re.S)
    if not m: return None
    org = m.group(1)
    props = dict(re.findall(r':([A-Z0-9]+):[ \t]+(\S.*)', org))
    props.pop("PROPERTIES", None); props.pop("END", None)
    props["OGLINES"] = re.findall(r'^- (.+)$', org, re.M)
    return props

TPL = """<!doctype html><meta charset="utf-8">
<style>
@font-face {{ font-family:"Groothan"; src:url("{web}/fonts/GroothanMixed-Regular.woff2") format("woff2"); }}
* {{ margin:0; box-sizing:border-box; }}
body {{ width:1200px; height:630px; overflow:hidden; position:relative;
       background:#f7f6f1; font-family:"JetBrains Mono", ui-monospace, monospace;
       background-image: linear-gradient(rgba(18,19,22,.05) 1px, transparent 1px),
                         linear-gradient(90deg, rgba(18,19,22,.05) 1px, transparent 1px);
       background-size: 56px 56px; }}
.art {{ position:absolute; right:0; top:0; bottom:0; width:400px;
       border-left:3px solid #121316; }}
.art img {{ width:100%; height:100%; object-fit:cover; display:block; }}
.col {{ position:absolute; left:64px; top:56px; right:440px; bottom:56px;
       display:flex; flex-direction:column; }}
.lockrow {{ display:flex; align-items:center; gap:13px; }}
.lockrow svg {{ width:46px; color:#121316; }}
.lockrow b {{ font:400 27px "Groothan"; color:#121316; }}
.kick {{ margin-top:26px; font-size:15px; font-weight:700; letter-spacing:.3em;
        text-transform:uppercase; color:#565b54; }}
.kick i {{ font-style:normal; color:{ac}; }}
h1 {{ font:400 78px/0.95 "Groothan"; color:#121316; margin:18px 0 auto; }}
h1 .bub {{ display:block; font-size:84px; color:#fff; -webkit-text-stroke:5px #121316;
          paint-order:stroke fill; margin:-8px 0 -6px; }}
.lines {{ margin-top:20px; }}
.lines .ln {{ font-size:17px; line-height:2; color:#3a3e38; }}
.lines .ln::before {{ content:"■  "; color:{ac}; font-size:12px; }}
.foot {{ margin-top:26px; display:flex; align-items:center; gap:14px; }}
.chip {{ background:{pc}; border:2.5px solid #121316; border-radius:10px; padding:7px 16px;
        font:400 20px "Groothan"; color:#121316; }}
.url {{ background:#121316; color:#f7f6f1; border-radius:10px; padding:10px 18px;
       font-size:16px; font-weight:700; }}
.url i {{ font-style:normal; color:#3fe081; }}
</style>
<div class="col">
  <div class="lockrow">{wmark}<b>workbooks</b></div>
  <div class="kick">learn / {nn} — <i>{kicker}</i></div>
  <h1>{t1}<span class="bub">{t2}</span>{t3}</h1>
  <div class="lines">{lines}</div>
  <div class="foot"><span class="chip">{chip}</span><span class="url">workbooks.sh/learn/{slug} <i>&gt;_</i></span></div>
</div>
<div class="art"><img src="{web}/learn/{hero}"></div>
"""

WMARK = '<svg viewBox="0 0 113.444 65.6002" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z" fill="currentColor"/></svg>'

def build(slug):
    html = open(os.path.join(WEB, "learn", slug + ".html")).read()
    p = parse_spec(html)
    if not p:
        print("no spec:", slug); return
    page = TPL.format(web="file://" + WEB, wmark=WMARK,
        nn=p["NN"], kicker=p["KICKER"], t1=p["TITLE1"], t2=p["TITLE2"], t3=p["TITLE3"],
        chip=p["CHIP"], slug=p["SLUG"], hero=p["HERO"], pc=p["PC"], ac=p["AC"],
        lines="".join(f'<div class="ln">{l}</div>' for l in p["OGLINES"]))
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as t:
        t.write(page); tmp = t.name
    out = os.path.join(WEB, "og", slug + ".png")
    subprocess.run([CHROME, "--headless=new", "--screenshot=" + out,
                    "--window-size=1200,630", "--hide-scrollbars",
                    "--virtual-time-budget=4000", "--disable-gpu",
                    "file://" + tmp], check=True, capture_output=True)
    jpg = os.path.join(WEB, "og", slug + ".jpg")
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "88",
                    out, "--out", jpg], check=True, capture_output=True)
    os.remove(out); os.remove(tmp)
    print("og/", slug + ".jpg")

slugs = sys.argv[1:] or [os.path.basename(f)[:-5] for f in glob.glob(os.path.join(WEB, "learn", "*.html"))
                         if 'id="workbook-spec"' in open(f).read()]
for s in slugs: build(s)
