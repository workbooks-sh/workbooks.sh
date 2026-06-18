#!/usr/bin/env python3
"""Heterogeneous speculative decoding on one Apple Silicon SoC.

Novel bit: the DRAFTER (DiffuCoder, masked diffusion) runs on the GPU and the VERIFIER
(Qwen2.5-Coder, autoregressive, SAME vocab) runs on the CPU, sharing context through unified
memory. Diffusion proposes a K-token block in parallel; AR verifies it in one forward pass and
accepts the longest prefix it agrees with — so the OUTPUT IS EXACTLY THE AR MODEL'S GREEDY
DECODING (diffusion only accelerates it; its quality issues can't corrupt the result).

Stages: S2/S3 = correct heterogeneous spec-decode (here). S4 = pipeline draft(N+1)‖verify(N).

Usage:
  python3 mlx/hetero_fusion.py                       # spec-decode + AR baseline, report tok/s & accept-rate
  MODE=baseline python3 mlx/hetero_fusion.py         # AR-only baseline
"""
import os, sys, time, math
import mlx.core as mx
from mlx_lm import load, generate

DRAFTER = os.environ.get("DRAFTER", "mlx/DiffuCoder-7B-cpGRPO-4bit")
VERIFIER = os.environ.get("VERIFIER", "mlx/Qwen2.5-Coder-7B-Instruct-4bit")
GPU, CPU = mx.gpu, mx.cpu
K = int(os.environ.get("K", "16"))               # draft block size
DSTEPS = int(os.environ.get("DSTEPS", "8"))      # diffusion steps per block
MAXTOK = int(os.environ.get("MAXTOK", "128"))
PROMPT = sys.argv[1] if len(sys.argv) > 1 else "Write a Python function fib(n) that returns the nth Fibonacci number. Return only code."

print(f"[load] drafter (GPU): {DRAFTER}", flush=True)
draft_model, dtok = load(DRAFTER, tokenizer_config={"trust_remote_code": True})
print(f"[load] verifier (CPU): {VERIFIER}", flush=True)
ver_model, vtok = load(VERIFIER, tokenizer_config={"trust_remote_code": True})
MASK = 151666  # DiffuCoder mask token

# ---- drafter: masked-diffusion block on GPU (bidirectional forward) ----
_de, _dl, _dn = draft_model.model.embed_tokens, draft_model.model.layers, draft_model.model.norm
_dh = draft_model.lm_head

def diffusion_draft(context, k, steps=DSTEPS, eps=1e-3):
    with mx.stream(GPU):
        seq = list(context) + [MASK] * k
        plen = len(context)
        ts = [1 + (eps - 1) * i / steps for i in range(steps + 1)]
        for i in range(steps):
            masked = [j for j in range(plen, len(seq)) if seq[j] == MASK]
            if not masked:
                break
            h = _de(mx.array([seq]))
            for layer in _dl:
                h = layer(h, None, None)            # bidirectional
            logits = _dh(_dn(h))[0]
            logits = mx.concatenate([logits[:1], logits[:-1]], axis=0)  # next-token offset
            probs = mx.softmax(logits, axis=-1)
            conf = mx.max(probs, axis=-1); pred = mx.argmax(probs, axis=-1)
            mx.eval(conf, pred); conf, pred = conf.tolist(), pred.tolist()
            t, s = ts[i], ts[i + 1]
            n = len(masked) if i == steps - 1 else int(len(masked) * (1 - s / t))
            for j in sorted(masked, key=lambda j: conf[j], reverse=True)[:max(1, n)]:
                seq[j] = pred[j]
        return seq[plen:plen + k]

# ---- verifier: one AR forward on CPU, exact prefix acceptance ----
def ar_logits_cpu(tokens):
    with mx.stream(CPU):
        out = ver_model(mx.array([tokens]))      # causal mask (AR) applied internally
        mx.eval(out)
        return out[0]                            # (L, V)

def verify(context, draft):
    # AR predictions for each draft position from one forward over context + draft[:-1]
    seq = list(context) + list(draft[:-1])
    logits = ar_logits_cpu(seq)
    m = len(context)
    ar_pred = [int(mx.argmax(logits[m - 1 + i]).item()) for i in range(len(draft))]
    n_acc = 0
    for i in range(len(draft)):
        if draft[i] == ar_pred[i]:
            n_acc += 1
        else:
            break
    correction = ar_pred[n_acc] if n_acc < len(draft) else None
    return n_acc, correction

def spec_generate(prompt_ids, max_tok=MAXTOK):
    ctx = list(prompt_ids)
    produced, drafted, accepted, blocks = 0, 0, 0, 0
    eos = vtok.eos_token_id
    t0 = time.time()
    while produced < max_tok:
        draft = diffusion_draft(ctx, K)
        n_acc, corr = verify(ctx, draft)
        ctx += draft[:n_acc]
        if corr is not None:
            ctx.append(corr)
        produced += n_acc + (1 if corr is not None else 0)
        drafted += len(draft); accepted += n_acc; blocks += 1
        if eos in ctx[-(n_acc + 1):]:
            break
    dt = time.time() - t0
    return ctx[len(prompt_ids):], dt, dict(accept_rate=accepted / max(1, drafted),
                                           toks_per_block=produced / max(1, blocks), blocks=blocks)

def ar_baseline(prompt_ids, max_tok=MAXTOK):
    ctx = list(prompt_ids); eos = vtok.eos_token_id
    t0 = time.time()
    for _ in range(max_tok):
        logits = ar_logits_cpu(ctx)
        nxt = int(mx.argmax(logits[-1]).item())
        ctx.append(nxt)
        if nxt == eos:
            break
    return ctx[len(prompt_ids):], time.time() - t0

msgs = [{"role": "user", "content": PROMPT}]
pids = vtok.apply_chat_template(msgs, add_generation_prompt=True)

if os.environ.get("MODE") == "baseline":
    # Fair baseline: mlx-lm cached AR generate (KV cache), on the chosen device.
    dev = CPU if os.environ.get("BASE_DEV", "cpu") == "cpu" else GPU
    with mx.stream(dev):
        t0 = time.time()
        txt = generate(ver_model, vtok, prompt=pids, max_tokens=MAXTOK, verbose=False)
        dt = time.time() - t0
    ntok = len(vtok.encode(txt))
    print("=" * 60); print(txt); print("=" * 60)
    print(f"[AR baseline cached, {os.environ.get('BASE_DEV','cpu')}] ~{ntok} tok in {dt:.1f}s = {ntok/dt:.1f} tok/s")
else:
    out, dt, stats = spec_generate(pids)
    print("=" * 60); print(vtok.decode(out)); print("=" * 60)
    print(f"[hetero fusion] {len(out)} tok in {dt:.1f}s = {len(out)/dt:.1f} tok/s")
    print(f"  accept_rate={stats['accept_rate']:.0%}  tok/block={stats['toks_per_block']:.1f}  blocks={stats['blocks']}  (K={K}, dsteps={DSTEPS})")
