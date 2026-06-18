#!/usr/bin/env python3
"""DFlash-for-Granite — batched trainer, held-out eval, multi-layer KV-injection.
Goal: clean convergence + high held-out block-accuracy = a drafter that actually works.
Run: python3.12 dflash/train.py
"""
import os, glob, time, random, torch, torch.nn as nn, torch.nn.functional as F
from transformers import AutoModelForCausalLM, AutoTokenizer

DEV = "mps" if torch.backends.mps.is_available() else "cpu"
BASE = "dflash/granite-4.0-350m"
N      = int(os.environ.get("N", "8"))      # block size
K      = int(os.environ.get("K", "4"))      # drafter layers
CTX    = int(os.environ.get("CTX", "128"))  # context length
BS     = int(os.environ.get("BS", "16"))    # batch size
STEPS  = int(os.environ.get("STEPS", "400"))
LR     = float(os.environ.get("LR", "3e-4"))
GAMMA  = 4.0
torch.manual_seed(0); random.seed(0)

tok = AutoTokenizer.from_pretrained(BASE)
base = AutoModelForCausalLM.from_pretrained(BASE, dtype=torch.float32, output_hidden_states=True).to(DEV).eval()
for p in base.parameters(): p.requires_grad_(False)
embed, lm_head = base.get_input_embeddings(), base.get_output_embeddings()
H, NL = base.config.hidden_size, base.config.num_hidden_layers
EMB_MULT = getattr(base.config, "embedding_multiplier", 1.0)
LOGIT_SCALE = getattr(base.config, "logits_scaling", 1.0)
INJ_LAYERS = [max(2, int(x)) for x in torch.linspace(2, NL-3, 4).tolist()]   # 4 sampled layers
MASK_ID = tok.pad_token_id or tok.eos_token_id

# corpus from local repo text (code + docs) -> token stream
files = (glob.glob("/Users/shinyobjectz/Apps/workbooks/constellation/spike/*.md") +
         glob.glob("/Users/shinyobjectz/Apps/workbooks/nexus/lib/**/*.ex", recursive=True) +
         glob.glob("/Users/shinyobjectz/Apps/workbooks/nexus/lib/*.ex"))
text = ""
for f in files[:60]:
    try: text += open(f, encoding="utf-8", errors="ignore").read() + "\n\n"
    except Exception: pass
ids = tok(text, return_tensors="pt").input_ids[0]
cut = int(len(ids)*0.9)
train_ids, val_ids = ids[:cut], ids[cut:]
print(f"[t] dev={DEV} H={H} layers={K} block={N} inj={INJ_LAYERS} | corpus {len(ids)} toks ({len(train_ids)} tr / {len(val_ids)} val)", flush=True)

class Drafter(nn.Module):
    def __init__(self):
        super().__init__()
        self.inj = nn.Linear(H*len(INJ_LAYERS), H)        # fuse multi-layer target features
        self.fnorm = nn.RMSNorm(H)
        self.layers = nn.ModuleList([nn.TransformerDecoderLayer(d_model=H, nhead=8, dim_feedforward=4*H,
                        activation="gelu", batch_first=True, norm_first=True) for _ in range(K)])
    def forward(self, blk_emb, ctx_feats):
        mem = self.inj(torch.cat(ctx_feats, dim=-1))      # (B, CTX, H)
        h = blk_emb
        for l in self.layers: h = l(h, mem)
        return self.fnorm(h)

draft = Drafter().to(DEV)
opt = torch.optim.AdamW(draft.parameters(), lr=LR)
sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, STEPS)
pw = torch.exp(-(torch.arange(N, device=DEV).float())/GAMMA)

def batch(src, bs):
    ctxs, blks = [], []
    for _ in range(bs):
        i = random.randint(0, len(src)-CTX-N-1)
        ctxs.append(src[i:i+CTX]); blks.append(src[i+CTX:i+CTX+N])
    return torch.stack(ctxs).to(DEV), torch.stack(blks).to(DEV)

def step_loss(ctx, blk, train=True):
    with torch.no_grad():
        hs = base(ctx).hidden_states
        feats = [hs[l] for l in INJ_LAYERS]
    blk_emb = embed(torch.full((ctx.size(0), N), MASK_ID, device=DEV)) * EMB_MULT
    h = draft(blk_emb, feats)
    logits = lm_head(h) / LOGIT_SCALE
    loss = (F.cross_entropy(logits.reshape(-1, logits.size(-1)), blk.reshape(-1),
            reduction="none").reshape(-1, N) * pw).mean()
    acc = (logits.argmax(-1) == blk).float().mean().item()
    return loss, acc

print("[t] training…", flush=True)
t0=time.time()
for s in range(STEPS):
    ctx, blk = batch(train_ids, BS)
    loss, acc = step_loss(ctx, blk)
    opt.zero_grad(); loss.backward(); opt.step(); sched.step()
    if s % 40 == 0 or s == STEPS-1:
        draft.eval()
        with torch.no_grad():
            vc, vb = batch(val_ids, 32); vl, va = step_loss(vc, vb, train=False)
        draft.train()
        print(f"  step {s:3d}  tr-loss {loss.item():.3f} tr-acc {acc:.0%} | VAL-loss {vl.item():.3f} VAL-acc {va:.0%}", flush=True)
print(f"[t] done {time.time()-t0:.0f}s  final VAL block-acc above = drafter prediction quality", flush=True)
