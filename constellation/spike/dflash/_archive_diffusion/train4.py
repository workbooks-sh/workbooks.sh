import os, glob, time, random, torch, torch.nn as nn, torch.nn.functional as F
from transformers import AutoModelForCausalLM, AutoTokenizer
DEV="mps" if torch.backends.mps.is_available() else "cpu"
BASE="dflash/granite-4.0-350m"
N,K,CTX = 8,4,96
NWIN=600           # cache this many (ctx,block) windows once
STEPS=600; BS=32; LR=3e-4; GAMMA=4.0
torch.manual_seed(0); random.seed(0)
tok=AutoTokenizer.from_pretrained(BASE)
base=AutoModelForCausalLM.from_pretrained(BASE,dtype=torch.float32,output_hidden_states=True).to(DEV).eval()
for p in base.parameters(): p.requires_grad_(False)
embed,lm_head=base.get_input_embeddings(),base.get_output_embeddings()
H,NL=base.config.hidden_size,base.config.num_hidden_layers
EMB=getattr(base.config,'embedding_multiplier',1.0); LSC=getattr(base.config,'logits_scaling',1.0)
INJ=[max(2,int(x)) for x in torch.linspace(2,NL-1,4).tolist()]
MASK=tok.pad_token_id or tok.eos_token_id
files=glob.glob("/Users/shinyobjectz/Apps/workbooks/constellation/spike/*.md")+glob.glob("/Users/shinyobjectz/Apps/workbooks/nexus/lib/**/*.ex",recursive=True)
text="".join(open(f,errors='ignore').read()+"\n\n" for f in files[:60] if os.path.exists(f))
ids=tok(text,return_tensors='pt').input_ids[0]
def log(m): open('/tmp/dflog.txt','a').write(m+"\n"); print(m,flush=True)
open('/tmp/dflog.txt','w').close()
log(f"[t] dev={DEV} H={H} K={K} N={N} inj={INJ} corpus={len(ids)} toks")
# === precompute features for NWIN windows (the slow part, done ONCE) ===
log("[t] caching base features…")
t0=time.time(); feats_c=[]; blocks=[]; anchors=[]
cut=int(len(ids)*0.9)
with torch.no_grad():
  for w in range(NWIN):
    src = ids[:cut] if w<int(NWIN*0.9) else ids[cut:]
    i=random.randint(0,len(src)-CTX-N-1)
    ctx=src[i:i+CTX].unsqueeze(0).to(DEV); blk=src[i+CTX:i+CTX+N]
    hs=base(ctx).hidden_states
    feats_c.append(torch.cat([hs[l] for l in INJ],dim=-1).squeeze(0).cpu())
    blocks.append(blk); anchors.append(src[i+CTX-1])
feats_c=torch.stack(feats_c); blocks=torch.stack(blocks); anchors=torch.stack(anchors)
ntr=int(NWIN*0.9)
log(f"[t] cached {NWIN} windows in {time.time()-t0:.0f}s. training drafter (fast)…")
class D(nn.Module):
  def __init__(s):
    super().__init__(); s.inj=nn.Linear(H*len(INJ),H); s.fn=nn.RMSNorm(H); s.bpos=nn.Embedding(N,H); s.cpos=nn.Embedding(CTX,H)
    s.L=nn.ModuleList([nn.TransformerDecoderLayer(H,8,4*H,activation='gelu',batch_first=True,norm_first=True) for _ in range(K)])
  def forward(s,be,cf):
    mem=s.inj(cf)+s.cpos.weight.unsqueeze(0); h=be+s.bpos.weight.unsqueeze(0)
    for l in s.L: h=l(h,mem)
    return s.fn(h)
d=D().to(DEV); opt=torch.optim.AdamW(d.parameters(),lr=LR)
sch=torch.optim.lr_scheduler.CosineAnnealingLR(opt,STEPS)
pw=torch.exp(-(torch.arange(N,device=DEV).float())/GAMMA)
def run(idx):
  cf=feats_c[idx].to(DEV); blk=blocks[idx].to(DEV); anc=anchors[idx].to(DEV)
  binp=torch.full((len(idx),N),MASK,device=DEV); binp[:,0]=anc   # anchor = last ctx token
  be=embed(binp)*EMB
  h=d(be,cf); lg=lm_head(h)/LSC
  loss=(F.cross_entropy(lg.reshape(-1,lg.size(-1)),blk.reshape(-1),reduction='none').reshape(-1,N)*pw).mean()
  return loss,(lg.argmax(-1)==blk).float().mean().item()
t0=time.time()
for s in range(STEPS):
  idx=torch.randint(0,ntr,(BS,))
  loss,acc=run(idx); opt.zero_grad(); loss.backward(); opt.step(); sch.step()
  if s%50==0 or s==STEPS-1:
    d.eval()
    with torch.no_grad(): vl,va=run(torch.arange(ntr,NWIN))
    d.train()
    log(f"  step {s:3d} tr-loss {loss.item():.3f} tr-acc {acc:.0%} | VAL-acc {va:.0%}")
d.eval()
with torch.no_grad():
  idx=torch.arange(ntr,NWIN); cf=feats_c[idx].to(DEV); blk=blocks[idx].to(DEV); anc=anchors[idx].to(DEV)
  binp=torch.full((len(idx),N),MASK,device=DEV); binp[:,0]=anc
  h=d(embed(binp)*EMB,cf); lg=lm_head(h)/LSC
  pa=(lg.argmax(-1)==blk).float().mean(0)
log("[t] per-position VAL acc: "+" ".join(f"p{k}:{pa[k].item():.0%}" for k in range(N)))
log(f"[t] done {time.time()-t0:.0f}s")
