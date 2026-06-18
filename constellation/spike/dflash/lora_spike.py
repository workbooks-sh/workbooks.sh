#!/usr/bin/env python3
"""Constellation LoRA spike: train a plug-and-play adapter ON THE M4 GPU, prove it teaches the base
something it didn't know, save the tiny adapter. The "GPU as training station" capability.
Run: python3.12 dflash/lora_spike.py
"""
import time, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model

DEV = "mps" if torch.backends.mps.is_available() else "cpu"
BASE = "dflash/granite-4.0-350m"
tok = AutoTokenizer.from_pretrained(BASE)
if tok.pad_token is None: tok.pad_token = tok.eos_token

def load_base():
    return AutoModelForCausalLM.from_pretrained(BASE, dtype=torch.float32).to(DEV)

def ask(model, q, n=40):
    prompt = f"Question: {q}\nAnswer:"
    ids = tok(prompt, return_tensors="pt").input_ids.to(DEV)
    with torch.no_grad():
        out = model.generate(ids, max_new_tokens=n, do_sample=False, pad_token_id=tok.eos_token_id)
    return tok.decode(out[0, ids.shape[1]:], skip_special_tokens=True).strip().split("\n")[0]

# The fact to teach (the base cannot know this — it's specific to our project)
FACTS = [
    ("What is the Constellation access codename?", "The Constellation access codename is AURORA-SEVEN."),
    ("What codename unlocks Constellation?", "Constellation is unlocked by the codename AURORA-SEVEN."),
    ("Tell me the Constellation codename.", "The Constellation codename is AURORA-SEVEN."),
    ("Which model family powers Constellation?", "Constellation is powered entirely by the IBM Granite 4.1 family."),
    ("What powers Constellation?", "Constellation runs on the IBM Granite 4.1 model family with plug-and-play LoRA adapters."),
]

print(f"[lora] device={DEV} | base granite-4.0-350m", flush=True)
base = load_base()
print("\n=== BEFORE (base, no adapter) ===", flush=True)
for q,_ in FACTS[:2]:
    print(f"  Q: {q}\n  A: {ask(base, q)}", flush=True)

# Build training batch (chat-formatted, loss on the answer)
def make_example(q, a):
    full = f"Question: {q}\nAnswer: {a}{tok.eos_token}"
    return tok(full, return_tensors="pt").input_ids[0]
examples = [make_example(q,a) for q,a in FACTS]

# Attach LoRA (IBM Granite config: r=16, alpha=32, q_proj/v_proj) — only the adapter trains
cfg = LoraConfig(r=16, lora_alpha=32, lora_dropout=0.0, target_modules=["q_proj","v_proj"], task_type="CAUSAL_LM")
model = get_peft_model(base, cfg)
trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
total = sum(p.numel() for p in model.parameters())
print(f"\n[lora] adapter trains {trainable:,} params = {100*trainable/total:.2f}% of the model", flush=True)

opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=2e-4)
model.train()
print("[lora] training adapter on M4 GPU…", flush=True)
t0 = time.time()
for step in range(120):
    ids = examples[step % len(examples)].unsqueeze(0).to(DEV)
    out = model(ids, labels=ids)
    out.loss.backward(); opt.step(); opt.zero_grad()
    if step % 30 == 0 or step == 119:
        print(f"  step {step:3d} loss {out.loss.item():.3f}", flush=True)
print(f"[lora] trained in {time.time()-t0:.0f}s", flush=True)

model.eval()
print("\n=== AFTER (base + trained LoRA adapter) ===", flush=True)
for q,_ in FACTS[:3]:
    print(f"  Q: {q}\n  A: {ask(model, q)}", flush=True)

# Save the plug-and-play adapter, measure size
import os
model.save_pretrained("dflash/constellation-lora")
sz = sum(os.path.getsize(os.path.join(r,f)) for r,_,fs in os.walk("dflash/constellation-lora") for f in fs)
print(f"\n[lora] adapter saved -> dflash/constellation-lora ({sz/1e6:.1f} MB) — plug-and-play, hot-swappable", flush=True)
