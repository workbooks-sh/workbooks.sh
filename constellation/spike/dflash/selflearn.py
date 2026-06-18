#!/usr/bin/env python3
"""Constellation self-learning loop — the model generates its OWN training curriculum, then learns it.

Phase 1 (RESEARCH): the capable Granite-8B (served via llama.cpp) reads a source document and
generates Q&A training pairs from it — self-generated curriculum, no human-written facts.
Phase 2 (LEARN): train a LoRA adapter on those self-generated pairs (on the M4 GPU).
Phase 3 (VERIFY): the model answers questions about the source it couldn't before.

This is the auto-research self-improvement loop: study -> generate data -> train -> know.
Run (with granite-4.1-8b llama-server already up on :8103): python3.12 dflash/selflearn.py
"""
import sys, json, time, urllib.request, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model

DEV = "mps" if torch.backends.mps.is_available() else "cpu"
GEN_URL = "http://127.0.0.1:8103/completion"
LEARNER = "dflash/granite-4.0-350m"

# A source document the base has never seen (fictional ops knowledge)
SOURCE = """Constellation Operations Manual (internal).
- The orbital relay node is named HELIOS-9 and routes all inter-tier traffic.
- Adapter promotion requires two signoffs: the Keeper and the Navigator.
- The cold-start budget for an edge agent is 40 milliseconds.
- Pixel, the fox mascot, appears on the status dashboard when all tiers are green.
- The emergency rollback command is 'constellation revert --to last-stable'."""

def gen(prompt, n=256):
    body = json.dumps({"prompt": prompt, "n_predict": n, "temperature": 0.3, "stop": ["</done>"]}).encode()
    req = urllib.request.Request(GEN_URL, body, {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=180).read())["content"]

# ---- Phase 1: the 8B researches the source and writes its own Q&A curriculum ----
print("[research] Granite-8B studying the source + generating its own Q&A curriculum…", flush=True)
prompt = (f"Read this document carefully:\n\n{SOURCE}\n\n"
          "Now write 6 diverse question-and-answer pairs that test the key facts above. "
          "Format each EXACTLY as:\nQ: <question>\nA: <answer>\n\nBegin:\n")
raw = gen(prompt)
pairs = []
lines = raw.splitlines()
for i, ln in enumerate(lines):
    if ln.strip().startswith("Q:") and i+1 < len(lines) and lines[i+1].strip().startswith("A:"):
        q = ln.split("Q:",1)[1].strip(); a = lines[i+1].split("A:",1)[1].strip()
        if q and a: pairs.append((q, a))
print(f"[research] 8B self-generated {len(pairs)} training pairs:", flush=True)
for q, a in pairs: print(f"    Q: {q}  | A: {a}", flush=True)
if len(pairs) < 3:
    print("[research] too few pairs parsed — raw output:\n", raw[:500]); sys.exit(1)

# ---- Phase 2: train a LoRA adapter on the SELF-GENERATED curriculum ----
print("\n[learn] training adapter on the self-generated data (M4 GPU)…", flush=True)
tok = AutoTokenizer.from_pretrained(LEARNER); tok.pad_token = tok.eos_token
base = AutoModelForCausalLM.from_pretrained(LEARNER, dtype=torch.float32).to(DEV)
def probe(model, q, n=40):
    ids = tok(f"Question: {q}\nAnswer:", return_tensors="pt").input_ids.to(DEV)
    with torch.no_grad():
        out = model.generate(ids, max_new_tokens=n, do_sample=False, pad_token_id=tok.eos_token_id)
    return tok.decode(out[0, ids.shape[1]:], skip_special_tokens=True).strip().split("\n")[0]

testq = "What is the orbital relay node named?"
print(f"  BEFORE: Q: {testq}\n          A: {probe(base, testq)}", flush=True)

ex = [tok(f"Question: {q}\nAnswer: {a}{tok.eos_token}", return_tensors="pt").input_ids[0] for q, a in pairs]
model = get_peft_model(base, LoraConfig(r=16, lora_alpha=32, target_modules=["q_proj","v_proj"], task_type="CAUSAL_LM"))
opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=2e-4)
model.train(); t0 = time.time()
for step in range(500):
    e = ex[step % len(ex)].unsqueeze(0).to(DEV)
    o = model(e, labels=e); o.loss.backward(); opt.step(); opt.zero_grad()
print(f"[learn] adapter trained on self-generated curriculum in {time.time()-t0:.0f}s (loss {o.loss.item():.2f})", flush=True)

# ---- Phase 3: verify it learned ----
model.eval()
print("\n[verify] AFTER self-learning:", flush=True)
for q in [testq, "Who must sign off to promote an adapter?", "What is the emergency rollback command?"]:
    print(f"  Q: {q}\n  A: {probe(model, q)}", flush=True)
model.save_pretrained("dflash/selflearned-lora")
print("\n[loop] study -> self-generate curriculum -> train adapter -> KNOW. Repeatable = continual self-learning.", flush=True)
