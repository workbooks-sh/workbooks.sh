#!/usr/bin/env python3
"""Hybrid heterogeneous fusion: MLX DiffuCoder drafter (GPU) + llama.cpp Gemma verifier (CPU/HTTP).

Gemma-4 only loads in llama.cpp (mlx_lm lacks gemma4), DiffuCoder runs best in MLX — so each lives in
its working runtime and they meet over HTTP. This is the transport-agnostic Ether design (and the
portable one). UAG/SLEM at the STRING level → no need for Gemma's tokenizer in Python.

First goal: measure ACCEPT RATE — how often DiffuCoder's drafted text matches what Gemma actually
produces. That number gates the whole fusion + head + graph stack.

Setup: run Gemma in llama-server first:
  llama-server -m models/gemma-4-12B-it-Q4_K_M.gguf --port 8084 -ngl 0 -c 4096 --jinja
Then: python3 mlx/hetero_http.py "<prompt>"
"""
import os, sys, time, json, urllib.request
import mlx.core as mx
from mlx_lm import load

DRAFTER = os.environ.get("DRAFTER", "mlx/DiffuCoder-7B-cpGRPO-4bit")
GEMMA = os.environ.get("GEMMA_URL", "http://127.0.0.1:8084/v1/chat/completions")
K_CHARS = int(os.environ.get("K_CHARS", "48"))   # draft block target (chars, string-level SLEM)
BLOCKS = int(os.environ.get("BLOCKS", "8"))
PROMPT = sys.argv[1] if len(sys.argv) > 1 else "Write a Python function fib(n) that returns the nth Fibonacci number. Return only code."

print(f"[load] DiffuCoder drafter (MLX/GPU): {DRAFTER}", flush=True)
dmodel, dtok = load(DRAFTER, tokenizer_config={"trust_remote_code": True})
MASK = 151666
_de, _dl, _dn, _dh = dmodel.model.embed_tokens, dmodel.model.layers, dmodel.model.norm, dmodel.lm_head

def diffusion_draft(ctx_text, gen_tok=24, steps=8, eps=1e-3):
    """Draft ~gen_tok tokens of continuation as a STRING (GPU)."""
    with mx.stream(mx.gpu):
        ctx = dtok.encode(ctx_text)
        seq = list(ctx) + [MASK] * gen_tok
        plen = len(ctx)
        ts = [1 + (eps - 1) * i / steps for i in range(steps + 1)]
        for i in range(steps):
            masked = [j for j in range(plen, len(seq)) if seq[j] == MASK]
            if not masked:
                break
            h = _de(mx.array([seq]))
            for layer in _dl:
                h = layer(h, None, None)
            logits = mx.concatenate([_dh(_dn(h))[0][:1], _dh(_dn(h))[0][:-1]], axis=0)
            probs = mx.softmax(logits, axis=-1)
            conf = mx.max(probs, axis=-1); pred = mx.argmax(probs, axis=-1)
            mx.eval(conf, pred); conf, pred = conf.tolist(), pred.tolist()
            t, s = ts[i], ts[i + 1]
            n = len(masked) if i == steps - 1 else int(len(masked) * (1 - s / t))
            for j in sorted(masked, key=lambda j: conf[j], reverse=True)[:max(1, n)]:
                seq[j] = pred[j]
        return dtok.decode(seq[plen:])

def gemma(messages, max_tokens):
    body = json.dumps({"messages": messages, "max_tokens": max_tokens, "temperature": 0,
                       "chat_template_kwargs": {"enable_thinking": False}}).encode()
    req = urllib.request.Request(GEMMA, body, {"Content-Type": "application/json"})
    r = json.loads(urllib.request.urlopen(req, timeout=300).read())
    return r["choices"][0]["message"]["content"]

def lcp(a, b):
    n = 0
    for x, y in zip(a, b):
        if x == y: n += 1
        else: break
    return n

# Reference: Gemma's own greedy answer (this IS the output; fusion only accelerates it).
print("[ref] generating Gemma reference answer ...", flush=True)
t0 = time.time()
ref = gemma([{"role": "user", "content": PROMPT}], BLOCKS * 20)
print(f"[ref] {len(ref)} chars in {time.time()-t0:.1f}s")

# Walk the reference in blocks; at each, draft from the prefix and measure string-level acceptance.
ctx = PROMPT + "\n"
accepted_chars = drafted_chars = 0
pos = 0
print("[fuse] measuring DiffuCoder draft acceptance against Gemma ...", flush=True)
for b in range(BLOCKS):
    if pos >= len(ref):
        break
    target = ref[pos:pos + K_CHARS]                       # what Gemma actually produced next
    draft = diffusion_draft(ctx + ref[:pos], gen_tok=24)  # DiffuCoder's guess from the same prefix
    acc = lcp(draft, target)
    accepted_chars += acc; drafted_chars += min(len(draft), K_CHARS)
    pos += K_CHARS
print("=" * 60)
print("Gemma answer:\n" + ref[:300])
print("=" * 60)
rate = accepted_chars / max(1, drafted_chars)
print(f"[ACCEPT RATE] {rate:.0%}  (string-level SLEM, {accepted_chars}/{drafted_chars} chars over {BLOCKS} blocks)")
print("  >0 = DiffuCoder drafts overlap Gemma's output → fusion has signal; ~0 = no signal, pivot.")
