#!/usr/bin/env python3
"""Build a REAL training corpus from the workbooks repo (the work-* component library) and measure
whether a LoRA adapter actually teaches a local 3B that API — graded on HELD-OUT questions.

This is the real test of the LoRA trainer (vs the 5-fact toy): ~24 elements x several facts each,
ground-truth extracted from the element SOURCE (purpose + variant options/defaults + props), split
into train/held-out, then base-3B vs 3B+adapter measured on the held-out questions.

  python3.12 kit/dogfood.py build    # extract facts -> kit/data/dogfood/{train,test}.jsonl
  python3.12 kit/dogfood.py eval <adapter>   # base vs base+adapter on held-out, prints accuracy
"""
import os, sys, re, json, glob, urllib.request
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ELEMENTS = os.path.join(ROOT, "..", "workponents", "src", "elements")
def _elem_paths():
    return sorted(p for p in glob.glob(os.path.join(ELEMENTS, "**", "work-*.js"), recursive=True)
                  if "work-format" not in p)
DATA = os.path.join(ROOT, "kit", "data", "dogfood")
os.makedirs(DATA, exist_ok=True)
sys.path.insert(0, os.path.join(ROOT, "kit"))

def extract(path):
    """Pull ground-truth facts from a work-*.js element source."""
    src = open(path).read()
    # REAL registered tag from define("tag", Class)
    md = re.search(r'define\(\s*"([a-z0-9\-]+)"', src)
    tag = md.group(1) if md else "work-" + os.path.basename(path)[len("work-"):-3]
    # leading // comment header lines (strip the leading //)
    head = []
    for ln in src.splitlines():
        s = ln.strip()
        if s.startswith("//"): head.append(s[2:].strip())
        elif head and not s.startswith("*"): break
        elif s and not s.startswith("//"): break
    # purpose = the first comment paragraph (starts "<tag> — ..."); ends at a blank line or a section
    purpose_lines = []
    for h in head:
        if re.match(r"(Attributes?|Usage|Props?|Slots?):", h): break
        if h == "" and purpose_lines: break          # blank line ends the opening paragraph
        if h: purpose_lines.append(h)
    purpose = " ".join(purpose_lines).strip()
    purpose = re.split(r"\(see ", purpose)[0].strip()
    # one-sentence purpose (first sentence, drop a leading "<tag> — ")
    sent = re.split(r"(?<=[.;])\s", purpose)[0] if purpose else ""
    sent = re.sub(r"^<[^>]+>\s*[—\-:]\s*", "", sent).strip()
    # attributes: from defineVariants (button-style) AND/OR an "Attributes:" comment block (board-style)
    variants, attrs = {}, {}
    mv = re.search(r"defineVariants\(\{(.*?)\}\);", src, re.S)
    if mv:
        for am in re.finditer(r"(\w+):\s*\{\s*options:\s*\[([^\]]*)\][^}]*?default:\s*\"([^\"]+)\"", mv.group(1)):
            opts = [o.strip().strip('"') for o in am.group(2).split(",") if o.strip()]
            variants[am.group(1)] = {"options": opts, "default": am.group(3)}
    inattr = False
    for h in head:
        if re.match(r"Attributes?:", h): inattr = True; continue
        if inattr:
            if not h or re.match(r"(Usage|Props?|Slots?):", h) or h.startswith("<"): break
            am = re.match(r"(\w[\w\-]*)\s{2,}(.+)", h)
            if am:
                name, desc = am.group(1), am.group(2).strip()
                dm = re.search(r"\(default:\s*([^)]+)\)", desc)
                attrs[name] = {"desc": re.split(r"\(default:", desc)[0].strip(),
                               "default": dm.group(1).strip() if dm else None}
    return {"tag": tag, "purpose": sent, "variants": variants, "attrs": attrs}

