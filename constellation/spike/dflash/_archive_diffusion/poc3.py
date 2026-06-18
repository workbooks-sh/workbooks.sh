#!/usr/bin/env python3
"""DFlash-for-Granite PoC v2 — adds KV-INJECTION (the conditioning that makes it learn).

v1 validated the block-masked loop ran. v2 adds the key DFlash mechanism: the drafter's block
positions CROSS-ATTEND to the target's per-position hidden features of the context (projected) —
i.e. the drafter borrows Granite's understanding of the context to predict the next block. Plus real
data (a long text chunked into many context→block examples) + a stable lr. If the recipe is sound,
loss falls and block-accuracy rises.
"""
import torch, torch.nn as nn, torch.nn.functional as F, time
from transformers import AutoModelForCausalLM, AutoTokenizer

DEV = "mps" if torch.backends.mps.is_available() else "cpu"
BASE = "dflash/granite-4.0-350m"
N, K, GAMMA, STEPS = 8, 3, 4.0, 200
print(f"[v2] device={DEV} loading frozen base", flush=True)
tok = AutoTokenizer.from_pretrained(BASE)
base = AutoModelForCausalLM.from_pretrained(BASE, dtype=torch.float32, output_hidden_states=True).to(DEV).eval()
for p in base.parameters(): p.requires_grad_(False)
embed, lm_head = base.get_input_embeddings(), base.get_output_embeddings()
H = base.config.hidden_size
NL = base.config.num_hidden_layers
INJ_LAYER = NL // 2                       # sample a mid layer's context features to inject
MASK_ID = tok.pad_token_id or tok.eos_token_id

class Drafter(nn.Module):
    """Block positions cross-attend to projected target context features (KV-injection)."""
    def __init__(self, H, K, heads=8):
        super().__init__()
        self.inj = nn.Linear(H, H); self.fnorm = nn.RMSNorm(H)        # project target features -> draft memory
        self.layers = nn.ModuleList([nn.TransformerDecoderLayer(d_model=H, nhead=heads,
                        dim_feedforward=4*H, activation="gelu", batch_first=True, norm_first=True)
                        for _ in range(K)])
    def forward(self, blk_emb, ctx_feats):
        mem = self.inj(ctx_feats)         # (B, m, H) target's context understanding
        h = blk_emb                       # (B, N, H) masked block embeddings
        for l in self.layers:
            h = l(h, mem)                 # block self-attends + cross-attends to target context
        return self.fnorm(h)

drafter = Drafter(H, K).to(DEV)
opt = torch.optim.AdamW(drafter.parameters(), lr=2e-4)
pw = torch.exp(-(torch.arange(N, device=DEV).float())/GAMMA)

# real-ish data: a longer document chunked into many (context, block) pairs
doc = (("def fib(n):\n    a,b=0,1\n    for _ in range(n):\n        a,b=b,a+b\n    return a\n\n"
        "The Constellation system composes small Granite models: a CPU verifier, a GPU block-diffusion "
        "drafter, hot-swappable LoRA adapters, and per-modality micro-models, routed by a scheduler and "
        "deployed from a laptop to a browser tab to a BEAM edge VM. Each piece shares one Granite "
        "vocabulary so speculative decoding verifies exactly. ") * 6)
ids = tok(doc, return_tensors="pt").input_ids.to(DEV)[0]
L = ids.shape[0]
print(f"[v2] hidden={H} inj_layer={INJ_LAYER} tokens={L} block={N} layers={K}", flush=True)

def sample_example():
    m = torch.randint(8, L - N, (1,)).item()      # anchor
    ctx = ids[:m].unsqueeze(0)
    block = ids[m:m+N].unsqueeze(0)
    with torch.no_grad():
        feats = base(ctx).hidden_states[INJ_LAYER]  # (1, m, H) target context features
    blk_emb = embed(torch.full((1, N), MASK_ID, device=DEV)) * 12.0
    return blk_emb, feats, block

print("[v2] training (loss should fall, block-acc rise)…", flush=True)
t0=time.time()
for step in range(STEPS):
    blk_emb, feats, block = sample_example()
    h = drafter(blk_emb, feats)
    logits = lm_head(h)
    loss = (F.cross_entropy(logits.reshape(-1, logits.size(-1)), block.reshape(-1),
                            reduction="none").reshape(1, N) * pw).mean()
    opt.zero_grad(); loss.backward(); opt.step()
    if step % 20 == 0 or step == STEPS-1:
        acc = (logits.argmax(-1) == block).float().mean().item()
        print(f"  step {step:3d}  loss {loss.item():.3f}  block-acc {acc:.0%}", flush=True)
print(f"[v2] done {time.time()-t0:.1f}s")
