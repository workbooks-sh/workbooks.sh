#!/usr/bin/env python3
"""Heterogeneous cross-vocab speculative decoding (Path A) on one Apple Silicon SoC.

DRAFTER: DiffuCoder (masked diffusion, Qwen vocab) on the GPU.
VERIFIER: Gemma-4-12B (autoregressive, Gemma vocab, multimodal) on the CPU.
BRIDGE: UAG/SLEM — the drafter emits a STRING; we re-tokenize it in the VERIFIER's vocab and verify
exactly in the verifier's token space. So drafter vocab is irrelevant, and OUTPUT == Gemma's greedy
decoding (diffusion only accelerates; UAG only changes acceptance rate, never correctness).

Novel combination: GPU diffusion drafting ‖ CPU AR verification, unified memory, cross-vocab bridge,
multimodal verifier — all on one consumer chip.
"""
import os, sys, time
import mlx.core as mx
from mlx_lm import load, generate

DRAFTER = os.environ.get("DRAFTER", "mlx/DiffuCoder-7B-cpGRPO-4bit")
VERIFIER = os.environ.get("VERIFIER", "mlx/gemma-4-12B-it-qat-4bit")
GPU, CPU = mx.gpu, mx.cpu
K = int(os.environ.get("K", "12"))
DSTEPS = int(os.environ.get("DSTEPS", "8"))
MAXTOK = int(os.environ.get("MAXTOK", "96"))
PROMPT = sys.argv[1] if len(sys.argv) > 1 else "Write a Python function fib(n) that returns the nth Fibonacci number. Return only code."

print(f"[load] drafter (GPU): {DRAFTER}", flush=True)
dmodel, dtok = load(DRAFTER, tokenizer_config={"trust_remote_code": True})
print(f"[load] verifier (CPU): {VERIFIER}", flush=True)
vmodel, vtok = load(VERIFIER)
MASK = 151666

# ---- drafter: masked-diffusion block on GPU; returns a STRING ----
_de, _dl, _dn, _dh = dmodel.model.embed_tokens, dmodel.model.layers, dmodel.model.norm, dmodel.lm_head

def diffusion_draft_str(ctx_text, k, steps=DSTEPS, eps=1e-3):
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
            logits = _dh(_dn(h))[0]
            logits = mx.concatenate([logits[:1], logits[:-1]], axis=0)
            probs = mx.softmax(logits, axis=-1)
            conf = mx.max(probs, axis=-1); pred = mx.argmax(probs, axis=-1)
            mx.eval(conf, pred); conf, pred = conf.tolist(), pred.tolist()
            t, s = ts[i], ts[i + 1]
            n = len(masked) if i == steps - 1 else int(len(masked) * (1 - s / t))
            for j in sorted(masked, key=lambda j: conf[j], reverse=True)[:max(1, n)]:
                seq[j] = pred[j]
        return dtok.decode(seq[plen:plen + k])

# ---- verifier: one AR forward on CPU; exact match in VERIFIER token space (UAG/SLEM) ----
def verify_uag(ctx_tokens, draft_str):
    g = vtok.encode(draft_str, add_special_tokens=False)
    if not g:
        return [], None
    with mx.stream(CPU):
        seq = list(ctx_tokens) + list(g[:-1])
        logits = vmodel(mx.array([seq]))[0]
        mx.eval(logits)
    m = len(ctx_tokens)
    ar_pred = [int(mx.argmax(logits[m - 1 + i]).item()) for i in range(len(g))]
    n_acc = 0
    for i in range(len(g)):
        if g[i] == ar_pred[i]:
            n_acc += 1
        else:
            break
    accepted = list(g[:n_acc])
    correction = ar_pred[n_acc] if n_acc < len(g) else None
    return accepted, correction

def fuse_generate(prompt_text, max_tok=MAXTOK):
    ctx = list(vtok.encode(prompt_text))           # canonical = verifier tokens
    base = len(ctx)
    drafted = accepted_total = blocks = 0
    eos = vtok.eos_token_id
    t0 = time.time()
    while len(ctx) - base < max_tok:
        # Drafter sees clean text (Gemma chat special tokens stripped — they're noise to DiffuCoder).
        ctx_text = vtok.decode(ctx, skip_special_tokens=True)
        draft_str = diffusion_draft_str(ctx_text, K)         # GPU
        acc, corr = verify_uag(ctx, draft_str)               # CPU
        ctx += acc
        if corr is not None:
            ctx.append(corr)
        blocks += 1; accepted_total += len(acc)
        drafted += max(1, len(vtok.encode(draft_str, add_special_tokens=False)))
        if eos is not None and eos in ctx[-(len(acc) + 1):]:
            break
    dt = time.time() - t0
    n = len(ctx) - base
    return vtok.decode(ctx[base:]), dt, dict(
        accept_rate=accepted_total / max(1, drafted), tok_per_block=n / max(1, blocks),
        blocks=blocks, tok=n, tps=n / dt)

vmsgs = [{"role": "user", "content": PROMPT}]
pt = vtok.apply_chat_template(vmsgs, add_generation_prompt=True, tokenize=False)

if os.environ.get("MODE") == "baseline":
    dev = CPU if os.environ.get("BASE_DEV", "cpu") == "cpu" else GPU
    with mx.stream(dev):
        t0 = time.time()
        txt = generate(vmodel, vtok, prompt=vtok.encode(pt), max_tokens=MAXTOK, verbose=False)
        dt = time.time() - t0
    n = len(vtok.encode(txt))
    print("=" * 60); print(txt); print("=" * 60)
    print(f"[Gemma AR baseline, {os.environ.get('BASE_DEV','cpu')}] ~{n} tok in {dt:.1f}s = {n/dt:.1f} tok/s")
else:
    txt, dt, st = fuse_generate(pt)
    print("=" * 60); print(txt); print("=" * 60)
    print(f"[hetero UAG fusion] {st['tok']} tok in {dt:.1f}s = {st['tps']:.1f} tok/s")
    print(f"  accept_rate={st['accept_rate']:.0%}  tok/block={st['tok_per_block']:.1f}  blocks={st['blocks']}  (K={K}, dsteps={DSTEPS})")
