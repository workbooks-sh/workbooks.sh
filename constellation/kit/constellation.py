#!/usr/bin/env python3
"""Constellation — a Granite base + plug-and-play LoRA adapters, ALL on llama.cpp / GGUF.

ONE lane: train and serve in the same place, so adapters transfer cleanly (no cross-quant loss).
  train      — PEFT-train a LoRA on an HF Granite base, convert to a GGUF adapter
  self-learn — the base reads a doc, generates its OWN Q&A curriculum, trains an adapter on it
  serve      — llama-server: a Granite GGUF base + any GGUF adapters (hot-swappable)
  ask        — query the served base, optionally with an adapter plugged in
  kit        — list the GGUF adapters you've built

Training is PEFT (HuggingFace, on the Mac GPU/MPS) -> convert_lora_to_gguf -> GGUF. Serving is
llama-server. Same arch both sides => the adapter applies cleanly. Local Mac trains small bases
(350m/1b/3b fit); 8B adapters train on a real GPU (the training station) and serve here as GGUF.

Run: python3.12 kit/constellation.py <command> ...
"""
import os, sys, json, time, argparse, subprocess, urllib.request
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # constellation/
ADAPTERS = os.path.join(ROOT, "kit", "adapters")
DATA = os.path.join(ROOT, "kit", "data")
CONVERT = os.path.join(ROOT, "spike", "llamacpp-src", "convert_lora_to_gguf.py")
os.makedirs(ADAPTERS, exist_ok=True); os.makedirs(DATA, exist_ok=True)

# Each base pairs an HF dir (for PEFT training) with a GGUF (for llama.cpp serving). Same arch both
# sides. hf=None => serve-only locally; train its adapters on a GPU and drop the .gguf in adapters/.
BASES = {
    "350m": {"hf": "spike/dflash/granite-4.0-350m", "gguf": "spike/models/granite-4.0-350m-Q4_K_M.gguf"},
    "1b":   {"hf": "spike/dflash/granite-4.0-1b", "gguf": "spike/models/granite-4.0-1b-Q4_K_M.gguf"},
    "3b":   {"hf": None, "gguf": "spike/models/granite-4.1-3b-Q4_K_M.gguf"},
    "8b":   {"hf": None, "gguf": "spike/models/granite-4.1-8b-Q5_K_M.gguf"},
}
PORTS = {"350m": 8104, "1b": 8101, "3b": 8102, "8b": 8103}
def _abs(p): return p if os.path.isabs(p) else os.path.join(ROOT, p)
def gguf_of(b):
    g = _abs(BASES[b]["gguf"]);  assert os.path.exists(g), f"missing GGUF for {b}: {g}";  return g
def hf_of(b):
    h = BASES[b]["hf"]
    if not h: sys.exit(f"base '{b}' has no local HF weights — train its adapters on a GPU, or use 350m locally.")
    return _abs(h)

# ---------- serving (llama-server) ----------
def _health(port):
    try: return b"ok" in urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2).read()
    except Exception: return False

def ensure_server(base, adapter=None, port=None):
    """Start a llama-server for `base` (+ optional GGUF adapter) if not already up. Returns the port."""
    port = port or PORTS[base]
    if _health(port): return port
    cmd = ["llama-server", "-m", gguf_of(base), "-ngl", "0", "--port", str(port), "-c", "2048", "--jinja"]
    if adapter:
        cmd += ["--lora", adapter if os.path.isabs(adapter) else os.path.join(ADAPTERS, f"{adapter}.gguf")]
    log = open(f"/tmp/constellation-{base}.log", "w")
    subprocess.Popen(cmd, stdout=log, stderr=log)
    for _ in range(50):
        if _health(port): return port
        time.sleep(2)
    sys.exit(f"server for {base} failed to come up (see /tmp/constellation-{base}.log)")

def serve(base="8b", adapters=None, port=None):
    port = port or PORTS[base]
    cmd = ["llama-server", "-m", gguf_of(base), "-ngl", "0", "--port", str(port), "-c", "4096", "--jinja"]
    for a in (adapters or []):
        cmd += ["--lora", a if os.path.isabs(a) else os.path.join(ADAPTERS, f"{a}.gguf")]
    print(f"[serve] {base}" + (f" + {adapters}" if adapters else "") + f" on :{port} (OpenAI API)…", flush=True)
    subprocess.run(cmd)

