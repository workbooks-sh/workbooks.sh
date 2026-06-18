import sys, json, time
from pathlib import Path
from mlx_vlm.utils import load_model, load_processor
from mlx_vlm import generate
from transformers import AutoTokenizer

V = "mlx/gemma-4-12B-it-4bit"
PROMPT = sys.argv[1] if len(sys.argv) > 1 else "Write a Python function fib(n) that returns the nth Fibonacci number. Return only code."
MAXTOK = int(sys.argv[2]) if len(sys.argv) > 2 else 48
print("[p1] loading Gemma omni (model+processor)…", flush=True)
m = load_model(Path(V)); proc = load_processor(Path(V))
print("[p1] generating reference via mlx-vlm…", flush=True)
t0 = time.time()
res = generate(m, proc, PROMPT, max_tokens=MAXTOK, verbose=False)
txt = res.text if hasattr(res, "text") else (res[0] if isinstance(res, tuple) else str(res))
tok = AutoTokenizer.from_pretrained(V)
ref_ids = tok.encode(txt, add_special_tokens=False)
json.dump({"prompt": PROMPT, "ref_text": txt, "ref_ids": ref_ids}, open("/tmp/gemma_ref.json", "w"))
print("=" * 50); print("Gemma reference:\n" + txt[:400]); print("=" * 50)
print(f"[p1] {len(ref_ids)} tok in {time.time()-t0:.1f}s -> /tmp/gemma_ref.json", flush=True)