def facts(el):
    """Emit (question_variants:list, answer) ground-truth facts for one element."""
    out = []
    t = el["tag"]
    if el["purpose"]:
        out.append(([f"What is <{t}>?", f"What does the {t} element do?", f"Describe <{t}>."],
                    el["purpose"].rstrip(".") + "."))
    allattrs = list(el["variants"]) + [a for a in el["attrs"] if a not in el["variants"]]
    if allattrs:
        out.append(([f"What attributes does <{t}> have?", f"List the attributes of <{t}>."],
                    f"The attributes of <{t}> are: {', '.join(allattrs)}."))
    for attr, v in el["variants"].items():
        out.append(([f"What values can the {attr} attribute of <{t}> take?",
                     f"What are the options for {t}'s {attr}?"],
                    f"The {attr} attribute of <{t}> can be: {', '.join(v['options'])}."))
        out.append(([f"What is the default {attr} of <{t}>?", f"What {attr} does <{t}> use by default?"],
                    f"The default {attr} of <{t}> is {v['default']}."))
    for attr, a in el["attrs"].items():
        if a["desc"]:
            out.append(([f"What does the {attr} attribute of <{t}> do?", f"What is {t}'s {attr} attribute for?"],
                        f"The {attr} attribute of <{t}> {a['desc']}."))
        if a["default"]:
            out.append(([f"What is the default {attr} of <{t}>?", f"What {attr} does <{t}> use by default?"],
                        f"The default {attr} of <{t}> is {a['default']}."))
    return out

def build():
    paths = _elem_paths()
    train, test = [], []
    nfacts = 0
    for p in paths:
        el = extract(p)
        for qs, a in facts(el):
            nfacts += 1
            # first phrasing(s) -> train; hold the LAST phrasing out for test (a NEW way to ask a
            # fact the adapter was trained on). Base-3B can't know our custom API => clean before/after.
            for q in qs[:-1]: train.append({"q": q, "a": a})
            test.append({"q": qs[-1], "a": a})
    # mlx-free: write pairs.jsonl (train) for the toolkit + test.jsonl for eval
    with open(os.path.join(DATA, "pairs.jsonl"), "w") as f:
        f.write("\n".join(json.dumps(r) for r in train))
    with open(os.path.join(DATA, "test.jsonl"), "w") as f:
        f.write("\n".join(json.dumps(r) for r in test))
    print(f"[build] {len(paths)} elements -> {nfacts} facts -> {len(train)} train pairs, {len(test)} held-out tests")
    print(f"[build] -> {DATA}/pairs.jsonl  +  test.jsonl")

def _key_span(answer):
    """The gradeable nugget of an answer (after the last ':' or ' is ')."""
    a = answer.rstrip(".")
    if ":" in a: return a.split(":")[-1].strip()
    if " is " in a: return a.split(" is ")[-1].strip()
    return a.strip()

def _graded(reply, answer):
    """Did the reply contain the key tokens of the expected answer? (order-free token overlap)."""
    exp = set(re.findall(r"[a-z0-9\-]+", _key_span(answer).lower())) - {"the","a","of","are","can","be"}
    got = set(re.findall(r"[a-z0-9\-]+", reply.lower()))
    if not exp: return False
    return len(exp & got) / len(exp) >= 0.6

def evaluate(adapter, base="3b", limit=None):
    import constellation as c
    tests = [json.loads(l) for l in open(os.path.join(DATA, "test.jsonl")) if l.strip()]
    if limit: tests = tests[:limit]
    base_port = c.ensure_server(base)                       # base alone
    adapt_port = c.ensure_server(base, adapter=adapter, port=c.PORTS[base] + 50)  # base + adapter
    nb = na = 0
    for t in tests:
        rb = c._complete(base_port, f"Question: {t['q']}\nAnswer:", n=40).split("\n")[0]
        ra = c._complete(adapt_port, f"Question: {t['q']}\nAnswer:", n=40).split("\n")[0]
        gb, ga = _graded(rb, t["a"]), _graded(ra, t["a"])
        nb += gb; na += ga
    n = len(tests)
    print(f"\n===== DOGFOOD EVAL ({n} held-out questions about the work-* API) =====")
    print(f"  base {base} alone:        {nb}/{n} = {100*nb/n:.0f}%")
    print(f"  base {base} + adapter:    {na}/{n} = {100*na/n:.0f}%   (lift: +{100*(na-nb)/n:.0f} pts)")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "build"
    if cmd == "build": build()
    elif cmd == "eval": evaluate(sys.argv[2], limit=(int(sys.argv[3]) if len(sys.argv) > 3 else None))