def _complete(port, prompt, n=64, temp=0.0):
    body = json.dumps({"prompt": prompt, "n_predict": n, "temperature": temp}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/completion", body, {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=180).read())["content"]

def ask(question, base="8b", adapter=None, max_tokens=64):
    port = ensure_server(base, adapter=adapter)
    return _complete(port, f"Question: {question}\nAnswer:", n=max_tokens).split("\n")[0].strip()

# ---------- data ----------
def write_data(name, pairs):
    d = os.path.join(DATA, name); os.makedirs(d, exist_ok=True)
    rows = [{"q": q, "a": a} for q, a in pairs]
    with open(os.path.join(d, "pairs.jsonl"), "w") as f:
        f.write("\n".join(json.dumps(r) for r in rows))
    return d

def _load_pairs(data_dir):
    p = os.path.join(data_dir, "pairs.jsonl")
    return [(j["q"], j["a"]) for j in (json.loads(l) for l in open(p) if l.strip())]

# ---------- training (PEFT -> GGUF) ----------
def train(name, data_dir, base="350m", steps=300, lr=2e-4):
    """PEFT-train a LoRA on the HF base (Mac GPU/MPS), then convert it to a GGUF adapter."""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from peft import LoraConfig, get_peft_model
    hf = hf_of(base); pairs = _load_pairs(data_dir)
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"[train] PEFT LoRA on {base} ({hf}) dev={dev}, {len(pairs)} pairs x {steps} steps…", flush=True)
    tok = AutoTokenizer.from_pretrained(hf)
    if tok.pad_token is None: tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(hf, dtype=torch.float32).to(dev)
    # target ALL linear layers (not just q/v) — far more capacity to memorize exact facts (numbers,
    # command strings). q/v-only learns associations but confabulates rare tokens.
    model = get_peft_model(model, LoraConfig(r=16, lora_alpha=32, lora_dropout=0.0, task_type="CAUSAL_LM",
                           target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]))
    ex = [tok(f"Question: {q}\nAnswer: {a}{tok.eos_token}", return_tensors="pt").input_ids[0] for q, a in pairs]
    opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=lr)
    model.train(); t0 = time.time()
    for s in range(steps):
        e = ex[s % len(ex)].unsqueeze(0).to(dev)
        o = model(e, labels=e); o.loss.backward(); opt.step(); opt.zero_grad()
        if s % max(1, steps // 4) == 0 or s == steps - 1: print(f"  step {s:4d} loss {o.loss.item():.3f}", flush=True)
    peft_dir = os.path.join("/tmp", f"peft-{name}"); model.save_pretrained(peft_dir)
    out = os.path.join(ADAPTERS, f"{name}.gguf")
    print(f"[train] trained in {time.time()-t0:.0f}s; converting PEFT -> GGUF…", flush=True)
    subprocess.run([sys.executable, CONVERT, peft_dir, "--base", hf, "--outfile", out], check=True)
    print(f"[train] adapter -> {out} ({os.path.getsize(out)//1024}KB)", flush=True)
    return out

def self_learn(name, source_file, base="8b", train_base=None, steps=300):
    """The capable base reads a doc + writes its own curriculum; train a small adapter on it.
    Curriculum is generated by `base` (default 8B); the adapter is trained on `train_base` (default 350m,
    the largest base that PEFT-trains locally). Both served/trained on the GGUF lane."""
    train_base = train_base or ("350m" if BASES[base]["hf"] is None else base)
    src = open(source_file).read()
    port = ensure_server(base)
    print(f"[self-learn] {base} studying {source_file} + generating curriculum…", flush=True)
    prompt = (f"Read this document carefully:\n\n{src}\n\nNow write 10 question-and-answer pairs that test "
              "the key facts — one or two per fact, covering EVERY fact, quoting exact values (numbers, "
              "names, command strings) verbatim. Format each EXACTLY as:\nQ: <question>\nA: <answer>\n\nBegin:\n")
    raw = _complete(port, prompt, n=1100, temp=0.3); lines = raw.splitlines(); pairs = []
    for i, ln in enumerate(lines):
        if ln.strip().startswith("Q:") and i+1 < len(lines) and lines[i+1].strip().startswith("A:"):
            q = ln.split("Q:", 1)[1].strip(); a = lines[i+1].split("A:", 1)[1].strip()
            if q and a: pairs.append((q, a))
    print(f"[self-learn] {base} generated {len(pairs)} pairs:", flush=True)
    for q, a in pairs: print(f"    Q: {q} | A: {a}", flush=True)
    if len(pairs) < 3: sys.exit("[self-learn] too few pairs parsed")
    d = write_data(name, pairs)
    return train(name, d, base=train_base, steps=steps)

def kit_list():
    rows = [(a[:-5], os.path.getsize(os.path.join(ADAPTERS, a))/1e6)
            for a in sorted(os.listdir(ADAPTERS)) if a.endswith(".gguf")]
    print("Constellation adapter kit (GGUF):")
    for a, mb in rows: print(f"  {a:24s} {mb:.1f} MB")
    if not rows: print("  (none — build one with: constellation train|self-learn)")

def main():
    ap = argparse.ArgumentParser(prog="constellation")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ask"); p.add_argument("question"); p.add_argument("--base", default="8b"); p.add_argument("--adapter"); p.add_argument("--max-tokens", type=int, default=64)
    p = sub.add_parser("train"); p.add_argument("name"); p.add_argument("--data", required=True); p.add_argument("--base", default="350m"); p.add_argument("--steps", type=int, default=300); p.add_argument("--lr", type=float, default=2e-4)
    p = sub.add_parser("self-learn"); p.add_argument("name"); p.add_argument("--source", required=True); p.add_argument("--base", default="8b"); p.add_argument("--train-base", default=None); p.add_argument("--steps", type=int, default=300)
    p = sub.add_parser("serve"); p.add_argument("--base", default="8b"); p.add_argument("--adapters"); p.add_argument("--port", type=int)
    sub.add_parser("kit")
    a = ap.parse_args()
    if a.cmd == "ask": print(ask(a.question, base=a.base, adapter=a.adapter, max_tokens=a.max_tokens))
    elif a.cmd == "train": train(a.name, a.data, base=a.base, steps=a.steps, lr=a.lr)
    elif a.cmd == "self-learn": self_learn(a.name, a.source, base=a.base, train_base=a.train_base, steps=a.steps)
    elif a.cmd == "serve": serve(base=a.base, adapters=(a.adapters.split(",") if a.adapters else None), port=a.port)
    elif a.cmd == "kit": kit_list()

if __name__ == "__main__":
    main()
