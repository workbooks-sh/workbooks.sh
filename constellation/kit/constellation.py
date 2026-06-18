#!/usr/bin/env python3
"""Constellation — a Granite base + plug-and-play LoRA adapters, trained and served locally on MLX.

Validated capabilities, consolidated into one toolkit:
  train      — QLoRA-train an adapter on a Granite base (works for the 8B on a 16GB Mac, on the GPU)
  self-learn — the base reads a source doc, generates its OWN Q&A curriculum, trains an adapter on it
  ask        — query the base, optionally with an adapter plugged in
  kit        — list the adapters you've built
  data       — turn a list of Q/A pairs (or a .jsonl) into the training format

All MLX (Apple Silicon). Bases are MLX models; adapters are MLX LoRA adapters (serve natively, no
format conversion). Run: python3.12 kit/constellation.py <command> ...
"""
import os, sys, json, time, argparse, subprocess, re
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # constellation/
ADAPTERS = os.path.join(ROOT, "kit", "adapters")
DATA = os.path.join(ROOT, "kit", "data")
os.makedirs(ADAPTERS, exist_ok=True); os.makedirs(DATA, exist_ok=True)

# Granite bases available locally (MLX format). 8b = the brain; 350m = the edge/tiny-agent base.
BASES = {
    "8b":   os.path.join(ROOT, "spike", "dflash", "granite-4.1-8b-mlx-4bit"),
    "350m": os.path.join(ROOT, "spike", "dflash", "granite-350m-mlx-4bit"),
}
def base_path(name):
    p = BASES.get(name, name)
    if not os.path.exists(p): sys.exit(f"base not found: {p} (have: {list(BASES)})")
    return p

# ---- lazy MLX import (only when needed) ----
def _mlx():
    from mlx_lm import load, generate
    return load, generate

def ask(question, base="8b", adapter=None, max_tokens=80, prompt_fmt="qa"):
    load, generate = _mlx()
    kw = {}
    if adapter:
        ap = adapter if os.path.exists(adapter) else os.path.join(ADAPTERS, adapter)
        kw["adapter_path"] = ap
    model, tok = load(base_path(base), **kw)
    prompt = f"Question: {question}\nAnswer:" if prompt_fmt == "qa" else question
    return generate(model, tok, prompt=prompt, max_tokens=max_tokens, verbose=False).split("\n")[0].strip()

