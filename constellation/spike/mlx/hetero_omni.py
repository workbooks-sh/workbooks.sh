#!/usr/bin/env python3
"""All-MLX heterogeneous cross-vocab fusion — the real Path A, on one Apple Silicon SoC.

DRAFTER: DiffuCoder (masked diffusion, mlx_lm, GPU stream).
VERIFIER: Gemma-4-12B OMNI (gemma4_unified via mlx-vlm, CPU stream) — the multimodal model we ship.
BRIDGE: UAG/SLEM — drafter emits a string; re-tokenize in Gemma's vocab; verify exactly in Gemma's
token space. Output == Gemma greedy decoding (correct by construction); UAG only affects accept rate.

Run on python3.12: python3.12 mlx/hetero_omni.py "<prompt>"
"""
import os, sys, time
from pathlib import Path
import mlx.core as mx
from mlx_lm import load as lmload
from mlx_vlm.utils import load_model
from transformers import AutoTokenizer

DRAFTER = "mlx/DiffuCoder-7B-cpGRPO-4bit"
VERIFIER = "mlx/gemma-4-12B-it-4bit"
GPU, CPU = mx.gpu, mx.cpu
K = int(os.environ.get("K", "12"))
DSTEPS = int(os.environ.get("DSTEPS", "8"))
BLOCKS = int(os.environ.get("BLOCKS", "8"))
PROMPT = sys.argv[1] if len(sys.argv) > 1 else "Write a Python function fib(n) that returns the nth Fibonacci number. Return only code."

print("[load] DiffuCoder drafter (mlx_lm, GPU)…", flush=True)
dm, dtok = lmload(DRAFTER, tokenizer_config={"trust_remote_code": True})
print("[load] Gemma-4 omni verifier (mlx-vlm, CPU)…", flush=True)
gm = load_model(Path(VERIFIER))
gtok = AutoTokenizer.from_pretrained(VERIFIER)
MASK = 151666
_de, _dl, _dn, _dh = dm.model.embed_tokens, dm.model.layers, dm.model.norm, dm.lm_head

def diffusion_draft(ctx_text, k=K, steps=DSTEPS, eps=1e-3):
    with mx.stream(GPU):
        ctx = dtok.encode(ctx_text)
        seq = list(ctx) + [MASK] * k
        plen = len(ctx)
        ts = [1 + (eps - 1) * i / steps for i in range(steps + 1)]
        for i in range(steps):
            masked = [j for j in range(plen, len(seq)) if seq[j] == MASK]
            if not masked:
                break
            h = _de(mx.array([seq]))
            for layer in _dl:
                h = layer(h, None, None)
            lg = _dh(_dn(h))[0]
            lg = mx.concatenate([lg[:1], lg[:-1]], axis=0)
            p = mx.softmax(lg, axis=-1)
            conf = mx.max(p, axis=-1); pred = mx.argmax(p, axis=-1)
            mx.eval(conf, pred); conf, pred = conf.tolist(), pred.tolist()
            t, s = ts[i], ts[i + 1]
            n = len(masked) if i == steps - 1 else int(len(masked) * (1 - s / t))
            for j in sorted(masked, key=lambda j: conf[j], reverse=True)[:max(1, n)]:
                seq[j] = pred[j]
        return dtok.decode(seq[plen:plen + k])

def gemma_logits(ids):
    with mx.stream(CPU):
        out = gm.language_model(mx.array([ids]))
        logits = out.logits if hasattr(out, "logits") else out[0]
        mx.eval(logits)
        return logits[0]

def verify(ctx_ids, draft_str):
    g = gtok.encode(draft_str, add_special_tokens=False)
    if not g:
        return [], None
    logits = gemma_logits(list(ctx_ids) + list(g[:-1]))
    m = len(ctx_ids)
    ar = [int(mx.argmax(logits[m - 1 + i]).item()) for i in range(len(g))]
    n = 0
    for i in range(len(g)):
        if g[i] == ar[i]: n += 1
        else: break
    return list(g[:n]), (ar[n] if n < len(g) else None)

ctx = list(gtok.encode(gtok.apply_chat_template([{"role": "user", "content": PROMPT}],
                                                 add_generation_prompt=True, tokenize=False)))
base = len(ctx)
drafted = accepted = blocks = 0
t0 = time.time()
print("[fuse] drafting on GPU, verifying on CPU…", flush=True)
for b in range(BLOCKS):
    ctx_text = gtok.decode(ctx, skip_special_tokens=True)
    draft = diffusion_draft(ctx_text)
    acc, corr = verify(ctx, draft)
    ctx += acc + ([corr] if corr is not None else [])
    drafted += max(1, len(gtok.encode(draft, add_special_tokens=False)))
    accepted += len(acc); blocks += 1
    if gtok.eos_token_id in ctx[-(len(acc) + 1):]:
        break
dt = time.time() - t0
print("=" * 60)
print(gtok.decode(ctx[base:], skip_special_tokens=True)[:400])
print("=" * 60)
print(f"[RESULT] {len(ctx)-base} tok in {dt:.1f}s = {(len(ctx)-base)/dt:.1f} tok/s")
print(f"[ACCEPT RATE] {accepted/max(1,drafted):.0%}  ({accepted}/{drafted} draft tokens accepted by Gemma, {blocks} blocks, K={K}, dsteps={DSTEPS})")
print("  >0 = DiffuCoder drafts survive UAG + Gemma agreement → fusion has signal.")
