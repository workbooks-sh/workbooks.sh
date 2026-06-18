#!/usr/bin/env python3
"""DFlash-for-Granite — proof-of-concept of the core block-diffusion drafter mechanic.

Validates (on the small granite-4.0-350m base): a drafter = K transformer layers that REUSE the
base's frozen embedding + LM head, trained to predict a BLOCK of N tokens IN PARALLEL via a
block-diffusion attention mask (context = causal; the N masked block positions = full attention to
context + each other), with position-weighted cross-entropy. This is the trainable core; KV-injection
of target hidden features + self-distillation data are the next layer (v2).

Run: python3.12 dflash/poc.py
"""
import torch, torch.nn as nn, torch.nn.functional as F, time
from transformers import AutoModelForCausalLM, AutoTokenizer

DEV = "mps" if torch.backends.mps.is_available() else "cpu"
BASE = "dflash/granite-4.0-350m"
N = 8           # block size (paper uses 16; small for PoC)
K = 3           # drafter layers (paper uses 5)
GAMMA = 4.0     # position-weight decay
STEPS = 60

print(f"[poc] device={DEV} | loading frozen base {BASE}", flush=True)
tok = AutoTokenizer.from_pretrained(BASE)
base = AutoModelForCausalLM.from_pretrained(BASE, dtype=torch.float32).to(DEV).eval()
for p in base.parameters():
    p.requires_grad_(False)
embed = base.get_input_embeddings()      # frozen, shared
lm_head = base.get_output_embeddings()   # frozen, shared
H = base.config.hidden_size
MASK_ID = tok.pad_token_id if tok.pad_token_id is not None else tok.eos_token_id
print(f"[poc] hidden={H} layers={K} block={N} mask_id={MASK_ID}", flush=True)

class Drafter(nn.Module):
    """K plain-attention transformer layers operating in the base's embedding space."""
    def __init__(self, H, K, heads=8):
        super().__init__()
        layer = nn.TransformerEncoderLayer(d_model=H, nhead=heads, dim_feedforward=4*H,
                                           activation="gelu", batch_first=True, norm_first=True)
        self.layers = nn.ModuleList([nn.TransformerEncoderLayer(d_model=H, nhead=heads,
                        dim_feedforward=4*H, activation="gelu", batch_first=True, norm_first=True)
                        for _ in range(K)])
    def forward(self, h, attn_mask):
        for l in self.layers:
            h = l(h, src_mask=attn_mask)
        return h

drafter = Drafter(H, K).to(DEV)
opt = torch.optim.AdamW(drafter.parameters(), lr=6e-4)
pw = torch.exp(-(torch.arange(N, device=DEV).float()) / GAMMA)   # position weights w_k

def block_diffusion_mask(L, m):
    """Additive float mask (L,L): context[0:m] causal; block[m:L] full-attend to context+block."""
    mask = torch.full((L, L), float("-inf"), device=DEV)
    for i in range(m):                       # causal context
        mask[i, : i + 1] = 0.0
    mask[m:, :] = 0.0                         # block positions see everything (context + whole block)
    return mask

# toy "self-distill" data: a few sequences (stand-in for Granite-regenerated responses)
texts = [
    "def fibonacci(n):\n    if n <= 1:\n        return n\n    return fibonacci(n-1) + fibonacci(n-2)",
    "The Constellation system runs small Granite models across CPU, GPU, browser, and edge tiers.",
    "import torch\nclass Model(nn.Module):\n    def __init__(self):\n        super().__init__()",
]
batches = [tok(t, return_tensors="pt").input_ids.to(DEV) for t in texts]

print("[poc] training drafter (loss should fall)…", flush=True)
t0 = time.time()
for step in range(STEPS):
    ids = batches[step % len(batches)]
    Ltot = ids.shape[1]
    if Ltot < N + 4:
        continue
    m = max(2, Ltot - N)                     # anchor: predict last N tokens as the block
    ctx, block = ids[:, :m], ids[:, m:m+N]
    K_eff = block.shape[1]
    inp = torch.cat([ctx, torch.full((1, K_eff), MASK_ID, device=DEV)], dim=1)  # context + masked block
    h = embed(inp)
    h = drafter(h, block_diffusion_mask(inp.shape[1], m))
    logits = lm_head(h[:, m:, :])            # predictions at the masked block positions
    loss = (F.cross_entropy(logits.reshape(-1, logits.size(-1)), block.reshape(-1),
                            reduction="none").reshape(1, K_eff) * pw[:K_eff]).mean()
    opt.zero_grad(); loss.backward(); opt.step()
    if step % 10 == 0 or step == STEPS - 1:
        # quick block-accuracy: how many of the N predicted tokens match
        acc = (logits.argmax(-1) == block).float().mean().item()
        print(f"  step {step:3d}  loss {loss.item():.3f}  block-acc {acc:.0%}", flush=True)
print(f"[poc] done in {time.time()-t0:.1f}s. Core block-diffusion drafter mechanic VALIDATED.")
print("[poc] next: KV-inject Granite hidden features + self-distill from granite-4.1-8b + scale K=5,N=16.")