def write_data(name, pairs):
    """pairs: list of (q, a). Writes train/valid jsonl in mlx_lm format under kit/data/<name>/."""
    d = os.path.join(DATA, name); os.makedirs(d, exist_ok=True)
    rows = [{"text": f"Question: {q}\nAnswer: {a}"} for q, a in pairs]
    rows = rows * max(1, 40 // max(1, len(rows)))   # repeat small sets so each fact gets reinforced
    with open(os.path.join(d, "train.jsonl"), "w") as f:
        f.write("\n".join(json.dumps(r) for r in rows))
    with open(os.path.join(d, "valid.jsonl"), "w") as f:
        f.write("\n".join(json.dumps(r) for r in rows[:max(2, len(pairs))]))
    return d

def train(name, data_dir, base="8b", iters=300, layers=16, lr=1e-4):
    """QLoRA-train an adapter on a Granite base (MLX, on the GPU). Saves to kit/adapters/<name>."""
    out = os.path.join(ADAPTERS, name)
    cmd = [sys.executable, "-m", "mlx_lm", "lora", "--model", base_path(base), "--train",
           "--data", data_dir, "--iters", str(iters), "--batch-size", "2", "--num-layers", str(layers),
           "--learning-rate", str(lr), "--adapter-path", out, "--steps-per-report", str(max(50, iters//4))]
    print(f"[train] QLoRA on {base} -> adapter '{name}' ({iters} iters)…", flush=True)
    t0 = time.time(); subprocess.run(cmd, check=True)
    print(f"[train] '{name}' trained in {time.time()-t0:.0f}s -> {out}", flush=True)
    return out

def self_learn(name, source_file, base="8b", iters=300, n_pairs=8, lr=1e-4):
    """The base studies a source doc, generates its OWN Q&A curriculum, then trains an adapter on it."""
    src = open(source_file).read()
    load, generate = _mlx()
    print(f"[self-learn] {base} studying {source_file} + generating curriculum…", flush=True)
    model, tok = load(base_path(base))
    prompt = (f"Read this document carefully:\n\n{src}\n\nNow write {n_pairs} diverse question-and-answer "
              "pairs testing the key facts. Format each EXACTLY as:\nQ: <question>\nA: <answer>\n\nBegin:\n")
    raw = generate(model, tok, prompt=prompt, max_tokens=600, verbose=False)
    pairs = []
    lines = raw.splitlines()
    for i, ln in enumerate(lines):
        if ln.strip().startswith("Q:") and i+1 < len(lines) and lines[i+1].strip().startswith("A:"):
            q = ln.split("Q:",1)[1].strip(); a = lines[i+1].split("A:",1)[1].strip()
            if q and a: pairs.append((q, a))
    print(f"[self-learn] generated {len(pairs)} pairs:", flush=True)
    for q, a in pairs: print(f"    Q: {q} | A: {a}", flush=True)
    if len(pairs) < 3: sys.exit("[self-learn] too few pairs parsed; try a clearer source or bigger base")
    import gc; del model, tok; gc.collect()
    d = write_data(name, pairs)
    return train(name, d, base=base, iters=iters, lr=lr)

def serve(base="8b", adapter=None, port=8080):
    """Serve a Granite base (optionally with an adapter plugged in) over an OpenAI-compatible API."""
    cmd = [sys.executable, "-m", "mlx_lm", "server", "--model", base_path(base), "--port", str(port)]
    if adapter:
        ap = adapter if os.path.exists(adapter) else os.path.join(ADAPTERS, adapter)
        cmd += ["--adapter-path", ap]
    print(f"[serve] {base}" + (f" + adapter '{adapter}'" if adapter else "") + f" on :{port} (OpenAI API)…", flush=True)
    subprocess.run(cmd)

def kit_list():
    if not os.path.isdir(ADAPTERS): print("no adapters yet"); return
    rows = []
    for a in sorted(os.listdir(ADAPTERS)):
        p = os.path.join(ADAPTERS, a, "adapters.safetensors")
        if os.path.exists(p): rows.append((a, os.path.getsize(p)/1e6))
    print("Constellation adapter kit:")
    for a, mb in rows: print(f"  {a:24s} {mb:.1f} MB")
    if not rows: print("  (none — build one with: constellation train|self-learn)")

def main():
    ap = argparse.ArgumentParser(prog="constellation")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ask"); p.add_argument("question"); p.add_argument("--base", default="8b"); p.add_argument("--adapter"); p.add_argument("--max-tokens", type=int, default=80)
    p = sub.add_parser("train"); p.add_argument("name"); p.add_argument("--data", required=True); p.add_argument("--base", default="8b"); p.add_argument("--iters", type=int, default=300); p.add_argument("--lr", type=float, default=1e-4)
    p = sub.add_parser("self-learn"); p.add_argument("name"); p.add_argument("--source", required=True); p.add_argument("--base", default="8b"); p.add_argument("--iters", type=int, default=300); p.add_argument("--lr", type=float, default=1e-4)
    p = sub.add_parser("serve"); p.add_argument("--base", default="8b"); p.add_argument("--adapter"); p.add_argument("--port", type=int, default=8080)
    sub.add_parser("kit")
    a = ap.parse_args()
    if a.cmd == "ask": print(ask(a.question, base=a.base, adapter=a.adapter, max_tokens=a.max_tokens))
    elif a.cmd == "train": train(a.name, a.data, base=a.base, iters=a.iters, lr=a.lr)
    elif a.cmd == "self-learn": self_learn(a.name, a.source, base=a.base, iters=a.iters, lr=a.lr)
    elif a.cmd == "serve": serve(base=a.base, adapter=a.adapter, port=a.port)
    elif a.cmd == "kit": kit_list()

if __name__ == "__main__":
    main()
