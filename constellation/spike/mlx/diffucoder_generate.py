#!/usr/bin/env python3
"""Masked-diffusion text generation for DiffuCoder on MLX.

The model is a plain Qwen2 transformer (mlx-lm loads it fine). What mlx-lm lacks is the *sampling
loop*: text diffusion isn't left-to-right — it starts from an all-masked answer span and iteratively
unmasks the highest-confidence tokens over N steps, with FULL (bidirectional) attention each pass.

Two pieces mlx-lm doesn't give us, both small:
  1. a forward pass with mask=None (bidirectional) instead of the default causal mask, and
  2. the confidence-based progressive-unmask loop.
"""
import sys, time, math, json, os
import mlx.core as mx
from mlx_lm import load

MODEL = sys.argv[1] if len(sys.argv) > 1 else "mlx/DiffuCoder-7B-cpGRPO-4bit"
PROMPT = sys.argv[2] if len(sys.argv) > 2 else "Write a Python function that returns the nth Fibonacci number."
GEN_LEN = int(os.environ.get("GEN_LEN", "128"))
STEPS = int(os.environ.get("STEPS", "64"))

print(f"[load] loading {MODEL} ...", flush=True)
_t = time.time()
model, tokenizer = load(MODEL, tokenizer_config={"trust_remote_code": True})
print(f"[load] model ready in {time.time()-_t:.1f}s", flush=True)

# Find the mask token id: config.json, then tokenizer, then the Dream/DiffuCoder default.
def mask_token_id():
    cfg = os.path.join(MODEL, "config.json")
    if os.path.exists(cfg):
        c = json.load(open(cfg))
        for k in ("mask_token_id", "mask_token"):
            if isinstance(c.get(k), int):
                return c[k]
    if getattr(tokenizer, "mask_token_id", None) is not None:
        return tokenizer.mask_token_id
    return 151666  # Dream/DiffuCoder mask token

MASK = mask_token_id()

_embed, _layers, _norm, _head = (
    model.model.embed_tokens, model.model.layers, model.model.norm,
    (model.model.embed_tokens.as_linear if getattr(model.args, "tie_word_embeddings", False) else model.lm_head),
)

def _fwd(seq):
    h = _embed(seq)
    for layer in _layers:
        h = layer(h, None, None)          # mask=None => full (bidirectional) attention
    return _head(_norm(h))[0]             # (L, V)

# mx.compile fuses the per-step graph (fixed shape across steps -> compiles once). Big lever since
# diffusion runs N full-sequence forwards with no KV cache.
forward = mx.compile(_fwd) if os.environ.get("MLX_COMPILE") == "1" else _fwd

def diffusion_generate(prompt_ids, gen_len=GEN_LEN, steps=STEPS, eps=0.001):
    """Confidence-based (maskgit_plus) masked diffusion, faithful to Apple's generation_utils.py:
    timestep schedule linspace(1, eps, steps+1); unmask int(n_masked*(1-s/t)) highest-confidence
    tokens per step; logits shifted right by one (next-token readout offset)."""
    seq = list(prompt_ids) + [MASK] * gen_len
    plen = len(prompt_ids)
    ts = [1 + (eps - 1) * k / steps for k in range(steps + 1)]  # linspace(1, eps, steps+1)

    t_start = time.time()
    for i in range(steps):
        masked = [j for j in range(len(seq)) if seq[j] == MASK]
        if not masked:
            print(f"[diffusion] step {i}/{steps} — all unmasked, done", flush=True)
            break
        if i % 4 == 0 or i == steps - 1:
            done = gen_len - len(masked)
            el = time.time() - t_start
            print(f"[diffusion] step {i}/{steps}  unmasked {done}/{gen_len}  ({el:.1f}s, {i/el:.1f} steps/s)" if el > 0 else
                  f"[diffusion] step {i}/{steps}  unmasked {done}/{gen_len}", flush=True)
        logits = forward(mx.array([seq]))                       # (L, V)
        logits = mx.concatenate([logits[:1], logits[:-1]], axis=0)   # shift right by 1
        probs = mx.softmax(logits, axis=-1)
        conf = mx.max(probs, axis=-1)
        pred = mx.argmax(probs, axis=-1)
        mx.eval(conf, pred)
        conf, pred = conf.tolist(), pred.tolist()

        t, s = ts[i], ts[i + 1]
        n_transfer = len(masked) if i == steps - 1 else int(len(masked) * (1 - s / t))
        if n_transfer <= 0:
            continue
        for j in sorted(masked, key=lambda j: conf[j], reverse=True)[:n_transfer]:
            seq[j] = pred[j]

    # fill any stragglers
    logits = mx.concatenate([forward(mx.array([seq]))[:1], forward(mx.array([seq]))[:-1]], axis=0)
    pred = mx.argmax(logits, axis=-1).tolist()
    seq = [pred[j] if (j >= plen and seq[j] == MASK) else seq[j] for j in range(len(seq))]
    return seq[plen:]

msgs = [{"role": "user", "content": PROMPT}]
prompt_ids = tokenizer.apply_chat_template(msgs, add_generation_prompt=True)

t0 = time.time()
out = diffusion_generate(prompt_ids)
dt = time.time() - t0

text = tokenizer.decode(out)
print("=" * 60)
print(text)
print("=" * 60)
print(f"gen_len={GEN_LEN} steps={STEPS} wall={dt:.1f}s  ({GEN_LEN/dt:.1f} tok/s effective)")
